import Foundation

public struct BlobReferenceOccurrence: Hashable, Codable, Sendable {
    public let blob: BlobLocator
    public let record: RecordLocator
    public let jsonPointer: String
    public let mimeType: String?
    public let declaredSize: Int?

    public init(
        blob: BlobLocator,
        record: RecordLocator,
        jsonPointer: String,
        mimeType: String? = nil,
        declaredSize: Int? = nil
    ) {
        self.blob = blob
        self.record = record
        self.jsonPointer = jsonPointer
        self.mimeType = mimeType
        self.declaredSize = declaredSize
    }
}

public enum BlobAvailability: String, Hashable, Codable, Sendable {
    case unknown
    case available
    case missing
}

public enum BlobVerificationState: Hashable, Codable, Sendable {
    case notVerified
    case hashVerified(sha256: String)
    case failed(reason: String)
}

public struct BlobDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String { locator.stableID }
    public let locator: BlobLocator
    public let mimeType: String?
    public let declaredSize: Int?
    public let referenceCount: Int
    public let referenceIndexComplete: Bool
    public let availability: BlobAvailability
    public let verification: BlobVerificationState

    public init(
        locator: BlobLocator,
        mimeType: String? = nil,
        declaredSize: Int? = nil,
        referenceCount: Int,
        referenceIndexComplete: Bool,
        availability: BlobAvailability,
        verification: BlobVerificationState
    ) {
        self.locator = locator
        self.mimeType = mimeType
        self.declaredSize = declaredSize
        self.referenceCount = referenceCount
        self.referenceIndexComplete = referenceIndexComplete
        self.availability = availability
        self.verification = verification
    }
}

public struct BlobCIDPage: Equatable, Sendable {
    public let cids: [String]
    public let cursor: String?

    public init(cids: [String], cursor: String? = nil) {
        self.cids = cids
        self.cursor = cursor
    }
}

public struct BlobReferenceScanProgress: Equatable, Sendable {
    public let collectionsScanned: Int
    public let recordsScanned: Int
    public let referencesFound: Int

    public init(collectionsScanned: Int = 0, recordsScanned: Int = 0, referencesFound: Int = 0) {
        self.collectionsScanned = collectionsScanned
        self.recordsScanned = recordsScanned
        self.referencesFound = referencesFound
    }
}

public enum BlobReferenceScanError: Error, Sendable {
    case unsupportedProjectedValue
}
