//
//  BackupTypes.swift
//  ATProtoDrive
//

import CryptoKit
import Foundation

public struct BackupManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: Int = 1
    public static let defaultCARFilename: String = "repo.car"
    public static let manifestFilename: String = "manifest.json"
    public static let recordsIndexFilename: String = "records-index.json"
    public static let packageExtension: String = "atprotodrivebackup"

    public let schemaVersion: Int
    public let backupID: UUID
    public let createdAt: Date
    public let accessClassification: AccessClassification
    public let did: String
    public let handle: String?
    public let pdsURL: URL
    public let spaceURI: String?
    public let commitRev: String?
    public let commitCID: String?
    public let carFilename: String
    public let carSHA256: String
    public let carByteCount: Int64
    public let recordCount: Int
    public let collectionCounts: [String: Int]
    public let verified: Bool
    public let verificationSummary: String

    public init(
        schemaVersion: Int = BackupManifest.currentSchemaVersion,
        backupID: UUID = UUID(),
        createdAt: Date = Date(),
        accessClassification: AccessClassification,
        did: String,
        handle: String? = nil,
        pdsURL: URL,
        spaceURI: String? = nil,
        commitRev: String? = nil,
        commitCID: String? = nil,
        carFilename: String = BackupManifest.defaultCARFilename,
        carSHA256: String,
        carByteCount: Int64,
        recordCount: Int,
        collectionCounts: [String: Int],
        verified: Bool,
        verificationSummary: String
    ) {
        self.schemaVersion = schemaVersion
        self.backupID = backupID
        self.createdAt = createdAt
        self.accessClassification = accessClassification
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.spaceURI = spaceURI
        self.commitRev = commitRev
        self.commitCID = commitCID
        self.carFilename = carFilename
        self.carSHA256 = carSHA256
        self.carByteCount = carByteCount
        self.recordCount = recordCount
        self.collectionCounts = collectionCounts
        self.verified = verified
        self.verificationSummary = verificationSummary
    }

    public var isSpaceBackup: Bool {
        if spaceURI != nil { return true }
        switch accessClassification.unwrappedOriginal {
        case .permissionedSpace:
            return true
        default:
            return false
        }
    }

    public var originLabel: String {
        isSpaceBackup ? "Permissioned Space" : "Public Repository"
    }

    public var shortOriginBadge: String {
        isSpaceBackup ? "Space" : "Public"
    }

    public var localAccessClassification: AccessClassification {
        if case .localBackup = accessClassification {
            return accessClassification
        }
        return .localBackup(backupID: backupID, original: accessClassification)
    }

    public var displayTarget: String {
        if let spaceURI, !spaceURI.isEmpty {
            return spaceURI
        }
        if let handle, !handle.isEmpty {
            return "@\(handle)"
        }
        return did
    }
}

public extension AccessClassification {
    var unwrappedOriginal: AccessClassification {
        var current = self
        while case .localBackup(_, let inner) = current {
            current = inner
        }
        return current
    }
}

public struct BackupRecordEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(collection)/\(rkey)" }
    public let collection: String
    public let rkey: String
    public let cid: String
    public let prettyJSON: String

    public init(
        collection: String,
        rkey: String,
        cid: String,
        prettyJSON: String
    ) {
        self.collection = collection
        self.rkey = rkey
        self.cid = cid
        self.prettyJSON = prettyJSON
    }
}

public struct BackupPackageSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let packageURL: URL
    public let manifest: BackupManifest

    public init(id: UUID, packageURL: URL, manifest: BackupManifest) {
        self.id = id
        self.packageURL = packageURL
        self.manifest = manifest
    }

    public init(packageURL: URL, manifest: BackupManifest) {
        self.id = manifest.backupID
        self.packageURL = packageURL
        self.manifest = manifest
    }
}

public struct BackupVerificationReport: Hashable, Sendable {
    public let isValid: Bool
    public let carSHA256Matches: Bool
    public let manifestValid: Bool
    public let recordCount: Int
    public let commitRev: String?
    public let issues: [String]

    public init(
        isValid: Bool,
        carSHA256Matches: Bool,
        manifestValid: Bool,
        recordCount: Int,
        commitRev: String?,
        issues: [String]
    ) {
        self.isValid = isValid
        self.carSHA256Matches = carSHA256Matches
        self.manifestValid = manifestValid
        self.recordCount = recordCount
        self.commitRev = commitRev
        self.issues = issues
    }
}

public struct VerifiedCARSnapshot: Hashable, Sendable {
    public let commitRev: String?
    public let commitCID: String?
    public let records: [BackupRecordEntry]
    public let verificationSummary: String

    public init(
        commitRev: String?,
        commitCID: String?,
        records: [BackupRecordEntry],
        verificationSummary: String
    ) {
        self.commitRev = commitRev
        self.commitCID = commitCID
        self.records = records
        self.verificationSummary = verificationSummary
    }
}

public enum BackupError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case invalidIdentifier(String)
    case httpError(endpoint: String, statusCode: Int, message: String?)
    case emptyResponse(endpoint: String)
    case archiveTooLarge(maxBytes: Int)
    case verificationFailed(String)
    case packageNotFound(String)
    case invalidPackageLayout(String)
    case stagingFailed(String)
    case moveFailed(String)
    case trashFailed(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid backup endpoint URL: \(url)"
        case .invalidIdentifier(let id):
            return "Invalid repository identifier: \(id)"
        case .httpError(let endpoint, let statusCode, let message):
            if let message, !message.isEmpty {
                return "\(endpoint) failed with HTTP \(statusCode): \(message)"
            }
            return "\(endpoint) failed with HTTP \(statusCode)."
        case .emptyResponse(let endpoint):
            return "\(endpoint) returned an empty archive response."
        case .archiveTooLarge(let maxBytes):
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
            return "Repository archive exceeded the maximum supported size (\(formatted))."
        case .verificationFailed(let reason):
            return "Backup verification failed: \(reason)"
        case .packageNotFound(let path):
            return "Backup package was not found at \(path)."
        case .invalidPackageLayout(let reason):
            return "Invalid backup package layout: \(reason)"
        case .stagingFailed(let reason):
            return "Failed to stage backup package: \(reason)"
        case .moveFailed(let reason):
            return "Failed to publish backup package atomically: \(reason)"
        case .trashFailed(let reason):
            return "Failed to move backup package to Trash: \(reason)"
        case .exportFailed(let reason):
            return "Failed to export backup package: \(reason)"
        }
    }
}

public enum BackupCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
