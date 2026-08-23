import Foundation
import Observation

@MainActor @Observable
public final class PublicRepositoryStore {
    private enum LoadOutcome: Sendable {
        case success(RepositoryDescription)
        case failure(BrowserFailure)
        case cancelled
    }

    public private(set) var state: LoadState<RepositoryDescription> = .idle
    public private(set) var target: RepositoryTarget?
    public var cachedCollectionCount: Int { recordStores.count }

    private let service: any PublicRepositoryServing
    private var recordStores: [String: PublicRecordStore] = [:]
    private var generation: UInt64 = 0
    private var activeLoad: Task<LoadOutcome, Never>?

    public init(service: any PublicRepositoryServing) {
        self.service = service
    }

    public func open(target newTarget: RepositoryTarget) async {
        let changed = target != newTarget
        if changed {
            target = newTarget
            recordStores.removeAll()
            state = .idle
        }
        await load(target: newTarget, preserveSnapshot: !changed)
    }

    public func refresh() async {
        guard let target else { return }
        await load(target: target, preserveSnapshot: true)
    }

    private func load(target requestedTarget: RepositoryTarget, preserveSnapshot: Bool) async {
        let preRequestState = state
        generation &+= 1
        let requestGeneration = generation
        activeLoad?.cancel()
        let previous = preserveSnapshot ? state.snapshot : nil
        state = .loading(previous: previous)
        let service = self.service
        let task = Task<LoadOutcome, Never> {
            do {
                let resolved = try await service.resolve(target: requestedTarget)
                return .success(try await service.describe(resolved))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(BrowserFailure.normalize(error))
            }
        }
        activeLoad = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == requestGeneration, target == requestedTarget else { return }
        switch outcome {
        case .success(let description): state = .loaded(description)
        case .failure(let failure): state = .failed(previous: previous, failure: failure)
        case .cancelled: state = preRequestState
        }
    }

    public func recordStore(for collection: String) -> PublicRecordStore? {
        guard let repository = state.snapshot?.repository else { return nil }
        let key = "\(repository.scope.stableID)|collection|\(collection)"
        if let existing = recordStores[key] { return existing }
        let store = PublicRecordStore(
            service: service,
            repository: repository,
            collection: collection
        )
        recordStores[key] = store
        return store
    }

    public func loadCollection(_ collection: String) async -> PublicRecordStore? {
        guard let store = recordStore(for: collection) else { return nil }
        switch store.state {
        case .idle, .failed:
            await store.loadFirstPage()
        case .loading, .loaded:
            break
        }
        return store
    }

    public func record(for reference: ResourceReference) -> RecordRow? {
        guard case .record(let locator) = reference else { return nil }
        let key = "\(locator.scope.stableID)|collection|\(locator.collection)"
        return recordStores[key]?.rows.first {
            $0.uri == locator.uri && $0.cid == locator.cid
        }
    }
}
