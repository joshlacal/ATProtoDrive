import Foundation
import Testing
@testable import ATProtoDrive

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor AttemptCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

private actor BoolBox {
    private var value = false

    func set(_ newValue: Bool) {
        value = newValue
    }

    func get() -> Bool {
        value
    }
}

private enum TransferTestError: Error, LocalizedError, Sendable {
    case transientFailure
    case leakedTokenFailure

    var errorDescription: String? {
        switch self {
        case .transientFailure:
            return "Simulated network interruption"
        case .leakedTokenFailure:
            return "Upstream rejected Bearer secret-token-12345 with DPoP proof.jwt.abc"
        }
    }
}

@Suite("Transfer queue and store")
@MainActor
struct TransferQueueTests {
    private static func makeTempStoreURL(prefix: String) throws -> (root: URL, fileURL: URL) {
        let root = try FixtureRoot.make(prefix: prefix)
        return (root, root.appendingPathComponent("transfers.json"))
    }

    @Test("canonical TransferState cases encode and decode cleanly")
    func canonicalStatesRoundTrip() throws {
        let expected: [String] = [
            "queued",
            "discovering",
            "waitingForPermission",
            "running",
            "verifying",
            "completed",
            "interrupted",
            "cancelled",
            "failed"
        ]
        #expect(TransferState.allCases.map(\.rawValue) == expected)

        let data = try JSONEncoder().encode(TransferState.allCases)
        let decoded = try JSONDecoder().decode([TransferState].self, from: data)
        #expect(decoded == TransferState.allCases)
    }

    @Test("TransferStore persists atomically and normalizes in-flight jobs on relaunch")
    func storeAtomicPersistenceAndRelaunchNormalization() throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-store-relaunch")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TransferStore(fileURL: fileURL)
        #expect(try store.load().isEmpty)

        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let records = TransferState.allCases.enumerated().map { index, state in
            TransferJobRecord(
                id: UUID(),
                kind: .blobDownload,
                title: "job-\(state.rawValue)",
                subtitle: "cid-\(index)",
                state: state,
                requiredAccountDIDs: state == .waitingForPermission ? ["did:plc:alice"] : [],
                bytesCompleted: Int64(index * 10),
                totalBytes: 100,
                destinationPath: state == .completed ? "/tmp/example.png" : nil,
                errorMessage: state == .failed ? "Hash mismatch" : nil,
                createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                updatedAt: baseDate.addingTimeInterval(TimeInterval(index))
            )
        }

        try store.save(records)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let relaunchDate = baseDate.addingTimeInterval(500)
        let reloaded = try TransferStore(fileURL: fileURL).load(normalizeInFlight: true, now: relaunchDate)
        #expect(reloaded.count == records.count)

        let byTitle = Dictionary(uniqueKeysWithValues: reloaded.map { ($0.title, $0) })

        for normalizedState in [TransferState.queued, .discovering, .running, .verifying] {
            let record = try #require(byTitle["job-\(normalizedState.rawValue)"])
            #expect(record.state == .interrupted)
            #expect(record.errorMessage == TransferStore.relaunchInterruptionMessage)
            #expect(record.updatedAt == relaunchDate)
        }

        for preservedState in [TransferState.waitingForPermission, .completed, .interrupted, .cancelled, .failed] {
            let record = try #require(byTitle["job-\(preservedState.rawValue)"])
            #expect(record.state == preservedState)
        }

        #expect(byTitle["job-failed"]?.errorMessage == "Hash mismatch")
        #expect(byTitle["job-completed"]?.destinationPath == "/tmp/example.png")
    }

    @Test("enqueueAndRun updates progress, completes with destination URL, and persists to disk")
    func enqueueAndRunCompletesAndPersists() async throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-queue-complete")
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("downloaded.bin")
        let store = TransferStore(fileURL: fileURL)
        let queue = TransferQueue(store: store)

        let jobID = queue.enqueueAndRun(
            kind: .blobDownload,
            title: "avatar.png",
            subtitle: "bafkreiexample",
            requiredAccountDIDs: []
        ) { report in
            report(.discovering, 0, 200)
            report(.running, 100, 200)
            report(.verifying, 200, 200)
            try Data("verified".utf8).write(to: destination, options: [.atomic])
            return destination
        }

        await queue.waitForJob(id: jobID)

        let job = try #require(queue.job(id: jobID))
        #expect(job.state == .completed)
        #expect(job.destinationPath == destination.path)
        #expect(job.errorMessage == nil)
        #expect(queue.activeCount == 0)

        let persisted = try TransferStore(fileURL: fileURL).load(normalizeInFlight: false)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == jobID)
        #expect(persisted.first?.state == .completed)
        #expect(persisted.first?.destinationPath == destination.path)
    }

    @Test("cancel stops an in-flight job and fences late progress or completion updates")
    func cancelFencesLateCallbacks() async throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-queue-cancel")
        defer { try? FileManager.default.removeItem(at: root) }

        let started = AsyncSignal()
        let cancelled = AsyncSignal()
        let release = AsyncSignal()

        let queue = TransferQueue(store: TransferStore(fileURL: fileURL))
        let jobID = queue.enqueueAndRun(
            kind: .blobDownload,
            title: "large.mov"
        ) { report in
            await started.signal()
            await withTaskCancellationHandler {
                await release.wait()
            } onCancel: {
                Task { await cancelled.signal() }
            }
            // Deliberately attempt stale callbacks after cancellation.
            report(.running, 500, 1_000)
            return URL(fileURLWithPath: "/tmp/should-never-commit.mov")
        }

        await started.wait()
        #expect(queue.activeCount == 1)

        queue.cancel(jobID: jobID)
        await cancelled.wait()
        #expect(queue.job(id: jobID)?.state == .cancelled)

        await release.signal()
        await queue.waitForJob(id: jobID)

        let finalJob = try #require(queue.job(id: jobID))
        #expect(finalJob.state == .cancelled)
        #expect(finalJob.destinationPath == nil)
        #expect(queue.activeCount == 0)
    }

    @Test("retry re-runs a failed job using its stored retry closure and redacts tokens in error text")
    func retrySucceedsAfterFailure() async throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-queue-retry")
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = AttemptCounter()
        let outputURL = root.appendingPathComponent("backup.atprotodrivebackup")
        let queue = TransferQueue(store: TransferStore(fileURL: fileURL))

        let jobID = queue.enqueueAndRun(
            kind: .backupExport,
            title: "Public Backup"
        ) { report in
            let attempt = await counter.increment()
            report(.running, 10, 100)
            if attempt == 1 {
                throw TransferTestError.leakedTokenFailure
            }
            report(.verifying, 100, 100)
            return outputURL
        }

        await queue.waitForJob(id: jobID)
        let failedJob = try #require(queue.job(id: jobID))
        #expect(failedJob.state == .failed)
        #expect(failedJob.errorMessage?.contains("secret-token-12345") == false)
        #expect(failedJob.errorMessage?.contains("proof.jwt.abc") == false)
        #expect(failedJob.errorMessage?.contains("[redacted]") == true)
        #expect(queue.canRetry(jobID: jobID))

        queue.retry(jobID: jobID)
        await queue.waitForJob(id: jobID)

        let retriedJob = try #require(queue.job(id: jobID))
        #expect(retriedJob.state == .completed)
        #expect(retriedJob.destinationPath == outputURL.path)
        #expect(retriedJob.errorMessage == nil)
    }

    @Test("clearFinished removes completed, failed, and cancelled jobs while keeping active jobs")
    func clearFinishedPreservesActiveJobs() async throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-queue-clear")
        defer { try? FileManager.default.removeItem(at: root) }

        let started = AsyncSignal()
        let release = AsyncSignal()
        let queue = TransferQueue(store: TransferStore(fileURL: fileURL))

        let completedID = queue.enqueueAndRun(kind: .blobDownload, title: "done.png") { _ in nil }
        await queue.waitForJob(id: completedID)

        let failedID = queue.enqueueAndRun(kind: .blobDownload, title: "failed.png") { _ in
            throw TransferTestError.transientFailure
        }
        await queue.waitForJob(id: failedID)

        let activeID = queue.enqueueAndRun(kind: .blobDownload, title: "in-flight.png") { _ in
            await started.signal()
            await release.wait()
            return nil
        }
        await started.wait()

        #expect(queue.jobs.count == 3)
        #expect(queue.activeCount == 1)
        #expect(queue.finishedCount == 2)

        queue.clearFinished()

        #expect(queue.jobs.map(\.id) == [activeID])
        #expect(queue.activeCount == 1)

        await release.signal()
        await queue.waitForJob(id: activeID)
        #expect(queue.job(id: activeID)?.state == .completed)
    }

    @Test("markAccountsUnavailable cancels, fences, and parks only exact-account jobs")
    func markAccountsUnavailableParksAndFencesExactAccounts() async throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-queue-parking")
        defer { try? FileManager.default.removeItem(at: root) }

        let anonStarted = AsyncSignal()
        let anonRelease = AsyncSignal()
        let aliceStarted = AsyncSignal()
        let aliceCancelObserved = AsyncSignal()
        let aliceRelease = AsyncSignal()
        let bobStarted = AsyncSignal()
        let bobRelease = AsyncSignal()

        let store = TransferStore(fileURL: fileURL)
        let queue = TransferQueue(store: store)

        let anonID = queue.enqueueAndRun(
            kind: .blobDownload,
            title: "public.jpg",
            requiredAccountDIDs: []
        ) { _ in
            await anonStarted.signal()
            await anonRelease.wait()
            return nil
        }

        let aliceID = queue.enqueueAndRun(
            kind: .backupExport,
            title: "alice-space-backup",
            requiredAccountDIDs: ["did:plc:alice"]
        ) { report in
            await aliceStarted.signal()
            await withTaskCancellationHandler {
                await aliceRelease.wait()
            } onCancel: {
                Task { await aliceCancelObserved.signal() }
            }
            // Deliberately attempt stale state/result updates while unwinding.
            report(.running, 999, 1_000)
            return URL(fileURLWithPath: "/tmp/stale-alice-backup.atprotodrivebackup")
        }

        let bobID = queue.enqueueAndRun(
            kind: .backupExport,
            title: "bob-space-backup",
            requiredAccountDIDs: ["did:plc:bob"]
        ) { _ in
            await bobStarted.signal()
            await bobRelease.wait()
            return nil
        }

        await anonStarted.wait()
        await aliceStarted.wait()
        await bobStarted.wait()

        let parkingFinished = BoolBox()
        let parkingTask = Task { @MainActor in
            let receipt = await queue.markAccountsUnavailable(["did:plc:alice"])
            await parkingFinished.set(true)
            return receipt
        }

        // Wait until Alice's task has received cancellation, while still holding aliceRelease.
        await aliceCancelObserved.wait()

        // Parking must wait on Alice's termination barrier before returning.
        #expect(await parkingFinished.get() == false)
        #expect(queue.job(id: aliceID)?.state == .interrupted)

        // Release Alice's unwinding task and await the parking receipt.
        await aliceRelease.signal()
        let receipt = await parkingTask.value

        #expect(await parkingFinished.get() == true)
        #expect(receipt.accountDIDs == ["did:plc:alice"])
        #expect(receipt.parkedJobIDs == [aliceID])

        // Alice's job must remain parked/interrupted with stale callbacks fenced and retry closure cleared.
        let aliceJob = try #require(queue.job(id: aliceID))
        #expect(aliceJob.state == .interrupted)
        #expect(aliceJob.destinationPath == nil)
        #expect(aliceJob.bytesCompleted == 0)
        #expect(queue.canRetry(jobID: aliceID) == false)

        // Anonymous and Bob's jobs must remain untouched and active.
        #expect(queue.job(id: anonID)?.state.isActive == true)
        #expect(queue.job(id: bobID)?.state.isActive == true)

        // Persisted JSON on disk must reflect Alice's parked state.
        let persisted = try TransferStore(fileURL: fileURL).load(normalizeInFlight: false)
        let persistedAlice = try #require(persisted.first { $0.id == aliceID })
        #expect(persistedAlice.state == .interrupted)

        await anonRelease.signal()
        await bobRelease.signal()
        await queue.waitForJob(id: anonID)
        await queue.waitForJob(id: bobID)
    }

    @Test("relaunching TransferQueue normalizes stale in-flight jobs on init")
    func relaunchQueueNormalizesPersistedInFlightJobs() throws {
        let (root, fileURL) = try Self.makeTempStoreURL(prefix: "transfer-queue-init-relaunch")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TransferStore(fileURL: fileURL)
        let runningRecord = TransferJobRecord(
            kind: .blobDownload,
            title: "in-flight-before-crash.png",
            state: .running,
            bytesCompleted: 42,
            totalBytes: 100
        )
        try store.save([runningRecord])

        let relaunchedQueue = TransferQueue(store: store)
        #expect(relaunchedQueue.activeCount == 0)
        let job = try #require(relaunchedQueue.job(id: runningRecord.id))
        #expect(job.state == .interrupted)
        #expect(job.errorMessage == TransferStore.relaunchInterruptionMessage)
    }
}
