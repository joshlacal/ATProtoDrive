//
//  WritePipelineTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

actor WriteTestCallTracker {
    private(set) var callCount: Int = 0
    private(set) var recordedInputs: [Any] = []

    func record(_ input: Any = ()) {
        callCount += 1
        recordedInputs.append(input)
    }
}

@Suite("Write Pipeline and Mutation Tests")
struct WritePipelineTests {

    private func makeTestAccount(id: String = "did:plc:alice123", handle: String = "alice.test") async -> AccountStore.Account {
        let dummyClient = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: dummyClient))
        let creds = SpaceCredentialManager(client: dummyClient, resolver: resolver)
        return AccountStore.Account(id: id, handle: handle, client: dummyClient, credentials: creds, authMode: .cab)
    }

    // MARK: - 1. CreateSpace Tests

    @Test("makeCreateSpaceInput constructs memberListPolicy and open appAccess correctly")
    func testCreateSpaceInputMemberList() throws {
        let input = try SpaceDetailModel.makeCreateSpaceInput(
            spaceType: "space.swan.drive",
            skey: "self",
            policy: .memberList
        )

        #expect(input.type.description == "space.swan.drive")
        #expect(input.skey?.description == "self")

        if case .comAtprotoSimplespaceDefsMemberListPolicy = input.policy {
            // expected
        } else {
            Issue.record("Expected comAtprotoSimplespaceDefsMemberListPolicy")
        }

        if case .comAtprotoSimplespaceDefsOpen = input.appAccess {
            // expected
        } else {
            Issue.record("Expected comAtprotoSimplespaceDefsOpen")
        }
    }

    @Test("makeCreateSpaceInput constructs publicPolicy correctly and handles nil skey")
    func testCreateSpaceInputPublicPolicy() throws {
        let input = try SpaceDetailModel.makeCreateSpaceInput(
            spaceType: "space.swan.notes",
            skey: nil,
            policy: .public
        )

        #expect(input.type.description == "space.swan.notes")
        #expect(input.skey == nil)

        if case .comAtprotoSimplespaceDefsPublicPolicy = input.policy {
            // expected
        } else {
            Issue.record("Expected comAtprotoSimplespaceDefsPublicPolicy")
        }

        if case .comAtprotoSimplespaceDefsOpen = input.appAccess {
            // expected
        } else {
            Issue.record("Expected comAtprotoSimplespaceDefsOpen")
        }
    }

    @Test("makeCreateSpaceInput rejects empty space type")
    func testCreateSpaceInputEmptyTypeValidation() {
        #expect(throws: CreateSpaceError.emptySpaceType) {
            try SpaceDetailModel.makeCreateSpaceInput(
                spaceType: "   ",
                skey: "self",
                policy: .memberList
            )
        }
    }

    @Test("performCreateSpace calls injected transport and returns created SpaceRef")
    func testPerformCreateSpace() async throws {
        let tracker = WriteTestCallTracker()
        let expectedRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()

        let result = try await SpaceDetailModel.performCreateSpace(
            spaceType: "space.swan.drive",
            skey: "self",
            policy: .memberList,
            account: dummyAccount,
            transport: { input in
                await tracker.record(input)
                #expect(input.type.description == "space.swan.drive")
                return (200, ComAtprotoSimplespaceCreateSpace.Output(uri: expectedRef))
            }
        )

        #expect(result.uriString() == expectedRef.uriString())
        let count = await tracker.callCount
        #expect(count == 1)
    }

    // MARK: - 2. Member Management Tests

    @Test("resolveIdentifierToDID handles direct DID input without resolving handle")
    func testResolveIdentifierDirectDID() async throws {
        let resolverTracker = WriteTestCallTracker()
        let did = try await SpaceDetailModel.resolveIdentifierToDID("did:plc:alice123") { handle in
            await resolverTracker.record(handle)
            return "did:plc:wrong"
        }
        #expect(did.description == "did:plc:alice123")
        let count = await resolverTracker.callCount
        #expect(count == 0) // Resolver must NOT be called for DIDs
    }

    @Test("resolveIdentifierToDID resolves handle and strips @ prefix")
    func testResolveIdentifierHandleResolution() async throws {
        let resolverTracker = WriteTestCallTracker()
        let did = try await SpaceDetailModel.resolveIdentifierToDID("@bob.test") { handle in
            await resolverTracker.record(handle)
            #expect(handle == "bob.test")
            return "did:plc:bob456"
        }
        #expect(did.description == "did:plc:bob456")
        let count = await resolverTracker.callCount
        #expect(count == 1)
    }

    @Test("resolveIdentifierToDID rejects empty identifier")
    func testResolveIdentifierEmptyValidation() async {
        await #expect(throws: MemberError.emptyIdentifier) {
            try await SpaceDetailModel.resolveIdentifierToDID("  ")
        }
    }

    @Test("performAddMember invokes handle resolution and member transport with SpaceRef and DID")
    func testPerformAddMember() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()

        try await SpaceDetailModel.performAddMember(
            space: spaceItem,
            identifier: "carol.test",
            account: dummyAccount,
            resolveHandle: { handle in
                #expect(handle == "carol.test")
                return "did:plc:carol789"
            },
            transport: { input in
                await tracker.record(input)
                #expect(input.space.uriString() == spaceItem.ref.uriString())
                #expect(input.did.description == "did:plc:carol789")
                return 200
            }
        )

        let count = await tracker.callCount
        #expect(count == 1)
    }

    @Test("performRemoveMember invokes remove transport with SpaceRef and DID")
    func testPerformRemoveMember() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()

        try await SpaceDetailModel.performRemoveMember(
            space: spaceItem,
            did: "did:plc:carol789",
            account: dummyAccount,
            transport: { input in
                await tracker.record(input)
                #expect(input.space.uriString() == spaceItem.ref.uriString())
                #expect(input.did.description == "did:plc:carol789")
                return 200
            }
        )

        let count = await tracker.callCount
        #expect(count == 1)
    }

    // MARK: - 3. Record CRUD Tests

    @Test("makeCreateRecordInput constructs valid payload and parses value container")
    func testMakeCreateRecordInput() throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let json = """
        {
          "text": "Hello ATProto Space",
          "count": 42
        }
        """

        let input = try RecordListModel.makeCreateRecordInput(
            space: spaceRef,
            repoDID: "did:plc:alice123",
            collection: "app.bsky.feed.post",
            rkey: "post123",
            jsonText: json
        )

        #expect(input.space.uriString() == spaceRef.uriString())
        #expect(input.repo.description == "did:plc:alice123")
        #expect(input.collection.description == "app.bsky.feed.post")
        #expect(input.rkey?.description == "post123")
        #expect(input.validate == true)

        let prettyJSON = RecordListModel.formatPrettyJSON(from: input.record)
        #expect(prettyJSON.contains("Hello ATProto Space"))
        #expect(prettyJSON.contains("42"))
    }

    @Test("makePutRecordInput constructs valid payload and requires rkey")
    func testMakePutRecordInput() throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let json = """
        {
          "title": "Document",
          "completed": true
        }
        """

        let input = try RecordListModel.makePutRecordInput(
            space: spaceRef,
            repoDID: "did:plc:alice123",
            collection: "space.swan.document",
            rkey: "doc456",
            jsonText: json
        )

        #expect(input.space.uriString() == spaceRef.uriString())
        #expect(input.repo.description == "did:plc:alice123")
        #expect(input.collection.description == "space.swan.document")
        #expect(input.rkey.description == "doc456")
        #expect(input.validate == true)

        let prettyJSON = RecordListModel.formatPrettyJSON(from: input.record)
        #expect(prettyJSON.contains("Document"))
        #expect(prettyJSON.contains("true"))
    }

    @Test("makeDeleteRecordInput constructs valid delete payload")
    func testMakeDeleteRecordInput() throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let input = try RecordListModel.makeDeleteRecordInput(
            space: spaceRef,
            repoDID: "did:plc:alice123",
            collection: "app.bsky.feed.post",
            rkey: "post123"
        )

        #expect(input.space.uriString() == spaceRef.uriString())
        #expect(input.repo.description == "did:plc:alice123")
        #expect(input.collection.description == "app.bsky.feed.post")
        #expect(input.rkey.description == "post123")
    }

    @Test("performCreateRecord executes injected transport")
    func testPerformCreateRecord() async throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()
        let expectedCID = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let expectedURI = try ATProtocolURI(uriString: "at://did:plc:alice123/app.bsky.feed.post/3l3vbfz2zsk22")

        let output = try await RecordListModel.performCreateRecord(
            space: spaceRef,
            repoDID: "did:plc:alice123",
            collection: "app.bsky.feed.post",
            rkey: nil,
            jsonText: "{\"text\": \"Hi\"}",
            account: dummyAccount,
            transport: { input in
                await tracker.record(input)
                #expect(input.collection.description == "app.bsky.feed.post")
                #expect(input.rkey == nil)
                return (200, ComAtprotoSpaceCreateRecord.Output(uri: expectedURI, cid: expectedCID))
            }
        )

        #expect(output.cid == expectedCID)
        #expect(output.uri == expectedURI)
        let count = await tracker.callCount
        #expect(count == 1)
    }

    @Test("performPutRecord executes injected transport")
    func testPerformPutRecord() async throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()
        let expectedCID = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let expectedURI = try ATProtocolURI(uriString: "at://did:plc:alice123/app.bsky.feed.post/post123")

        let output = try await RecordListModel.performPutRecord(
            space: spaceRef,
            repoDID: "did:plc:alice123",
            collection: "app.bsky.feed.post",
            rkey: "post123",
            jsonText: "{\"text\": \"Updated\"}",
            account: dummyAccount,
            transport: { input in
                await tracker.record(input)
                #expect(input.rkey.description == "post123")
                return (200, ComAtprotoSpacePutRecord.Output(uri: expectedURI, cid: expectedCID))
            }
        )

        #expect(output.cid == expectedCID)
        #expect(output.uri == expectedURI)
        let count = await tracker.callCount
        #expect(count == 1)
    }

    @Test("performDeleteRecord executes injected transport")
    func testPerformDeleteRecord() async throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()

        _ = try await RecordListModel.performDeleteRecord(
            space: spaceRef,
            repoDID: "did:plc:alice123",
            collection: "app.bsky.feed.post",
            rkey: "post123",
            account: dummyAccount,
            transport: { input in
                await tracker.record(input)
                #expect(input.collection.description == "app.bsky.feed.post")
                #expect(input.rkey.description == "post123")
                return (200, ComAtprotoSpaceDeleteRecord.Output())
            }
        )

        let count = await tracker.callCount
        #expect(count == 1)
    }

    // MARK: - 4. JSON Validation Gate Tests

    @Test("JSON validation gate: empty string throws and NEVER calls transport")
    func testValidationGateEmptyString() async throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()

        do {
            _ = try await RecordListModel.performCreateRecord(
                space: spaceRef,
                repoDID: "did:plc:alice123",
                collection: "app.bsky.feed.post",
                rkey: nil,
                jsonText: "   ",
                account: dummyAccount,
                transport: { input in
                    await tracker.record(input)
                    return (200, nil)
                }
            )
            Issue.record("Should have thrown validation error")
        } catch let error as RecordListModel.RecordValidationError {
            #expect(error == .empty)
        }

        let count = await tracker.callCount
        #expect(count == 0) // CRITICAL: Transport was NEVER called
    }

    @Test("JSON validation gate: malformed syntax throws and NEVER calls transport")
    func testValidationGateMalformedSyntax() async throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()

        do {
            _ = try await RecordListModel.performPutRecord(
                space: spaceRef,
                repoDID: "did:plc:alice123",
                collection: "app.bsky.feed.post",
                rkey: "1",
                jsonText: "{ unquoted_key: 123, }",
                account: dummyAccount,
                transport: { input in
                    await tracker.record(input)
                    return (200, nil)
                }
            )
            Issue.record("Should have thrown validation error")
        } catch let error as RecordListModel.RecordValidationError {
            if case .serializationFailed = error {
                // expected
            } else {
                Issue.record("Expected serializationFailed error, got \(error)")
            }
        }

        let count = await tracker.callCount
        #expect(count == 0) // CRITICAL: Transport was NEVER called
    }

    @Test("JSON validation gate: array root instead of object throws notJSONObject and NEVER calls transport")
    func testValidationGateArrayRoot() async throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let dummyAccount = await makeTestAccount()
        let tracker = WriteTestCallTracker()

        do {
            _ = try await RecordListModel.performCreateRecord(
                space: spaceRef,
                repoDID: "did:plc:alice123",
                collection: "app.bsky.feed.post",
                rkey: nil,
                jsonText: "[1, 2, 3]",
                account: dummyAccount,
                transport: { input in
                    await tracker.record(input)
                    return (200, nil)
                }
            )
            Issue.record("Should have thrown validation error")
        } catch let error as RecordListModel.RecordValidationError {
            #expect(error == .notJSONObject)
        }

        let count = await tracker.callCount
        #expect(count == 0) // CRITICAL: Transport was NEVER called
    }

    // MARK: - 5. Blob Upload & Insertion Tests

    @Test("performUploadBlob calls transport with Data and mimeType and returns Blob")
    func testPerformUploadBlob() async throws {
        let dummyAccount = await makeTestAccount()
        let testData = Data("sample-image-data".utf8)
        let link = try ATProtoLink(cidString: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let returnedBlob = Blob(type: "blob", ref: link, mimeType: "image/png", size: testData.count)

        let tracker = WriteTestCallTracker()

        let blob = try await RecordListModel.performUploadBlob(
            data: testData,
            mimeType: "image/png",
            account: dummyAccount,
            transport: { data, mimeType in
                await tracker.record(data)
                #expect(data == testData)
                #expect(mimeType == "image/png")
                return (200, ComAtprotoRepoUploadBlob.Output(blob: returnedBlob))
            }
        )

        #expect(blob.mimeType == "image/png")
        #expect(blob.size == testData.count)
        #expect(blob.ref?.cid.description == "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let count = await tracker.callCount
        #expect(count == 1)
    }

    @Test("formatBlobRefJSON produces valid ATProto blob descriptor JSON")
    func testFormatBlobRefJSON() throws {
        let link = try ATProtoLink(cidString: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let blob = Blob(type: "blob", ref: link, mimeType: "image/jpeg", size: 4096)

        let json = RecordListModel.formatBlobRefJSON(blob: blob)
        #expect(json.contains("\"$type\" : \"blob\"") || json.contains("\"$type\": \"blob\""))
        #expect(json.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))
        #expect(json.contains("image/jpeg"))
        #expect(json.contains("4096"))
    }

    @Test("spliceBlobRef throws noSelection error when no replacement range is provided")
    func testSpliceBlobRefRequiresExplicitSelection() throws {
        let link = try ATProtoLink(cidString: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let blob = Blob(type: "blob", ref: link, mimeType: "image/png", size: 1024)

        #expect(throws: RecordListModel.SpliceBlobError.noSelection) {
            try RecordListModel.spliceBlobRef(into: "{}", blob: blob, replacementRange: nil)
        }
    }

    @Test("spliceBlobRef inserts at explicit cursor range without modifying other text")
    func testSpliceBlobRefAtCursorRange() throws {
        let initialJSON = "{\n  \"text\": \"Hello\",\n  \"image\": null\n}"
        let link = try ATProtoLink(cidString: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let blob = Blob(type: "blob", ref: link, mimeType: "image/png", size: 1024)

        let nullRange = try #require(initialJSON.range(of: "null"))
        let spliced = try RecordListModel.spliceBlobRef(into: initialJSON, blob: blob, replacementRange: nullRange)

        #expect(spliced.contains("\"text\": \"Hello\""))
        #expect(spliced.contains("\"image\": {"))
        #expect(!spliced.contains("null"))

        let container = try RecordListModel.validateRecordJSON(spliced)
        let blobs = RecordListModel.extractBlobRefs(from: container)
        #expect(blobs.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))
    }

    // MARK: - 6. Model Refresh & Callback Invariant Tests

    @MainActor
    @Test("SpaceListModel createSpace executes transport and reloads model state from empty to populated")
    func testSpaceListModelCreateSpaceReloads() async throws {
        let dummyAccount = await makeTestAccount()
        let model = SpaceListModel(spaces: [])
        #expect(model.spaces.isEmpty)

        let createdRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let createTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()

        let ref = try await model.createSpace(
            spaceType: "space.swan.drive",
            skey: "self",
            policy: .memberList,
            account: dummyAccount,
            transport: { input in
                await createTracker.record(input)
                return (200, ComAtprotoSimplespaceCreateSpace.Output(uri: createdRef))
            },
            listSpacesTransport: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSpaceListSpaces.Output(cursor: nil, spaces: [ComAtprotoSpaceListSpaces.SpaceView(uri: createdRef)]))
            }
        )

        #expect(ref.uriString() == createdRef.uriString())
        let createCount = await createTracker.callCount
        let listCount = await listTracker.callCount
        #expect(createCount == 1)
        #expect(listCount == 1)
        #expect(model.spaces.count == 1)
        #expect(model.spaces.first?.skey == "self")
    }

    @MainActor
    @Test("SpaceListModel deleteSpace executes transport and reloads model state to empty")
    func testSpaceListModelDeleteSpaceReloads() async throws {
        let dummyAccount = await makeTestAccount()
        let spaceRef = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/self")
        let spaceItem = SpaceItem(ref: spaceRef, accountDID: "did:plc:alice123")

        let model = SpaceListModel(spaces: [spaceItem])
        #expect(model.spaces.count == 1)

        let deleteTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()

        try await model.deleteSpace(
            space: spaceItem,
            account: dummyAccount,
            transport: { input in
                await deleteTracker.record(input)
                return 200
            },
            listSpacesTransport: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSpaceListSpaces.Output(cursor: nil, spaces: []))
            }
        )

        let deleteCount = await deleteTracker.callCount
        let listCount = await listTracker.callCount
        #expect(deleteCount == 1)
        #expect(listCount == 1)
        #expect(model.spaces.isEmpty)
    }

    @MainActor
    @Test("RecordListModel createRecord executes transport and reloads model state from empty to populated")
    func testRecordListModelCreateRecordReloads() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let repo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")
        let dummyAccount = await makeTestAccount()

        let model = RecordListModel(rows: [])
        #expect(model.rows.isEmpty)

        let expectedURI = try ATProtocolURI(uriString: "at://did:plc:alice123/app.bsky.feed.post/post1")
        let expectedCID = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")

        let createdRecord = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "post1"),
            cid: expectedCID,
            value: try RecordListModel.validateRecordJSON("{\"text\": \"New Post\"}")
        )

        let signedCommit = ComAtprotoSpaceDefs.SignedCommit(
            ver: 1,
            hash: Bytes(data: Data([1, 2, 3])),
            ikm: Bytes(data: Data()),
            sig: Bytes(data: Data()),
            mac: Bytes(data: Data()),
            rev: try TID(tidString: "3l3vbfz2zsk22")
        )

        let createTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()
        let commitTracker = WriteTestCallTracker()

        let output = try await model.createRecord(
            space: spaceItem,
            repo: repo,
            collection: "app.bsky.feed.post",
            rkey: "post1",
            jsonText: "{\"text\": \"New Post\"}",
            account: dummyAccount,
            transport: { input in
                await createTracker.record(input)
                return (200, ComAtprotoSpaceCreateRecord.Output(uri: expectedURI, cid: expectedCID))
            },
            clientListRecords: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSpaceListRecords.Output(cursor: nil, records: [createdRecord]))
            },
            clientGetLatestCommit: {
                await commitTracker.record()
                return (200, ComAtprotoSpaceGetLatestCommit.Output(commit: signedCommit))
            }
        )

        #expect(output.uri == expectedURI)
        let createCount = await createTracker.callCount
        let listCount = await listTracker.callCount
        let commitCount = await commitTracker.callCount
        #expect(createCount == 1)
        #expect(listCount == 1)
        #expect(commitCount == 1)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.rkey == "post1")
        #expect(model.commit?.rev == "3l3vbfz2zsk22")
    }

    @MainActor
    @Test("RecordListModel putRecord executes transport and reloads model state with updated content")
    func testRecordListModelPutRecordReloads() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let repo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")
        let dummyAccount = await makeTestAccount()

        let oldRow = RecordRow(
            uri: "at://did:plc:alice123/space/space.swan.drive/self/did:plc:alice123/app.bsky.feed.post/post1",
            collection: "app.bsky.feed.post",
            rkey: "post1",
            cid: "oldcid",
            json: "{\"text\": \"Old Post\"}"
        )
        let model = RecordListModel(rows: [oldRow])

        let expectedURI = try ATProtocolURI(uriString: "at://did:plc:alice123/app.bsky.feed.post/post1")
        let expectedCID = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")

        let updatedRecord = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "post1"),
            cid: expectedCID,
            value: try RecordListModel.validateRecordJSON("{\"text\": \"Updated Post\"}")
        )

        let signedCommit = ComAtprotoSpaceDefs.SignedCommit(
            ver: 1,
            hash: Bytes(data: Data([1, 2, 3])),
            ikm: Bytes(data: Data()),
            sig: Bytes(data: Data()),
            mac: Bytes(data: Data()),
            rev: try TID(tidString: "3l3vbfz2zsk22")
        )

        let putTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()
        let commitTracker = WriteTestCallTracker()

        let output = try await model.putRecord(
            space: spaceItem,
            repo: repo,
            collection: "app.bsky.feed.post",
            rkey: "post1",
            jsonText: "{\"text\": \"Updated Post\"}",
            account: dummyAccount,
            transport: { input in
                await putTracker.record(input)
                return (200, ComAtprotoSpacePutRecord.Output(uri: expectedURI, cid: expectedCID))
            },
            clientListRecords: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSpaceListRecords.Output(cursor: nil, records: [updatedRecord]))
            },
            clientGetLatestCommit: {
                await commitTracker.record()
                return (200, ComAtprotoSpaceGetLatestCommit.Output(commit: signedCommit))
            }
        )

        #expect(output.uri == expectedURI)
        let putCount = await putTracker.callCount
        let listCount = await listTracker.callCount
        let commitCount = await commitTracker.callCount
        #expect(putCount == 1)
        #expect(listCount == 1)
        #expect(commitCount == 1)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.json.contains("Updated Post") == true)
    }

    @MainActor
    @Test("RecordListModel deleteRecord executes transport and reloads model state to empty")
    func testRecordListModelDeleteRecordReloads() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let repo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")
        let dummyAccount = await makeTestAccount()

        let existingRow = RecordRow(
            uri: "at://did:plc:alice123/space/space.swan.drive/self/did:plc:alice123/app.bsky.feed.post/post1",
            collection: "app.bsky.feed.post",
            rkey: "post1",
            cid: "cid1",
            json: "{\"text\": \"Post\"}"
        )
        let model = RecordListModel(rows: [existingRow])
        #expect(model.rows.count == 1)

        let signedCommit = ComAtprotoSpaceDefs.SignedCommit(
            ver: 1,
            hash: Bytes(data: Data([1, 2, 3])),
            ikm: Bytes(data: Data()),
            sig: Bytes(data: Data()),
            mac: Bytes(data: Data()),
            rev: try TID(tidString: "3l3vbfz2zsk22")
        )

        let deleteTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()
        let commitTracker = WriteTestCallTracker()

        _ = try await model.deleteRecord(
            space: spaceItem,
            repo: repo,
            collection: "app.bsky.feed.post",
            rkey: "post1",
            account: dummyAccount,
            transport: { input in
                await deleteTracker.record(input)
                return (200, ComAtprotoSpaceDeleteRecord.Output())
            },
            clientListRecords: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSpaceListRecords.Output(cursor: nil, records: []))
            },
            clientGetLatestCommit: {
                await commitTracker.record()
                return (200, ComAtprotoSpaceGetLatestCommit.Output(commit: signedCommit))
            }
        )

        let deleteCount = await deleteTracker.callCount
        let listCount = await listTracker.callCount
        let commitCount = await commitTracker.callCount
        #expect(deleteCount == 1)
        #expect(listCount == 1)
        #expect(commitCount == 1)
        #expect(model.rows.isEmpty)
    }

    @MainActor
    @Test("SpaceDetailModel addMember executes transport and reloads model state with new member")
    func testSpaceDetailModelAddMemberReloads() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let dummyAccount = await makeTestAccount()
        let model = SpaceDetailModel(members: [])
        #expect(model.members?.isEmpty == true)

        let m1 = ComAtprotoSimplespaceListMembers.Member(did: try DID(didString: "did:plc:alice123"))
        let m2 = ComAtprotoSimplespaceListMembers.Member(did: try DID(didString: "did:plc:bob456"))

        let addTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()

        try await model.addMember(
            identifier: "did:plc:bob456",
            space: spaceItem,
            account: dummyAccount,
            resolveHandle: nil,
            transport: { input in
                await addTracker.record(input)
                return 200
            },
            listMembersTransport: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSimplespaceListMembers.Output(cursor: nil, members: [m1, m2]))
            }
        )

        let addCount = await addTracker.callCount
        let listCount = await listTracker.callCount
        #expect(addCount == 1)
        #expect(listCount == 1)
        #expect(model.members == ["did:plc:alice123", "did:plc:bob456"])
    }

    @MainActor
    @Test("SpaceDetailModel removeMember executes transport and reloads model state removing member")
    func testSpaceDetailModelRemoveMemberReloads() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let dummyAccount = await makeTestAccount()
        let model = SpaceDetailModel(members: ["did:plc:alice123", "did:plc:bob456"])
        #expect(model.members?.count == 2)

        let m1 = ComAtprotoSimplespaceListMembers.Member(did: try DID(didString: "did:plc:alice123"))

        let removeTracker = WriteTestCallTracker()
        let listTracker = WriteTestCallTracker()

        try await model.removeMember(
            did: "did:plc:bob456",
            space: spaceItem,
            account: dummyAccount,
            transport: { input in
                await removeTracker.record(input)
                return 200
            },
            listMembersTransport: { cursor in
                await listTracker.record(cursor as Any)
                return (200, ComAtprotoSimplespaceListMembers.Output(cursor: nil, members: [m1]))
            }
        )

        let removeCount = await removeTracker.callCount
        let listCount = await listTracker.callCount
        #expect(removeCount == 1)
        #expect(listCount == 1)
        #expect(model.members == ["did:plc:alice123"])
    }
}
