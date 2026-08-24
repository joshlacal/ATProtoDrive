import Foundation
import Testing
@testable import ATProtoDrive

@Suite("Recent repository store")
struct RecentRepositoryStoreTests {
    @MainActor
    @Test("recents use a versioned envelope, dedupe, and restore without production preferences")
    func recentRepositoryPersistence() async throws {
        let persistence = MemoryRecentRepositoryPersistence()
        let first = RecentRepositoryStore(persistence: persistence, maximumCount: 2)
        let summary = OpenedRepositorySummary(
            did: ResolvedRepository.fixture.did,
            handle: "alice.test.blue",
            pdsURL: ResolvedRepository.fixture.pdsURL,
            sourceAccountDID: ResolvedRepository.fixture.did,
            lastOpenedAt: .distantPast
        )
        await first.remember(summary)
        let newestDate = Date(timeIntervalSince1970: 1_787_488_496)
        await first.remember(.init(
            did: summary.did,
            handle: summary.handle,
            pdsURL: summary.pdsURL,
            sourceAccountDID: summary.sourceAccountDID,
            lastOpenedAt: newestDate
        ))
        let encoded = try #require(await persistence.data)
        #expect(try JSONDecoder().decode(RecentRepositoryEnvelope.self, from: encoded).version == 1)

        let restored = RecentRepositoryStore(persistence: persistence, maximumCount: 2)
        await restored.restore()
        #expect(restored.entries.count == 1)
        #expect(restored.entries[0].lastOpenedAt == newestDate)
    }

    @MainActor
    @Test("recents cap by newest and account cleanup preserves anonymous history")
    func recentRepositoryQualificationAndCap() async {
        let store = RecentRepositoryStore(
            persistence: MemoryRecentRepositoryPersistence(),
            maximumCount: 2
        )
        let did = ResolvedRepository.fixture.did
        let anonymous = OpenedRepositorySummary(
            did: did,
            handle: "alice.test.blue",
            pdsURL: ResolvedRepository.fixture.pdsURL,
            sourceAccountDID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 30)
        )
        let accountQualified = OpenedRepositorySummary(
            did: did,
            handle: "alice.test.blue",
            pdsURL: ResolvedRepository.fixture.pdsURL,
            sourceAccountDID: did,
            lastOpenedAt: Date(timeIntervalSince1970: 20)
        )
        await store.remember(.init(
            did: ResolvedRepository.secondFixture.did,
            handle: nil,
            pdsURL: ResolvedRepository.secondFixture.pdsURL,
            sourceAccountDID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        ))
        await store.remember(accountQualified)
        await store.remember(anonymous)
        #expect(store.entries.map(\.id) == [anonymous.id, accountQualified.id])
        await store.removeEntries(sourceAccountDID: did)
        #expect(store.entries.map(\.id) == [anonymous.id])
    }

    @Test("file persistence failure keeps old envelope and retry replaces with new envelope")
    func filePersistenceFailureKeepsOldEnvelope() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("RecentRepositories-v1.json")
        let initialData = try JSONEncoder().encode(RecentRepositoryEnvelope(version: 1, entries: []))
        try initialData.write(to: fileURL)

        final class ThrowingFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var _shouldThrow = true
            var shouldThrow: Bool {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return _shouldThrow
                }
                set {
                    lock.lock()
                    defer { lock.unlock() }
                    _shouldThrow = newValue
                }
            }
        }
        let flag = ThrowingFlag()

        let persistence = FileRecentRepositoryPersistence(fileURL: fileURL) { data, url in
            if flag.shouldThrow {
                throw NSError(domain: "test", code: -1, userInfo: nil)
            }
            try data.write(to: url, options: .atomic)
        }

        let store = await RecentRepositoryStore(persistence: persistence, maximumCount: 5)
        let summary = OpenedRepositorySummary(
            did: ResolvedRepository.fixture.did,
            handle: "alice.test.blue",
            pdsURL: ResolvedRepository.fixture.pdsURL,
            sourceAccountDID: nil,
            lastOpenedAt: Date()
        )
        await store.remember(summary)
        let storeFailure = await store.failure
        #expect(storeFailure != nil)

        // Old file unchanged and valid
        let diskData = try Data(contentsOf: fileURL)
        let diskEnvelope = try JSONDecoder().decode(RecentRepositoryEnvelope.self, from: diskData)
        #expect(diskEnvelope.entries.isEmpty)

        // Retry succeeds
        flag.shouldThrow = false
        await store.remember(summary)
        let retryFailure = await store.failure
        #expect(retryFailure == nil)

        let newDiskData = try Data(contentsOf: fileURL)
        let newDiskEnvelope = try JSONDecoder().decode(RecentRepositoryEnvelope.self, from: newDiskData)
        #expect(newDiskEnvelope.entries.count == 1)
    }
}
