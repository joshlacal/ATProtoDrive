import Foundation

public enum RepositoryScope: Hashable, Codable, Sendable {
    case publicRepository(did: String, pdsURL: URL)
    case permissionedSpace(
        spaceURI: String,
        writerDID: String,
        accountDID: String
    )
}

public extension RepositoryScope {
    var accessClassification: AccessClassification {
        switch self {
        case .publicRepository(let did, _):
            return .publicRepository(did: did)
        case .permissionedSpace(let spaceURI, let writerDID, _):
            return .permissionedSpace(spaceURI: spaceURI, writerDID: writerDID)
        }
    }

    var stableID: String {
        switch self {
        case .publicRepository(let did, let pdsURL):
            return "public|\(did)|\(pdsURL.absoluteString)"
        case .permissionedSpace(let spaceURI, let writerDID, let accountDID):
            return "space|\(accountDID)|\(spaceURI)|\(writerDID)"
        }
    }
}

public struct RecordLocator: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let uri: String
    public let collection: String
    public let rkey: String
    public let cid: String

    public init(
        scope: RepositoryScope,
        uri: String,
        collection: String,
        rkey: String,
        cid: String
    ) {
        self.scope = scope
        self.uri = uri
        self.collection = collection
        self.rkey = rkey
        self.cid = cid
    }
}

public struct BlobLocator: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let cid: String

    public init(scope: RepositoryScope, cid: String) {
        self.scope = scope
        self.cid = cid
    }
}

public extension BlobLocator {
    var stableID: String { "\(scope.stableID)|blob|\(cid)" }
}

public enum ResourceReference: Hashable, Sendable, Codable, Identifiable {
    case repository(RepositoryScope)
    case collection(scope: RepositoryScope, collection: String)
    case record(RecordLocator)
    case blob(BlobLocator)

    public var id: String { stableID }
    public var stableID: String {
        switch self {
        case .repository(let scope): "\(scope.stableID)|repository"
        case .collection(let scope, let collection): "\(scope.stableID)|collection|\(collection)"
        case .record(let locator): "\(locator.scope.stableID)|record|\(locator.uri)|\(locator.cid)"
        case .blob(let locator): locator.stableID
        }
    }

    public var scope: RepositoryScope {
        switch self {
        case .repository(let scope): scope
        case .collection(let scope, _): scope
        case .record(let locator): locator.scope
        case .blob(let locator): locator.scope
        }
    }
}
