import Foundation

/// Canonical lifecycle state for every durable transfer job in ATProtoDrive.
public enum TransferState: String, Codable, Hashable, Sendable, CaseIterable {
    case queued
    case discovering
    case waitingForPermission
    case running
    case verifying
    case completed
    case interrupted
    case cancelled
    case failed

    /// Whether the job is currently non-terminal and awaiting or executing work.
    public var isActive: Bool {
        switch self {
        case .queued, .discovering, .waitingForPermission, .running, .verifying:
            true
        case .completed, .interrupted, .cancelled, .failed:
            false
        }
    }

    /// Whether the job was actively in flight when the app terminated and must
    /// normalize to `.interrupted` on relaunch.
    public var requiresRelaunchNormalization: Bool {
        switch self {
        case .queued, .discovering, .running, .verifying:
            true
        case .waitingForPermission, .completed, .interrupted, .cancelled, .failed:
            false
        }
    }

    /// Whether the job is in a finished (non-active) state eligible for Clear Finished.
    public var isFinished: Bool {
        !isActive
    }

    /// Whether the job state permits an explicit user retry.
    public var isRetryable: Bool {
        switch self {
        case .interrupted, .failed, .cancelled:
            true
        case .queued, .discovering, .waitingForPermission, .running, .verifying, .completed:
            false
        }
    }

    public var displayLabel: String {
        switch self {
        case .queued:
            "Queued"
        case .discovering:
            "Discovering"
        case .waitingForPermission:
            "Waiting for Permission"
        case .running:
            "Running"
        case .verifying:
            "Verifying"
        case .completed:
            "Completed"
        case .interrupted:
            "Interrupted"
        case .cancelled:
            "Cancelled"
        case .failed:
            "Failed"
        }
    }

    public var symbolName: String {
        switch self {
        case .queued:
            "clock"
        case .discovering:
            "magnifyingglass"
        case .waitingForPermission:
            "hand.raised"
        case .running:
            "arrow.down.circle"
        case .verifying:
            "checkmark.shield"
        case .completed:
            "checkmark.circle.fill"
        case .interrupted:
            "pause.circle.fill"
        case .cancelled:
            "xmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

/// High-level category of a durable transfer job.
public enum TransferKind: String, Codable, Hashable, Sendable, CaseIterable {
    case blobDownload
    case blobPreview
    case backupExport
    case recordAttachment
    case custom

    public var displayLabel: String {
        switch self {
        case .blobDownload:
            "File Download"
        case .blobPreview:
            "File Preview"
        case .backupExport:
            "Backup Export"
        case .recordAttachment:
            "Record Attachment"
        case .custom:
            "Transfer"
        }
    }

    public var symbolName: String {
        switch self {
        case .blobDownload:
            "arrow.down.doc"
        case .blobPreview:
            "eye"
        case .backupExport:
            "externaldrive.badge.timemachine"
        case .recordAttachment:
            "paperclip"
        case .custom:
            "arrow.left.arrow.right"
        }
    }
}

/// Durable metadata record for a transfer job.
///
/// Security invariant: `TransferJobRecord` persists only scalar metadata, progress counters,
/// local destination paths, required account DIDs, and redacted error summaries. It NEVER
/// persists OAuth tokens, DPoP keys, Space credentials, network clients, or record bodies.
public struct TransferJobRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let kind: TransferKind
    public var title: String
    public var subtitle: String?
    public var state: TransferState
    public var requiredAccountDIDs: Set<String>
    public var bytesCompleted: Int64
    public var totalBytes: Int64?
    public var destinationPath: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: TransferKind,
        title: String,
        subtitle: String? = nil,
        state: TransferState = .queued,
        requiredAccountDIDs: Set<String> = [],
        bytesCompleted: Int64 = 0,
        totalBytes: Int64? = nil,
        destinationPath: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.requiredAccountDIDs = requiredAccountDIDs
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.destinationPath = destinationPath
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(bytesCompleted) / Double(totalBytes)))
    }

    public var destinationURL: URL? {
        destinationPath.map { URL(fileURLWithPath: $0) }
    }
}

/// Receipt returned by `TransferQueue.markAccountsUnavailable(_:)` after every matching
/// in-flight job has been cancelled, fenced, transitioned to `.interrupted`, and durably saved.
public struct TransferAccountParkingReceipt: Hashable, Sendable {
    public let accountDIDs: Set<String>
    public let parkedJobIDs: [UUID]
    public let parkedAt: Date

    public init(
        accountDIDs: Set<String>,
        parkedJobIDs: [UUID],
        parkedAt: Date = Date()
    ) {
        self.accountDIDs = accountDIDs
        self.parkedJobIDs = parkedJobIDs
        self.parkedAt = parkedAt
    }
}
