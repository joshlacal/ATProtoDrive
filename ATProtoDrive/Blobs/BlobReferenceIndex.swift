import Foundation
import Petrel

public actor BlobReferenceIndex {
    private struct RecordReferenceKey: Hashable {
        let scope: RepositoryScope
        let uri: String
    }
    private var occurrencesByBlob: [BlobLocator: Set<BlobReferenceOccurrence>] = [:]
    private var blobsByRecord: [RecordReferenceKey: Set<BlobLocator>] = [:]

    public init() {}

    public func replaceReferences(
        for record: RecordLocator,
        value: ATProtocolValueContainer
    ) throws {
        let occurrences = try BlobReferenceScanner.scan(value: value, record: record)
        removeRecord(record)
        let recordKey = RecordReferenceKey(scope: record.scope, uri: record.uri)
        for occurrence in occurrences {
            occurrencesByBlob[occurrence.blob, default: []].insert(occurrence)
            blobsByRecord[recordKey, default: []].insert(occurrence.blob)
        }
    }

    public func removeRecord(_ record: RecordLocator) {
        let recordKey = RecordReferenceKey(scope: record.scope, uri: record.uri)
        removeRecord(key: recordKey)
    }

    private func removeRecord(key recordKey: RecordReferenceKey) {
        for blob in blobsByRecord.removeValue(forKey: recordKey) ?? [] {
            occurrencesByBlob[blob] = occurrencesByBlob[blob]?.filter {
                $0.record.scope != recordKey.scope || $0.record.uri != recordKey.uri
            }
            if occurrencesByBlob[blob]?.isEmpty == true {
                occurrencesByBlob.removeValue(forKey: blob)
            }
        }
    }

    public func references(to blob: BlobLocator) -> [BlobReferenceOccurrence] {
        (occurrencesByBlob[blob] ?? []).sorted {
            ($0.record.uri, $0.jsonPointer) < ($1.record.uri, $1.jsonPointer)
        }
    }

    public func references(in scope: RepositoryScope) -> [BlobReferenceOccurrence] {
        occurrencesByBlob.values.flatMap { $0 }
            .filter { $0.blob.scope == scope }
            .sorted { ($0.record.uri, $0.jsonPointer) < ($1.record.uri, $1.jsonPointer) }
    }

    public func snapshot() -> [BlobLocator: [BlobReferenceOccurrence]] {
        occurrencesByBlob.mapValues(Array.init)
    }

    /// Replaces one repository scope as a single actor-isolated mutation.
    /// Callers can build and validate a complete scan off to the side before publishing it.
    public func replace(
        scope: RepositoryScope,
        with occurrences: [BlobReferenceOccurrence]
    ) throws {
        guard occurrences.allSatisfy({ $0.blob.scope == scope && $0.record.scope == scope }) else {
            throw BrowserFailure.identityMismatch(expected: scope.stableID, actual: "mixed reference scope")
        }
        try Task.checkCancellation()
        let records = blobsByRecord.keys.filter { $0.scope == scope }
        for record in records { removeRecord(key: record) }

        for occurrence in occurrences {
            let recordKey = RecordReferenceKey(scope: scope, uri: occurrence.record.uri)
            occurrencesByBlob[occurrence.blob, default: []].insert(occurrence)
            blobsByRecord[recordKey, default: []].insert(occurrence.blob)
        }
    }

    public func removeSpace(spaceURI: String, accountDID: String) {
        let matchingRecords = blobsByRecord.keys.filter { key in
            guard case .permissionedSpace(let candidateSpace, _, let candidateAccount) = key.scope else {
                return false
            }
            return candidateSpace == spaceURI && candidateAccount == accountDID
        }
        for key in matchingRecords {
            removeRecord(key: key)
        }
    }
}
