import Foundation

/// Atomic JSON persistence for durable `TransferJobRecord` history.
///
/// Stores metadata-only records at a configurable `fileURL` (defaulting to
/// `Application Support/ATProtoDrive/transfers.json`). On relaunch, previously
/// in-flight jobs (`queued`, `discovering`, `running`, `verifying`) normalize to
/// `.interrupted` so stale active states never hang across app restarts.
public struct TransferStore: Sendable {
    public static let relaunchInterruptionMessage =
        "Interrupted because ATProtoDrive closed before the transfer finished."

    public let fileURL: URL

    public init(fileURL: URL = TransferStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Computes the default persistence URL without creating directories on disk.
    public static func defaultFileURL() -> URL {
        let baseDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("ATProtoDrive", isDirectory: true)
            .appendingPathComponent("transfers.json", isDirectory: false)
    }

    /// Loads persisted transfer records from disk.
    ///
    /// When `normalizeInFlight` is `true` (default for app relaunch), any jobs left in
    /// `.queued`, `.discovering`, `.running`, or `.verifying` are transitioned to
    /// `.interrupted` with a clear explanation.
    public func load(
        normalizeInFlight: Bool = true,
        now: Date = Date()
    ) throws -> [TransferJobRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }
        let decoder = Self.makeDecoder()
        let decoded = try decoder.decode([TransferJobRecord].self, from: data)
        guard normalizeInFlight else {
            return Self.sortedRecords(decoded)
        }
        let normalized = decoded.map { record -> TransferJobRecord in
            guard record.state.requiresRelaunchNormalization else {
                return record
            }
            var updated = record
            updated.state = .interrupted
            if updated.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                updated.errorMessage = Self.relaunchInterruptionMessage
            }
            updated.updatedAt = now
            return updated
        }
        return Self.sortedRecords(normalized)
    }

    /// Atomically encodes and writes transfer job metadata to `fileURL`.
    public func save(_ jobs: [TransferJobRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let encoder = Self.makeEncoder()
        let data = try encoder.encode(Self.sortedRecords(jobs))
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func sortedRecords(_ records: [TransferJobRecord]) -> [TransferJobRecord] {
        records.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
