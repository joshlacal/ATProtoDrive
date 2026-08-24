import Foundation
import Testing
import Petrel
@testable import ATProtoDrive

private let fixtureDID = "did:plc:4hqjfn7m6n5hno3doamuhgef"

@Suite("DID document PDS resolver")
struct DIDDocumentPDSResolverTests {
    @Test(arguments: [
        ("did:plc:4hqjfn7m6n5hno3doamuhgef", "https://plc.directory/did:plc:4hqjfn7m6n5hno3doamuhgef"),
        ("did:web:identity.example", "https://identity.example/.well-known/did.json"),
        ("did:web:sub.domain.example.com", "https://sub.domain.example.com/.well-known/did.json")
    ])
    func constructsATProtoResolutionURLs(did: String, expectedURL: String) throws {
        #expect(try DIDDocumentPDSResolver.documentURL(for: did).absoluteString == expectedURL)
    }

    @Test(arguments: [
        "did:web:identity.example:users:alice",
        "did:web:identity.example%3A8443",
        "did:web:localhost%3A2582",
        "did:web:localhost",
        "did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuBV8xRoAnwWsdvktH",
        "did:ion:12345",
        "did:plc:short",
        "did:plc:4hqjfn7m6n5hno3doamuhgef!@#",
        "did:web:bad/path",
        "did:web:user@host.com",
        ""
    ])
    func rejectsPathsNonLocalPortsAndProductionLocalhost(did: String) {
        #expect(throws: BrowserFailure.self) {
            _ = try DIDDocumentPDSResolver.documentURL(for: did)
        }
    }

    @Test(arguments: [
        "did:web:node.local",
        "did:web:auth.internal",
        "did:web:mesh.alt",
        "did:web:router.in-addr.arpa",
        "did:web:hidden.onion",
        "did:web:identity.test",
        "did:web:singlename",
        "did:web:bad..domain",
        "did:web:example.",
        "did:web:.example.com",
        "did:web:-example.com",
        "did:web:example-.com"
    ])
    func rejectsDisallowedTLDsAndMalformedDomains(did: String) {
        #expect(throws: BrowserFailure.self) {
            _ = try DIDDocumentPDSResolver.documentURL(for: did, allowLocalhostDevelopment: false)
        }
    }

    @Test("dot-test TLD is allowed in localhost-development mode")
    func dotTestTLDInDevelopmentMode() throws {
        let url = try DIDDocumentPDSResolver.documentURL(
            for: "did:web:identity.test",
            allowLocalhostDevelopment: true
        )
        #expect(url.absoluteString == "https://identity.test/.well-known/did.json")
    }

    @Test("localhost encoded ports require explicit development policy")
    func localhostDevelopmentResolution() throws {
        let url = try DIDDocumentPDSResolver.documentURL(
            for: "did:web:localhost%3A2582",
            allowLocalhostDevelopment: true
        )
        #expect(url.absoluteString == "http://localhost:2582/.well-known/did.json")

        let bareLocalhost = try DIDDocumentPDSResolver.documentURL(
            for: "did:web:localhost",
            allowLocalhostDevelopment: true
        )
        #expect(bareLocalhost.absoluteString == "http://localhost/.well-known/did.json")
    }

    @Test("a document needs no handle to resolve its secure PDS")
    func noHandleRequired() async throws {
        let resolver = DIDDocumentPDSResolver(fetchDocument: { url in
            #expect(url.absoluteString.contains("plc.directory"))
            return (200, Data(##"{"id":"did:plc:4hqjfn7m6n5hno3doamuhgef","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://alice.example"}]}"##.utf8))
        })
        let result = try await resolver.resolvePDS(for: fixtureDID)
        #expect(result.did == fixtureDID)
        #expect(result.pdsURL == URL(string: "https://alice.example")!)
        #expect(result.declaredHandle == nil)
    }

    @Test("document with alsoKnownAs handle extracts valid handle")
    func handleExtraction() async throws {
        let resolver = DIDDocumentPDSResolver(fetchDocument: { _ in
            return (200, Data(##"{"id":"did:plc:4hqjfn7m6n5hno3doamuhgef","alsoKnownAs":["invalid-entry","at://alice.test.blue","at://second.test.blue"],"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://alice.example"}]}"##.utf8))
        })
        let result = try await resolver.resolvePDS(for: fixtureDID)
        #expect(result.declaredHandle == "alice.test.blue")
    }

    @Test("identity mismatch and wrong service are rejected")
    func rejectsUntrustedDocuments() async throws {
        func encoded(_ document: DIDDocument) throws -> Data {
            try JSONEncoder().encode(document)
        }

        let wrongID = try encoded(.init(
            id: "did:plc:z72i7hdynmk6r22z27h6tvur",
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://alice.example"
            )]
        ))
        let wrongIDResolver = DIDDocumentPDSResolver(fetchDocument: { _ in (200, wrongID) })
        await #expect(throws: BrowserFailure.identityMismatch(
            expected: fixtureDID,
            actual: "did:plc:z72i7hdynmk6r22z27h6tvur"
        )) {
            _ = try await wrongIDResolver.resolvePDS(for: fixtureDID)
        }

        let spaceHostOnly = try encoded(.init(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_space_host",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://space.example"
            )]
        ))
        let spaceHostResolver = DIDDocumentPDSResolver(fetchDocument: { _ in (200, spaceHostOnly) })
        await #expect(throws: BrowserFailure.invalidDIDDocument("Missing #atproto_pds service")) {
            _ = try await spaceHostResolver.resolvePDS(for: fixtureDID)
        }
    }

    @Test("fully qualified service id is accepted")
    func fullyQualifiedServiceID() async throws {
        let resolver = DIDDocumentPDSResolver(fetchDocument: { _ in
            return (200, Data(##"{"id":"did:plc:4hqjfn7m6n5hno3doamuhgef","service":[{"id":"did:plc:4hqjfn7m6n5hno3doamuhgef#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://alice.example"}]}"##.utf8))
        })
        let result = try await resolver.resolvePDS(for: fixtureDID)
        #expect(result.pdsURL == URL(string: "https://alice.example")!)
    }

    @Test(arguments: [
        "http://alice.example",
        "https://alice.example/xrpc",
        "https://alice.example?token=secret",
        "https://alice.example#fragment",
        "https://user:password@alice.example",
        "http://localhost:2583",
        "https://alice.example%2Fevil",
        "https://alice.example%3A8443",
        "https://alice.example%23fragment",
        "https://%61lice.example"
    ])
    func rejectsNonOriginOrProductionHTTPPDSEndpoints(endpoint: String) throws {
        let document = DIDDocument(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: endpoint
            )]
        )
        #expect(throws: BrowserFailure.invalidDIDDocument(
            "PDS endpoint must be an allowed origin"
        )) {
            _ = try DIDDocumentPDSResolver.validatedIdentity(
                from: document,
                expectedDID: fixtureDID
            )
        }
    }

    @Test("localhost HTTP PDS origin requires explicit development policy")
    func localhostDevelopmentPDS() throws {
        let document = DIDDocument(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "http://localhost:2583"
            )]
        )
        let identity = try DIDDocumentPDSResolver.validatedIdentity(
            from: document,
            expectedDID: fixtureDID,
            allowLocalhostDevelopment: true
        )
        #expect(identity.pdsURL.absoluteString == "http://localhost:2583")
    }

    @Test("canonicalizes origin dropping default ports and trailing slash")
    func canonicalizesOrigin() throws {
        let document = DIDDocument(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://ALICE.EXAMPLE:443/"
            )]
        )
        let identity = try DIDDocumentPDSResolver.validatedIdentity(
            from: document,
            expectedDID: fixtureDID
        )
        #expect(identity.pdsURL.absoluteString == "https://alice.example")

        // Direct canonicalPDSOrigin tests
        let withSlash = try DIDDocumentPDSResolver.canonicalPDSOrigin(from: "https://alice.example/")
        let withoutSlash = try DIDDocumentPDSResolver.canonicalPDSOrigin(from: "https://alice.example")
        #expect(withSlash == withoutSlash)
        #expect(withSlash.absoluteString == "https://alice.example")

        let nonDefaultPort = try DIDDocumentPDSResolver.canonicalPDSOrigin(from: "https://alice.example:8443/")
        #expect(nonDefaultPort.absoluteString == "https://alice.example:8443")

        let devLocalhost = try DIDDocumentPDSResolver.canonicalPDSOrigin(
            from: "http://localhost:2583/",
            allowLocalhostDevelopment: true
        )
        #expect(devLocalhost.absoluteString == "http://localhost:2583")
    }

    @Test("validateFetchURL enforces HTTPS, host policy, and localhost development policy")
    func fetchURLValidation() {
        #expect(DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://plc.directory/did:plc:123")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "http://plc.directory/did:plc:123")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://localhost/.well-known/did.json")!, allowLocalhostDevelopment: false))
        #expect(DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://localhost/.well-known/did.json")!, allowLocalhostDevelopment: true))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "http://localhost:2582/.well-known/did.json")!, allowLocalhostDevelopment: false))
        #expect(DIDDocumentPDSResolver.validateFetchURL(URL(string: "http://localhost:2582/.well-known/did.json")!, allowLocalhostDevelopment: true))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://user:pass@plc.directory/did")!))

        // Redirect hop URLs must respect the shared host policy and reject blocked TLDs/bare IPs
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://node.local/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://auth.internal/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://mesh.alt/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://router.in-addr.arpa/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://hidden.onion/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://identity.test/did.json")!, allowLocalhostDevelopment: false))
        #expect(DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://identity.test/did.json")!, allowLocalhostDevelopment: true))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://192.168.1.1/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://127.0.0.1/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://singlename/did.json")!))
        #expect(!DIDDocumentPDSResolver.validateFetchURL(URL(string: "https://bad..domain.com/did.json")!))
    }

    @Test("validateHost checks label structure, disallowed TLDs, and bare IPs")
    func validateHostPolicy() {
        #expect(DIDDocumentPDSResolver.validateHost("plc.directory"))
        #expect(DIDDocumentPDSResolver.validateHost("identity.example"))
        #expect(DIDDocumentPDSResolver.validateHost("sub.domain.example.com"))
        #expect(!DIDDocumentPDSResolver.validateHost("localhost", allowLocalhostDevelopment: false))
        #expect(DIDDocumentPDSResolver.validateHost("localhost", allowLocalhostDevelopment: true))
        #expect(!DIDDocumentPDSResolver.validateHost("auth.internal"))
        #expect(!DIDDocumentPDSResolver.validateHost("node.local"))
        #expect(!DIDDocumentPDSResolver.validateHost("hidden.onion"))
        #expect(!DIDDocumentPDSResolver.validateHost("mesh.alt"))
        #expect(!DIDDocumentPDSResolver.validateHost("router.in-addr.arpa"))
        #expect(!DIDDocumentPDSResolver.validateHost("identity.test", allowLocalhostDevelopment: false))
        #expect(DIDDocumentPDSResolver.validateHost("identity.test", allowLocalhostDevelopment: true))
        #expect(!DIDDocumentPDSResolver.validateHost("192.168.1.1"))
        #expect(!DIDDocumentPDSResolver.validateHost("127.0.0.1"))
        #expect(!DIDDocumentPDSResolver.validateHost("singlename"))
        #expect(!DIDDocumentPDSResolver.validateHost("bad..domain.com"))
    }

    @Test("dev-mode resolver derives default fetch from allowLocalhostDevelopment")
    func devModeDefaultFetchDerivation() async {
        let resolver = DIDDocumentPDSResolver(allowLocalhostDevelopment: true)
        let localhostDID = "did:web:localhost%3A2582"

        do {
            _ = try await resolver.resolvePDS(for: localhostDID)
        } catch let failure as BrowserFailure {
            if case .transport(let message) = failure {
                #expect(message != "URL rejected by policy")
            }
        } catch {}
    }

    @Test("DIDFetchRedirectDelegate refuses invalid redirect targets")
    func redirectDelegateValidation() async {
        let prodDelegate = DIDFetchRedirectDelegate(allowLocalhostDevelopment: false)
        let session = URLSession.shared
        let dummyTask = session.dataTask(with: URL(string: "https://plc.directory")!)
        let dummyResponse = HTTPURLResponse(
            url: URL(string: "https://plc.directory")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!

        // Reject HTTP redirect target in production
        let insecureRequest = URLRequest(url: URL(string: "http://evil.com/did.json")!)
        await withCheckedContinuation { continuation in
            prodDelegate.urlSession(
                session,
                task: dummyTask,
                willPerformHTTPRedirection: dummyResponse,
                newRequest: insecureRequest
            ) { request in
                #expect(request == nil)
                #expect(prodDelegate.redirectFailure != nil)
                continuation.resume()
            }
        }

        // Reject redirect target to disallowed TLD (.internal)
        let internalRequest = URLRequest(url: URL(string: "https://auth.internal/did.json")!)
        await withCheckedContinuation { continuation in
            prodDelegate.urlSession(
                session,
                task: dummyTask,
                willPerformHTTPRedirection: dummyResponse,
                newRequest: internalRequest
            ) { request in
                #expect(request == nil)
                #expect(prodDelegate.redirectFailure != nil)
                continuation.resume()
            }
        }

        // Reject redirect target to bare IP address
        let ipRequest = URLRequest(url: URL(string: "https://192.168.1.1/did.json")!)
        await withCheckedContinuation { continuation in
            prodDelegate.urlSession(
                session,
                task: dummyTask,
                willPerformHTTPRedirection: dummyResponse,
                newRequest: ipRequest
            ) { request in
                #expect(request == nil)
                #expect(prodDelegate.redirectFailure != nil)
                continuation.resume()
            }
        }

        // Allow HTTPS redirect target
        let secureRequest = URLRequest(url: URL(string: "https://redirected.example/.well-known/did.json")!)
        let devDelegate = DIDFetchRedirectDelegate(allowLocalhostDevelopment: true)
        await withCheckedContinuation { continuation in
            devDelegate.urlSession(
                session,
                task: dummyTask,
                willPerformHTTPRedirection: dummyResponse,
                newRequest: secureRequest
            ) { request in
                #expect(request != nil)
                #expect(devDelegate.redirectFailure == nil)
                continuation.resume()
            }
        }
    }

    @Test(arguments: [199, 300, 401, 404, 429, 503])
    func fetchDocumentStatusErrors(statusCode: Int) async {
        let resolver = DIDDocumentPDSResolver(fetchDocument: { _ in
            (statusCode, Data())
        })
        await #expect(throws: BrowserFailure.http(
            endpoint: "https://plc.directory/\(fixtureDID)",
            statusCode: statusCode
        )) {
            _ = try await resolver.resolvePDS(for: fixtureDID)
        }
    }

    @Test("fetch document decode failure on empty or malformed data")
    func fetchDocumentDecodeFailure() async {
        let emptyResolver = DIDDocumentPDSResolver(fetchDocument: { _ in
            (200, Data())
        })
        await #expect(throws: BrowserFailure.decodeFailure(
            endpoint: "https://plc.directory/\(fixtureDID)",
            statusCode: 200
        )) {
            _ = try await emptyResolver.resolvePDS(for: fixtureDID)
        }

        let malformedResolver = DIDDocumentPDSResolver(fetchDocument: { _ in
            (200, Data("not json".utf8))
        })
        await #expect(throws: BrowserFailure.decodeFailure(
            endpoint: "https://plc.directory/\(fixtureDID)",
            statusCode: 200
        )) {
            _ = try await malformedResolver.resolvePDS(for: fixtureDID)
        }
    }
}
