//
//  RepoVerifier.swift
//  ATProtoDrive
//

import CryptoKit
import Foundation
import Petrel
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
            return "Author signing key could not be parsed as a valid P-256 public key."
        case .invalidSpaceRef:
            return "Invalid space reference."
        case .missingVerificationMethod(let did):
            return "No suitable verification method found in DID document for \(did)."
        case .invalidMultikey(let key):
            return "Invalid multikey format: \(key)"
        }
    }
}

public enum RepoVerifier {
    /// Parses public key data in any standard P-256 encoding:
    /// - 33-byte compressed SEC1 (0x02/0x03 prefix)
    /// - 65-byte uncompressed X9.63 (0x04 prefix)
    /// - 64-byte raw (x || y)
    /// - 35-byte multicodec P-256 (0x80, 0x24 prefix + 33-byte compressed)
    /// - DER encoded
    public static func parseP256PublicKey(from data: Data) throws -> P256.Signing.PublicKey {
        if data.count == 33, let key = try? P256.Signing.PublicKey(compressedRepresentation: data) {
            return key
        }
        if data.count == 65, let key = try? P256.Signing.PublicKey(x963Representation: data) {
            return key
        }
        if data.count == 64, let key = try? P256.Signing.PublicKey(rawRepresentation: data) {
            return key
        }
        if data.count == 35 && data.prefix(2) == Data([0x80, 0x24]),
           let key = try? P256.Signing.PublicKey(compressedRepresentation: data.dropFirst(2)) {
            return key
        }
        if let key = try? P256.Signing.PublicKey(derRepresentation: data) {
            return key
        }
        if let key = try? P256.Signing.PublicKey(x963Representation: data) {
            return key
        }
        throw RepoVerifierError.invalidAuthorSigningKey
    }

    /// Verifies a permissioned repository CAR file using SwanSpaces.
    ///
    /// Reuses SwanSpaces recovery verification:
    /// 1. Verifies the signed commit envelope and its DPoP/IKM content binding.
    /// 2. Verifies the context signature using the author's P-256 public signing key.
    /// 3. Validates the DRISL index DAG-CBOR map and canonical order.
    /// 4. Validates every record block (canonical DAG-CBOR and content-addressed CID).
    /// 5. Verifies that the computed LtHash commitment across all indexed records matches the commit commitment.
    public static func verify(
        carData: Data,
        authorDID: String,
        space: SpaceRef,
        authorSigningKey: Data
    ) throws -> VerificationReport {
        let publicKey = try parseP256PublicKey(from: authorSigningKey)
        let spaceURI: SpaceURI
        do {
            spaceURI = try SpaceURI(authority: space.spaceDID, spaceType: space.spaceType, skey: space.skey)
        } catch {
            throw RepoVerifierError.invalidSpaceRef
        }

        // Parse CAR reader to inspect header & commit envelope
        let reader: CARReader
        do {
            reader = try CARReader(data: carData)
        } catch {
            return VerificationReport(outcome: .malformedCAR(error.localizedDescription), rev: "")
        }

        guard reader.roots.count == 2 else {
            return VerificationReport(
                outcome: .malformedCAR("Permissioned CAR must declare exactly two roots"),
                rev: ""
            )
        }

        let commitCID = reader.roots[0]
        let indexCID = reader.roots[1]

        guard let commitBlock = try? reader.rawBlockData(for: CARReader.cidHex(from: commitCID)) else {
            return VerificationReport(outcome: .malformedCAR("Missing commit block in CAR"), rev: "")
        }
        let envelope: SpaceCommitEnvelope
        do {
            envelope = try SpaceCARCodec.structurallyValidateRecoveryCommit(commitBlock, space: spaceURI, author: authorDID)
        } catch {
            return VerificationReport(
                outcome: .malformedCAR("Invalid commit envelope: \(error.localizedDescription)"),
                rev: ""
            )
        }

        let rev = envelope.context.rev
        let expectedCommitmentHex = Hex.encode(envelope.commitment)

        // Verify Context Signature and Content Binding
        guard let sigValid = try? SpaceCommitCodec.verifyContextSignature(envelope, publicKey: publicKey),
              sigValid,
              SpaceCommitCodec.verifyContentBinding(envelope) else {
            return VerificationReport(outcome: .signatureInvalid, rev: rev)
        }

        // Try direct high-level verification from SwanSpaces
        do {
            let recovery = try SpaceCARCodec.verifyRecovery(
                carData,
                space: spaceURI,
                author: authorDID,
                publicKey: publicKey
            )
            return VerificationReport(outcome: .verified(recordCount: recovery.records.count), rev: rev)
        } catch let swanError as SwanError {
            switch swanError {
            case .unauthorized:
                return VerificationReport(outcome: .signatureInvalid, rev: rev)
            case .malformed(let reason):
                if reason.contains("does not match commit") || reason.contains("block CID does not match body") || reason.contains("block order is invalid") || reason.contains("missing") {
                    let computed = computeLtHash(reader: reader, indexCID: indexCID)
                    return VerificationReport(
                        outcome: .hashMismatch(
                            expected: expectedCommitmentHex,
                            computed: computed.map { Hex.encode($0) } ?? "mismatch"
                        ),
                        rev: rev
                    )
                }
                return VerificationReport(outcome: .malformedCAR(reason), rev: rev)
            default:
                return VerificationReport(outcome: .malformedCAR(swanError.localizedDescription), rev: rev)
            }
        } catch {
            // Check if computing LtHash gives a mismatch
            if let computed = computeLtHash(reader: reader, indexCID: indexCID) {
                if !constantTimeEqual(envelope.commitment, computed) {
                    return VerificationReport(
                        outcome: .hashMismatch(
                            expected: expectedCommitmentHex,
                            computed: Hex.encode(computed)
                        ),
                        rev: rev
                    )
                }
            }
            return VerificationReport(outcome: .malformedCAR(error.localizedDescription), rev: rev)
        }
    }

    /// Computes LtHash over the indexed records in the CAR if index and record blocks are present.
    private static func computeLtHash(reader: CARReader, indexCID: CID) -> Data? {
        guard let indexBlock = try? reader.rawBlockData(for: CARReader.cidHex(from: indexCID)) else {
            return nil
        }
        guard let map = (try? decodeDAGCBORMap(indexBlock)) else {
            return nil
        }
        var setHash = LtHash()
        let sortedEntries = map.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for path in sortedEntries {
            guard let cidVal = map[path] as? CID else { return nil }
            if let blockData = try? reader.rawBlockData(for: CARReader.cidHex(from: cidVal)) {
                let actualCID = CID.fromDAGCBOR(blockData)
                setHash.add(element: "\(path)/\(actualCID.string)")
            } else {
                // If block is not present under expected CID, check if there's any block whose actual data matches or differs
                setHash.add(element: "\(path)/\(cidVal.string)")
            }
        }
        return setHash.commitment
    }
    private static func decodeDAGCBORMap(_ data: Data) throws -> [String: Any]? {
        let cid = CID.fromDAGCBOR(data)
        let header = OrderedCBORMap(entries: [
            (key: "roots", value: [ATProtoLink(cid: cid)]),
            (key: "version", value: 1),
        ])
        let headerData = try DAGCBOR.encodeValue(header)
        var singleBlockCAR = Data()
        appendVarint(headerData.count, to: &singleBlockCAR)
        singleBlockCAR.append(headerData)
        appendBlock(cid: cid, data: data, to: &singleBlockCAR)
        let reader = try CARReader(data: singleBlockCAR)
        return try reader.decodeBlock(for: CARReader.cidHex(from: cid)) as? [String: Any]
    }

    private static func appendBlock(cid: CID, data: Data, to output: inout Data) {
        appendVarint(cid.bytes.count + data.count, to: &output)
        output.append(cid.bytes)
        output.append(data)
    }

    private static func appendVarint(_ value: Int, to output: inout Data) {
        precondition(value >= 0)
        var remaining = UInt64(value)
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            output.append(byte)
        } while remaining != 0
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) {
            result |= x ^ y
        }
        return result == 0
    }
}

// MARK: - DID Document Key Extraction

extension RepoVerifier {
    /// Extracts the P-256 public signing key bytes from a DIDDocument.
    public static func extractSigningKey(from doc: DIDDocument) throws -> Data {
        let method = doc.verificationMethod.first {
            $0.id == "#atproto_space" || $0.id.hasSuffix("#atproto_space")
        } ?? doc.verificationMethod.first {
            $0.id == "#atproto" || $0.id.hasSuffix("#atproto")
        } ?? doc.verificationMethod.first

        guard let method = method else {
            throw RepoVerifierError.missingVerificationMethod(doc.id)
        }

        return try decodePublicKeyMultibase(method.publicKeyMultibase)
    }

    /// Decodes a multibase public key string (e.g. `zQ3sh...` or `zDna...`).
    public static func decodePublicKeyMultibase(_ multibase: String) throws -> Data {
        guard multibase.hasPrefix("z") else {
            throw RepoVerifierError.invalidMultikey(multibase)
        }
        let encoded = String(multibase.dropFirst())
        let decoded = try Base58BTC.decode(encoded)
        guard Base58BTC.encode(decoded) == encoded else {
            throw RepoVerifierError.invalidMultikey(multibase)
        }
        if decoded.count == 35 && decoded.prefix(2) == Data([0x80, 0x24]) {
            return Data(decoded.dropFirst(2))
        }
        return decoded
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
