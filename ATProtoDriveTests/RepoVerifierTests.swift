//
//  RepoVerifierTests.swift
//  ATProtoDriveTests
//

import CryptoKit
import Foundation
import Petrel
import secp256k1
import PetrelCrypto
import SwanSpaces
import Testing
@testable import ATProtoDrive

@Suite("RepoVerifier and Verification Pipeline Tests")
struct RepoVerifierTests {

    // MARK: - Step 1: Known-Good P-256 (ES256) CAR Verification

    @Test("RepoVerifier verifies known-good P-256 (ES256) CAR fixture")
    func testVerifyKnownGoodP256CAR() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()

        // Persist fixture to disk
        let fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("ATProtoDriveFixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let fixtureURL = fixtureDir.appendingPathComponent("space-repo.car")
        try fixture.carData.write(to: fixtureURL)

        let report = try await RepoVerifier.verify(
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

    // MARK: - Step 2: Known-Good secp256k1 (ES256K) CAR Verification

    @Test("RepoVerifier verifies known-good secp256k1 (ES256K) CAR fixture from reference PDS")
    func testVerifyKnownGoodSecp256k1CAR() async throws {
        let fixture = try await TestCARFixtureHelper.makeSecp256k1Fixture()

        let report = try await RepoVerifier.verify(
            carData: fixture.carData,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKeyBytes
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        guard case let .verified(recordCount) = report.outcome else {
            Issue.record("Expected .verified outcome for secp256k1 CAR, got \(report.outcome)")
            return
        }
        #expect(recordCount == 2)
    }

    // MARK: - Step 3: Genuine Commitment Mismatch Reporting (Finding 1)

    @Test("RepoVerifier reports genuine expected and computed LtHash commitments on commitment mismatch")
    func testVerifyCommitmentMismatchReportsGenuineExpectedAndComputedHashes() async throws {
        let fixture = try await TestCARFixtureHelper.makeCommitmentMismatchFixture()

        let report = try await RepoVerifier.verify(
            carData: fixture.carData,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKey.rawRepresentation
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        guard case let .hashMismatch(expected, computed) = report.outcome else {
            Issue.record("Expected .hashMismatch outcome, got \(report.outcome)")
            return
        }
        #expect(expected == fixture.expectedHex)
        #expect(computed == fixture.computedHex)
        #expect(expected != computed)
    }

    // MARK: - Step 4: Malformed archive on Corrupted Record Block

    @Test("RepoVerifier returns malformedArchive after flipping one byte in a record block")
    func testVerifyMalformedCAROnCorruptedRecordBlock() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()

        // Corrupt one byte in the trailing record block
        var corruptedCAR = fixture.carData
        let lastIndex = corruptedCAR.index(before: corruptedCAR.endIndex)
        corruptedCAR[lastIndex] ^= 0x01

        let report = try await RepoVerifier.verify(
            carData: corruptedCAR,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKey.rawRepresentation
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        guard case .malformedArchive = report.outcome else {
            Issue.record("Expected .malformedArchive outcome for corrupted record block, got \(report.outcome)")
            return
        }
    }

    // MARK: - Step 5: Signature Invalid with Wrong Key

    @Test("RepoVerifier returns signatureInvalid when author signing key does not match commit signature")
    func testVerifySignatureInvalidWithWrongKey() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()
        let differentKey = P256.Signing.PrivateKey()

        let report = try await RepoVerifier.verify(
            carData: fixture.carData,
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: differentKey.publicKey.rawRepresentation
        )

        #expect(report.rev == TestCARFixtureHelper.revision)
        #expect(report.outcome == .signatureInvalid)
    }

    // MARK: - Step 6: Malformed archive Handling on Truncated Data

    @Test("RepoVerifier returns malformedArchive on truncated or invalid CAR bytes")
    func testVerifyMalformedCAROnTruncatedData() async throws {
        let fixture = try await TestCARFixtureHelper.makeFixture()
        let truncated = fixture.carData.prefix(20)

        let report = try await RepoVerifier.verify(
            carData: Data(truncated),
            authorDID: TestCARFixtureHelper.authorDID,
            space: fixture.spaceRef,
            authorSigningKey: fixture.publicKey.rawRepresentation
        )

        guard case .malformedArchive = report.outcome else {
            Issue.record("Expected .malformedArchive outcome for truncated CAR data, got \(report.outcome)")
            return
        }
    }

    // MARK: - Step 7: Malformed archive Remains Visible for Requested Repo Rev (Finding 2)

    @Test("SpaceDetailModel keeps malformed CAR report visible for requested repo revision and invalidates on advance")
    @MainActor
    func testMalformedCARReportRemainsVisibleForRequestedRepoRev() {
        let repoDID = "did:plc:alice"
        let initialRev = "3l3vbfz2zsk22"
        let advancedRev = "3l3vbfz2zsk23"

        // Malformed archive report has rev == ""
        let malformedReport = VerificationReport(
            outcome: .malformedArchive("malformedHeader"),
            rev: ""
        )

        let model = SpaceDetailModel(
            verificationReports: [
                repoDID: SpaceDetailModel.StoredVerification(
                    targetRev: initialRev,
                    report: malformedReport
                )
            ]
        )

        let currentRepo = RepoEntry(did: repoDID, rev: initialRev, hash: "hash1")
        let advancedRepo = RepoEntry(did: repoDID, rev: advancedRev, hash: "hash2")

        // 1. Malformed archive failure remains visible for the requested repo
        let visibleReport = model.verificationReport(for: currentRepo)
        #expect(visibleReport != nil)
        #expect(visibleReport?.outcome == .malformedArchive("malformedHeader"))

        // 2. Advanced revision invalidates the report
        #expect(model.verificationReport(for: advancedRepo) == nil)
    }
    // MARK: - Step 8: Wire Revision Mismatch Rejects Verified Badge (Round 3 Finding 2)

    @Test("SpaceDetailModel rejects verified badge when wire revision differs from repo revision")
    @MainActor
    func testWireRevisionMismatchSuppressesVerifiedBadge() {
        let repoDID = "did:plc:alice"
        let requestedRev = "3l3vbfz2zsk22"
        let mismatchedWireRev = "3l3vbfz2zsk20" // Stale or raced CAR response

        // Verified report for wire revision B
        let verifiedReportForOtherRev = VerificationReport(
            outcome: .verified(recordCount: 5),
            rev: mismatchedWireRev
        )

        let model = SpaceDetailModel(
            verificationReports: [
                repoDID: SpaceDetailModel.StoredVerification(
                    targetRev: requestedRev,
                    report: verifiedReportForOtherRev
                )
            ]
        )

        let repo = RepoEntry(did: repoDID, rev: requestedRev, hash: "hash1")

        // Must reject verified badge because wire rev != repo rev
        #expect(model.verificationReport(for: repo) == nil)
    }

    // MARK: - Step 9: Linear-Time Recovery Index Performance (Finding 3)

    @Test("InMemorySpaceRecoveryIndex performs O(1) insertions and lookups without quadratic slowdown across distinct CIDs")
    func testLinearTimeRecoveryIndexPerformanceWithLargeEntrySet() async throws {
        let entryCount = 3_000

        // Build 3,000 index entries with 3,000 DISTINCT CIDs
        var entries: [SpaceCARRecoveryIndexEntry] = []
        entries.reserveCapacity(entryCount)
        for i in 0 ..< entryCount {
            var cborBytes = Data([0xa1, 0x61, 0x61]) // {"a": i}
            cborBytes.append(contentsOf: withUnsafeBytes(of: UInt32(i).bigEndian) { Array($0) })
            let cid = CID.fromDAGCBOR(cborBytes)
            let path = String(format: "app.bsky.feed.post/%06d", i)
            entries.append(SpaceCARRecoveryIndexEntry(path: path, cid: cid))
        }

        // Test insertion and per-CID consumption time
        let startTime = ContinuousClock.now
        let recoveryIndex = InMemorySpaceRecoveryIndex()
        for entry in entries {
            try await recoveryIndex.insert(entry)
        }

        // Sequentially inspect and consume each of the 3,000 canonical entries.
        for expectedEntry in entries {
            let next = try await recoveryIndex.nextUnconsumedCanonicalEntry()
            #expect(next?.path == expectedEntry.path)
            #expect(next?.cid == expectedEntry.cid)
            #expect(try await recoveryIndex.hasConsumedCID(expectedEntry.cid) == false)
            try await recoveryIndex.consumeEntry(expectedEntry)
            #expect(try await recoveryIndex.hasConsumedCID(expectedEntry.cid) == true)
        }

        let afterConsume = try await recoveryIndex.nextUnconsumedCanonicalEntry()
        #expect(afterConsume == nil)

        let elapsedTime = ContinuousClock.now - startTime
        // 3,000 distinct insertions + 3,000 distinct lookups + 3,000 distinct consumptions
        // In linear time this takes ~0.05s; quadratic would take >10s and fail this bound
        #expect(elapsedTime < .milliseconds(500))
    }

    @Test("InMemorySpaceRecoveryIndex uses DAG-CBOR path order and consumes shared-CID paths individually")
    func testRecoveryIndexCanonicalOrderAndSharedCIDConsumption() async throws {
        let sharedCID = CID.fromDAGCBOR(Data([0xa1, 0x61, 0x61, 0x01]))
        let distinctCID = CID.fromDAGCBOR(Data([0xa1, 0x61, 0x62, 0x02]))
        let recoveryIndex = InMemorySpaceRecoveryIndex()
        let longerShared = SpaceCARRecoveryIndexEntry(path: "aa", cid: sharedCID)
        let laterSameLength = SpaceCARRecoveryIndexEntry(path: "z", cid: distinctCID)
        let shorterShared = SpaceCARRecoveryIndexEntry(path: "b", cid: sharedCID)

        try await recoveryIndex.insert(longerShared)
        try await recoveryIndex.insert(laterSameLength)
        try await recoveryIndex.insert(shorterShared)

        #expect(try await recoveryIndex.nextUnconsumedCanonicalEntry() == shorterShared)
        #expect(try await recoveryIndex.hasConsumedCID(sharedCID) == false)
        try await recoveryIndex.consumeEntry(shorterShared)
        #expect(try await recoveryIndex.hasConsumedCID(sharedCID) == true)

        #expect(try await recoveryIndex.nextUnconsumedCanonicalEntry() == laterSameLength)
        await #expect(throws: SpaceCARStreamingError.invalidRecordOrder) {
            try await recoveryIndex.consumeEntry(longerShared)
        }
        try await recoveryIndex.consumeEntry(laterSameLength)

        #expect(try await recoveryIndex.nextUnconsumedCanonicalEntry() == longerShared)
        try await recoveryIndex.consumeEntry(longerShared)
        #expect(try await recoveryIndex.nextUnconsumedCanonicalEntry() == nil)
    }

    // MARK: - Public Key Format Support (P-256 and secp256k1)

    @Test("RepoVerifier parses P-256 and secp256k1 public keys in all standard representations")
    func testPublicKeyParsing() throws {
        let p256PrivateKey = P256.Signing.PrivateKey()
        let p256PublicKey = p256PrivateKey.publicKey

        let rawP256 = p256PublicKey.rawRepresentation
        let compressedP256 = p256PublicKey.compressedRepresentation
        let x963P256 = p256PublicKey.x963Representation
        let derP256 = p256PublicKey.derRepresentation
        let multicodecP256 = Data([0x80, 0x24]) + compressedP256

        let secpKey = try secp256k1.Signing.PrivateKey(dataRepresentation: Data(repeating: 2, count: 32))
        let multicodecSecp = Data([0xe7, 0x01]) + secpKey.publicKey.dataRepresentation

        let parsedRaw = try RepoVerifier.parseSigningKey(from: rawP256)
        let parsedCompressed = try RepoVerifier.parseSigningKey(from: compressedP256)
        let parsedX963 = try RepoVerifier.parseSigningKey(from: x963P256)
        let parsedDER = try RepoVerifier.parseSigningKey(from: derP256)
        let parsedMulticodecP256 = try RepoVerifier.parseSigningKey(from: multicodecP256)
        let parsedMulticodecSecp = try RepoVerifier.parseSigningKey(from: multicodecSecp)

        #expect(parsedRaw == .p256(p256PublicKey))
        #expect(parsedCompressed == .p256(p256PublicKey))
        #expect(parsedX963 == .p256(p256PublicKey))
        #expect(parsedDER == .p256(p256PublicKey))
        #expect(parsedMulticodecP256 == .p256(p256PublicKey))
        #expect(parsedMulticodecSecp == .secp256k1PublicKey(secpKey.publicKey.dataRepresentation))

        // Invalid key bytes throw RepoVerifierError.invalidAuthorSigningKey
        #expect(throws: RepoVerifierError.self) {
            try RepoVerifier.parseSigningKey(from: Data([0x00, 0x01, 0x02]))
        }
    }

    // MARK: - Strict DID Document Key Extraction

    @Test("RepoVerifier extracts signing key from DIDDocument with exact #atproto_space or #atproto match")
    func testExtractSigningKeyFromDIDDoc() throws {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: TestCARFixtureHelper.privateKeyRaw)
        let publicKey = privateKey.publicKey
        let rawMultikey = "z" + Base58BTCEncoder.encode(Data([0x80, 0x24]) + publicKey.compressedRepresentation)
        let didKeyFormat = "did:key:" + rawMultikey

        // 1. Exact #atproto_space succeeds
        let docWithSpaceKey = DIDDocument(
            context: ["https://www.w3.org/ns/did/v1"],
            id: TestCARFixtureHelper.authorDID,
            alsoKnownAs: [],
            verificationMethod: [
                VerificationMethod(
                    id: "\(TestCARFixtureHelper.authorDID)#atproto_space",
                    type: "Multikey",
                    controller: TestCARFixtureHelper.authorDID,
                    publicKeyMultibase: rawMultikey
                )
            ],
            service: []
        )

        let extractedKeyData = try RepoVerifier.extractSigningKey(from: docWithSpaceKey)
        let parsedKey = try RepoVerifier.parseSigningKey(from: extractedKeyData)
        #expect(parsedKey == .p256(publicKey))

        // 2. Exact #atproto succeeds
        let docWithAtprotoKey = DIDDocument(
            context: ["https://www.w3.org/ns/did/v1"],
            id: TestCARFixtureHelper.authorDID,
            alsoKnownAs: [],
            verificationMethod: [
                VerificationMethod(
                    id: "#atproto",
                    type: "Multikey",
                    controller: TestCARFixtureHelper.authorDID,
                    publicKeyMultibase: didKeyFormat
                )
            ],
            service: []
        )

        let extractedAtprotoKey = try RepoVerifier.extractSigningKey(from: docWithAtprotoKey)
        let parsedAtprotoKey = try RepoVerifier.parseSigningKey(from: extractedAtprotoKey)
        #expect(parsedAtprotoKey == .p256(publicKey))

        // 3. Document with only unrelated keys FAILS (Finding 3)
        let docWithUnrelatedKey = DIDDocument(
            context: ["https://www.w3.org/ns/did/v1"],
            id: TestCARFixtureHelper.authorDID,
            alsoKnownAs: [],
            verificationMethod: [
                VerificationMethod(
                    id: "\(TestCARFixtureHelper.authorDID)#unrelated_key",
                    type: "Multikey",
                    controller: TestCARFixtureHelper.authorDID,
                    publicKeyMultibase: rawMultikey
                ),
                VerificationMethod(
                    id: "#other_oauth_key",
                    type: "Multikey",
                    controller: TestCARFixtureHelper.authorDID,
                    publicKeyMultibase: rawMultikey
                )
            ],
            service: []
        )

        #expect(throws: RepoVerifierError.self) {
            try RepoVerifier.extractSigningKey(from: docWithUnrelatedKey)
        }
    }

    // MARK: - did:web Path-Based Resolution (Finding 5)

    @Test("SpaceHostResolver resolves path-based did:web according to W3C specification")
    func testPathBasedDidWebResolution() throws {
        // Path-based did:web: did:web:example.com:users:alice -> https://example.com/users/alice/did.json
        let pathDID = "did:web:example.com:users:alice"
        let pathURL = try SpaceHostResolver.didDocumentURL(for: pathDID)
        #expect(pathURL.absoluteString == "https://example.com/users/alice/did.json")

        // Bare did:web: did:web:example.com -> https://example.com/.well-known/did.json
        let bareDID = "did:web:example.com"
        let bareURL = try SpaceHostResolver.didDocumentURL(for: bareDID)
        #expect(bareURL.absoluteString == "https://example.com/.well-known/did.json")

        // PLC DID: did:plc:12345 -> https://plc.directory/did:plc:12345
        let plcDID = "did:plc:12345"
        let plcURL = try SpaceHostResolver.didDocumentURL(for: plcDID)
        #expect(plcURL.absoluteString == "https://plc.directory/did:plc:12345")
    }

    // MARK: - Dual Routing Exclusivity for getRepo Fetch

    @Test("verifyRepoPipeline dual-routing routes own repo to clientGetRepo and foreign repo to credentialGet")
    func testDualRoutingExclusivityForGetRepoFetch() async throws {
        let fixture = try TestSTARFixtureHelper.makeFixture()
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
                return (200, ComAtprotoSpaceGetRepo.Output(data: fixture.archive))
            },
            resolveDIDToPDS: { did in
                await tracker.incPDS()
                return URL(string: "https://pds.example.com")!
            },
            credentialGet: { url, space in
                await tracker.incForeign()
                return (200, fixture.archive)
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
        let foreignFixture = try TestSTARFixtureHelper.makeFixture(authorDID: foreignDID)
        let foreignReport = try await SpaceDetailModel.verifyRepoPipeline(
            space: spaceItem,
            repo: foreignRepo,
            accountDID: ownDID,
            clientGetRepo: { space, repoDID in
                await tracker.incClient()
                return (200, ComAtprotoSpaceGetRepo.Output(data: foreignFixture.archive))
            },
            resolveDIDToPDS: { did in
                await tracker.incPDS()
                return URL(string: "https://pds.example.com")!
            },
            credentialGet: { url, space in
                await tracker.incForeign()
                return (200, foreignFixture.archive)
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
