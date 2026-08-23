import Foundation
import Petrel

public struct ResolvedPDSIdentity: Hashable, Sendable {
    public let did: String
    public let pdsURL: URL
    public let declaredHandle: String?

    public init(did: String, pdsURL: URL, declaredHandle: String? = nil) {
        self.did = did
        self.pdsURL = pdsURL
        self.declaredHandle = declaredHandle
    }
}

public typealias DIDDocumentFetch = @Sendable (URL) async throws -> (
    statusCode: Int,
    data: Data?
)

public protocol DIDDocumentPDSResolving: Sendable {
    func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity
    func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity
}
