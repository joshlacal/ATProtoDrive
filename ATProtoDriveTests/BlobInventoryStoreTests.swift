import Foundation
import Testing
@testable import ATProtoDrive

private actor InventoryBlobService: PublicBlobServing {
    var pages: [String?: BlobCIDPage]
    var failure: BrowserFailure?
    init(_ pages: [String?: BlobCIDPage]) { self.pages = pages }
    func setFailure(_ failure: BrowserFailure?) { self.failure = failure }
    func listBlobs(in repository: ResolvedRepository, cursor: String?, limit: Int) async throws -> BlobCIDPage {
        if let failure { throw failure }
        return pages[cursor] ?? .init(cids: [])
    }
}

private actor DeferredBlobService: PublicBlobServing {
    private var continuation: CheckedContinuation<BlobCIDPage, any Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ result: Result<BlobCIDPage, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
    func listBlobs(in repository: ResolvedRepository, cursor: String?, limit: Int) async throws -> BlobCIDPage {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

private actor StoreRecordService: PublicRepositoryServing {
    let row: RecordRow
    init(blobCID: String) {
        row = .fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one",
            json: "{\"image\":{\"$type\":\"blob\",\"ref\":{\"$link\":\"\(blobCID)\"},\"mimeType\":\"image/png\",\"size\":42}}"
        )
    }
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository { .fixture }
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        .init(repository: repository, collections: ["app.test.item"])
    }
    func listRecords(in repository: ResolvedRepository, collection: String, cursor: String?, limit: Int, reverse: Bool) async throws -> RepositoryRecordPage {
        .init(records: cursor == nil ? [row] : [], cursor: nil)
    }
    func getRecord(in repository: ResolvedRepository, collection: String, rkey: String, cid: String?) async throws -> RecordRow { row }
}

private actor LateRecordService: PublicRepositoryServing {
    private var calls = 0
    private var firstContinuation: CheckedContinuation<RepositoryRecordPage, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false
    let row: RecordRow

    init(blobCID: String) {
        row = .fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one",
            json: "{\"image\":{\"$type\":\"blob\",\"ref\":{\"$link\":\"\(blobCID)\"}}}"
        )
    }
    func waitForFirstRequest() async {
        if firstStarted { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func releaseFirstRequest() {
        firstContinuation?.resume(returning: .init(records: [], cursor: nil))
        firstContinuation = nil
    }
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository { .fixture }
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        .init(repository: repository, collections: ["app.test.item"])
    }
    func listRecords(in repository: ResolvedRepository, collection: String, cursor: String?, limit: Int, reverse: Bool) async throws -> RepositoryRecordPage {
        calls += 1
        if calls == 1 {
            firstStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return .init(records: [row], cursor: nil)
    }
    func getRecord(in repository: ResolvedRepository, collection: String, rkey: String, cid: String?) async throws -> RecordRow { row }
}

@Suite("Blob inventory store") @MainActor
struct BlobInventoryStoreTests {
    @Test("deduplicates pages and keeps enumeration completeness separate")
    func pagination() async {
        let c1 = "bafkreione"
        let c2 = "bafkreitwo"
        let blobs = InventoryBlobService([
            nil: .init(cids: [c1], cursor: "next"),
            "next": .init(cids: [c1, c2], cursor: nil)
        ])
        let store = BlobInventoryStore(
            repository: .fixture, blobService: blobs,
            recordService: ScriptedPublicRepositoryService.successfulFixture()
        )
        await store.reload()
        #expect(store.snapshot.blobEnumerationComplete == false)
        await store.loadMore()
        #expect(store.snapshot.blobs.map(\.locator.cid).sorted() == [c1, c2])
        #expect(store.snapshot.blobEnumerationComplete)
        #expect(store.snapshot.referenceScanComplete == false)
        #expect(store.snapshot.blobs.allSatisfy { $0.availability == .unknown && $0.verification == .notVerified })
    }

    @Test("repeated cursors remain incomplete and expose retry")
    func cursorCycle() async {
        let blobs = InventoryBlobService([
            nil: .init(cids: ["one"], cursor: "a"),
            "a": .init(cids: ["two"], cursor: "b"),
            "b": .init(cids: ["three"], cursor: "a")
        ])
        let store = BlobInventoryStore(
            repository: .fixture, blobService: blobs,
            recordService: ScriptedPublicRepositoryService.successfulFixture()
        )
        await store.reload()
        await store.loadMore()
        await store.loadMore()
        #expect(store.snapshot.blobEnumerationComplete == false)
        #expect(store.canRetryPage)
        #expect(store.appendFailure != nil)
    }

    @Test("failed refresh retains the last loaded snapshot as stale content")
    func failedRefreshRetainsSnapshot() async {
        let blobs = InventoryBlobService([nil: .init(cids: ["one"], cursor: nil)])
        let store = BlobInventoryStore(
            repository: .fixture, blobService: blobs,
            recordService: ScriptedPublicRepositoryService.successfulFixture()
        )
        await store.reload()
        await blobs.setFailure(.offline)
        await store.reload()
        #expect(store.snapshot.blobs.map(\.locator.cid) == ["one"])
        #expect(store.loadState.isStale)
    }

    @Test("cancelling the first enumeration restores idle instead of publishing an empty load")
    func cancelledInitialReloadRestoresIdle() async {
        let blobs = DeferredBlobService()
        let store = BlobInventoryStore(
            repository: .fixture, blobService: blobs,
            recordService: ScriptedPublicRepositoryService.successfulFixture()
        )
        let load = Task { await store.reload() }
        await blobs.waitUntilStarted()
        load.cancel()
        await blobs.finish(.failure(CancellationError()))
        await load.value
        if case .idle = store.loadState {
            // Expected.
        } else {
            Issue.record("Cancelled initial reload did not restore idle")
        }
        #expect(store.loadState.snapshot == nil)
    }

    @Test("reference completion preserves a failed refresh and its stale snapshot")
    func referenceScanPreservesRefreshFailure() async {
        let referenced = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let blobs = InventoryBlobService([nil: .init(cids: [referenced], cursor: nil)])
        let store = BlobInventoryStore(
            repository: .fixture, blobService: blobs,
            recordService: StoreRecordService(blobCID: referenced)
        )
        await store.reload()
        await blobs.setFailure(.offline)
        await store.reload()
        await store.scanReferences()
        #expect(store.loadState.isStale)
        if case .failed(let previous, let failure) = store.loadState {
            #expect(failure == .offline)
            #expect(previous?.referenceScanComplete == true)
        } else {
            Issue.record("Reference scan erased refresh failure")
        }
    }

    @Test("a scan completed before pagination enriches blobs appended later")
    func scanBeforeAppend() async {
        let referenced = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let blobs = InventoryBlobService([
            nil: .init(cids: ["bafkreione"], cursor: "next"),
            "next": .init(cids: [referenced], cursor: nil)
        ])
        let store = BlobInventoryStore(
            repository: .fixture, blobService: blobs,
            recordService: StoreRecordService(blobCID: referenced)
        )
        await store.reload()
        await store.scanReferences()
        #expect(store.snapshot.blobs.count == 1)
        await store.loadMore()
        let descriptor = store.blob(for: .init(scope: ResolvedRepository.fixture.scope, cid: referenced))
        #expect(descriptor?.mimeType == "image/png")
        #expect(descriptor?.declaredSize == 42)
        #expect(descriptor?.referenceCount == 1)
    }

    @Test("cancelled scan cannot overwrite a restarted scan with a late result")
    func cancelRestartFencesLateResult() async {
        let referenced = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let blobs = InventoryBlobService([nil: .init(cids: [referenced], cursor: nil)])
        let records = LateRecordService(blobCID: referenced)
        let store = BlobInventoryStore(repository: .fixture, blobService: blobs, recordService: records)
        await store.reload()

        let first = Task { await store.scanReferences() }
        await records.waitForFirstRequest()
        store.cancelReferenceScan()
        await store.scanReferences()
        #expect(store.references(to: .init(scope: ResolvedRepository.fixture.scope, cid: referenced)).count == 1)

        await records.releaseFirstRequest()
        await first.value
        #expect(store.references(to: .init(scope: ResolvedRepository.fixture.scope, cid: referenced)).count == 1)
        #expect(store.snapshot.referenceScanComplete)
        #expect(store.isScanningReferences == false)
    }
}
