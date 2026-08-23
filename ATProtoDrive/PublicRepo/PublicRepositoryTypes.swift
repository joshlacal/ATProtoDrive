import Foundation
import Petrel

public enum RepositoryTarget: Hashable, Sendable {
    case connectedAccount(did: String)
    case publicIdentifier(String)
}

public struct ResolvedRepository: Identifiable, Hashable, Sendable {
    public var id: String { scope.stableID }
    public let did: String
    public let handle: String?
    public let pdsURL: URL
    public let connectedAccountDID: String?
    public let handleIsCorrect: Bool?

    public var scope: RepositoryScope {
        .publicRepository(did: did, pdsURL: pdsURL)
    }

    public init(
        did: String,
        handle: String? = nil,
        pdsURL: URL,
        connectedAccountDID: String? = nil,
        handleIsCorrect: Bool? = nil
    ) {
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
        self.connectedAccountDID = connectedAccountDID
        self.handleIsCorrect = handleIsCorrect
    }
}

public struct RepositoryDescription: Hashable, Sendable {
    public let repository: ResolvedRepository
    public let collections: [String]

    public init(repository: ResolvedRepository, collections: [String]) {
        self.repository = repository
        self.collections = collections
    }
}

public struct RepositoryRecordPage: Hashable, Sendable {
    public let records: [RecordRow]
    public let cursor: String?

    public init(records: [RecordRow], cursor: String?) {
        self.records = records
        self.cursor = cursor
    }
}

public protocol PublicRepositoryServing: Sendable {
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription
    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage
    func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow
}
