import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("Qualified blob reference index")
struct BlobReferenceIndexTests {
    @Test("keeps every occurrence and separates identical CIDs by repository scope")
    func occurrencesAreQualified() async throws {
        let publicScope = RepositoryScope.publicRepository(
            did: "did:plc:alice",
            pdsURL: try #require(URL(string: "https://alice.example"))
        )
        let spaceScope = RepositoryScope.permissionedSpace(
            spaceURI: "at:space/did:plc:owner/app.example.drive/shared",
            writerDID: "did:plc:alice",
            accountDID: "did:plc:alice"
        )
        let cid = "bafkreigh2akiscaildcq"
        let value: ATProtocolValueContainer = .object([
            "images": .array([
                .object(["$type": .string("blob"), "ref": .object(["$link": .string(cid)])]),
                .object(["$type": .string("blob"), "ref": .object(["$link": .string(cid)])])
            ])
        ])
        let publicRecord = RecordLocator(
            scope: publicScope,
            uri: "at://did:plc:alice/app.example.file/one",
            collection: "app.example.file",
            rkey: "one",
            cid: "bafyreipublic"
        )
        let spaceRecord = RecordLocator(
            scope: spaceScope,
            uri: "at:space/did:plc:owner/app.example.drive/shared/did:plc:alice/app.example.file/one",
            collection: "app.example.file",
            rkey: "one",
            cid: "bafyreispace"
        )
        let index = BlobReferenceIndex()

        try await index.replaceReferences(for: publicRecord, value: value)
        try await index.replaceReferences(for: spaceRecord, value: value)

        let publicRefs = await index.references(to: BlobLocator(scope: publicScope, cid: cid))
        let spaceRefs = await index.references(to: BlobLocator(scope: spaceScope, cid: cid))
        #expect(publicRefs.map(\.jsonPointer) == ["/images/0", "/images/1"])
        #expect(spaceRefs.map(\.jsonPointer) == ["/images/0", "/images/1"])
        #expect(await index.snapshot().keys.count == 2)
    }

    @Test("escapes RFC 6901 object keys and replaces stale record references with different record CID")
    func pointerEscapingAndReplacement() async throws {
        let scope = RepositoryScope.publicRepository(
            did: "did:plc:alice",
            pdsURL: try #require(URL(string: "https://alice.example"))
        )
        let recordInitial = RecordLocator(
            scope: scope,
            uri: "at://did:plc:alice/app.example.file/key",
            collection: "app.example.file",
            rkey: "key",
            cid: "bafyreione"
        )
        let recordUpdated = RecordLocator(
            scope: scope,
            uri: "at://did:plc:alice/app.example.file/key",
            collection: "app.example.file",
            rkey: "key",
            cid: "bafyreitwo"
        )
        let first: ATProtocolValueContainer = .object([
            "a/b~c": .object([
                "$type": .string("blob"),
                "ref": .object(["$link": .string("bafkreifirst")])
            ])
        ])
        let second: ATProtocolValueContainer = .object([
            "next": .object([
                "$type": .string("blob"),
                "ref": .object(["$link": .string("bafkreisecond")])
            ])
        ])
        let index = BlobReferenceIndex()
        try await index.replaceReferences(for: recordInitial, value: first)
        let firstRefs = await index.references(to: .init(scope: scope, cid: "bafkreifirst"))
        #expect(firstRefs.count == 1)
        #expect(firstRefs.first?.jsonPointer == "/a~1b~0c")
        #expect(firstRefs.first?.record.cid == "bafyreione")

        try await index.replaceReferences(for: recordUpdated, value: second)
        #expect(await index.references(to: .init(scope: scope, cid: "bafkreifirst")).isEmpty)
        let secondRefs = await index.references(to: .init(scope: scope, cid: "bafkreisecond"))
        #expect(secondRefs.count == 1)
        #expect(secondRefs.first?.jsonPointer == "/next")
        #expect(secondRefs.first?.record.cid == "bafyreitwo")
    }

    @Test("scans blobs inside decoded known and unknown record containers")
    func decodedRepresentations() throws {
        let record = RecordLocator.fixturePublic()
        let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
        let known = try JSONDecoder().decode(
            ATProtocolValueContainer.self,
            from: Data(#"{"$type":"app.bsky.actor.profile","avatar":{"$type":"blob","ref":{"$link":"bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"},"mimeType":"image/png","size":12}}"#.utf8)
        )
        guard case .knownType = known else {
            Issue.record("Expected generated known-type dispatch")
            return
        }
        let knownOccurrences = try BlobReferenceScanner.scan(value: known, record: record)
        #expect(knownOccurrences.count == 1)
        #expect(knownOccurrences.first?.blob.cid == cid)
        #expect(knownOccurrences.first?.jsonPointer == "/avatar")
        #expect(knownOccurrences.first?.mimeType == "image/png")
        #expect(knownOccurrences.first?.declaredSize == 12)

        let unknown = try JSONDecoder().decode(
            ATProtocolValueContainer.self,
            from: Data(#"{"$type":"app.example.unknown","nested":{"$type":"blob","ref":{"$link":"bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"},"mimeType":"image/png","size":12}}"#.utf8)
        )
        let unknownOccurrences = try BlobReferenceScanner.scan(value: unknown, record: record)
        #expect(unknownOccurrences.count == 1)
        #expect(unknownOccurrences.first?.blob.cid == cid)
        #expect(unknownOccurrences.first?.jsonPointer == "/nested")
        #expect(unknownOccurrences.first?.mimeType == "image/png")
        #expect(unknownOccurrences.first?.declaredSize == 12)
    }

    @Test("projection or scanner errors preserve existing references")
    func projectionErrorPreservesOldRefs() async throws {
        let scope = RepositoryScope.fixturePublic()
        let record = RecordLocator.fixturePublic()
        let index = BlobReferenceIndex()

        let initialValue: ATProtocolValueContainer = .object([
            "avatar": .object([
                "$type": .string("blob"),
                "ref": .object(["$link": .string("bafkreioriginal")])
            ])
        ])
        try await index.replaceReferences(for: record, value: initialValue)
        #expect(await index.references(to: .init(scope: scope, cid: "bafkreioriginal")).count == 1)

        let failingValue = ATProtocolValueContainer.knownType(ThrowingATProtocolValue())
        await #expect(throws: FixtureError.self) {
            try await index.replaceReferences(for: record, value: failingValue)
        }

        let existingRefs = await index.references(to: .init(scope: scope, cid: "bafkreioriginal"))
        #expect(existingRefs.count == 1)
        #expect(existingRefs.first?.record.uri == record.uri)
    }

    @Test("removeRecord isolates removal to the specified record without affecting other records")
    func removeRecordIsolation() async throws {
        let publicScope = RepositoryScope.fixturePublic()
        let record1 = RecordLocator(
            scope: publicScope,
            uri: "at://did:plc:alice/app.example.file/r1",
            collection: "app.example.file",
            rkey: "r1",
            cid: "bafyreir1"
        )
        let record2 = RecordLocator(
            scope: publicScope,
            uri: "at://did:plc:alice/app.example.file/r2",
            collection: "app.example.file",
            rkey: "r2",
            cid: "bafyreir2"
        )
        let spaceRecord = RecordLocator.fixtureSpace(rkey: "s1", recordCID: "bafyreis1")

        let blobCID = "bafkreishared"
        let val: ATProtocolValueContainer = .object([
            "file": .object([
                "$type": .string("blob"),
                "ref": .object(["$link": .string(blobCID)])
            ])
        ])

        let index = BlobReferenceIndex()
        try await index.replaceReferences(for: record1, value: val)
        try await index.replaceReferences(for: record2, value: val)
        try await index.replaceReferences(for: spaceRecord, value: val)

        #expect(await index.references(to: .init(scope: publicScope, cid: blobCID)).count == 2)
        #expect(await index.references(to: .init(scope: spaceRecord.scope, cid: blobCID)).count == 1)

        await index.removeRecord(record1)

        let publicRemaining = await index.references(to: .init(scope: publicScope, cid: blobCID))
        #expect(publicRemaining.count == 1)
        #expect(publicRemaining.first?.record.uri == record2.uri)

        let spaceRemaining = await index.references(to: .init(scope: spaceRecord.scope, cid: blobCID))
        #expect(spaceRemaining.count == 1)
        #expect(spaceRemaining.first?.record.uri == spaceRecord.uri)
    }

    @Test("removeSpace isolates removal to target space and account while removing all writers and preserving other spaces/accounts/public")
    func removeSpaceIsolation() async throws {
        let spaceURI1 = "at:space/did:plc:owner/app.example.drive/space1"
        let spaceURI2 = "at:space/did:plc:owner/app.example.drive/space2"

        let scopeSpace1AliceWriter1 = RepositoryScope.permissionedSpace(spaceURI: spaceURI1, writerDID: "did:plc:alice", accountDID: "did:plc:alice")
        let scopeSpace1AliceWriter2 = RepositoryScope.permissionedSpace(spaceURI: spaceURI1, writerDID: "did:plc:writer2", accountDID: "did:plc:alice")
        let scopeSpace1BobWriterBob = RepositoryScope.permissionedSpace(spaceURI: spaceURI1, writerDID: "did:plc:bob", accountDID: "did:plc:bob")
        let scopeSpace2AliceWriter1 = RepositoryScope.permissionedSpace(spaceURI: spaceURI2, writerDID: "did:plc:alice", accountDID: "did:plc:alice")
        let scopePublic = RepositoryScope.fixturePublic()

        let recSpace1AliceWriter1 = RecordLocator(scope: scopeSpace1AliceWriter1, uri: "\(spaceURI1)/did:plc:alice/col/r1", collection: "col", rkey: "r1", cid: "bafy1")
        let recSpace1AliceWriter2 = RecordLocator(scope: scopeSpace1AliceWriter2, uri: "\(spaceURI1)/did:plc:writer2/col/r1", collection: "col", rkey: "r1", cid: "bafy2")
        let recSpace1BobWriterBob = RecordLocator(scope: scopeSpace1BobWriterBob, uri: "\(spaceURI1)/did:plc:bob/col/r1", collection: "col", rkey: "r1", cid: "bafy3")
        let recSpace2AliceWriter1 = RecordLocator(scope: scopeSpace2AliceWriter1, uri: "\(spaceURI2)/did:plc:alice/col/r1", collection: "col", rkey: "r1", cid: "bafy4")
        let recPublic = RecordLocator(scope: scopePublic, uri: "at://did:plc:alice/col/r1", collection: "col", rkey: "r1", cid: "bafy5")

        let blobCID = "bafkreicommon"
        let val: ATProtocolValueContainer = .object([
            "b": .object(["$type": .string("blob"), "ref": .object(["$link": .string(blobCID)])])
        ])

        let index = BlobReferenceIndex()
        try await index.replaceReferences(for: recSpace1AliceWriter1, value: val)
        try await index.replaceReferences(for: recSpace1AliceWriter2, value: val)
        try await index.replaceReferences(for: recSpace1BobWriterBob, value: val)
        try await index.replaceReferences(for: recSpace2AliceWriter1, value: val)
        try await index.replaceReferences(for: recPublic, value: val)

        await index.removeSpace(spaceURI: spaceURI1, accountDID: "did:plc:alice")

        // Both writers under space1 + account did:plc:alice must be removed
        #expect(await index.references(to: .init(scope: scopeSpace1AliceWriter1, cid: blobCID)).isEmpty)
        #expect(await index.references(to: .init(scope: scopeSpace1AliceWriter2, cid: blobCID)).isEmpty)

        // Other accounts, other spaces, and public repositories must be preserved
        #expect(await index.references(to: .init(scope: scopeSpace1BobWriterBob, cid: blobCID)).count == 1)
        #expect(await index.references(to: .init(scope: scopeSpace2AliceWriter1, cid: blobCID)).count == 1)
        #expect(await index.references(to: .init(scope: scopePublic, cid: blobCID)).count == 1)
    }
}
