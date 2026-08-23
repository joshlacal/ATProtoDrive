import Foundation

public enum AccountDestination: String, CaseIterable, Hashable, Sendable, Codable {
    case overview, publicRecords, publicBlobs, spaces
    case privateAppState, backups, activity, serverAndAccount
}

public enum GlobalDestination: String, Hashable, Sendable, Codable {
    case openPublicRepository, openSpace, addAccount
}

public enum BrowserSource: Hashable, Sendable, Codable {
    case account(did: String, destination: AccountDestination)
    case openedPublicRepository(did: String)
    case global(GlobalDestination)

    public var stableID: String {
        switch self {
        case .account(let did, let destination):
            return "account|\(did)|\(destination.rawValue)"
        case .openedPublicRepository(let did):
            return "public|\(did)"
        case .global(let destination):
            return "global|\(destination.rawValue)"
        }
    }
}

public struct OpenedRepositorySummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String {
        "\(did)|source|\(sourceAccountDID ?? "anonymous")"
    }
    public let did: String
    public let handle: String?
    public let pdsURL: URL
    public let sourceAccountDID: String?
    public let lastOpenedAt: Date

    public init(
        did: String,
        handle: String? = nil,
        pdsURL: URL,
        sourceAccountDID: String? = nil,
        lastOpenedAt: Date = Date()
    ) {
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.sourceAccountDID = sourceAccountDID
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct BrowserPath: Hashable, Sendable, Codable {
    public let source: BrowserSource
    public var components: [ResourceReference]

    public init(source: BrowserSource, components: [ResourceReference] = []) {
        self.source = source
        self.components = components
    }
}

public struct BrowserItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case repository, collection, record, blob, utility }
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let kind: Kind
    public let reference: ResourceReference?
    public let accessClassification: AccessClassification?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbolName: String,
        kind: Kind,
        reference: ResourceReference? = nil,
        accessClassification: AccessClassification? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.kind = kind
        self.reference = reference
        self.accessClassification = accessClassification
    }
}

public struct BrowserSort: Hashable, Sendable, Codable {
    public var field: String
    public var ascending: Bool

    public init(field: String = "title", ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}
