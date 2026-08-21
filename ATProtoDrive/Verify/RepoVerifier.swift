//
//  RepoVerifier.swift
//  ATProtoDrive
//

import CryptoKit
import Foundation
import Petrel
import secp256k1
import SwanCore
import SwanSpaces

public struct VerificationReport: Sendable, Equatable, CustomStringConvertible {
    public enum Outcome: Sendable, Equatable, CustomStringConvertible {
        case verified(recordCount: Int)
        case signatureInvalid
        case hashMismatch(expected: String, computed: String)
        case malformedCAR(String)

        public var description: String {
            switch self {
            case .verified(let count):
                return "verified(recordCount: \(count))"
            case .signatureInvalid:
                return "signatureInvalid"
            case .hashMismatch(let expected, let computed):
                return "hashMismatch(expected: \(expected), computed: \(computed))"
            case .malformedCAR(let msg):
                return "malformedCAR(\(msg))"
            }
        }
    }

    public let outcome: Outcome
    public let rev: String

    public init(outcome: Outcome, rev: String) {
        self.outcome = outcome
        self.rev = rev
    }

    public var description: String {
        "VerificationReport(outcome: \(outcome), rev: \"\(rev)\")"
    }
}

public enum RepoVerifierError: LocalizedError, Equatable, Sendable {
    case invalidAuthorSigningKey
    case invalidSpaceRef
    case missingVerificationMethod(String)
    case invalidMultikey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorSigningKey:
            return "Author signing key could not be parsed as a valid P-256 or secp256k1 public key."
        case .invalidSpaceRef:
            return "Invalid space reference."
        case .missingVerificationMethod(let did):
            return "No suitable #atproto_space or #atproto verification method found in DID document for \(did)."
        case .invalidMultikey(let key):
            return "Invalid multikey format: \(key)"
        }
    }
}

public enum AuthorSigningKey: Sendable, Equatable {
    case p256(P256.Signing.PublicKey)
    case secp256k1PublicKey(Data)

    public static func == (lhs: AuthorSigningKey, rhs: AuthorSigningKey) -> Bool {
        switch (lhs, rhs) {
        case let (.p256(l), .p256(r)):
            return l.rawRepresentation == r.rawRepresentation
        case let (.secp256k1PublicKey(l), .secp256k1PublicKey(r)):
            return l == r
        default:
            return false
        }
    }

    public func verify(signature: Data, context: SpaceCommitContext) -> Bool {
        guard let signingInput = try? SpaceCommitCodec.contextSigningBytes(context) else {
            return false
        }
        switch self {
        case .p256(let publicKey):
            guard let canonicalSignature = try? P256WireSignature.decodeCanonical(signature) else {
                return false
            }
            return publicKey.isValidSignature(canonicalSignature, for: signingInput)
        case .secp256k1PublicKey(let keyBytes):
            do {
                let format: secp256k1.Format = (keyBytes.count == 33) ? .compressed : .uncompressed
                let publicKey = try secp256k1.Signing.PublicKey(dataRepresentation: keyBytes, format: format)
                let compact = try secp256k1.Signing.ECDSASignature(compactRepresentation: signature)
                return publicKey.isValidSignature(compact, for: signingInput)
            } catch {
                return false
            }
        }
    }
}

public enum RepoVerifier {
    /// Parses public key data in standard P-256 (ES256) or secp256k1 (ES256K) multicodec formats:
    /// - P-256: multicodec prefix `0x80 0x24` (35 bytes), compressed (33 bytes), uncompressed (65 bytes), raw (64 bytes), or DER
    /// - secp256k1: multicodec prefix `0xe7 0x01` (35 bytes), compressed (33 bytes), uncompressed (65 bytes)
    public static func parseSigningKey(from data: Data) throws -> AuthorSigningKey {
        // Multicodec P-256: prefix [0x80, 0x24] + 33 bytes
        if data.count == 35 && data.prefix(2) == Data([0x80, 0x24]) {
            if let key = try? P256.Signing.PublicKey(compressedRepresentation: data.dropFirst(2)) {
                return .p256(key)
            }
        }
        // Multicodec secp256k1: prefix [0xe7, 0x01] + 33 bytes
        if data.count == 35 && data.prefix(2) == Data([0xe7, 0x01]) {
            let point = Data(data.dropFirst(2))
            if (try? secp256k1.Signing.PublicKey(dataRepresentation: point, format: .compressed)) != nil {
                return .secp256k1PublicKey(point)
            }
        }
        // 33-byte compressed key
        if data.count == 33 {
            if let key = try? P256.Signing.PublicKey(compressedRepresentation: data) {
                return .p256(key)
            }
            if (try? secp256k1.Signing.PublicKey(dataRepresentation: data, format: .compressed)) != nil {
                return .secp256k1PublicKey(data)
            }
        }
        // 65-byte uncompressed key (0x04 prefix)
        if data.count == 65 {
            if let key = try? P256.Signing.PublicKey(x963Representation: data) {
                return .p256(key)
            }
            if (try? secp256k1.Signing.PublicKey(dataRepresentation: data, format: .uncompressed)) != nil {
                return .secp256k1PublicKey(data)
            }
        }
        // 64-byte raw P-256 key
        if data.count == 64, let key = try? P256.Signing.PublicKey(rawRepresentation: data) {
            return .p256(key)
        }
        // DER representation P-256
        if let key = try? P256.Signing.PublicKey(derRepresentation: data) {
            return .p256(key)
        }

        throw RepoVerifierError.invalidAuthorSigningKey
    }

    /// Verifies a permissioned repository CAR file using SwanSpaces' streaming verification API.
    ///
    /// Delegates strictly to `SpaceCARCodec.verifyStreamingRecovery`:
    /// 1. Bounded memory recovery streaming via `SpaceCARRecoveryByteSource`.
    /// 2. Bounded in-memory index staging via `SpaceCARRecoveryIndex` (O(1) lookups).
    /// 3. Validates commit context signature with ES256 (P-256) or ES256K (secp256k1).
    /// 4. Validates DPoP/IKM content binding, DRISL canonical index ordering, and record DAG-CBOR CIDs.
    /// 5. Validates LtHash homomorphic set commitment match.
    public static func verify(
        carData: Data,
        authorDID: String,
        space: SpaceRef,
        authorSigningKey: Data
    ) async throws -> VerificationReport {
        let signingKey = try parseSigningKey(from: authorSigningKey)
        let spaceURI: SpaceURI
        do {
            spaceURI = try SpaceURI(authority: space.spaceDID, spaceType: space.spaceType, skey: space.skey)
        } catch {
            throw RepoVerifierError.invalidSpaceRef
        }

        let byteSource = MemoryCARByteSource(data: carData)
        let recoveryIndex = InMemorySpaceRecoveryIndex()
        let sink = MemoryRecordSink()

        do {
            let result = try await SpaceCARCodec.verifyStreamingRecovery(
                from: byteSource,
                space: spaceURI,
                author: authorDID,
                contextSignatureVerifier: { envelope in
                    signingKey.verify(signature: envelope.contextSignature, context: envelope.context)
                },
                index: recoveryIndex,
                recordSink: sink
            )
            return VerificationReport(
                outcome: .verified(recordCount: result.recordCount),
                rev: result.wireRevision.toString()
            )
        } catch let streamingError as SpaceCARStreamingError {
            let commitBody = await sink.commitBody
            let envelope = commitBody.flatMap { try? SpaceCARCodec.structurallyValidateRecoveryCommit($0, space: spaceURI, author: authorDID) }
            let rev = envelope?.context.rev ?? (extractRevision(from: carData, space: spaceURI, author: authorDID) ?? "")

            switch streamingError {
            case .commitDidNotVerify:
                return VerificationReport(outcome: .signatureInvalid, rev: rev)
            case .commitmentMismatch:
                let expectedCommitment = envelope.map { Hex.encode($0.commitment) }
                    ?? (extractCommitInfo(from: carData, space: spaceURI, author: authorDID).commitment ?? "expected")
                let computedCommitment = await Hex.encode(recoveryIndex.ltHash.commitment)
                return VerificationReport(
                    outcome: .hashMismatch(
                        expected: expectedCommitment,
                        computed: computedCommitment
                    ),
                    rev: rev
                )
            default:
                return VerificationReport(
                    outcome: .malformedCAR(String(describing: streamingError)),
                    rev: rev
                )
            }
        } catch let swanError as SwanError {
            let rev = extractRevision(from: carData, space: spaceURI, author: authorDID) ?? ""
            switch swanError {
            case .unauthorized:
                return VerificationReport(outcome: .signatureInvalid, rev: rev)
            case .malformed(let reason):
                return VerificationReport(outcome: .malformedCAR(reason), rev: rev)
            default:
                return VerificationReport(outcome: .malformedCAR(swanError.localizedDescription), rev: rev)
            }
        } catch {
            let rev = extractRevision(from: carData, space: spaceURI, author: authorDID) ?? ""
            return VerificationReport(outcome: .malformedCAR(error.localizedDescription), rev: rev)
        }
    }

    /// Helper to extract commit revision and commitment from the first CAR frame for reporting on early stream failures.
    private static func extractCommitInfo(from carData: Data, space: SpaceURI, author: String) -> (rev: String?, commitment: String?) {
        guard let reader = try? CARReader(data: carData), reader.roots.count >= 1 else {
            return (nil, nil)
        }
        guard let commitBlock = try? reader.rawBlockData(for: CARReader.cidHex(from: reader.roots[0])) else {
            return (nil, nil)
        }
        guard let envelope = try? SpaceCARCodec.structurallyValidateRecoveryCommit(commitBlock, space: space, author: author) else {
            return (nil, nil)
        }
        return (envelope.context.rev, Hex.encode(envelope.commitment))
    }

    private static func extractRevision(from carData: Data, space: SpaceURI, author: String) -> String? {
        extractCommitInfo(from: carData, space: space, author: author).rev
    }
}

// MARK: - Strict DID Document Key Extraction

extension RepoVerifier {
    /// Extracts the public signing key bytes from a DIDDocument.
    /// Requires an exact `#atproto_space` or `#atproto` method belonging to `doc.id`; no other fallback.
    public static func extractSigningKey(from doc: DIDDocument) throws -> Data {
        let method = doc.verificationMethod.first {
            $0.id == "#atproto_space" || $0.id == "\(doc.id)#atproto_space"
        } ?? doc.verificationMethod.first {
            $0.id == "#atproto" || $0.id == "\(doc.id)#atproto"
        }

        guard let method = method else {
            throw RepoVerifierError.missingVerificationMethod(doc.id)
        }

        return try decodePublicKeyMultibase(method.publicKeyMultibase)
    }

    /// Decodes a multibase public key string (e.g. `did:key:z...` or `z...`).
    public static func decodePublicKeyMultibase(_ multibase: String) throws -> Data {
        let clean = multibase.hasPrefix("did:key:") ? String(multibase.dropFirst("did:key:".count)) : multibase
        guard clean.hasPrefix("z") else {
            throw RepoVerifierError.invalidMultikey(multibase)
        }
        let encoded = String(clean.dropFirst())
        let decoded = try Base58BTC.decode(encoded)
        guard Base58BTC.encode(decoded) == encoded else {
            throw RepoVerifierError.invalidMultikey(multibase)
        }
        return decoded
    }
}

// MARK: - Streaming Recovery Byte Source, Sink & Keyed Index

/// Bounded in-memory pull source conforming to SwanSpaces' `SpaceCARRecoveryByteSource`.
actor MemoryCARByteSource: SpaceCARRecoveryByteSource {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    func read(maximumBytes: Int) async throws -> Data? {
        guard offset < data.count else { return nil }
        let count = min(maximumBytes, data.count - offset)
        let chunk = data.subdata(in: offset ..< (offset + count))
        offset += count
        return chunk
    }
}

/// Sink to capture commit block from stream for error classification.
actor MemoryRecordSink: SpaceCARRecoveryRecordSink {
    var commitCID: CID?
    var commitBody: Data?

    func receiveRoots(commit: CID, index: CID) async throws {}

    func receiveCommit(cid: CID, body: Data) async throws {
        self.commitCID = cid
        self.commitBody = body
    }

    func beginRecord(cid: CID, byteCount: Int) async throws {}
    func appendRecordChunk(cid: CID, chunkIndex: Int, bytes: Data) async throws {}
    func completeRecord(cid: CID, byteCount: Int, chunkCount: Int) async throws {}
}

/// Linear-time in-memory DRISL index conforming to SwanSpaces' `SpaceCARRecoveryIndex`.
///
/// Uses O(1) keyed lookups for insertions, CID-to-path index, and a forward cursor over
/// a lazily sorted path list to ensure high performance even for 100,000+ repository records.
actor InMemorySpaceRecoveryIndex: SpaceCARRecoveryIndex {
    private var seenPaths = Set<String>()
    private var entriesByPath: [String: SpaceCARRecoveryIndexEntry] = [:]
    private var pathsByCID: [CID: [String]] = [:]
    private var consumedPaths = Set<String>()
    private var sortedPaths: [String]? = nil
    private var cursor: Int = 0
    private(set) var ltHash = LtHash()

    func insert(_ entry: SpaceCARRecoveryIndexEntry) throws {
        guard seenPaths.insert(entry.path).inserted else {
            throw SpaceCARStreamingError.duplicateIndexEntry
        }
        entriesByPath[entry.path] = entry
        pathsByCID[entry.cid, default: []].append(entry.path)
        ltHash.add(element: "\(entry.path)/\(entry.cid.string)")
        sortedPaths = nil
    }

    func nextUnconsumedLexicographicEntry() -> SpaceCARRecoveryIndexEntry? {
        if sortedPaths == nil {
            sortedPaths = entriesByPath.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            cursor = 0
        }
        guard let sorted = sortedPaths else { return nil }
        while cursor < sorted.count {
            let path = sorted[cursor]
            if !consumedPaths.contains(path) {
                return entriesByPath[path]
            }
            cursor += 1
        }
        return nil
    }

    func consumeEntries(forCID cid: CID) throws -> Int {
        guard let paths = pathsByCID[cid] else {
            throw SpaceCARStreamingError.invalidRecordOrder
        }
        var count = 0
        for path in paths {
            if consumedPaths.insert(path).inserted {
                count += 1
            }
        }
        guard count > 0 else {
            throw SpaceCARStreamingError.invalidRecordOrder
        }
        return count
    }
}

// MARK: - Base58BTC Implementation

private enum Base58BTC {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let lookup: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })

    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var digits = [UInt8](repeating: 0, count: data.count * 138 / 100 + 1)
        var digitLength = 1
        for byte in data {
            var carry = Int(byte)
            for index in 0 ..< digitLength {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits[digitLength] = UInt8(carry % 58)
                digitLength += 1
                carry /= 58
            }
        }
        let leadingZeros = data.prefix { $0 == 0 }.count
        var output = [UInt8](repeating: alphabet[0], count: leadingZeros)
        output.append(contentsOf: digits[..<digitLength].reversed().map { alphabet[Int($0)] })
        return String(decoding: output, as: UTF8.self)
    }

    static func decode(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 256 else {
            throw RepoVerifierError.invalidMultikey(value)
        }
        var output = [UInt8](repeating: 0, count: bytes.count * 733 / 1_000 + 1)
        var outputLength = 1
        for byte in bytes {
            guard let digit = lookup[byte] else {
                throw RepoVerifierError.invalidMultikey(value)
            }
            var carry = digit
            for index in 0 ..< outputLength {
                carry += Int(output[index]) * 58
                output[index] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                output[outputLength] = UInt8(carry & 0xff)
                outputLength += 1
                carry >>= 8
            }
        }
        let leadingZeros = bytes.prefix { $0 == alphabet[0] }.count
        return Data(repeating: 0, count: leadingZeros) + Data(output[..<outputLength].reversed())
    }
}
