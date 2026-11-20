//
//  BackupServiceTests.swift
//  ATProtoDriveTests
//

import CryptoKit
import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

// MARK: - Minimal Deterministic Public CAR v1 Builder for Offline Tests

private enum BackupTestCBOR {
    static func header(major: UInt8, argument: UInt64) -> Data {
        let prefix = major << 5
        var result = Data()
        switch argument {
        case 0 ..< 24:
            result.append(prefix | UInt8(argument))
        case 24 ... UInt64(UInt8.max):
            result.append(prefix | 24)
            result.append(UInt8(argument))
        case (UInt64(UInt8.max) + 1) ... UInt64(UInt16.max):
            result.append(prefix | 25)
            var value = UInt16(argument).bigEndian
            result.append(Data(bytes: &value, count: MemoryLayout<UInt16>.size))
        case (UInt64(UInt16.max) + 1) ... UInt64(UInt32.max):
            result.append(prefix | 26)
            var value = UInt32(argument).bigEndian
            result.append(Data(bytes: &value, count: MemoryLayout<UInt32>.size))
        default:
            result.append(prefix | 27)
            var value = argument.bigEndian
            result.append(Data(bytes: &value, count: MemoryLayout<UInt64>.size))
        }
        return result
    }

    static func uint(_ value: UInt64) -> Data {
        header(major: 0, argument: value)
    }

    static func bytes(_ value: Data) -> Data {
        header(major: 2, argument: UInt64(value.count)) + value
    }

    static func text(_ value: String) -> Data {
        let utf8 = Data(value.utf8)
        return header(major: 3, argument: UInt64(utf8.count)) + utf8
    }

    static func array(_ items: [Data]) -> Data {
        items.reduce(header(major: 4, argument: UInt64(items.count))) { $0 + $1 }
    }

    static func map(_ pairs: [(String, Data)]) -> Data {
        let sorted = pairs.sorted { a, b in
            let aBytes = a.0.utf8
            let bBytes = b.0.utf8
            if aBytes.count != bBytes.count {
                return aBytes.count < bBytes.count
            }
            return aBytes.lexicographicallyPrecedes(bBytes)
        }
        return sorted.reduce(header(major: 5, argument: UInt64(sorted.count))) { $0 + text($1.0) + $1.1 }
    }

    static func link(_ cid: CID) -> Data {
        header(major: 6, argument: 42) + bytes(Data([0x00]) + cid.bytes)
    }
}

private struct BackupTestPublicCARBuilder {
    private var blocks: [(cid: CID, payload: Data)] = []

    static func varint(_ value: Int) -> Data {
        var remaining = UInt64(value)
        var result = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }

    mutating func add(_ payload: Data) -> CID {
        let cid = CID.fromDAGCBOR(payload)
        blocks.append((cid, payload))
        return cid
    }

    func archive(root: CID) -> Data {
        let header = BackupTestCBOR.map([
            ("roots", BackupTestCBOR.array([BackupTestCBOR.link(root)])),
            ("version", BackupTestCBOR.uint(1)),
        ])
        var result = Self.varint(header.count) + header
        for block in blocks {
            let framed = block.cid.bytes + block.payload
            result += Self.varint(framed.count) + framed
        }
        return result
    }

    static func makeSamplePublicCAR(
        did: String = "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        rev: String = "3l3vbfz2zsk22"
    ) -> (carData: Data, commitCID: CID, profileCID: CID, postCID: CID) {
        var builder = BackupTestPublicCARBuilder()

        let profileCID = builder.add(BackupTestCBOR.map([
            ("$type", BackupTestCBOR.text("app.bsky.actor.profile")),
            ("displayName", BackupTestCBOR.text("Alice Backup Test")),
        ]))

        let postCID = builder.add(BackupTestCBOR.map([
            ("$type", BackupTestCBOR.text("app.bsky.feed.post")),
            ("text", BackupTestCBOR.text("Offline backup verification post")),
            ("createdAt", BackupTestCBOR.text("2026-08-23T12:00:00.000Z")),
        ]))

        // Strictly sorted MST keys: "app.bsky.actor.profile/self" < "app.bsky.feed.post/3kpost1"
        let entry1 = BackupTestCBOR.map([
            ("p", BackupTestCBOR.uint(0)),
            ("k", BackupTestCBOR.bytes(Data("app.bsky.actor.profile/self".utf8))),
            ("v", BackupTestCBOR.link(profileCID)),
        ])
        let entry2 = BackupTestCBOR.map([
            ("p", BackupTestCBOR.uint(0)),
            ("k", BackupTestCBOR.bytes(Data("app.bsky.feed.post/3kpost1".utf8))),
            ("v", BackupTestCBOR.link(postCID)),
        ])

        let rootMSTCID = builder.add(BackupTestCBOR.map([
            ("e", BackupTestCBOR.array([entry1, entry2])),
        ]))

        let commitCID = builder.add(BackupTestCBOR.map([
            ("did", BackupTestCBOR.text(did)),
            ("version", BackupTestCBOR.uint(3)),
            ("data", BackupTestCBOR.link(rootMSTCID)),
            ("rev", BackupTestCBOR.text(rev)),
        ]))

        return (
            carData: builder.archive(root: commitCID),
            commitCID: commitCID,
            profileCID: profileCID,
            postCID: postCID
        )
    }
}

private func makeIsolatedTempDirectory(prefix: String = "ATProtoDriveBackupTests") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@Suite("Backup Service and Store Tests")
struct BackupServiceTests {
    private static let aliceDID = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
    private static let bobDID = "did:plc:z72i7hdynmk6r22z27h6tvur"

    @Test("Public getRepo URL builder targets exact unauthenticated sync endpoint")
    func testMakePublicGetRepoURL() throws {
        let pdsURL = try #require(URL(string: "https://pds.example.com/"))
        let url = try BackupService.makePublicGetRepoURL(pdsURL: pdsURL, did: Self.aliceDID)
        #expect(url.absoluteString == "https://pds.example.com/xrpc/com.atproto.sync.getRepo?did=\(Self.aliceDID)")
    }

    @Test("Atomic public backup creates .atprotodrivebackup package, manifest round-trips, and passes verification")
    func testPublicBackupAtomicCreationAndManifestRoundTrip() async throws {
        let rootDir = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let pdsURL = try #require(URL(string: "https://alice.pds.example"))
        let fixture = BackupTestPublicCARBuilder.makeSamplePublicCAR(did: Self.aliceDID, rev: "3l3vbfz2zsk22")

        actor ProgressRecorder {
            var updates: [(Int64, Int64?)] = []
            func record(_ completed: Int64, _ total: Int64?) { updates.append((completed, total)) }
        }
        let recorder = ProgressRecorder()

        let service = BackupService(operations: .init(
            fetchPublicRepoCAR: { requestedPDS, requestedDID, progress in
                #expect(requestedPDS == pdsURL)
                #expect(requestedDID == Self.aliceDID)
                progress?(Int64(fixture.carData.count / 2), Int64(fixture.carData.count))
                return fixture.carData
            }
        ))

        let summary = try await service.createPublicBackup(
            did: Self.aliceDID,
            handle: "alice.bsky.social",
            pdsURL: pdsURL,
            rootDirectory: rootDir,
            progressHandler: { completed, total in
                Task { await recorder.record(completed, total) }
            }
        )

        #expect(summary.packageURL.pathExtension == "atprotodrivebackup")
        #expect(FileManager.default.fileExists(atPath: summary.packageURL.path))

        // No temporary .staging-* directories may remain after atomic move
        let rootChildren = try FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: []
        )
        #expect(rootChildren.allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") })
        #expect(rootChildren.count == 1)

        // Expected files exist inside package
        let carURL = summary.packageURL.appendingPathComponent("repo.car")
        let indexURL = summary.packageURL.appendingPathComponent("records-index.json")
        let manifestURL = summary.packageURL.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: carURL.path))
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        // Manifest JSON round-trip
        let loadedManifest = try service.loadManifest(at: summary.packageURL)
        #expect(loadedManifest.schemaVersion == 1)
        #expect(loadedManifest.backupID == summary.manifest.backupID)
        #expect(loadedManifest.accessClassification == .publicRepository(did: Self.aliceDID))
        #expect(loadedManifest.did == Self.aliceDID)
        #expect(loadedManifest.handle == "alice.bsky.social")
        #expect(loadedManifest.pdsURL == pdsURL)
        #expect(loadedManifest.spaceURI == nil)
        #expect(loadedManifest.commitRev == "3l3vbfz2zsk22")
        #expect(loadedManifest.commitCID == fixture.commitCID.string)
        #expect(loadedManifest.carFilename == "repo.car")
        #expect(loadedManifest.carSHA256 == BackupCoding.sha256Hex(of: fixture.carData))
        #expect(loadedManifest.carByteCount == Int64(fixture.carData.count))
        #expect(loadedManifest.recordCount == 2)
        #expect(loadedManifest.collectionCounts == [
            "app.bsky.actor.profile": 1,
            "app.bsky.feed.post": 1,
        ])
        #expect(loadedManifest.verified == true)

        // Independent package verification succeeds
        let report = try await service.verifyPackage(at: summary.packageURL)
        #expect(report.isValid == true)
        #expect(report.carSHA256Matches == true)
        #expect(report.manifestValid == true)
        #expect(report.recordCount == 2)
        #expect(report.commitRev == "3l3vbfz2zsk22")
        #expect(report.issues.isEmpty)
    }

    @Test("Tampering with 1 byte of repo.car fails verifyPackage")
    func testTamperDetectionOnCARByteFlip() async throws {
        let rootDir = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let pdsURL = try #require(URL(string: "https://alice.pds.example"))
        let fixture = BackupTestPublicCARBuilder.makeSamplePublicCAR(did: Self.aliceDID)
        let service = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in fixture.carData }
        ))

        let summary = try await service.createPublicBackup(
            did: Self.aliceDID,
            pdsURL: pdsURL,
            rootDirectory: rootDir
        )

        // Modify a single byte in repo.car
        let carURL = summary.packageURL.appendingPathComponent("repo.car")
        var tampered = try Data(contentsOf: carURL)
        let lastIndex = tampered.index(before: tampered.endIndex)
        tampered[lastIndex] ^= 0x01
        try tampered.write(to: carURL, options: .atomic)

        let report = try await service.verifyPackage(at: summary.packageURL)
        #expect(report.isValid == false)
        #expect(report.carSHA256Matches == false)
        #expect(report.manifestValid == true)
        #expect(!report.issues.isEmpty)
    }

    @Test("Unsupported manifest schemaVersion and tampered records-index.json fail verifyPackage")
    func testManifestSchemaAndRecordsIndexTamperDetection() async throws {
        let rootDir = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let pdsURL = try #require(URL(string: "https://alice.pds.example"))
        let fixture = BackupTestPublicCARBuilder.makeSamplePublicCAR(did: Self.aliceDID)
        let service = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in fixture.carData }
        ))

        let summary = try await service.createPublicBackup(
            did: Self.aliceDID,
            pdsURL: pdsURL,
            rootDirectory: rootDir
        )

        // 1. Tamper records-index.json by dropping one record
        let indexURL = summary.packageURL.appendingPathComponent("records-index.json")
        let records = try service.loadRecords(at: summary.packageURL)
        let truncatedData = try BackupCoding.makeEncoder().encode(Array(records.prefix(1)))
        try truncatedData.write(to: indexURL, options: .atomic)

        let indexReport = try await service.verifyPackage(at: summary.packageURL)
        #expect(indexReport.isValid == false)
        #expect(indexReport.carSHA256Matches == true)
        #expect(indexReport.recordCount == 1)
        #expect(!indexReport.issues.isEmpty)

        // 2. Restore index and tamper manifest schemaVersion to 99
        let restoredData = try BackupCoding.makeEncoder().encode(records)
        try restoredData.write(to: indexURL, options: .atomic)

        let badManifest = BackupManifest(
            schemaVersion: 99,
            backupID: summary.manifest.backupID,
            createdAt: summary.manifest.createdAt,
            accessClassification: summary.manifest.accessClassification,
            did: summary.manifest.did,
            handle: summary.manifest.handle,
            pdsURL: summary.manifest.pdsURL,
            spaceURI: summary.manifest.spaceURI,
            commitRev: summary.manifest.commitRev,
            commitCID: summary.manifest.commitCID,
            carFilename: summary.manifest.carFilename,
            carSHA256: summary.manifest.carSHA256,
            carByteCount: summary.manifest.carByteCount,
            recordCount: summary.manifest.recordCount,
            collectionCounts: summary.manifest.collectionCounts,
            verified: summary.manifest.verified,
            verificationSummary: summary.manifest.verificationSummary
        )
        let manifestURL = summary.packageURL.appendingPathComponent("manifest.json")
        try BackupCoding.makeEncoder().encode(badManifest).write(to: manifestURL, options: .atomic)

        let schemaReport = try await service.verifyPackage(at: summary.packageURL)
        #expect(schemaReport.isValid == false)
        #expect(schemaReport.manifestValid == false)
        #expect(!schemaReport.issues.isEmpty)
    }

    @Test("Public CAR commit DID mismatch fails closed and cleans up staging directory")
    func testPublicBackupRejectsCommitDIDMismatch() async throws {
        let rootDir = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let pdsURL = try #require(URL(string: "https://alice.pds.example"))
        // CAR claims bobDID while caller requests aliceDID
        let mismatchedFixture = BackupTestPublicCARBuilder.makeSamplePublicCAR(did: Self.bobDID)
        let service = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in mismatchedFixture.carData }
        ))

        await #expect(throws: BackupError.self) {
            _ = try await service.createPublicBackup(
                did: Self.aliceDID,
                pdsURL: pdsURL,
                rootDirectory: rootDir
            )
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: []
        )
        #expect(remaining.isEmpty)
    }

    @Test("Offline record loading and LocalBackupBrowserView filtering require zero network calls")
    func testOfflineRecordLoadingAndFiltering() async throws {
        let rootDir = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let pdsURL = try #require(URL(string: "https://alice.pds.example"))
        let fixture = BackupTestPublicCARBuilder.makeSamplePublicCAR(did: Self.aliceDID)
        let createService = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in fixture.carData }
        ))

        let summary = try await createService.createPublicBackup(
            did: Self.aliceDID,
            pdsURL: pdsURL,
            rootDirectory: rootDir
        )

        // Separate service whose network transport always throws — proves 100% offline read
        let offlineService = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in
                throw BackupError.verificationFailed("Network must not be called for offline browsing")
            }
        ))

        let loadedRecords = try offlineService.loadRecords(at: summary.packageURL)
        #expect(loadedRecords.count == 2)
        #expect(Set(loadedRecords.map(\.id)) == [
            "app.bsky.actor.profile/self",
            "app.bsky.feed.post/3kpost1",
        ])

        let post = try #require(loadedRecords.first(where: { $0.collection == "app.bsky.feed.post" }))
        #expect(post.cid == fixture.postCID.string)
        #expect(post.prettyJSON.contains("Offline backup verification post"))

        let filteredByCollection = LocalBackupBrowserView.filterRecords(
            loadedRecords,
            collection: "app.bsky.feed.post",
            query: ""
        )
        #expect(filteredByCollection.map(\.id) == ["app.bsky.feed.post/3kpost1"])

        let filteredByJSON = LocalBackupBrowserView.filterRecords(
            loadedRecords,
            collection: nil,
            query: "Alice Backup Test"
        )
        #expect(filteredByJSON.map(\.id) == ["app.bsky.actor.profile/self"])
    }

    @Test("Space STAR backup routes own vs foreign writers exclusively without falling back to public sync and verifies archive")
    func testSpaceSTARBackupOwnAndForeignRoutingAndVerification() async throws {
        let rootDir = try makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let ownDID = Self.aliceDID
        let foreignDID = Self.bobDID
        let spaceURI = "at://\(ownDID)/space/app.bsky.bookmarks/shared"
        let ownFixture = try TestSTARFixtureHelper.makeFixture(authorDID: ownDID, spaceURI: spaceURI)
        let foreignFixture = try TestSTARFixtureHelper.makeFixture(authorDID: foreignDID, spaceURI: spaceURI)

        let spaceItem = SpaceItem(ref: ownFixture.spaceRef, accountDID: ownDID)
        let ownRepo = RepoEntry(did: ownDID, rev: TestCARFixtureHelper.revision, hash: "")
        let foreignRepo = RepoEntry(did: foreignDID, rev: TestCARFixtureHelper.revision, hash: "")

        actor CallTracker {
            var publicSyncCalls = 0
            var clientGetRepoCalls = 0
            var credentialGetCalls = 0
            var credentialURLs: [URL] = []

            func recordPublicSync() { publicSyncCalls += 1 }
            func recordClientGetRepo() { clientGetRepoCalls += 1 }
            func recordCredentialGet(_ url: URL) {
                credentialGetCalls += 1
                credentialURLs.append(url)
            }
        }
        let tracker = CallTracker()

        let service = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in
                await tracker.recordPublicSync()
                throw BackupError.verificationFailed("Space backup must NEVER fall back to public sync")
            }
        ))

        let writerPDS = try #require(URL(string: "https://writer.pds.example"))

        // 1. Own writer repo backup
        let ownSummary = try await service.createSpaceBackup(
            space: spaceItem,
            repo: ownRepo,
            accountDID: ownDID,
            fallbackOwnPDSURL: writerPDS,
            rootDirectory: rootDir,
            clientGetRepo: { _, _ in
                await tracker.recordClientGetRepo()
                return (200, ownFixture.archive)
            },
            resolveDIDToPDS: { _ in writerPDS },
            credentialGet: { url, _ in
                await tracker.recordCredentialGet(url)
                return (200, ownFixture.archive)
            }
        )

        #expect(await tracker.publicSyncCalls == 0)
        #expect(await tracker.clientGetRepoCalls == 1)
        #expect(await tracker.credentialGetCalls == 0)
        #expect(ownSummary.manifest.isSpaceBackup == true)
        #expect(ownSummary.manifest.spaceURI == spaceURI)
        #expect(ownSummary.manifest.accessClassification == .permissionedSpace(spaceURI: spaceURI, writerDID: ownDID))
        #expect(ownSummary.manifest.commitRev == TestCARFixtureHelper.revision)
        #expect(ownSummary.manifest.recordCount == 2)

        let ownVerifyReport = try await service.verifyPackage(at: ownSummary.packageURL)
        #expect(ownVerifyReport.isValid == true)
        #expect(ownVerifyReport.carSHA256Matches == true)
        #expect(ownVerifyReport.manifestValid == true)
        #expect(ownVerifyReport.recordCount == 2)

        let ownRecords = try service.loadRecords(at: ownSummary.packageURL)
        #expect(ownRecords.count == 2)
        #expect(ownRecords.contains(where: { $0.id == "app.bsky.feed.post/one" && $0.prettyJSON.contains("hello") }))

        // 2. Foreign writer repo backup
        let foreignSummary = try await service.createSpaceBackup(
            space: spaceItem,
            repo: foreignRepo,
            accountDID: ownDID,
            rootDirectory: rootDir,
            clientGetRepo: { _, _ in
                await tracker.recordClientGetRepo()
                return (200, foreignFixture.archive)
            },
            resolveDIDToPDS: { _ in writerPDS },
            credentialGet: { url, _ in
                await tracker.recordCredentialGet(url)
                return (200, foreignFixture.archive)
            }
        )

        #expect(await tracker.publicSyncCalls == 0)
        #expect(await tracker.clientGetRepoCalls == 1)
        #expect(await tracker.credentialGetCalls == 1)
        let fetchedURL = try #require(await tracker.credentialURLs.first)
        #expect(fetchedURL.path == "/xrpc/com.atproto.space.getRepo")

        let foreignVerifyReport = try await service.verifyPackage(at: foreignSummary.packageURL)
        #expect(foreignVerifyReport.isValid == true)
        #expect(foreignVerifyReport.recordCount == 2)

        // 3. Tampering with 1 byte of the Space STAR repo.car fails verification
        let spaceCARURL = foreignSummary.packageURL.appendingPathComponent("repo.car")
        var tamperedSpaceBytes = try Data(contentsOf: spaceCARURL)
        let lastByte = tamperedSpaceBytes.index(before: tamperedSpaceBytes.endIndex)
        tamperedSpaceBytes[lastByte] ^= 0x01
        try tamperedSpaceBytes.write(to: spaceCARURL, options: .atomic)

        let tamperedSpaceReport = try await service.verifyPackage(at: foreignSummary.packageURL)
        #expect(tamperedSpaceReport.isValid == false)
        #expect(tamperedSpaceReport.carSHA256Matches == false)
        #expect(!tamperedSpaceReport.issues.isEmpty)
    }

    @Test("BackupStore reload, verify, export copy, and move-to-Trash update state cleanly")
    @MainActor
    func testBackupStoreLifecycleExportAndMoveToTrash() async throws {
        let rootDir = try makeIsolatedTempDirectory(prefix: "ATProtoDriveBackupStoreTests")
        let exportDir = try makeIsolatedTempDirectory(prefix: "ATProtoDriveBackupExportTests")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: exportDir)
        }

        let pdsURL = try #require(URL(string: "https://alice.pds.example"))
        let fixture = BackupTestPublicCARBuilder.makeSamplePublicCAR(did: Self.aliceDID)
        let service = BackupService(operations: .init(
            fetchPublicRepoCAR: { _, _, _ in fixture.carData }
        ))

        let store = BackupStore(rootDirectory: rootDir, service: service)
        store.reload()
        #expect(store.packages.isEmpty)

        let created = try await store.createPublicBackup(
            did: Self.aliceDID,
            handle: "alice.bsky.social",
            pdsURL: pdsURL
        )
        #expect(store.packages.count == 1)
        #expect(store.packages(forAccountDID: Self.aliceDID).count == 1)
        #expect(store.otherPackages(excludingAccountDID: Self.aliceDID).isEmpty)

        // Verify via store
        let report = try await store.verify(package: created)
        #expect(report.isValid == true)
        #expect(store.verificationReports[created.id]?.isValid == true)

        // Load offline records via store
        let records = try store.loadRecords(for: created)
        #expect(records.count == 2)

        // Export copy to another folder and verify copy integrity
        let exportedURL = exportDir.appendingPathComponent(created.packageURL.lastPathComponent, isDirectory: true)
        let copied = try store.export(package: created, to: exportedURL)
        let copiedReport = try await service.verifyPackage(at: copied)
        #expect(copiedReport.isValid == true)

        // Move to Trash via store
        try store.trash(package: created)
        #expect(store.packages.isEmpty)
        #expect(store.verificationReports[created.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: created.packageURL.path))

        // Fresh store reload against the same directory confirms package is gone
        let reloadedStore = BackupStore(rootDirectory: rootDir, service: service)
        reloadedStore.reload()
        #expect(reloadedStore.packages.isEmpty)
    }
}
