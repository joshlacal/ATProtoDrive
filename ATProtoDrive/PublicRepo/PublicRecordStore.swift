import Foundation
import Observation

@MainActor @Observable
public final class PublicRecordStore {
    public private(set) var state: LoadState<[RecordRow]> = .idle
    public private(set) var nextCursor: String?
    public private(set) var completedCursors: Set<String> = []
    public private(set) var appendFailure: BrowserFailure?
    public private(set) var retryCursor: String?
    public private(set) var isLoadingPage: Bool = false

    public var rows: [RecordRow] { state.snapshot ?? [] }
    public var canLoadMore: Bool { nextCursor != nil && appendFailure == nil && !isLoadingPage }
    public var canRetryPage: Bool { retryCursor != nil && appendFailure != nil && !isLoadingPage }

    private let service: any PublicRepositoryServing
    public let repository: ResolvedRepository
    public let collection: String
    public let pageLimit: Int
    public let reverse: Bool

    public init(
        service: any PublicRepositoryServing,
        repository: ResolvedRepository,
        collection: String,
        pageLimit: Int = 100,
        reverse: Bool = false
    ) {
        precondition((1 ... 100).contains(pageLimit))
        self.service = service
        self.repository = repository
        self.collection = collection
        self.pageLimit = pageLimit
        self.reverse = reverse
    }

    public func loadFirstPage() async {
        guard !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let preRequestState = state
        let previous = state.snapshot
        state = .loading(previous: previous)

        do {
            let page = try await service.listRecords(
                in: repository,
                collection: collection,
                cursor: nil,
                limit: pageLimit,
                reverse: reverse
            )
            appendFailure = nil
            retryCursor = nil
            completedCursors.removeAll()
            merge(page, requestedCursor: nil, replacingSnapshot: true)
        } catch is CancellationError {
            state = preRequestState
            return
        } catch {
            let failure = BrowserFailure.normalize(error)
            state = .failed(previous: previous, failure: failure)
        }
    }
    public func refresh() async {
        await loadFirstPage()
    }

    public func loadNextPage() async {
        guard canLoadMore, let cursor = nextCursor else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let page = try await service.listRecords(
                in: repository,
                collection: collection,
                cursor: cursor,
                limit: pageLimit,
                reverse: reverse
            )
            appendFailure = nil
            retryCursor = nil
            merge(page, requestedCursor: cursor, replacingSnapshot: false)
        } catch is CancellationError {
            return
        } catch {
            let failure = BrowserFailure.normalize(error)
            appendFailure = failure
            retryCursor = cursor
        }
    }

    public func retryFailedPage() async {
        guard canRetryPage, let cursor = retryCursor else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let page = try await service.listRecords(
                in: repository,
                collection: collection,
                cursor: cursor,
                limit: pageLimit,
                reverse: reverse
            )
            appendFailure = nil
            retryCursor = nil
            merge(page, requestedCursor: cursor, replacingSnapshot: false)
        } catch is CancellationError {
            return
        } catch {
            let failure = BrowserFailure.normalize(error)
            appendFailure = failure
            retryCursor = cursor
        }
    }

    private func merge(
        _ page: RepositoryRecordPage,
        requestedCursor: String?,
        replacingSnapshot: Bool
    ) {
        if let requestedCursor { completedCursors.insert(requestedCursor) }
        var merged = replacingSnapshot ? [] : (state.snapshot ?? [])
        var identities = Set(merged.map { "\($0.uri)\u{1F}\($0.cid)" })
        for row in page.records {
            let identity = "\(row.uri)\u{1F}\(row.cid)"
            guard identities.insert(identity).inserted else { continue }
            if let existing = merged.firstIndex(where: { $0.uri == row.uri }) {
                identities.remove("\(merged[existing].uri)\u{1F}\(merged[existing].cid)")
                merged[existing] = row
            } else {
                merged.append(row)
            }
        }
        state = .loaded(merged)
        if let cursor = page.cursor,
           cursor != requestedCursor,
           !completedCursors.contains(cursor) {
            nextCursor = cursor
        } else {
            nextCursor = nil
        }
    }
}
