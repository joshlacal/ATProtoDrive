import Foundation
import Petrel

public struct RecordInventoryScanReceipt: Equatable, Sendable {
    public let scope: RepositoryScope
    public let collectionsScanned: Int
    public let recordsScanned: Int
    public let referencesFound: Int

    public init(scope: RepositoryScope, collectionsScanned: Int, recordsScanned: Int, referencesFound: Int) {
        self.scope = scope
        self.collectionsScanned = collectionsScanned
        self.recordsScanned = recordsScanned
        self.referencesFound = referencesFound
    }
}

public struct PublicRecordInventoryScanner: Sendable {
    private let service: any PublicRepositoryServing

    public init(service: any PublicRepositoryServing) { self.service = service }

    public func scan(
        repository: ResolvedRepository,
        index: BlobReferenceIndex,
        progress: @escaping @Sendable (BlobReferenceScanProgress) async -> Void
    ) async throws -> RecordInventoryScanReceipt {
        try Task.checkCancellation()
        let description = try await service.describe(repository)
        guard description.repository.did == repository.did else {
            throw BrowserFailure.identityMismatch(expected: repository.did, actual: description.repository.did)
        }
        guard description.repository.pdsURL == repository.pdsURL else {
            throw BrowserFailure.identityMismatch(
                expected: repository.pdsURL.absoluteString,
                actual: description.repository.pdsURL.absoluteString
            )
        }

        let staging = BlobReferenceIndex()
        var collectionsScanned = 0
        var recordsScanned = 0
        var referencesFound = 0

        for collection in description.collections {
            var cursor: String?
            var consumed = Set<String>()
            repeat {
                try Task.checkCancellation()
                if let cursor, !consumed.insert(cursor).inserted {
                    throw BrowserFailure.transport("Record pagination cursor cycle in \(collection)")
                }
                let page = try await service.listRecords(
                    in: repository, collection: collection, cursor: cursor, limit: 100, reverse: false
                )
                for row in page.records {
                    try Task.checkCancellation()
                    guard row.collection == collection else {
                        throw BrowserFailure.identityMismatch(expected: collection, actual: row.collection)
                    }
                    guard row.uri.hasPrefix("at://\(repository.did)/\(collection)/") else {
                        throw BrowserFailure.identityMismatch(
                            expected: "at://\(repository.did)/\(collection)/…",
                            actual: row.uri
                        )
                    }
                    if case .publicRepository(let did) = row.origin, did != repository.did {
                        throw BrowserFailure.identityMismatch(expected: repository.did, actual: did)
                    }
                    let value: ATProtocolValueContainer
                    do { value = try JSONDecoder().decode(ATProtocolValueContainer.self, from: Data(row.json.utf8)) }
                    catch { throw BrowserFailure.decodeFailure(endpoint: row.uri, statusCode: 200) }
                    let record = RecordLocator(
                        scope: repository.scope, uri: row.uri, collection: row.collection,
                        rkey: row.rkey, cid: row.cid
                    )
                    try await staging.replaceReferences(for: record, value: value)
                    referencesFound += try BlobReferenceScanner.scan(value: value, record: record).count
                    recordsScanned += 1
                    await progress(.init(
                        collectionsScanned: collectionsScanned,
                        recordsScanned: recordsScanned,
                        referencesFound: referencesFound
                    ))
                }
                cursor = page.cursor
            } while cursor != nil
            collectionsScanned += 1
            await progress(.init(
                collectionsScanned: collectionsScanned,
                recordsScanned: recordsScanned,
                referencesFound: referencesFound
            ))
        }

        try Task.checkCancellation()
        let staged = await staging.references(in: repository.scope)
        try Task.checkCancellation()
        try await index.replace(scope: repository.scope, with: staged)
        return .init(
            scope: repository.scope,
            collectionsScanned: collectionsScanned,
            recordsScanned: recordsScanned,
            referencesFound: referencesFound
        )
    }
}
