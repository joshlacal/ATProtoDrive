import Foundation
import Observation

public struct RecentRepositoryEnvelope: Codable, Sendable {
    public let version: Int
    public let entries: [OpenedRepositorySummary]
}

public protocol RecentRepositoryPersisting: Sendable {
    func load() async throws -> Data?
    func saveAtomically(_ data: Data) async throws
}

public actor MemoryRecentRepositoryPersistence: RecentRepositoryPersisting {
    public private(set) var data: Data?
    public init(data: Data? = nil) { self.data = data }
    public func load() async throws -> Data? { data }
    public func saveAtomically(_ data: Data) async throws { self.data = data }
}

public typealias AtomicDataWrite = @Sendable (Data, URL) throws -> Void

public actor FileRecentRepositoryPersistence: RecentRepositoryPersisting {
    public let fileURL: URL
    private let writeAtomically: AtomicDataWrite

    public init(
        fileURL: URL,
        writeAtomically: @escaping AtomicDataWrite = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.writeAtomically = writeAtomically
    }

    public static func live() throws -> FileRecentRepositoryPersistence {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return .init(fileURL: applicationSupport
            .appendingPathComponent("ATProtoDrive", isDirectory: true)
            .appendingPathComponent("RecentRepositories-v1.json", isDirectory: false))
    }

    public func load() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func saveAtomically(_ data: Data) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomically(data, fileURL)
    }
}

@MainActor @Observable
public final class RecentRepositoryStore {
    public private(set) var entries: [OpenedRepositorySummary] = []
    public private(set) var failure: BrowserFailure?
    private let persistence: any RecentRepositoryPersisting
    private let maximumCount: Int

    public init(
        persistence: any RecentRepositoryPersisting,
        maximumCount: Int = 20
    ) {
        precondition(maximumCount > 0)
        self.persistence = persistence
        self.maximumCount = maximumCount
    }

    public func restore() async {
        do {
            guard let data = try await persistence.load() else { return }
            let envelope = try JSONDecoder().decode(RecentRepositoryEnvelope.self, from: data)
            guard envelope.version == 1 else {
                throw BrowserFailure.unsupported("Recent repository format \(envelope.version)")
            }
            entries = normalized(envelope.entries)
            failure = nil
        } catch {
            failure = BrowserFailure.normalize(error)
        }
    }

    public func remember(_ summary: OpenedRepositorySummary) async {
        entries = normalized([summary] + entries)
        await persist()
    }

    public func removeEntries(sourceAccountDID: String) async {
        entries.removeAll { $0.sourceAccountDID == sourceAccountDID }
        await persist()
    }

    private func normalized(_ values: [OpenedRepositorySummary]) -> [OpenedRepositorySummary] {
        var seen = Set<String>()
        return values.enumerated()
            .sorted {
                $0.element.lastOpenedAt == $1.element.lastOpenedAt
                    ? $0.offset < $1.offset
                    : $0.element.lastOpenedAt > $1.element.lastOpenedAt
            }
            .compactMap { seen.insert($0.element.id).inserted ? $0.element : nil }
            .prefix(maximumCount)
            .map(\.self)
    }

    private func persist() async {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(RecentRepositoryEnvelope(version: 1, entries: entries))
            try await persistence.saveAtomically(data)
            failure = nil
        } catch {
            failure = BrowserFailure.normalize(error)
        }
    }
}
