import Foundation
import Testing
@testable import ATProtoDrive

actor NeverCompletingPublicRepositoryService: PublicRepositoryServing {
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository {
        try await Task.sleep(for: .seconds(60))
        throw BrowserFailure.unsupported("Unexpected fixture operation")
    }

    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        throw BrowserFailure.unsupported("Unexpected fixture operation")
    }

    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        throw BrowserFailure.unsupported("Unexpected fixture operation")
    }

    func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow {
        throw BrowserFailure.unsupported("Unexpected fixture operation")
    }
}

@MainActor
final class BrowserFixtureScene {
    let session = BrowserSession()
    let repositoryStore: PublicRepositoryStore
    let recentRepositoryStore: RecentRepositoryStore
    private(set) var readiness: FixtureReadiness = .idle

    init(service: any PublicRepositoryServing, recents: RecentRepositoryStore) {
        repositoryStore = PublicRepositoryStore(service: service)
        recentRepositoryStore = recents
    }

    func bootstrap(timeout: Duration) async throws {
        readiness = .loading
        do {
            try await PublicBrowserFixture.bootstrap(
                session: session,
                repositoryStore: repositoryStore,
                recentRepositoryStore: recentRepositoryStore,
                timeout: timeout
            )
            readiness = .ready
        } catch is CancellationError {
            readiness = .idle
            throw CancellationError()
        } catch {
            let failure = BrowserFailure.normalize(error)
            readiness = .failed(failure)
            throw failure
        }
    }
}

@Suite("Public browser fixture")
struct PublicBrowserFixtureTests {
    @MainActor
    @Test("one app-scoped fixture service drives isolated, bounded scene state")
    func fixtureTraversal() async throws {
        let service = FixturePublicRepositoryService()
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let first = BrowserFixtureScene(service: service, recents: recents)
        let second = BrowserFixtureScene(service: service, recents: recents)
        try await first.bootstrap(timeout: .seconds(1))
        #expect(PublicBrowserFixture.accounts.isEmpty)
        #expect(first.readiness == .ready)
        #expect(second.readiness == .idle)
        #expect(second.repositoryStore.target == nil)
        #expect(recents.entries.map(\.did) == [PublicBrowserFixture.did])
        let description = try #require(first.repositoryStore.state.snapshot)
        #expect(description.collections == ["app.bsky.feed.post", "com.example.drive.file"])
        let records = try #require(first.repositoryStore.recordStore(for: "app.bsky.feed.post"))
        while records.canLoadMore { await records.loadNextPage() }
        #expect(records.rows.map(\.rkey) == ["first", "second", "third"])
        #expect(first.session.primarySelection?.stableID.contains(description.repository.scope.stableID) == true)
    }

    @MainActor
    @Test("fixture bootstrap times out with a visible typed failure")
    func fixtureTimeout() async {
        let service = NeverCompletingPublicRepositoryService()
        let scene = BrowserFixtureScene(
            service: service,
            recents: RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        )
        await #expect(throws: BrowserFailure.transport("Fixture readiness timed out")) {
            try await scene.bootstrap(timeout: .milliseconds(20))
        }
        #expect(scene.readiness.isFailure)
    }

    @MainActor
    @Test("cancelled fixture bootstrap resets readiness to idle")
    func fixtureCancellation() async {
        let service = NeverCompletingPublicRepositoryService()
        let scene = BrowserFixtureScene(
            service: service,
            recents: RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        )
        let task = Task { @MainActor in
            try await scene.bootstrap(timeout: .seconds(10))
        }
        task.cancel()
        _ = try? await task.value
        #expect(scene.readiness == .idle)
    }

    @MainActor
    @Test("cancelled open leaves repository store in pre-request state")
    func cancelledOpenLeavesStateUntouched() async {
        let service = NeverCompletingPublicRepositoryService()
        let store = PublicRepositoryStore(service: service)
        if case .idle = store.state {
            #expect(true)
        } else {
            Issue.record("Expected store state to be idle initially")
        }
        let task = Task { @MainActor in
            await store.open(target: .publicIdentifier("fixture.test"))
        }
        task.cancel()
        await task.value
        if case .idle = store.state {
            #expect(true)
        } else {
            Issue.record("Expected store state to remain idle after cancelled open")
        }
    }
}
