import Foundation
import Observation

/// Progress and state callback passed into each transfer operation.
public typealias TransferProgressHandler = @Sendable (
    _ state: TransferState,
    _ bytesCompleted: Int64,
    _ totalBytes: Int64?
) -> Void

/// Async unit of work executed by `TransferQueue`.
/// Returns an optional local destination `URL` once the transfer completes.
public typealias TransferOperation = @Sendable (
    _ report: @escaping TransferProgressHandler
) async throws -> URL?

/// App-scoped durable transfer queue managing execution, cancellation fencing,
/// retry closures, and atomic metadata persistence.
@MainActor @Observable
public final class TransferQueue {
    public static let accountRemovalInterruptionMessage =
        "Interrupted because account access was removed."

    public private(set) var jobs: [TransferJobRecord] = []
    public private(set) var lastPersistenceError: String?

    public var activeCount: Int {
        jobs.filter(\.state.isActive).count
    }

    public var finishedCount: Int {
        jobs.filter(\.state.isFinished).count
    }

    private struct ActiveTaskHandle {
        let generation: UInt64
        let requiredAccountDIDs: Set<String>
        let task: Task<Void, Never>
    }

    @ObservationIgnored private let store: TransferStore
    @ObservationIgnored private let persistChanges: Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var activeTasks: [UUID: ActiveTaskHandle] = [:]
    @ObservationIgnored private var executionGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var retryOperations: [UUID: TransferOperation] = [:]

    public init(
        store: TransferStore = TransferStore(),
        restoreOnInit: Bool = true,
        persistChanges: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.persistChanges = persistChanges
        self.now = now
        if restoreOnInit {
            reloadFromStore()
        }
    }

    /// Creates an ephemeral in-memory queue that never reads from or writes to disk.
    /// Useful for SwiftUI previews, fixtures, and isolated tests.
    public static func inMemory(
        now: @escaping @Sendable () -> Date = Date.init
    ) -> TransferQueue {
        TransferQueue(
            store: TransferStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ATProtoDrive-in-memory-\(UUID().uuidString).json")
            ),
            restoreOnInit: false,
            persistChanges: false,
            now: now
        )
    }

    /// Reloads persisted job records from disk, normalizing any stale in-flight
    /// records (`queued`, `discovering`, `running`, `verifying`) to `.interrupted`.
    public func reloadFromStore() {
        do {
            let timestamp = now()
            let raw = try store.load(normalizeInFlight: false, now: timestamp)
            let normalized = try store.load(normalizeInFlight: true, now: timestamp)
            jobs = normalized
            lastPersistenceError = nil
            if persistChanges && raw != normalized {
                persistCurrentJobs()
            }
        } catch {
            lastPersistenceError = Self.redactedErrorMessage(for: error)
        }
    }

    /// Looks up a transfer job by identifier.
    public func job(id: UUID) -> TransferJobRecord? {
        jobs.first { $0.id == id }
    }

    /// Enqueues a new transfer job, persists it immediately, and launches execution off the main actor.
    @discardableResult
    public func enqueueAndRun(
        kind: TransferKind,
        title: String,
        subtitle: String? = nil,
        requiredAccountDIDs: Set<String> = [],
        destinationPath: String? = nil,
        operation: @escaping TransferOperation
    ) -> UUID {
        let timestamp = now()
        let record = TransferJobRecord(
            id: UUID(),
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: .queued,
            requiredAccountDIDs: requiredAccountDIDs,
            bytesCompleted: 0,
            totalBytes: nil,
            destinationPath: destinationPath,
            errorMessage: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        jobs.insert(record, at: 0)
        retryOperations[record.id] = operation
        persistCurrentJobs()
        startTask(for: record.id, requiredAccountDIDs: requiredAccountDIDs, operation: operation)
        return record.id
    }

    /// Cancels an active job and fences any late progress or completion callbacks from its running task.
    public func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state.isActive else { return }

        executionGenerations[jobID] = (executionGenerations[jobID] ?? 0) &+ 1
        jobs[index].state = .cancelled
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = now()
        persistCurrentJobs()

        activeTasks[jobID]?.task.cancel()
    }

    /// Whether the given job can be retried using an in-memory retry closure.
    public func canRetry(jobID: UUID) -> Bool {
        guard let record = jobs.first(where: { $0.id == jobID }) else { return false }
        return record.state.isRetryable && retryOperations[jobID] != nil
    }

    /// Re-runs a failed, interrupted, or cancelled job if its in-memory operation closure is available.
    public func retry(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state.isRetryable, let operation = retryOperations[jobID] else { return }

        activeTasks[jobID]?.task.cancel()
        jobs[index].state = .queued
        jobs[index].bytesCompleted = 0
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = now()
        let requiredDIDs = jobs[index].requiredAccountDIDs
        persistCurrentJobs()

        startTask(for: jobID, requiredAccountDIDs: requiredDIDs, operation: operation)
    }

    /// Removes all finished (non-active) jobs from the queue and persists the remaining jobs.
    public func clearFinished() {
        let finishedIDs = Set(jobs.filter(\.state.isFinished).map(\.id))
        guard !finishedIDs.isEmpty else { return }
        jobs.removeAll { finishedIDs.contains($0.id) }
        for id in finishedIDs {
            retryOperations.removeValue(forKey: id)
            if activeTasks[id] == nil {
                executionGenerations.removeValue(forKey: id)
            }
        }
        persistCurrentJobs()
    }

    /// Parks and cancellation-fences every active job requiring any DID in `accountDIDs`.
    ///
    /// This method:
    /// 1. Synchronously increments the execution generation for every matching active job
    ///    so late progress or completion callbacks cannot mutate state.
    /// 2. Transitions matching active jobs to `.interrupted` and persists durably.
    /// 3. Releases in-memory retry closures for matching jobs so removed account credentials/clients
    ///    are not retained.
    /// 4. Cancels and awaits termination of every matching running task before returning the receipt.
    public func markAccountsUnavailable(
        _ accountDIDs: Set<String>
    ) async -> TransferAccountParkingReceipt {
        guard !accountDIDs.isEmpty else {
            return TransferAccountParkingReceipt(
                accountDIDs: accountDIDs,
                parkedJobIDs: [],
                parkedAt: now()
            )
        }

        let timestamp = now()
        var parkedIDs: [UUID] = []
        var mutated = false

        for index in jobs.indices {
            guard !jobs[index].requiredAccountDIDs.isDisjoint(with: accountDIDs) else {
                continue
            }
            let jobID = jobs[index].id
            retryOperations.removeValue(forKey: jobID)

            if jobs[index].state.isActive {
                executionGenerations[jobID] = (executionGenerations[jobID] ?? 0) &+ 1
                jobs[index].state = .interrupted
                jobs[index].errorMessage = Self.accountRemovalInterruptionMessage
                jobs[index].updatedAt = timestamp
                parkedIDs.append(jobID)
                mutated = true
            }
        }

        var handlesToAwait: [ActiveTaskHandle] = []
        for (jobID, handle) in activeTasks {
            guard !handle.requiredAccountDIDs.isDisjoint(with: accountDIDs) else {
                continue
            }
            executionGenerations[jobID] = max(executionGenerations[jobID] ?? 0, handle.generation) &+ 1
            handle.task.cancel()
            handlesToAwait.append(handle)
        }

        if mutated {
            persistCurrentJobs()
        }

        for handle in handlesToAwait {
            await handle.task.value
        }

        return TransferAccountParkingReceipt(
            accountDIDs: accountDIDs,
            parkedJobIDs: parkedIDs.sorted { $0.uuidString < $1.uuidString },
            parkedAt: now()
        )
    }

    /// Awaits the currently running task for `id`, if any. Primarily useful for deterministic tests.
    public func waitForJob(id: UUID) async {
        while let handle = activeTasks[id] {
            await handle.task.value
            if activeTasks[id]?.generation == handle.generation {
                break
            }
        }
    }

    private func startTask(
        for jobID: UUID,
        requiredAccountDIDs: Set<String>,
        operation: @escaping TransferOperation
    ) {
        let generation = (executionGenerations[jobID] ?? 0) &+ 1
        executionGenerations[jobID] = generation

        let report: TransferProgressHandler = { [weak self] newState, bytesCompleted, totalBytes in
            Task { @MainActor [weak self] in
                self?.applyProgress(
                    jobID: jobID,
                    generation: generation,
                    state: newState,
                    bytesCompleted: bytesCompleted,
                    totalBytes: totalBytes
                )
            }
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<URL?, any Error>
            do {
                try Task.checkCancellation()
                let finalURL = try await operation(report)
                try Task.checkCancellation()
                outcome = .success(finalURL)
            } catch {
                outcome = .failure(error)
            }
            await self?.finishExecution(
                jobID: jobID,
                generation: generation,
                outcome: outcome
            )
        }

        activeTasks[jobID] = ActiveTaskHandle(
            generation: generation,
            requiredAccountDIDs: requiredAccountDIDs,
            task: task
        )
    }

    private func applyProgress(
        jobID: UUID,
        generation: UInt64,
        state: TransferState,
        bytesCompleted: Int64,
        totalBytes: Int64?
    ) {
        guard executionGenerations[jobID] == generation else { return }
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].state.isActive else { return }

        let previousState = jobs[index].state
        jobs[index].state = state
        jobs[index].bytesCompleted = max(0, bytesCompleted)
        if let totalBytes {
            jobs[index].totalBytes = max(0, totalBytes)
        }
        jobs[index].updatedAt = now()

        if previousState != state {
            persistCurrentJobs()
        }
    }

    private func finishExecution(
        jobID: UUID,
        generation: UInt64,
        outcome: Result<URL?, any Error>
    ) {
        if activeTasks[jobID]?.generation == generation {
            activeTasks.removeValue(forKey: jobID)
        }

        guard executionGenerations[jobID] == generation else {
            return
        }
        // Advance generation so any queued MainActor progress tasks from this run are ignored.
        executionGenerations[jobID] = generation &+ 1

        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        guard jobs[index].state.isActive else {
            return
        }

        switch outcome {
        case .success(let destinationURL):
            jobs[index].state = .completed
            if let destinationURL {
                jobs[index].destinationPath = destinationURL.path
            }
            if let total = jobs[index].totalBytes {
                jobs[index].bytesCompleted = max(jobs[index].bytesCompleted, total)
            }
            jobs[index].errorMessage = nil
            jobs[index].updatedAt = now()

        case .failure(let error):
            if error is CancellationError {
                jobs[index].state = .cancelled
                jobs[index].errorMessage = nil
            } else {
                jobs[index].state = .failed
                jobs[index].errorMessage = Self.redactedErrorMessage(for: error)
            }
            jobs[index].updatedAt = now()
        }

        persistCurrentJobs()
    }

    private func persistCurrentJobs() {
        guard persistChanges else { return }
        do {
            try store.save(jobs)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = Self.redactedErrorMessage(for: error)
        }
    }

    private static func redactedErrorMessage(for error: any Error) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Transfer failed." }
        let stripped = raw
            .replacingOccurrences(
                of: #"(?i)\b(bearer|dpop)\s+[A-Za-z0-9._~+/=-]+"#,
                with: "$1 [redacted]",
                options: .regularExpression
            )
        if stripped.count <= 300 {
            return stripped
        }
        return String(stripped.prefix(297)) + "…"
    }
}
