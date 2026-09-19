import Foundation
import Observation

public struct BlobInventorySnapshot: Equatable, Sendable {
    public let blobs: [BlobDescriptor]
    public let nextCursor: String?
    public let blobEnumerationComplete: Bool
    public let referenceScanComplete: Bool

    public var isComplete: Bool { blobEnumerationComplete && referenceScanComplete }

    public init(
        blobs: [BlobDescriptor] = [],
        nextCursor: String? = nil,
        blobEnumerationComplete: Bool = false,
        referenceScanComplete: Bool = false
    ) {
        self.blobs = blobs
        self.nextCursor = nextCursor
        self.blobEnumerationComplete = blobEnumerationComplete
        self.referenceScanComplete = referenceScanComplete
    }
}

@MainActor @Observable
public final class BlobInventoryStore {
    public let repository: ResolvedRepository
    public private(set) var snapshot = BlobInventorySnapshot()
    public private(set) var loadState: LoadState<BlobInventorySnapshot> = .idle
    public private(set) var isLoadingPage = false
    public private(set) var appendFailure: BrowserFailure?
    public private(set) var referenceFailure: BrowserFailure?
    public private(set) var isScanningReferences = false
    public private(set) var referenceProgress = BlobReferenceScanProgress()

    public var canLoadMore: Bool {
        snapshot.nextCursor != nil && appendFailure == nil && !isLoadingPage && !loadState.isRefreshFailure
    }
    public var canRetryPage: Bool {
        retryCursor != nil && appendFailure != nil && !isLoadingPage && !loadState.isRefreshFailure
    }

    private let blobService: any PublicBlobServing
    private let recordService: any PublicRepositoryServing
    private let index = BlobReferenceIndex()
    private let pageLimit: Int
    private var completedCursors = Set<String>()
    private var retryCursor: String?
    private var generation = 0
    private var scanGeneration = 0
    @ObservationIgnored private var referenceTask: Task<Void, Never>?
    private var referenceCache: [BlobLocator: [BlobReferenceOccurrence]] = [:]

    public init(
        repository: ResolvedRepository,
        blobService: any PublicBlobServing,
        recordService: any PublicRepositoryServing,
        pageLimit: Int = 1_000
    ) {
        precondition((1 ... 1_000).contains(pageLimit))
        self.repository = repository
        self.blobService = blobService
        self.recordService = recordService
        self.pageLimit = pageLimit
    }

    public func reload() async {
        cancelReferenceScan()
        generation &+= 1
        let requestGeneration = generation
        let previous = snapshot
        let preRequestLoadState = loadState
        let previousForLoadState = preRequestLoadState.snapshot
        isLoadingPage = true
        loadState = .loading(previous: previousForLoadState)
        defer { if generation == requestGeneration { isLoadingPage = false } }
        do {
            let page = try await blobService.listBlobs(in: repository, cursor: nil, limit: pageLimit)
            guard generation == requestGeneration else { return }
            completedCursors.removeAll()
            appendFailure = nil
            retryCursor = nil
            publish(page: page, replacing: true, requestedCursor: nil)
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            loadState = preRequestLoadState
        } catch {
            guard generation == requestGeneration else { return }
            loadState = .failed(previous: previousForLoadState, failure: .normalize(error))
            snapshot = previous
        }
    }

    public func loadMore() async {
        guard canLoadMore, let cursor = snapshot.nextCursor else { return }
        await requestPage(cursor: cursor)
    }

    public func retryPage() async {
        guard canRetryPage, let cursor = retryCursor else { return }
        await requestPage(cursor: cursor)
    }

    private func requestPage(cursor: String) async {
        let requestGeneration = generation
        isLoadingPage = true
        defer { if generation == requestGeneration { isLoadingPage = false } }
        do {
            let page = try await blobService.listBlobs(in: repository, cursor: cursor, limit: pageLimit)
            guard generation == requestGeneration else { return }
            appendFailure = nil
            retryCursor = nil
            publish(page: page, replacing: false, requestedCursor: cursor)
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            appendFailure = .normalize(error)
            retryCursor = cursor
        }
    }

    public func scanReferences() async {
        guard !isScanningReferences else { return }
        referenceTask?.cancel()
        scanGeneration &+= 1
        let requestScanGeneration = scanGeneration
        let requestGeneration = generation
        isScanningReferences = true
        referenceFailure = nil
        referenceProgress = .init()
        let scanner = PublicRecordInventoryScanner(service: recordService)
        let task = Task { [repository, index] in
            do {
                _ = try await scanner.scan(repository: repository, index: index) { progress in
                    await MainActor.run {
                        guard self.generation == requestGeneration,
                              self.scanGeneration == requestScanGeneration else { return }
                        self.referenceProgress = progress
                    }
                }
                let occurrences = await index.references(in: repository.scope)
                await MainActor.run {
                    guard self.generation == requestGeneration,
                          self.scanGeneration == requestScanGeneration,
                          !Task.isCancelled else { return }
                    self.finishReferenceScan(occurrences)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.generation == requestGeneration,
                          self.scanGeneration == requestScanGeneration else { return }
                    self.isScanningReferences = false
                }
            } catch {
                await MainActor.run {
                    guard self.generation == requestGeneration,
                          self.scanGeneration == requestScanGeneration else { return }
                    self.referenceFailure = .normalize(error)
                    self.isScanningReferences = false
                }
            }
        }
        referenceTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == requestGeneration && scanGeneration == requestScanGeneration {
            referenceTask = nil
        }
    }

    public func cancelReferenceScan() {
        scanGeneration &+= 1
        referenceTask?.cancel()
        referenceTask = nil
        isScanningReferences = false
    }

    public func references(to locator: BlobLocator) -> [BlobReferenceOccurrence] {
        referenceCache[locator] ?? []
    }

    public func blob(for locator: BlobLocator) -> BlobDescriptor? {
        snapshot.blobs.first { $0.locator == locator }
    }

    private func publish(page: BlobCIDPage, replacing: Bool, requestedCursor: String?) {
        if let requestedCursor { completedCursors.insert(requestedCursor) }
        var descriptors = replacing ? [] : snapshot.blobs
        let priorByLocator = Dictionary(uniqueKeysWithValues: snapshot.blobs.map { ($0.locator, $0) })
        let referencesAreCurrent = replacing ? false : snapshot.referenceScanComplete
        var seen = Set(descriptors.map(\.locator))
        for cid in page.cids {
            let locator = BlobLocator(scope: repository.scope, cid: cid)
            guard seen.insert(locator).inserted else { continue }
            let old = priorByLocator[locator]
            let refs = referenceCache[locator] ?? []
            let mimeTypes = Set(refs.compactMap(\.mimeType))
            let sizes = Set(refs.compactMap(\.declaredSize))
            descriptors.append(.init(
                locator: locator,
                mimeType: mimeTypes.count == 1 ? mimeTypes.first : old?.mimeType,
                declaredSize: sizes.count == 1 ? sizes.first : old?.declaredSize,
                referenceCount: refs.count,
                referenceIndexComplete: referencesAreCurrent,
                availability: old?.availability ?? .unknown,
                verification: old?.verification ?? .notVerified
            ))
        }
        let cursorCycle = page.cursor.map { $0 == requestedCursor || completedCursors.contains($0) } ?? false
        let next = cursorCycle ? nil : page.cursor
        if cursorCycle {
            appendFailure = .transport("Blob pagination cursor cycle")
            retryCursor = requestedCursor ?? page.cursor
        }
        snapshot = .init(
            blobs: descriptors, nextCursor: next,
            blobEnumerationComplete: page.cursor == nil,
            referenceScanComplete: referencesAreCurrent
        )
        loadState = .loaded(snapshot)
    }

    private func finishReferenceScan(_ occurrences: [BlobReferenceOccurrence]) {
        referenceCache = Dictionary(grouping: occurrences, by: \.blob)
            .mapValues { $0.sorted { ($0.record.uri, $0.jsonPointer) < ($1.record.uri, $1.jsonPointer) } }
        var byLocator = Dictionary(uniqueKeysWithValues: snapshot.blobs.map { ($0.locator, $0) })
        for (locator, refs) in referenceCache {
            guard let old = byLocator[locator] else { continue }
            let mimeTypes = Set(refs.compactMap(\.mimeType))
            let sizes = Set(refs.compactMap(\.declaredSize))
            byLocator[locator] = .init(
                locator: locator,
                mimeType: mimeTypes.count == 1 ? mimeTypes.first : nil,
                declaredSize: sizes.count == 1 ? sizes.first : nil,
                referenceCount: refs.count,
                referenceIndexComplete: true,
                availability: old.availability,
                verification: old.verification
            )
        }
        for locator in Array(byLocator.keys) where referenceCache[locator] == nil {
            guard let old = byLocator[locator] else { continue }
            byLocator[locator] = .init(
                locator: locator, mimeType: nil, declaredSize: nil,
                referenceCount: 0, referenceIndexComplete: true,
                availability: old.availability, verification: old.verification
            )
        }
        snapshot = .init(
            blobs: byLocator.values.sorted { $0.locator.cid < $1.locator.cid },
            nextCursor: snapshot.nextCursor,
            blobEnumerationComplete: snapshot.blobEnumerationComplete,
            referenceScanComplete: true
        )
        switch loadState {
        case .failed(_, let failure):
            loadState = .failed(previous: snapshot, failure: failure)
        case .loading:
            loadState = .loading(previous: snapshot)
        case .idle, .loaded:
            loadState = .loaded(snapshot)
        }
        isScanningReferences = false
        referenceFailure = nil
    }
}

private extension LoadState {
    var isRefreshFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
