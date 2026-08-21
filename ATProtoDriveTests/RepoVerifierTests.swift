//
//  RepoVerifierTests.swift
//  ATProtoDriveTests
//

import CryptoKit
import Foundation
import Petrel
import SwanCore
import SwanSpaces
import Testing
@testable import ATProtoDrive

@Suite("RepoVerifier and Verification Pipeline Tests")
struct RepoVerifierTests {

    // MARK: - Step 1: Known-Good CAR Verification

    @Test("RepoVerifier verifies known-good CAR fixture and returns record count and revision")
    func testVerifyKnownGoodCAR() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()

        // Also write out the fixture to disk to persist as a committed fixture
        let fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("ATProtoDriveFixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let fixtureURL = fixtureDir.appendingPathComponent("space-repo.car")
        try fixture.carData.write(to: fixtureURL)

        let report = try RepoVerifier.verify(
            carData: fixture.carData,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKey.rawRepresentation
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        guard case let .verified(recordCount) = report.outcome else {
            Issue.record("Expected .verified outcome, got \(report.outcome)")
            return
        }
        #expect(recordCount == 2)
    }

    // MARK: - Step 2: Hash Mismatch on Corrupted Record Block

    @Test("RepoVerifier returns hashMismatch after flipping one byte in a record block")
    func testVerifyHashMismatchOnFlippedByteInRecordBlock() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()

        // Corrupt one byte in the trailing record block
        var corruptedCAR = fixture.carData
        let lastIndex = corruptedCAR.index(before: corruptedCAR.endIndex)
        corruptedCAR[lastIndex] ^= 0x01

        let report = try RepoVerifier.verify(
            carData: corruptedCAR,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKey.rawRepresentation
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        guard case let .hashMismatch(expected, computed) = report.outcome else {
            Issue.record("Expected .hashMismatch outcome for corrupted record block, got \(report.outcome)")
            return
        }
        #expect(!expected.isEmpty)
        #expect(!computed.isEmpty)
        #expect(expected != computed)
    }

    // MARK: - Step 3: Signature Invalid with Wrong Key

    @Test("RepoVerifier returns signatureInvalid when author signing key does not match commit signature")
    func testVerifySignatureInvalidWithWrongKey() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()
        let differentKey = P256.Signing.PrivateKey()

        let report = try RepoVerifier.verify(
            carData: fixture.carData,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: differentKey.publicKey.rawRepresentation
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        #expect(report.outcome == .signatureInvalid)
    }

    // MARK: - Step 4: Malformed CAR Handling

    @Test("RepoVerifier returns malformedCAR on truncated or invalid CAR bytes")
    func testVerifyMalformedCAR() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()
        let truncated = fixture.carData.prefix(20)

        let report = try RepoVerifier.verify(
            carData: Data(truncated),
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKey.rawRepresentation
        )

        guard case .malformedCAR = report.outcome else {
            Issue.record("Expected .malformedCAR outcome for truncated CAR data, got \(report.outcome)")
            return
        }
    }

    // MARK: - Public Key Format Support

    @Test("RepoVerifier parses P-256 public keys in all standard representations")
    func testPublicKeyParsing() throws {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let raw = publicKey.rawRepresentation
        let compressed = publicKey.compressedRepresentation
        let x963 = publicKey.x963Representation
        let der = publicKey.derRepresentation
        let multicodec = Data([0x80, 0x24]) + compressed

        let parsedRaw = try RepoVerifier.parseP256PublicKey(from: raw)
        let parsedCompressed = try RepoVerifier.parseP256PublicKey(from: compressed)
        let parsedX963 = try RepoVerifier.parseP256PublicKey(from: x963)
        let parsedDER = try RepoVerifier.parseP256PublicKey(from: der)
        let parsedMulticodec = try RepoVerifier.parseP256PublicKey(from: multicodec)

        #expect(parsedRaw.rawRepresentation == raw)
        #expect(parsedCompressed.rawRepresentation == raw)
        #expect(parsedX963.rawRepresentation == raw)
        #expect(parsedDER.rawRepresentation == raw)
        #expect(parsedMulticodec.rawRepresentation == raw)

        // Invalid key bytes throw RepoVerifierError.invalidAuthorSigningKey
        #expect(throws: RepoVerifierError.self) {
            try RepoVerifier.parseP256PublicKey(from: Data([0x00, 0x01, 0x02]))
        }
    }

    // MARK: - DID Document Key Extraction

    @Test("RepoVerifier extracts signing key from DIDDocument with multikey decoding")
    func testExtractSigningKeyFromDIDDoc() throws {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: TestCARFixtureHelper.privateKeyRaw)
        let publicKey = privateKey.publicKey
        let multikey = "did:key:z" + Base58BTCEncoder.encode(Data([0x80, 0x24]) + publicKey.compressedRepresentation)
        let rawMultikey = "z" + Base58BTCEncoder.encode(Data([0x80, 0x24]) + publicKey.compressedRepresentation)

        let docJSON = """
        {
            "@context": ["https://www.w3.org/ns/did/v1"],
            "id": "\(TestCARFixtureHelper.authorDID)",
            "verificationMethod": [
                {
                    "id": "\(TestCARFixtureHelper.authorDID)#atproto_space",
                    "type": "Multikey",
                    "controller": "\(TestCARFixtureHelper.authorDID)",
                    "publicKeyMultibase": "\(rawMultikey)"
                }
            ]
        }
        """.data(using: .utf8)!

        let doc = try JSONDecoder().decode(DIDDocument.self, from: docJSON)
        let extractedKeyData = try RepoVerifier.extractSigningKey(from: doc)
        let parsedKey = try RepoVerifier.parseP256PublicKey(from: extractedKeyData)
        #expect(parsedKey.rawRepresentation == publicKey.rawRepresentation)
    }

    // MARK: - Dual Routing Exclusivity for getRepo Fetch

    @Test("verifyRepoPipeline dual-routing routes own repo to clientGetRepo and foreign repo to credentialGet")
    func testDualRoutingExclusivityForGetRepoFetch() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()
        let ownDID = "did:plc:alice"
        let foreignDID = "did:plc:bob"
        let spaceItem = SpaceItem(
            ref: fixture.spaceRef,
            accountDID: ownDID
        )

        let ownRepo = RepoEntry(did: ownDID, rev: TestCARFixtureHelper.revision, hash: "dummyHash")
        let foreignRepo = RepoEntry(did: foreignDID, rev: TestCARFixtureHelper.revision, hash: "dummyHash")

        actor CallCounts {
            var clientGetRepoCount = 0
            var foreignGetCount = 0
            var resolvePDSSCount = 0

            func incClient() { clientGetRepoCount += 1 }
            func incForeign() { foreignGetCount += 1 }
            func incPDS() { resolvePDSSCount += 1 }
        }

        let tracker = CallCounts()

        // 1. Own Repo Test: must call clientGetRepo exclusively
        let ownReport = try await SpaceDetailModel.verifyRepoPipeline(
            space: spaceItem,
            repo: ownRepo,
            accountDID: ownDID,
            clientGetRepo: { space, repoDID in
                await tracker.incClient()
                return (200, ComAtprotoSpaceGetRepo.Output(data: fixture.carData))
            },
            resolveDIDToPDS: { did in
                await tracker.incPDS()
                return URL(string: "https://pds.example.com")!
            },
            resolveSigningKey: { did in
                return fixture.publicKey.rawRepresentation
            },
            credentialGet: { url, space in
                await tracker.incForeign()
                return (200, fixture.carData)
            }
        )

        let clientCountAfterOwn = await tracker.clientGetRepoCount
        let foreignCountAfterOwn = await tracker.foreignGetCount
        let pdsCountAfterOwn = await tracker.resolvePDSSCount

        #expect(clientCountAfterOwn == 1)
        #expect(foreignCountAfterOwn == 0)
        #expect(pdsCountAfterOwn == 0)
        #expect(ownReport.outcome == VerificationReport.Outcome.verified(recordCount: 2))

        // 2. Foreign Repo Test: must call resolveDIDToPDS + credentialGet exclusively
        let foreignFixture = try await TestCARFixtureHelper.makeFixture(authorDID: foreignDID)
        let foreignReport = try await SpaceDetailModel.verifyRepoPipeline(
            space: spaceItem,
            repo: foreignRepo,
            accountDID: ownDID,
            clientGetRepo: { space, repoDID in
                await tracker.incClient()
                return (200, ComAtprotoSpaceGetRepo.Output(data: foreignFixture.carData))
            },
            resolveDIDToPDS: { did in
                await tracker.incPDS()
                return URL(string: "https://pds.example.com")!
            },
            resolveSigningKey: { did in
                return foreignFixture.publicKey.rawRepresentation
            },
            credentialGet: { url, space in
                await tracker.incForeign()
                return (200, foreignFixture.carData)
            }
        )

        let clientCountAfterForeign = await tracker.clientGetRepoCount
        let foreignCountAfterForeign = await tracker.foreignGetCount
        let pdsCountAfterForeign = await tracker.resolvePDSSCount

        #expect(clientCountAfterForeign == 1) // Unchanged
        #expect(foreignCountAfterForeign == 1)
        #expect(pdsCountAfterForeign == 1)
        #expect(foreignReport.outcome == VerificationReport.Outcome.verified(recordCount: 2))
    }
}

// Helper for test Base58BTC multikey encoding
private enum Base58BTCEncoder {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

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
}
