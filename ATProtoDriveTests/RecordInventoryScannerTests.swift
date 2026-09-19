import Foundation
import Testing
@testable import ATProtoDrive

private actor InventoryRecordService: PublicRepositoryServing {
    var pages: [String?: RepositoryRecordPage]
    var failure: BrowserFailure?
    var failuresByCursor: [String: BrowserFailure] = [:]
    init(pages: [String?: RepositoryRecordPage]) { self.pages = pages }
    func fail(_ value: BrowserFailure?) { failure = value }
    func setPages(_ value: [String?: RepositoryRecordPage]) { pages = value }
    func fail(cursor: String, with failure: BrowserFailure) {
        failuresByCursor[cursor] = failure
    }
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository { .fixture }
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        if let failure { throw failure }
        return .init(repository: repository, collections: ["app.test.item"])
    }
    func listRecords(in repository: ResolvedRepository, collection: String, cursor: String?, limit: Int, reverse: Bool) async throws -> RepositoryRecordPage {
        if let failure { throw failure }
        if let cursor, let cursorFailure = failuresByCursor[cursor] {
            throw cursorFailure
        }
        return pages[cursor] ?? .init(records: [], cursor: nil)
    }
    func getRecord(in repository: ResolvedRepository, collection: String, rkey: String, cid: String?) async throws -> RecordRow {
        throw BrowserFailure.notFound(resource: rkey)
    }
}

@Suite("Public record inventory scan")
struct RecordInventoryScannerTests {
    @Test("scans all pages and preserves occurrence pointers")
    func scanAllPages() async throws {
        let blob = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let service = InventoryRecordService(pages: [
            nil: .init(records: [.fixture(
                uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one",
                json: #"{"image":{"$type":"blob","ref":{"$link":"bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"}}}"#
            )], cursor: "two"),
            "two": .init(records: [], cursor: nil)
        ])
        let index = BlobReferenceIndex()
        let receipt = try await PublicRecordInventoryScanner(service: service).scan(
            repository: .fixture, index: index, progress: { _ in }
        )
        #expect(receipt.recordsScanned == 1)
        #expect(receipt.referencesFound == 1)
        let refs = await index.references(to: .init(scope: ResolvedRepository.fixture.scope, cid: blob))
        #expect(refs.map(\.jsonPointer) == ["/image"])
    }

    @Test("failed rescan never replaces the previous complete index")
    func failedRescanIsAtomic() async throws {
        let blob = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let row = RecordRow.fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one",
            json: #"{"image":{"$type":"blob","ref":{"$link":"bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"}}}"#
        )
        let service = InventoryRecordService(pages: [
            nil: .init(records: [row], cursor: nil)
        ])
        let index = BlobReferenceIndex()
        _ = try await PublicRecordInventoryScanner(service: service).scan(
            repository: .fixture, index: index, progress: { _ in }
        )
        await service.fail(.offline)
        await #expect(throws: BrowserFailure.offline) {
            try await PublicRecordInventoryScanner(service: service).scan(
                repository: .fixture, index: index, progress: { _ in }
            )
        }
        let refs = await index.references(to: .init(scope: ResolvedRepository.fixture.scope, cid: blob))
        #expect(refs.count == 1)
    }

    @Test("rejects a repeated record cursor instead of publishing an incomplete scan")
    func cursorCycleIsRejected() async {
        let service = InventoryRecordService(pages: [
            nil: .init(records: [], cursor: "cycle"),
            "cycle": .init(records: [], cursor: "cycle")
        ])
        let index = BlobReferenceIndex()

        await #expect(throws: BrowserFailure.transport(
            "Record pagination cursor cycle in app.test.item"
        )) {
            try await PublicRecordInventoryScanner(service: service).scan(
                repository: .fixture, index: index, progress: { _ in }
            )
        }
        #expect(await index.references(in: ResolvedRepository.fixture.scope).isEmpty)
    }

    @Test("failure after partial staging preserves the previous complete index")
    func partialStagingFailureIsAtomic() async throws {
        let oldBlob = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let stagedBlob = "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"
        let oldRow = RecordRow.fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/old",
            rkey: "old",
            json: #"{"image":{"$type":"blob","ref":{"$link":"bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"}}}"#
        )
        let stagedRow = RecordRow.fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/staged",
            rkey: "staged",
            json: #"{"image":{"$type":"blob","ref":{"$link":"bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"}}}"#
        )
        let service = InventoryRecordService(pages: [
            nil: .init(records: [oldRow], cursor: nil)
        ])
        let index = BlobReferenceIndex()
        let scanner = PublicRecordInventoryScanner(service: service)
        _ = try await scanner.scan(repository: .fixture, index: index, progress: { _ in })

        await service.setPages([
            nil: .init(records: [stagedRow], cursor: "fail-after-staging")
        ])
        await service.fail(cursor: "fail-after-staging", with: .offline)
        await #expect(throws: BrowserFailure.offline) {
            try await scanner.scan(repository: .fixture, index: index, progress: { _ in })
        }

        let oldRefs = await index.references(to: .init(
            scope: ResolvedRepository.fixture.scope, cid: oldBlob
        ))
        let stagedRefs = await index.references(to: .init(
            scope: ResolvedRepository.fixture.scope, cid: stagedBlob
        ))
        #expect(oldRefs.count == 1)
        #expect(stagedRefs.isEmpty)
    }
}
