import Foundation
import Petrel

public typealias DIDDocumentFetch = @Sendable (URL) async throws -> (
    statusCode: Int,
    data: Data?
)

public struct ResolvedPDSIdentity: Hashable, Sendable {
    public let did: String
    public let pdsURL: URL
    public let declaredHandle: String?

    public init(did: String, pdsURL: URL, declaredHandle: String? = nil) {
        self.did = did
        self.pdsURL = pdsURL
        self.declaredHandle = declaredHandle
    }
}

public protocol DIDDocumentPDSResolving: Sendable {
    func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity
    func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity
}

final class DIDFetchRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowLocalhostDevelopment: Bool
    private(set) var redirectFailure: Error?

    init(allowLocalhostDevelopment: Bool) {
        self.allowLocalhostDevelopment = allowLocalhostDevelopment
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = newRequest.url,
              DIDDocumentPDSResolver.validateFetchURL(
                  targetURL,
                  allowLocalhostDevelopment: allowLocalhostDevelopment
              )
        else {
            redirectFailure = BrowserFailure.transport("Redirect rejected by policy")
            completionHandler(nil)
            return
        }
        completionHandler(newRequest)
    }
}

public actor DIDDocumentPDSResolver: DIDDocumentPDSResolving {
    public static func validateHost(
        _ host: String,
        allowLocalhostDevelopment: Bool = false
    ) -> Bool {
        let lowercased = host.lowercased()
        if lowercased == "localhost" {
            return allowLocalhostDevelopment
        }

        if lowercased.hasPrefix(".") || lowercased.hasSuffix(".") {
            return false
        }

        let labels = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }

        let validHostnameChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else {
                return false
            }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else {
                return false
            }
            guard label.unicodeScalars.allSatisfy({ validHostnameChars.contains($0) }) else {
                return false
            }
        }

        let tld = String(labels.last!)
        let validTLDChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        guard tld.count >= 2, tld.unicodeScalars.allSatisfy({ validTLDChars.contains($0) }) else {
            return false
        }

        // Disallowed top-level domains (TLDs) per AT Protocol DID specification and RFCs:
        // - .local (RFC 6762 - multicast DNS / local network)
        // - .internal (private / internal networks)
        // - .alt (RFC 9476 - alternative resolution)
        // - .arpa (RFC 3172 - infrastructure)
        // - .onion (RFC 7686 - Tor hidden services)
        // - .test (RFC 2606 / 6761 - reserved for testing; rejected unless allowLocalhostDevelopment is true)
        let disallowedTLDs: Set<String> = [
            "local",
            "internal",
            "alt",
            "arpa",
            "onion"
        ]
        if disallowedTLDs.contains(tld) {
            return false
        }
        if tld == "test" && !allowLocalhostDevelopment {
            return false
        }

        return true
    }

    public static func validateFetchURL(
        _ url: URL,
        allowLocalhostDevelopment: Bool = false
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else {
            return false
        }

        guard validateHost(host, allowLocalhostDevelopment: allowLocalhostDevelopment) else {
            return false
        }

        if scheme == "https" {
            return true
        } else if scheme == "http" {
            return allowLocalhostDevelopment && host == "localhost"
        }

        return false
    }

    public static func makeLiveFetch(
        allowLocalhostDevelopment: Bool = false
    ) -> DIDDocumentFetch {
        return { url in
            guard validateFetchURL(url, allowLocalhostDevelopment: allowLocalhostDevelopment) else {
                throw BrowserFailure.transport("URL rejected by policy")
            }

            let config = URLSessionConfiguration.ephemeral
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            let session = URLSession(configuration: config)

            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 30

            let delegate = DIDFetchRedirectDelegate(
                allowLocalhostDevelopment: allowLocalhostDevelopment
            )

            do {
                let (asyncBytes, response) = try await session.bytes(for: request, delegate: delegate)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BrowserFailure.transport("Invalid HTTP response")
                }

                if let redirectError = delegate.redirectFailure {
                    throw redirectError
                }

                if (300 ... 399).contains(httpResponse.statusCode) {
                    throw BrowserFailure.transport("Redirect rejected by policy")
                }

                var data = Data()
                let maxBytes = 1024 * 1024 // 1 MiB limit enforced while streaming
                for try await byte in asyncBytes {
                    data.append(byte)
                    if data.count > maxBytes {
                        throw BrowserFailure.transport("DID document exceeded 1 MiB limit")
                    }
                }

                return (httpResponse.statusCode, data)
            } catch let failure as BrowserFailure {
                throw failure
            } catch {
                throw BrowserFailure.normalize(error)
            }
        }
    }

    public static let liveFetch: DIDDocumentFetch = makeLiveFetch(allowLocalhostDevelopment: false)

    private let fetchDocument: DIDDocumentFetch
    private let allowLocalhostDevelopment: Bool

    public init(
        fetchDocument: DIDDocumentFetch? = nil,
        allowLocalhostDevelopment: Bool = false
    ) {
        self.allowLocalhostDevelopment = allowLocalhostDevelopment
        self.fetchDocument = fetchDocument ?? Self.makeLiveFetch(allowLocalhostDevelopment: allowLocalhostDevelopment)
    }

    public static func documentURL(
        for did: String,
        allowLocalhostDevelopment: Bool = false
    ) throws -> URL {
        guard !did.isEmpty else {
            throw BrowserFailure.invalidIdentifier(did)
        }

        if did.hasPrefix("did:plc:") {
            let plcId = String(did.dropFirst("did:plc:".count))
            guard plcId.count == 24 else {
                throw BrowserFailure.invalidIdentifier(did)
            }
            let base32Alphabet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
            guard plcId.unicodeScalars.allSatisfy({ base32Alphabet.contains($0) }) else {
                throw BrowserFailure.invalidIdentifier(did)
            }
            guard let url = URL(string: "https://plc.directory/\(did)") else {
                throw BrowserFailure.invalidIdentifier(did)
            }
            return url
        }

        if did.hasPrefix("did:web:") {
            let methodSpecific = String(did.dropFirst("did:web:".count))
            guard !methodSpecific.isEmpty else {
                throw BrowserFailure.invalidIdentifier(did)
            }
            // AT Protocol rejects every path-form did:web (colons in method-specific part)
            if methodSpecific.contains(":") {
                throw BrowserFailure.invalidIdentifier(did)
            }

            guard let decoded = methodSpecific.removingPercentEncoding else {
                throw BrowserFailure.invalidIdentifier(did)
            }

            // Reject paths, queries, fragments, userInfo
            if decoded.contains("/") || decoded.contains("?") || decoded.contains("#") || decoded.contains("@") {
                throw BrowserFailure.invalidIdentifier(did)
            }

            if decoded.hasPrefix("localhost:") || decoded == "localhost" {
                guard allowLocalhostDevelopment else {
                    throw BrowserFailure.invalidIdentifier(did)
                }
                if decoded.hasPrefix("localhost:") {
                    let portString = String(decoded.dropFirst("localhost:".count))
                    guard let port = Int(portString), port > 0, port <= 65535 else {
                        throw BrowserFailure.invalidIdentifier(did)
                    }
                }
                guard let url = URL(string: "http://\(decoded)/.well-known/did.json") else {
                    throw BrowserFailure.invalidIdentifier(did)
                }
                return url
            } else {
                // Non-localhost cannot contain encoded port
                if decoded.contains(":") {
                    throw BrowserFailure.invalidIdentifier(did)
                }

                // Domain and TLD validation
                guard validateHost(decoded, allowLocalhostDevelopment: allowLocalhostDevelopment) else {
                    throw BrowserFailure.invalidIdentifier(did)
                }

                guard let url = URL(string: "https://\(decoded)/.well-known/did.json") else {
                    throw BrowserFailure.invalidIdentifier(did)
                }
                return url
            }
        }

        throw BrowserFailure.invalidIdentifier(did)
    }

    public static func canonicalPDSOrigin(
        from endpoint: String,
        allowLocalhostDevelopment: Bool = false
    ) throws -> URL {
        guard let components = URLComponents(string: endpoint) else {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        guard let scheme = components.scheme?.lowercased() else {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        // Host must exist and MUST NOT contain percent-encoding (reject percent-encoded host characters outright)
        guard let encodedHost = components.percentEncodedHost?.lowercased(),
              !encodedHost.isEmpty,
              !encodedHost.contains("%")
        else {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        // Scheme & host security validation
        if scheme == "http" {
            guard allowLocalhostDevelopment, encodedHost == "localhost" else {
                throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
            }
        } else if scheme == "https" {
            if encodedHost == "localhost" && !allowLocalhostDevelopment {
                throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
            }
        } else {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        // No userInfo, query, fragment
        if components.user != nil || components.password != nil ||
           components.percentEncodedUser != nil || components.percentEncodedPassword != nil ||
           components.query != nil || components.percentEncodedQuery != nil ||
           components.fragment != nil || components.percentEncodedFragment != nil {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        // No non-root path
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        // Canonicalize origin (lowercase scheme/host, drop default ports, normalize trailing slash)
        let originString: String
        if let port = components.port {
            guard (1 ... 65535).contains(port) else {
                throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
            }
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                originString = "\(scheme)://\(encodedHost)"
            } else {
                originString = "\(scheme)://\(encodedHost):\(port)"
            }
        } else {
            originString = "\(scheme)://\(encodedHost)"
        }

        guard let canonicalURL = URL(string: originString) else {
            throw BrowserFailure.invalidDIDDocument("PDS endpoint must be an allowed origin")
        }

        return canonicalURL
    }

    public static func canonicalPDSOrigin(
        from url: URL,
        allowLocalhostDevelopment: Bool = false
    ) throws -> URL {
        try canonicalPDSOrigin(from: url.absoluteString, allowLocalhostDevelopment: allowLocalhostDevelopment)
    }

    public static func validatedIdentity(
        from document: DIDDocument,
        expectedDID: String,
        allowLocalhostDevelopment: Bool = false
    ) throws -> ResolvedPDSIdentity {
        guard document.id == expectedDID else {
            throw BrowserFailure.identityMismatch(expected: expectedDID, actual: document.id)
        }

        // Find the first service whose resolved ID is exactly expectedDID + "#atproto_pds" (or relative "#atproto_pds")
        // and whose type is exactly "AtprotoPersonalDataServer"
        guard let pdsService = document.service.first(where: { service in
            let idMatches = service.id == "#atproto_pds" || service.id == "\(expectedDID)#atproto_pds"
            let typeMatches = service.type == "AtprotoPersonalDataServer"
            return idMatches && typeMatches
        }) else {
            throw BrowserFailure.invalidDIDDocument("Missing #atproto_pds service")
        }

        let canonicalPDSURL = try canonicalPDSOrigin(
            from: pdsService.serviceEndpoint,
            allowLocalhostDevelopment: allowLocalhostDevelopment
        )

        var declaredHandle: String? = nil
        for entry in document.alsoKnownAs {
            if entry.hasPrefix("at://") {
                let candidate = String(entry.dropFirst("at://".count))
                if (try? Handle(handleString: candidate)) != nil {
                    declaredHandle = candidate
                    break
                }
            }
        }

        return ResolvedPDSIdentity(
            did: expectedDID,
            pdsURL: canonicalPDSURL,
            declaredHandle: declaredHandle
        )
    }

    public func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity {
        try Self.validatedIdentity(
            from: document,
            expectedDID: expectedDID,
            allowLocalhostDevelopment: allowLocalhostDevelopment
        )
    }

    public func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity {
        let url = try Self.documentURL(for: did, allowLocalhostDevelopment: allowLocalhostDevelopment)
        let (statusCode, data) = try await fetchDocument(url)

        guard (200 ... 299).contains(statusCode) else {
            throw BrowserFailure.http(endpoint: url.absoluteString, statusCode: statusCode)
        }

        guard let data, !data.isEmpty else {
            throw BrowserFailure.decodeFailure(endpoint: url.absoluteString, statusCode: statusCode)
        }

        let document: DIDDocument
        do {
            document = try JSONDecoder().decode(DIDDocument.self, from: data)
        } catch {
            throw BrowserFailure.decodeFailure(endpoint: url.absoluteString, statusCode: statusCode)
        }

        return try Self.validatedIdentity(
            from: document,
            expectedDID: did,
            allowLocalhostDevelopment: allowLocalhostDevelopment
        )
    }
}
