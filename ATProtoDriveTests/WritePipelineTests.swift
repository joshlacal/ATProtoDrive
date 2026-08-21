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

    @Test("insertBlobRef inserts blob into empty JSON")
    func testInsertBlobRefIntoEmptyJSON() throws {
        let link = try ATProtoLink(cidString: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let blob = Blob(type: "blob", ref: link, mimeType: "image/png", size: 1024)

        let result = RecordListModel.insertBlobRef(into: "{}", blob: blob)
        #expect(result.contains("blob"))
        #expect(result.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))

        // Validate resulting JSON is well-formed
        let container = try RecordListModel.validateRecordJSON(result)
        let extractedBlobs = RecordListModel.extractBlobRefs(from: container)
        #expect(extractedBlobs.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))
    }

    @Test("insertBlobRef merges blob into existing JSON preserving fields")
    func testInsertBlobRefIntoExistingJSON() throws {
        let initialJSON = """
        {
          "text": "Check out this image",
          "title": "My Post"
        }
        """
        let link = try ATProtoLink(cidString: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let blob = Blob(type: "blob", ref: link, mimeType: "image/png", size: 2048)

        let result = RecordListModel.insertBlobRef(into: initialJSON, blob: blob)

        // Validate text & title are preserved and blob is added
        #expect(result.contains("Check out this image"))
        #expect(result.contains("My Post"))
        #expect(result.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))

        let container = try RecordListModel.validateRecordJSON(result)
        let extractedBlobs = RecordListModel.extractBlobRefs(from: container)
        #expect(extractedBlobs.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))
    }
}
