import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum BlobPayloadError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedScope
    case invalidPDSURL(String)
    case invalidCID(cid: String, reason: String)
    case unsupportedCID(cid: String, reason: String)
    case cidDigestMismatch(cid: String, expectedSHA256: String, actualSHA256: String)
    case blobNotFound(cid: String)
    case httpError(statusCode: Int)
    case activeFormatDownloadOnly(mimeType: String)
    case transportError(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScope:
            return "Anonymous public blob downloads only support public repositories and never fall back across Space boundaries."
        case .invalidPDSURL(let raw):
            return "Invalid PDS URL for blob fetch: \(raw)"
        case .invalidCID(let cid, let reason):
            return "Invalid CID '\(cid)': \(reason)"
        case .unsupportedCID(let cid, let reason):
            return "Unsupported CID '\(cid)': \(reason)"
        case .cidDigestMismatch(let cid, let expected, let actual):
            return "CID verification failed for \(cid): expected SHA-256 \(expected.prefix(12))…, got \(actual.prefix(12))…."
        case .blobNotFound(let cid):
            return "Blob not found on the repository PDS (\(cid))."
        case .httpError(let statusCode):
            return "Blob fetch failed with HTTP status \(statusCode)."
        case .activeFormatDownloadOnly(let mimeType):
            return "Active web format (\(mimeType)) cannot be previewed directly. Use Download… to save it safely."
        case .transportError(let summary):
            return "Blob transport error: \(summary)"
        }
    }
}

public struct BlobPayloadResponse: Equatable, Sendable {
    public let data: Data
    public let contentType: String?

    public init(data: Data, contentType: String? = nil) {
        self.data = data
        self.contentType = contentType
    }
}

public struct BlobVerificationResult: Hashable, Sendable {
    public let cid: String
    public let sha256Hex: String
    public let byteCount: Int64
    public let state: BlobVerificationState

    public init(
        cid: String,
        sha256Hex: String,
        byteCount: Int64
    ) {
        self.cid = cid
        self.sha256Hex = sha256Hex
        self.byteCount = byteCount
        self.state = .hashVerified(sha256: sha256Hex)
    }
}

public struct VerifiedBlobPayload: Hashable, Sendable {
    public let locator: BlobLocator
    public let data: Data
    public let contentType: String?
    public let verification: BlobVerificationResult

    public init(
        locator: BlobLocator,
        data: Data,
        contentType: String?,
        verification: BlobVerificationResult
    ) {
        self.locator = locator
        self.data = data
        self.contentType = contentType
        self.verification = verification
    }
}

public struct BlobPreviewResult: Hashable, Sendable {
    public let locator: BlobLocator
    public let fileURL: URL
    public let contentType: String?
    public let verification: BlobVerificationResult

    public init(
        locator: BlobLocator,
        fileURL: URL,
        contentType: String?,
        verification: BlobVerificationResult
    ) {
        self.locator = locator
        self.fileURL = fileURL
        self.contentType = contentType
        self.verification = verification
    }
}

public struct BlobDownloadResult: Hashable, Sendable {
    public let locator: BlobLocator
    public let destinationURL: URL
    public let contentType: String?
    public let verification: BlobVerificationResult

    public init(
        locator: BlobLocator,
        destinationURL: URL,
        contentType: String?,
        verification: BlobVerificationResult
    ) {
        self.locator = locator
        self.destinationURL = destinationURL
        self.contentType = contentType
        self.verification = verification
    }
}

/// Injectable anonymous HTTP transport for public blob payloads.
public typealias BlobPayloadTransport = @Sendable (
    _ requestURL: URL,
    _ onProgress: @escaping @Sendable (Int64, Int64?) -> Void
) async throws -> BlobPayloadResponse

/// Anonymous public blob payload fetcher, CIDv1 SHA-256 verifier, qualified preview
/// materializer, and atomic security-scoped file downloader.
///
/// Security invariant: Always uses unauthenticated `com.atproto.sync.getBlob` on the
/// resolved target PDS and rejects `.permissionedSpace` locators before any transport call.
public actor BlobPayloadService {
    public static var defaultPreviewRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ATProtoDrive", isDirectory: true)
            .appendingPathComponent("PublicBlobPreviews", isDirectory: true)
    }

    private let transport: BlobPayloadTransport
    private let previewRootDirectory: URL

    public init(
        previewRootDirectory: URL = BlobPayloadService.defaultPreviewRootDirectory,
        transport: @escaping BlobPayloadTransport = BlobPayloadService.liveAnonymousTransport
    ) {
        self.previewRootDirectory = previewRootDirectory
        self.transport = transport
    }

    /// Unauthenticated ephemeral `URLSession` transport that sends zero OAuth tokens,
    /// zero cookies, and zero shared credentials.
    public static let liveAnonymousTransport: BlobPayloadTransport = { requestURL, onProgress in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false

        onProgress(0, nil)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BlobPayloadError.transportError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BlobPayloadError.transportError("Non-HTTP response from PDS")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                let cid = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "cid" })?
                    .value ?? "unknown"
                throw BlobPayloadError.blobNotFound(cid: cid)
            }
            throw BlobPayloadError.httpError(statusCode: httpResponse.statusCode)
        }

        onProgress(Int64(data.count), Int64(data.count))
        return BlobPayloadResponse(
            data: data,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
        )
    }

    /// Builds the canonical unauthenticated `com.atproto.sync.getBlob` endpoint URL on `pdsURL`.
    public static func buildPublicGetBlobURL(
        did: String,
        pdsURL: URL,
        cid: String
    ) throws -> URL {
        guard let scheme = pdsURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = pdsURL.host,
              !host.isEmpty,
              pdsURL.user == nil,
              pdsURL.password == nil,
              var components = URLComponents(url: pdsURL, resolvingAgainstBaseURL: false) else {
            throw BlobPayloadError.invalidPDSURL(pdsURL.absoluteString)
        }

        components.path = "/xrpc/com.atproto.sync.getBlob"
        components.queryItems = [
            URLQueryItem(name: "did", value: did),
            URLQueryItem(name: "cid", value: cid)
        ]
        components.fragment = nil

        guard let url = components.url else {
            throw BlobPayloadError.invalidPDSURL(pdsURL.absoluteString)
        }
        return url
    }

    /// Fetches a public blob anonymously and verifies its bytes against the expected CIDv1 SHA-256 digest.
    public func fetchVerifiedBlob(
        _ locator: BlobLocator,
        onProgress: (@Sendable (TransferState, Int64, Int64?) -> Void)? = nil
    ) async throws -> VerifiedBlobPayload {
        guard case .publicRepository(let did, let pdsURL) = locator.scope else {
            throw BlobPayloadError.unsupportedScope
        }

        let requestURL = try Self.buildPublicGetBlobURL(did: did, pdsURL: pdsURL, cid: locator.cid)
        try Task.checkCancellation()

        onProgress?(.running, 0, nil)
        let response = try await transport(requestURL) { completed, total in
            onProgress?(.running, completed, total)
        }
        try Task.checkCancellation()

        let byteCount = Int64(response.data.count)
        onProgress?(.verifying, byteCount, byteCount)
        let verification = try Self.verify(data: response.data, expectedCID: locator.cid)

        return VerifiedBlobPayload(
            locator: locator,
            data: response.data,
            contentType: Self.normalizedMIMEType(response.contentType),
            verification: verification
        )
    }

    /// Computes the qualified temp preview file path:
    /// `<previewRootDirectory>/<sanitizedDID>/<cid>.<ext>` (or `<cid>` when extension is unknown).
    public func previewFileURL(
        for locator: BlobLocator,
        mimeType: String?
    ) throws -> URL {
        guard case .publicRepository(let did, _) = locator.scope else {
            throw BlobPayloadError.unsupportedScope
        }
        let sanitizedDID = Self.sanitizedPathComponent(did)
        let sanitizedCID = Self.sanitizedPathComponent(locator.cid)
        let filename: String
        if let ext = Self.fileExtension(forMIMEType: mimeType), !ext.isEmpty {
            filename = "\(sanitizedCID).\(ext)"
        } else {
            filename = sanitizedCID
        }
        return previewRootDirectory
            .appendingPathComponent(sanitizedDID, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Fetches, CID-verifies, and atomically writes a public blob into the qualified preview directory.
    ///
    /// Active web formats (`text/html`, `application/xhtml+xml`, `image/svg+xml`) are rejected
    /// by default so previews never render untrusted active content.
    public func materializePreview(
        for locator: BlobLocator,
        mimeType: String? = nil,
        allowActiveFormats: Bool = false,
        onProgress: (@Sendable (TransferState, Int64, Int64?) -> Void)? = nil
    ) async throws -> BlobPreviewResult {
        guard case .publicRepository = locator.scope else {
            throw BlobPayloadError.unsupportedScope
        }

        let requestedMIME = Self.normalizedMIMEType(mimeType)
        if !allowActiveFormats,
           let requestedMIME,
           Self.isActiveDownloadOnlyFormat(mimeType: requestedMIME) {
            throw BlobPayloadError.activeFormatDownloadOnly(mimeType: requestedMIME)
        }

        let verified = try await fetchVerifiedBlob(locator, onProgress: onProgress)
        let effectiveMIME = requestedMIME ?? verified.contentType

        if !allowActiveFormats,
           let effectiveMIME,
           Self.isActiveDownloadOnlyFormat(mimeType: effectiveMIME) {
            throw BlobPayloadError.activeFormatDownloadOnly(mimeType: effectiveMIME)
        }

        let targetURL = try previewFileURL(for: locator, mimeType: effectiveMIME)
        let parentDirectory = targetURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try verified.data.write(to: targetURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)

        return BlobPreviewResult(
            locator: locator,
            fileURL: targetURL,
            contentType: effectiveMIME,
            verification: verified.verification
        )
    }

    /// Fetches, CID-verifies, and atomically writes a public blob to a user-selected `destinationURL`
    /// with balanced security-scoped resource access.
    public func downloadBlob(
        _ locator: BlobLocator,
        to destinationURL: URL,
        onProgress: (@Sendable (TransferState, Int64, Int64?) -> Void)? = nil
    ) async throws -> BlobDownloadResult {
        let verified = try await fetchVerifiedBlob(locator, onProgress: onProgress)
        try Self.writeVerifiedDataAtomically(verified.data, to: destinationURL)
        return BlobDownloadResult(
            locator: locator,
            destinationURL: destinationURL,
            contentType: verified.contentType,
            verification: verified.verification
        )
    }

    /// Atomically writes already-verified bytes to a user-selected URL while balancing
    /// App Sandbox security-scoped resource access.
    public static func writeVerifiedDataAtomically(
        _ data: Data,
        to destinationURL: URL
    ) throws {
        let didStartAccessing = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        let parentDirectory = destinationURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
        }
        try data.write(to: destinationURL, options: [.atomic])
    }

    /// Verifies raw blob bytes against a canonical lowercase base32 CIDv1 (`b...`)
    /// carrying a `raw` (`0x55`) codec and `sha2-256` (`0x12`, 32-byte) multihash.
    public static func verify(
        data: Data,
        expectedCID: String
    ) throws -> BlobVerificationResult {
        let expectedDigest = try extractRawSHA256Digest(from: expectedCID)
        let actualDigest = Data(CryptoKit.SHA256.hash(data: data))
        let expectedHex = hexString(expectedDigest)
        let actualHex = hexString(actualDigest)

        guard actualDigest == expectedDigest else {
            throw BlobPayloadError.cidDigestMismatch(
                cid: expectedCID,
                expectedSHA256: expectedHex,
                actualSHA256: actualHex
            )
        }

        return BlobVerificationResult(
            cid: expectedCID,
            sha256Hex: actualHex,
            byteCount: Int64(data.count)
        )
    }

    /// Extracts the 32-byte SHA-256 digest from a canonical base32 CIDv1 (`b...`) raw blob CID.
    public static func extractRawSHA256Digest(from cidString: String) throws -> Data {
        guard !cidString.isEmpty else {
            throw BlobPayloadError.invalidCID(cid: cidString, reason: "CID cannot be empty.")
        }
        if cidString.hasPrefix("Qm") {
            throw BlobPayloadError.unsupportedCID(
                cid: cidString,
                reason: "CIDv0 is not supported; expected base32 CIDv1 ('b...' prefix)."
            )
        }
        guard cidString.hasPrefix("b") else {
            throw BlobPayloadError.invalidCID(
                cid: cidString,
                reason: "Expected base32 multibase CIDv1 starting with 'b'."
            )
        }

        let base32Payload = String(cidString.dropFirst())
        guard !base32Payload.isEmpty else {
            throw BlobPayloadError.invalidCID(cid: cidString, reason: "CID payload is empty.")
        }

        let bytes = try decodeStrictBase32Lower(base32Payload, originalCID: cidString)
        var offset = 0

        let version = try decodeUnsignedVarint(bytes, offset: &offset, cid: cidString)
        guard version == 0x01 else {
            throw BlobPayloadError.unsupportedCID(
                cid: cidString,
                reason: "Unsupported CID version \(version); expected CIDv1."
            )
        }

        let codec = try decodeUnsignedVarint(bytes, offset: &offset, cid: cidString)
        guard codec == 0x55 else {
            throw BlobPayloadError.unsupportedCID(
                cid: cidString,
                reason: "Unsupported CID codec 0x\(String(codec, radix: 16)); expected raw (0x55)."
            )
        }

        let hashCode = try decodeUnsignedVarint(bytes, offset: &offset, cid: cidString)
        guard hashCode == 0x12 else {
            throw BlobPayloadError.unsupportedCID(
                cid: cidString,
                reason: "Unsupported multihash code 0x\(String(hashCode, radix: 16)); expected sha2-256 (0x12)."
            )
        }

        let digestLength = try decodeUnsignedVarint(bytes, offset: &offset, cid: cidString)
        guard digestLength == 32 else {
            throw BlobPayloadError.unsupportedCID(
                cid: cidString,
                reason: "Unsupported SHA-256 digest length \(digestLength); expected 32 bytes."
            )
        }

        guard bytes.count - offset == 32 else {
            throw BlobPayloadError.invalidCID(
                cid: cidString,
                reason: "CID multihash byte length does not match declared 32-byte digest."
            )
        }

        return Data(bytes[offset ..< (offset + 32)])
    }

    public static func isActiveDownloadOnlyFormat(mimeType: String?) -> Bool {
        guard let normalized = normalizedMIMEType(mimeType) else { return false }
        return normalized == "text/html"
            || normalized == "application/xhtml+xml"
            || normalized == "image/svg+xml"
    }

    public static func isInlinePreviewableImage(mimeType: String?) -> Bool {
        guard let normalized = normalizedMIMEType(mimeType),
              !isActiveDownloadOnlyFormat(mimeType: normalized) else {
            return false
        }
        if let utType = UTType(mimeType: normalized) {
            return utType.conforms(to: .image) && !utType.conforms(to: .svg)
        }
        return [
            "image/png",
            "image/jpeg",
            "image/jpg",
            "image/gif",
            "image/webp",
            "image/tiff",
            "image/bmp",
            "image/heic",
            "image/avif"
        ].contains(normalized)
    }

    public static func normalizedMIMEType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func fileExtension(forMIMEType mimeType: String?) -> String? {
        guard let normalized = normalizedMIMEType(mimeType) else { return nil }
        if let utType = UTType(mimeType: normalized),
           let ext = utType.preferredFilenameExtension {
            return ext
        }
        let fallbackMap: [String: String] = [
            "image/jpeg": "jpg",
            "image/jpg": "jpg",
            "image/png": "png",
            "image/gif": "gif",
            "image/webp": "webp",
            "image/svg+xml": "svg",
            "text/plain": "txt",
            "text/html": "html",
            "text/markdown": "md",
            "text/csv": "csv",
            "application/json": "json",
            "application/pdf": "pdf",
            "application/zip": "zip",
            "application/gzip": "gz",
            "application/octet-stream": "bin",
            "audio/mpeg": "mp3",
            "audio/wav": "wav",
            "audio/ogg": "ogg",
            "video/mp4": "mp4",
            "video/webm": "webm",
            "video/quicktime": "mov"
        ]
        return fallbackMap[normalized]
    }

    public static func sanitizedPathComponent(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            let isSafe = (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar == "_" || scalar == "-" || scalar == "."
            return isSafe ? Character(scalar) : "_"
        }
        let collapsed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return collapsed.isEmpty ? "unknown" : collapsed
    }

    private static func decodeStrictBase32Lower(
        _ encoded: String,
        originalCID: String
    ) throws -> [UInt8] {
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity((encoded.utf8.count * 5) / 8)

        for byte in encoded.utf8 {
            let value: UInt64
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"):
                value = UInt64(byte - UInt8(ascii: "a"))
            case UInt8(ascii: "2") ... UInt8(ascii: "7"):
                value = UInt64(byte - UInt8(ascii: "2")) + 26
            default:
                throw BlobPayloadError.invalidCID(
                    cid: originalCID,
                    reason: "Invalid base32 character in CID."
                )
            }

            bitBuffer = (bitBuffer << 5) | value
            bitCount += 5

            while bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((bitBuffer >> bitCount) & 0xFF))
            }
            if bitCount == 0 {
                bitBuffer = 0
            } else {
                bitBuffer &= (1 << bitCount) - 1
            }
        }

        if bitCount >= 5 {
            throw BlobPayloadError.invalidCID(
                cid: originalCID,
                reason: "Non-canonical base32 length."
            )
        }
        if bitCount > 0 && bitBuffer != 0 {
            throw BlobPayloadError.invalidCID(
                cid: originalCID,
                reason: "Non-zero base32 padding bits."
            )
        }

        return bytes
    }

    private static func decodeUnsignedVarint(
        _ bytes: [UInt8],
        offset: inout Int,
        cid: String
    ) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if shift >= 64 {
                throw BlobPayloadError.invalidCID(cid: cid, reason: "Varint overflow in CID.")
            }
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }

        throw BlobPayloadError.invalidCID(cid: cid, reason: "Truncated varint in CID.")
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
