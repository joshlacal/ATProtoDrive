import Foundation
import Testing
@testable import ATProtoDrive

private actor GatedCollectionPublicRepositoryService: PublicRepositoryServing {
    private var fetchContinuation: CheckedContinuation<RepositoryRecordPage, any Error>?
    private var fetchStarted = false
    private var fetchStartWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilCollectionFetchStarts() async {
        if fetchStarted { return }
        await withCheckedContinuation { continuation in
            fetchStartWaiters.append(continuation)
        }
    }

    func completeCollectionFetch() {
        fetchContinuation?.resume(returning: .init(records: [], cursor: nil))
        fetchContinuation = nil
    }

    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository {
        .fixture
    }

    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        .fixture(collections: ["app.bsky.feed.post", "com.example.unknown"])
    }

    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        try await withCheckedThrowingContinuation { continuation in
            fetchContinuation = continuation
            fetchStarted = true
            for waiter in fetchStartWaiters { waiter.resume() }
            fetchStartWaiters.removeAll()
        }
    }

    func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow {
        throw BrowserFailure.notFound(resource: rkey)
    }
}

@Suite("Public Files navigation races")
@MainActor
struct PublicFilesNavigationRaceTests {
    private let requestedCollection = "app.bsky.feed.post"
    private let otherCollection = "com.example.unknown"

    @Test("pending collection fetch does not replace a Files to Records navigation")
    func recordsNavigationWinsPendingCollectionFetch() async throws {
        let context = try await makePendingOpen()
        let recordsPath = BrowserPath(
            source: context.source,
            components: [.repository(context.scope)],
            repositoryDestination: .records
        )
        let retainedSelection = ResourceReference.collection(
            scope: context.scope,
            collection: otherCollection
        )

        context.session.navigate(to: recordsPath)
        #expect(context.session.replaceSelection(with: [retainedSelection]))
        await context.service.completeCollectionFetch()
        let opened = await context.openTask.value

        #expect(opened == false)
        #expect(context.session.path == recordsPath)
        #expect(context.session.selectedSource == context.source)
        #expect(context.session.selectedReferences == [retainedSelection.stableID: retainedSelection])
    }

    @Test("pending collection fetch does not replace another collection navigation")
    func otherCollectionNavigationWinsPendingFetch() async throws {
        let context = try await makePendingOpen()
        let otherCollectionPath = BrowserPath(
            source: context.source,
            components: [
                .repository(context.scope),
                .collection(scope: context.scope, collection: otherCollection)
            ],
            repositoryDestination: .records
        )
        let retainedSelection = ResourceReference.collection(
            scope: context.scope,
            collection: otherCollection
        )

        context.session.navigate(to: otherCollectionPath)
        #expect(context.session.replaceSelection(with: [retainedSelection]))
        await context.service.completeCollectionFetch()
        let opened = await context.openTask.value

        #expect(opened == false)
        #expect(context.session.path == otherCollectionPath)
        #expect(context.session.selectedSource == context.source)
        #expect(context.session.selectedReferences == [retainedSelection.stableID: retainedSelection])
    }

    @Test("pending collection fetch does not restore a source after the user leaves")
    func sourceNavigationWinsPendingCollectionFetch() async throws {
        let context = try await makePendingOpen()
        let replacementSource = BrowserSource.global(.openPublicRepository)

        context.session.selectSource(replacementSource)
        await context.service.completeCollectionFetch()
        let opened = await context.openTask.value

        #expect(opened == false)
        #expect(context.session.selectedSource == replacementSource)
        #expect(context.session.path == nil)
        #expect(context.session.selectedReferences.isEmpty)
    }

    private func makePendingOpen() async throws -> PendingOpenContext {
        let service = GatedCollectionPublicRepositoryService()
        let store = PublicRepositoryStore(service: service)
        await store.open(target: .publicIdentifier("alice.test"))
        let scope = try #require(store.state.snapshot?.repository.scope)
        let source = BrowserSource.openedPublicRepository(did: ResolvedRepository.fixture.did)
        let filesPath = BrowserPath(
            source: source,
            components: [.repository(scope)],
            repositoryDestination: .files
        )
        let session = BrowserSession()
        session.navigate(to: filesPath)

        let openTask = Task { @MainActor in
            await PublicRepositoryOpenCoordinator.openCollection(
                requestedCollection,
                store: store,
                session: session
            )
        }
        await service.waitUntilCollectionFetchStarts()
        return PendingOpenContext(
            service: service,
            session: session,
            source: source,
            scope: scope,
            openTask: openTask
        )
    }
}

@MainActor
private struct PendingOpenContext {
    let service: GatedCollectionPublicRepositoryService
    let session: BrowserSession
    let source: BrowserSource
    let scope: RepositoryScope
    let openTask: Task<Bool, Never>
}
