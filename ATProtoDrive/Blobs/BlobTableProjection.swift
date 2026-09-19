import Foundation
import UniformTypeIdentifiers

public extension BlobDescriptor {
    var suggestedFilename: String {
        guard let mimeType,
              let contentType = UTType(mimeType: mimeType),
              let filenameExtension = contentType.preferredFilenameExtension else {
            return locator.cid
        }
        return "\(locator.cid).\(filenameExtension)"
    }

    var displayMIMEType: String { mimeType ?? "Unknown" }

    var ownerDID: String {
        switch locator.scope {
        case .publicRepository(let did, _): did
        case .permissionedSpace(_, let writerDID, _): writerDID
        }
    }

    var dataPlaneLabel: String {
        switch locator.scope {
        case .publicRepository: "Public Repository"
        case .permissionedSpace: "Permissioned Space"
        }
    }

    var verificationLabel: String {
        switch verification {
        case .notVerified: "Not Verified"
        case .hashVerified: "Hash Verified"
        case .failed: "Verification Failed"
        }
    }

    var fileSymbolName: String {
        guard let mimeType, let type = UTType(mimeType: mimeType) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

public struct BlobTableItem: Identifiable, Hashable, Sendable {
    public let blob: BlobDescriptor
    public var id: String { blob.id }
    public var reference: ResourceReference { .blob(blob.locator) }

    public init(blob: BlobDescriptor) { self.blob = blob }

    public var suggestedFilename: String { blob.suggestedFilename }
    public var cid: String { blob.locator.cid }
    public var mimeType: String { blob.displayMIMEType }
    public var sizeSortValue: Int { blob.declaredSize ?? .max }
    public var referenceCount: Int { blob.referenceCount }
    public var verification: String { blob.verificationLabel }

    public var declaredSizeLabel: String {
        guard let size = blob.declaredSize else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    public var referenceCountLabel: String {
        if blob.referenceIndexComplete {
            return "\(blob.referenceCount) found · scan complete"
        }
        return "\(blob.referenceCount) found · scan incomplete"
    }
}

public enum BlobBrowserSurfaceState: Equatable, Sendable {
    case rows([BlobTableItem])
    case emptyInventory
    case noMatches
    case unsupportedTokens([SearchToken])
}

public enum BlobBrowserPresentation {
    public static func surface(blobs: [BlobDescriptor], query: SearchQuery) -> BlobBrowserSurfaceState {
        let unsupported = query.unsupportedTokens(for: .publicBlob)
        if !unsupported.isEmpty { return .unsupportedTokens(unsupported) }
        if blobs.isEmpty { return .emptyInventory }
        let matches = blobs.filter { query.matches(blob: $0) }.map(BlobTableItem.init)
        return matches.isEmpty ? .noMatches : .rows(matches)
    }

    public static func updatedSelection(
        currentSelectedReferences: [String: ResourceReference],
        repositoryScope: RepositoryScope,
        visibleItems: [BlobTableItem],
        newSelectedIDs: Set<BlobTableItem.ID>
    ) -> Set<ResourceReference> {
        let byID = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.id, $0.reference) })
        return Set(newSelectedIDs.compactMap { id in
            guard let reference = byID[id],
                  case .blob(let locator) = reference,
                  locator.scope == repositoryScope else { return nil }
            return reference
        })
    }

    public static func prunedSelection(
        currentSelectedReferences: [String: ResourceReference],
        repositoryScope: RepositoryScope,
        refreshedBlobs: [BlobDescriptor]
    ) -> Set<ResourceReference> {
        let fresh = Set(refreshedBlobs.map { ResourceReference.blob($0.locator) })
        return Set(currentSelectedReferences.values.filter { reference in
            guard case .blob(let locator) = reference,
                  locator.scope == repositoryScope else { return false }
            return fresh.contains(reference)
        })
    }
}

public extension Array where Element == BlobTableItem {
    func sorted(by sort: BrowserSort) -> [BlobTableItem] {
        sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sort.field.lowercased() {
            case "cid":
                comparison = lhs.blob.locator.cid.localizedStandardCompare(rhs.blob.locator.cid)
            case "mime", "mime type":
                comparison = lhs.blob.displayMIMEType.localizedStandardCompare(rhs.blob.displayMIMEType)
            case "size":
                comparison = compareOptional(lhs.blob.declaredSize, rhs.blob.declaredSize)
            case "references", "reference count":
                comparison = compare(lhs.blob.referenceCount, rhs.blob.referenceCount)
            case "verification":
                comparison = lhs.blob.verificationLabel.localizedStandardCompare(rhs.blob.verificationLabel)
            default:
                comparison = lhs.blob.suggestedFilename.localizedStandardCompare(rhs.blob.suggestedFilename)
            }
            if comparison == .orderedSame { return lhs.blob.locator.cid < rhs.blob.locator.cid }
            return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private func compareOptional(_ lhs: Int?, _ rhs: Int?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): compare(lhs, rhs)
        case (.some, .none): .orderedAscending
        case (.none, .some): .orderedDescending
        case (.none, .none): .orderedSame
        }
    }
}
