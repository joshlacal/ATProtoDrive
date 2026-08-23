import Foundation
import Petrel
@testable import ATProtoDrive

extension ResolvedRepository {
    static let fixture = ResolvedRepository(
        did: "did:plc:4hqjfn7m6n5hno3doamuhgef",
        handle: "alice.test",
        pdsURL: URL(string: "https://alice.example")!,
        connectedAccountDID: nil,
        handleIsCorrect: true
    )

    static let secondFixture = ResolvedRepository(
        did: "did:web:second.example",
        handle: nil,
        pdsURL: URL(string: "https://second.example")!,
        connectedAccountDID: nil,
        handleIsCorrect: nil
    )
}

extension RepositoryDescription {
    static func fixture(collections: [String]) -> Self {
        .init(repository: .fixture, collections: collections)
    }
}

extension RecordRow {
    static func fixture(
        uri: String,
        collection: String = "app.test.item",
        rkey: String = "one",
        cid: String = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a",
        json: String = #"{"$type":"app.test.item","name":"Fixture"}"#
    ) -> Self {
        .init(
            uri: uri,
            collection: collection,
            rkey: rkey,
            cid: cid,
            json: json,
            origin: .publicRepository(did: ResolvedRepository.fixture.did)
        )
    }
}

actor ScriptedPublicRepositoryService: PublicRepositoryServing {
    private var pages: [String: RepositoryRecordPage]
    private var firstPage: RepositoryRecordPage?
    private var failure: BrowserFailure?
    private var failuresByCursor: [String: BrowserFailure] = [:]
    private(set) var requestedCursors: [String?] = []

    init(pages: [String?: RepositoryRecordPage]) {
        firstPage = pages[nil]
        self.pages = Dictionary(uniqueKeysWithValues: pages.compactMap { entry in
            entry.key.map { ($0, entry.value) }
        })
    }

    static func successfulFixture() -> ScriptedPublicRepositoryService {
        .init(pages: [nil: .init(records: [], cursor: nil)])
    }

    func setPages(_ pages: [String?: RepositoryRecordPage]) {
        firstPage = pages[nil]
        self.pages = Dictionary(uniqueKeysWithValues: pages.compactMap { entry in
            entry.key.map { ($0, entry.value) }
        })
    }

    func fail(with failure: BrowserFailure) { self.failure = failure }
    func failNextPage(cursor: String, with failure: BrowserFailure) {
        failuresByCursor[cursor] = failure
    }
    func clearFailure() {
        failure = nil
        failuresByCursor.removeAll()
    }
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository {
        if let failure { throw failure }
        return .fixture
    }
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        if let failure { throw failure }
        return .fixture(collections: ["app.bsky.feed.post", "com.example.unknown"])
    }
    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        if let failure { throw failure }
        requestedCursors.append(cursor)
        if let cursor, let failure = failuresByCursor.removeValue(forKey: cursor) {
            throw failure
        }
        if let cursor { return pages[cursor] ?? .init(records: [], cursor: nil) }
        return firstPage ?? .init(records: [], cursor: nil)
    }
    func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow {
        if let failure { throw failure }
        throw BrowserFailure.notFound(resource: rkey)
    }
}

actor DeferredPublicRepositoryService: PublicRepositoryServing {
    private var resolveWaiters: [RepositoryTarget: [CheckedContinuation<Void, Never>]] = [:]
    private var resolveStarted: Set<RepositoryTarget> = []
    private var resolveContinuations: [RepositoryTarget: CheckedContinuation<ResolvedRepository, any Error>] = [:]

    func waitUntilResolveStarted(for target: RepositoryTarget) async {
        if resolveStarted.contains(target) { return }
        await withCheckedContinuation { continuation in
            resolveWaiters[target, default: []].append(continuation)
        }
    }

    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository {
        resolveStarted.insert(target)
        if let waiters = resolveWaiters.removeValue(forKey: target) {
            for waiter in waiters { waiter.resume() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            resolveContinuations[target] = continuation
        }
    }

    func complete(target: RepositoryTarget, with repository: ResolvedRepository) {
        if let continuation = resolveContinuations.removeValue(forKey: target) {
            continuation.resume(returning: repository)
        }
    }

    func completeIgnoringCancellation(target: RepositoryTarget, with repository: ResolvedRepository) {
        if let continuation = resolveContinuations.removeValue(forKey: target) {
            continuation.resume(returning: repository)
        }
    }

    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        .init(repository: repository, collections: [])
    }

    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        .init(records: [], cursor: nil)
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
