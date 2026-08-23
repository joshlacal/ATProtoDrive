import Foundation
import Testing
@testable import ATProtoDrive

@Suite("Public record store")
struct PublicRecordStoreTests {
    @MainActor
    @Test("empty pages advance and a repeated cursor terminates")
    func emptyPageAndCycle() async {
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [], cursor: "opaque+/="),
            "opaque+/=": .init(records: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")], cursor: "opaque+/=")
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        #expect(store.rows.isEmpty)
        #expect(store.canLoadMore)
        await store.loadNextPage()
        #expect(store.rows.map(\.uri) == ["at://\(ResolvedRepository.fixture.did)/app.test.item/1"])
        #expect(!store.canLoadMore)
        #expect(await service.requestedCursors == [nil, "opaque+/="])
    }

    @MainActor
    @Test("failed refresh keeps visible rows")
    func failedRefreshIsStale() async {
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        await service.fail(with: .offline)
        await store.refresh()
        #expect(store.rows.count == 1)
        #expect(store.state.isStale)
    }

    @MainActor
    @Test("append failure retains its exact cursor and retries only that page")
    func appendFailureRetry() async {
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [], cursor: "retry+/="),
            "retry+/=": .init(records: [.fixture(
                uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/recovered",
                rkey: "recovered",
                cid: "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"
            )], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        await service.failNextPage(cursor: "retry+/=", with: .offline)
        await store.loadNextPage()
        #expect(store.rows.isEmpty)
        #expect(store.appendFailure == .offline)
        #expect(store.retryCursor == "retry+/=")
        #expect(store.canRetryPage)
        await store.retryFailedPage()
        #expect(store.rows.map(\.rkey) == ["recovered"])
        #expect(store.appendFailure == nil)
        #expect(await service.requestedCursors == [nil, "retry+/=", "retry+/="])
    }

    @MainActor
    @Test("a newer target clears old rows and wins a non-cooperative race")
    func targetGenerationWins() async {
        let service = DeferredPublicRepositoryService()
        let store = PublicRepositoryStore(service: service)
        let first = RepositoryTarget.publicIdentifier("first.test")
        let second = RepositoryTarget.publicIdentifier("second.test")
        let firstOpen = Task { @MainActor in await store.open(target: first) }
        await service.waitUntilResolveStarted(for: first)
        let secondOpen = Task { @MainActor in await store.open(target: second) }
        await service.waitUntilResolveStarted(for: second)
        await service.complete(target: second, with: .secondFixture)
        await service.completeIgnoringCancellation(target: first, with: .fixture)
        _ = await (firstOpen.value, secondOpen.value)
        #expect(store.target == second)
        #expect(store.state.snapshot?.repository.did == ResolvedRepository.secondFixture.did)
        #expect(store.cachedCollectionCount == 0)
    }

    @MainActor
    @Test("two repository stores over same service maintain isolated window state")
    func windowLocalIsolation() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store1 = PublicRepositoryStore(service: service)
        let store2 = PublicRepositoryStore(service: service)
        await store1.open(target: .publicIdentifier("alice.test"))
        #expect(store1.target == .publicIdentifier("alice.test"))
        #expect(store2.target == nil)
        _ = store1.recordStore(for: "app.test.item")
        #expect(store1.cachedCollectionCount == 1)
        #expect(store2.cachedCollectionCount == 0)
    }

    @MainActor
    @Test("first page only loads correctly")
    func firstPageOnly() async {
        let row1 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row1], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        #expect(store.rows == [row1])
        #expect(store.nextCursor == nil)
        #expect(!store.canLoadMore)
        #expect(await service.requestedCursors == [nil])
    }

    @MainActor
    @Test("two appended pages paginate in sequence")
    func twoAppendedPages() async {
        let row1 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1")
        let row2 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/2", rkey: "2", cid: "cid2")
        let row3 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/3", rkey: "3", cid: "cid3")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row1], cursor: "c1"),
            "c1": .init(records: [row2], cursor: "c2"),
            "c2": .init(records: [row3], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        #expect(store.rows == [row1])
        #expect(store.canLoadMore)
        await store.loadNextPage()
        #expect(store.rows == [row1, row2])
        #expect(store.canLoadMore)
        await store.loadNextPage()
        #expect(store.rows == [row1, row2, row3])
        #expect(!store.canLoadMore)
        #expect(await service.requestedCursors == [nil, "c1", "c2"])
    }

    @MainActor
    @Test("exact parameter stability preserves repo collection limit and reverse")
    func parameterStability() async {
        actor ParamRecordingService: PublicRepositoryServing {
            var recordedLimits: [Int] = []
            var recordedReverses: [Bool] = []
            var recordedCollections: [String] = []
            func resolve(target: RepositoryTarget) async throws -> ResolvedRepository { .fixture }
            func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription { .fixture(collections: []) }
            func listRecords(
                in repository: ResolvedRepository,
                collection: String,
                cursor: String?,
                limit: Int,
                reverse: Bool
            ) async throws -> RepositoryRecordPage {
                recordedLimits.append(limit)
                recordedReverses.append(reverse)
                recordedCollections.append(collection)
                return .init(records: [], cursor: cursor == nil ? "c1" : nil)
            }
            func getRecord(in repository: ResolvedRepository, collection: String, rkey: String, cid: String?) async throws -> RecordRow {
                throw BrowserFailure.notFound(resource: rkey)
            }
        }
        let service = ParamRecordingService()
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.custom", pageLimit: 42, reverse: true)
        await store.loadFirstPage()
        await store.loadNextPage()
        let limits = await service.recordedLimits
        let reverses = await service.recordedReverses
        let collections = await service.recordedCollections
        #expect(limits == [42, 42])
        #expect(reverses == [true, true])
        #expect(collections == ["app.test.custom", "app.test.custom"])
    }

    @MainActor
    @Test("duplicate (URI, CID) removal across pages")
    func deduplication() async {
        let row1 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1")
        let row2 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/2", rkey: "2", cid: "cid2")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row1, row2], cursor: "c1"),
            "c1": .init(records: [row1, row2], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        #expect(store.rows.count == 2)
        await store.loadNextPage()
        #expect(store.rows.count == 2)
        #expect(store.rows == [row1, row2])
    }

    @MainActor
    @Test("same URI with new CID replaces older row in place")
    func sameURIUpdatedCID() async {
        let row1Old = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1_old", json: "old")
        let row2 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/2", rkey: "2", cid: "cid2")
        let row1New = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1_new", json: "new")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row1Old, row2], cursor: "c1"),
            "c1": .init(records: [row1New], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        #expect(store.rows.map(\.cid) == ["cid1_old", "cid2"])
        await store.loadNextPage()
        #expect(store.rows.count == 2)
        #expect(store.rows.map(\.cid) == ["cid1_new", "cid2"])
        #expect(store.rows[0].json == "new")
    }

    @MainActor
    @Test("first-page refresh removes records no longer returned in same store")
    func firstPageRefreshRemovesDeletedRecords() async {
        let row1 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1")
        let row2 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/2", rkey: "2", cid: "cid2")
        let row3 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/3", rkey: "3", cid: "cid3")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row1, row2], cursor: "c1"),
            "c1": .init(records: [row3], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        await store.loadNextPage()
        #expect(store.rows.count == 3)

        // Re-script the same service and refresh the same store
        await service.setPages([
            nil: .init(records: [row1], cursor: nil)
        ])
        await store.refresh()
        #expect(store.rows == [row1])
        #expect(store.rows.count == 1)
        #expect(!store.canLoadMore)
    }

    @MainActor
    @Test("cancellation restores pre-request state without permanent loading spinner")
    func cancellationRestoresState() async {
        actor BlockingService: PublicRepositoryServing {
            private var continuation: CheckedContinuation<RepositoryRecordPage, any Error>?
            private var started: [CheckedContinuation<Void, Never>] = []
            func waitUntilStarted() async {
                await withCheckedContinuation { started.append($0) }
            }
            func cancelWaiting() {
                continuation?.resume(throwing: CancellationError())
                continuation = nil
            }
            func resolve(target: RepositoryTarget) async throws -> ResolvedRepository { .fixture }
            func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription { .fixture(collections: []) }
            func listRecords(in repository: ResolvedRepository, collection: String, cursor: String?, limit: Int, reverse: Bool) async throws -> RepositoryRecordPage {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { cont in
                        self.continuation = cont
                        for waiter in started { waiter.resume() }
                        started.removeAll()
                    }
                } onCancel: {
                    Task { await self.cancelWaiting() }
                }
            }
            func getRecord(in repository: ResolvedRepository, collection: String, rkey: String, cid: String?) async throws -> RecordRow {
                throw BrowserFailure.notFound(resource: rkey)
            }
        }
        let service = BlockingService()
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        let loadTask = Task { @MainActor in
            await store.loadFirstPage()
        }
        await service.waitUntilStarted()
        loadTask.cancel()
        _ = await loadTask.value
        // State must be restored to .idle, not stuck in .loading
        if case .idle = store.state {
            #expect(true)
        } else {
            #expect(Bool(false), "State should have been restored to .idle on cancellation")
        }
    }

    @MainActor
    @Test("loadCollection fires from failed state and enables retry with inspectable failure")
    func loadCollectionRetriesAfterFailure() async {
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", cid: "cid1")], cursor: nil)
        ])
        let repoStore = PublicRepositoryStore(service: service)
        await repoStore.open(target: .publicIdentifier("alice.test"))

        // Simulate transient network failure on collection load
        await service.fail(with: .offline)
        let failedStore = await repoStore.loadCollection("app.test.item")
        #expect(failedStore != nil)
        #expect(failedStore?.state.isStale == false)
        if case .failed(_, let failure) = failedStore?.state {
            #expect(failure == .offline)
        } else {
            #expect(Bool(false), "Expected store to be in .failed state")
        }

        // Clear failure and retry loadCollection
        await service.clearFailure()
        let retriedStore = await repoStore.loadCollection("app.test.item")
        #expect(retriedStore != nil)
        if case .loaded(let rows) = retriedStore?.state {
            #expect(rows.count == 1)
        } else {
            #expect(Bool(false), "Expected store to be in .loaded state after retry")
        }
    }

    @MainActor
    @Test("empty terminal page terminates pagination")
    func emptyTerminalPage() async {
        let row1 = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row1], cursor: "c1"),
            "c1": .init(records: [], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        await store.loadFirstPage()
        #expect(store.canLoadMore)
        await store.loadNextPage()
        #expect(store.rows == [row1])
        #expect(!store.canLoadMore)
        #expect(store.nextCursor == nil)
    }

    @MainActor
    @Test("concurrent double-load suppression")
    func concurrentDoubleLoadSuppression() async {
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", cid: "cid1")], cursor: nil)
        ])
        let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
        async let t1: Void = store.loadFirstPage()
        async let t2: Void = store.loadFirstPage()
        _ = await (t1, t2)
        #expect(await service.requestedCursors.count == 1)
    }

    @MainActor
    @Test("record locator lookup in repository store")
    func recordLocatorLookup() async {
        let row = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", rkey: "1", cid: "cid1")
        let service = ScriptedPublicRepositoryService(pages: [
            nil: .init(records: [row], cursor: nil)
        ])
        let store = PublicRepositoryStore(service: service)
        await store.open(target: .publicIdentifier("alice.test"))
        _ = await store.loadCollection("app.test.item")
        let reference = ResourceReference.record(RecordLocator(
            scope: ResolvedRepository.fixture.scope,
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1",
            collection: "app.test.item",
            rkey: "1",
            cid: "cid1"
        ))
        let found = store.record(for: reference)
        #expect(found?.uri == row.uri)
        #expect(found?.cid == row.cid)
    }
}
