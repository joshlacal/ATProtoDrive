import Foundation
import Petrel

public protocol PublicBlobServing: Sendable {
    func listBlobs(
        in repository: ResolvedRepository,
        cursor: String?,
        limit: Int
    ) async throws -> BlobCIDPage
}

public actor PublicBlobService: PublicBlobServing {
    public struct Operations: Sendable {
        public let listBlobs: @Sendable (
            URL, ComAtprotoSyncListBlobs.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoSyncListBlobs.Output?)

        public init(listBlobs: @escaping @Sendable (
            URL, ComAtprotoSyncListBlobs.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoSyncListBlobs.Output?)) {
            self.listBlobs = listBlobs
        }

        public static let live = Self { pdsURL, parameters in
            let client = await ATProtoClient(baseURL: pdsURL)
            return try await client.com.atproto.sync.listBlobs(input: parameters)
        }
    }

    private let operations: Operations

    public init(operations: Operations = .live) {
        self.operations = operations
    }

    public func listBlobs(
        in repository: ResolvedRepository,
        cursor: String?,
        limit: Int
    ) async throws -> BlobCIDPage {
        guard case .publicRepository(let did, let pdsURL) = repository.scope,
              did == repository.did, pdsURL == repository.pdsURL else {
            throw BrowserFailure.unsupported("Permissioned blob enumeration")
        }
        guard (1 ... 1_000).contains(limit) else {
            throw BrowserFailure.invalidIdentifier("Blob page limit must be between 1 and 1000")
        }
        let parsedDID: DID
        do { parsedDID = try DID(didString: repository.did) }
        catch { throw BrowserFailure.invalidIdentifier(repository.did) }

        let (status, output) = try await operations.listBlobs(
            repository.pdsURL,
            .init(did: parsedDID, limit: limit, cursor: cursor)
        )
        guard (200 ... 299).contains(status) else {
            throw BrowserFailure.http(endpoint: ComAtprotoSyncListBlobs.typeIdentifier, statusCode: status)
        }
        guard let output else {
            throw BrowserFailure.decodeFailure(endpoint: ComAtprotoSyncListBlobs.typeIdentifier, statusCode: status)
        }
        return BlobCIDPage(cids: output.cids.map(\.string), cursor: output.cursor)
    }
}
