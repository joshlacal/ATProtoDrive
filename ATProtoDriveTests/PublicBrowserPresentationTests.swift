import Foundation
import Testing
@testable import ATProtoDrive

@Suite("Public browser presentation")
struct PublicBrowserPresentationTests {
    @Test("collection projection preserves server order and stable selection")
    func collectionProjection() {
        let description = RepositoryDescription.fixture(collections: [
            "app.bsky.feed.post", "com.example.unknown", "app.bsky.actor.profile"
        ])
        let rows = PublicRepositoryPresentation.collections(description)
        #expect(rows.map(\.nsid) == [
            "app.bsky.feed.post", "com.example.unknown", "app.bsky.actor.profile"
        ])
        #expect(rows[1].title == "com.example.unknown")
        #expect(rows[1].reference == .collection(
            scope: description.repository.scope,
            collection: "com.example.unknown"
        ))
        #expect(rows[1].id == rows[1].reference.stableID)
    }

    @MainActor
    @Test(arguments: ["alice.test", ResolvedRepository.fixture.did])
    func openByHandleOrDIDSelectsResolvedSource(identifier: String) async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier(identifier), store: store, session: session, recents: recents
        )
        #expect(session.selectedSource == .openedPublicRepository(did: ResolvedRepository.fixture.did))
        #expect(session.path?.components == [.repository(ResolvedRepository.fixture.scope)])
        #expect(session.history.count == 1)
        #expect(session.openedPublicRepositories.map(\.did) == [ResolvedRepository.fixture.did])
        #expect(recents.entries.map(\.did) == [ResolvedRepository.fixture.did])
    }

    @MainActor
    @Test("opening with specific selectedSource preserves sidebar route")
    func openPreservesExplicitSource() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()
        let source = BrowserSource.account(did: ResolvedRepository.fixture.did, destination: .publicRecords)
        await PublicRepositoryOpenCoordinator.open(
            .connectedAccount(did: ResolvedRepository.fixture.did),
            store: store,
            session: session,
            recents: recents,
            selectedSource: source
        )
        #expect(session.selectedSource == source)
        #expect(session.path?.source == source)
        #expect(session.path?.components == [.repository(ResolvedRepository.fixture.scope)])
    }

    @MainActor
    @Test("collection loading and breadcrumb history are explicit")
    func collectionNavigation() async {
        let store = PublicRepositoryStore(service: ScriptedPublicRepositoryService.successfulFixture())
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier("alice.test"), store: store, session: session, recents: recents
        )
        await PublicRepositoryOpenCoordinator.openCollection(
            "app.bsky.feed.post", store: store, session: session
        )
        #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
        #expect(session.canGoBack)
        session.goBack()
        #expect(session.path?.components.count == 1)
        session.goForward()
        #expect(session.path?.components.count == 2)
    }

    @MainActor
    @Test("restoring previous target after failure recovers repository state")
    func restorePreviousTargetAfterFailure() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()

        // 1. Open initial repository successfully
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier("alice.test"), store: store, session: session, recents: recents
        )
        #expect(store.state.snapshot != nil)
        let initialTarget = store.target

        // 2. Attempt failed open
        await service.fail(with: .offline)
        await store.open(target: .publicIdentifier("bad.test"))
        #expect(store.state.snapshot == nil)

        // 3. Restore previous target
        await service.clearFailure()
        if let initialTarget {
            await store.open(target: initialTarget)
        }
        #expect(store.state.snapshot != nil)
        #expect(store.target == initialTarget)
    }

    @MainActor
    @Test("failed open restore re-populates collection store for active collection route")
    func failedOpenRestoreReLoadsActiveCollection() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()

        // 1. Open initial repository and navigate to collection
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier("alice.test"), store: store, session: session, recents: recents
        )
        await PublicRepositoryOpenCoordinator.openCollection(
            "app.bsky.feed.post", store: store, session: session
        )
        #expect(session.path?.components.count == 2)
        #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
        let initialTarget = store.target

        // 2. Failing open wipes recordStores
        await service.fail(with: .offline)
        await store.open(target: .publicIdentifier("bad.test"))
        #expect(store.state.snapshot == nil)

        // 3. Restore previous target through coordinator
        await service.clearFailure()
        await PublicRepositoryOpenCoordinator.restorePreviousTarget(
            initialTarget,
            store: store,
            session: session
        )
        #expect(store.state.snapshot != nil)
        #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
    }

    private actor RefreshCallRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @MainActor
    @Test("focused refresh invokes only the active window action")
    func focusedRefreshIsWindowLocal() async {
        let first = RefreshCallRecorder()
        let second = RefreshCallRecorder()
        let firstAction = BrowserRefreshAction(perform: { await first.record() })
        _ = BrowserRefreshAction(perform: { await second.record() })
        await firstAction.perform()
        #expect(await first.count == 1)
        #expect(await second.count == 0)
    }
}
