//
//  SpaceListModelTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("SpaceListModel and SpaceItem Tests")
struct SpaceListModelTests {

    @Test("SpaceItem mapping correctly extracts components and flags own authority")
    func testSpaceItemOwnAuthorityMapping() throws {
        let ownDID = "did:plc:alice123"
        let spaceURI = "at://did:plc:alice123/space/com.example.drive/main"
        let ref = try SpaceRef(uriString: spaceURI)

        let item = SpaceItem(ref: ref, accountDID: ownDID)

        #expect(item.ref == ref)
        #expect(item.accountDID == ownDID)
        #expect(item.id == "\(ownDID):\(ref.uriString())")
        #expect(item.authorityDID == "did:plc:alice123")
        #expect(item.spaceType == "com.example.drive")
        #expect(item.skey == "main")
        #expect(item.isOwnAuthority == true)
    }

    @Test("SpaceItem mapping flags foreign authority when account DID does not match")
    func testSpaceItemForeignAuthorityMapping() throws {
        let userDID = "did:plc:bob456"
        let spaceURI = "at://did:plc:alice123/space/com.example.drive/shared-folder"
        let ref = try SpaceRef(uriString: spaceURI)

        let item = SpaceItem(ref: ref, accountDID: userDID)

        #expect(item.ref == ref)
        #expect(item.accountDID == userDID)
        #expect(item.id == "\(userDID):\(ref.uriString())")
        #expect(item.authorityDID == "did:plc:alice123")
        #expect(item.spaceType == "com.example.drive")
        #expect(item.skey == "shared-folder")
        #expect(item.isOwnAuthority == false)
    }

    @Test("SpaceItem convenience init from uriString")
    func testSpaceItemURIStringInit() throws {
        let ownDID = "did:plc:alice123"
        let spaceURI = "at://did:plc:alice123/space/com.atproto.feed/custom"

        let item = try SpaceItem(uriString: spaceURI, accountDID: ownDID)
        #expect(item.accountDID == ownDID)
        #expect(item.authorityDID == ownDID)
        #expect(item.spaceType == "com.atproto.feed")
        #expect(item.skey == "custom")
        #expect(item.isOwnAuthority == true)
        // Invalid URI throws
        #expect(throws: Error.self) {
            try SpaceItem(uriString: "not-a-space-uri", accountDID: ownDID)
        }
    }

    @Test("SpaceItem Hashable and Identifiable conformance")
    func testSpaceItemHashableAndIdentifiable() throws {
        let ref1 = try SpaceRef(uriString: "at://did:plc:user1/space/app.bsky.feed/item1")
        let ref2 = try SpaceRef(uriString: "at://did:plc:user1/space/app.bsky.feed/item1")
        let ref3 = try SpaceRef(uriString: "at://did:plc:user1/space/app.bsky.feed/item2")

        let item1 = SpaceItem(ref: ref1, accountDID: "did:plc:user1")
        let item2 = SpaceItem(ref: ref2, accountDID: "did:plc:user1")
        let item3 = SpaceItem(ref: ref3, accountDID: "did:plc:user1")

        #expect(item1 == item2)
        #expect(item1.hashValue == item2.hashValue)
        #expect(item1 != item3)
        #expect(item1.id == item2.id)
    }

    @MainActor
    @Test("SpaceListModel initial state")
    func testSpaceListModelInitialState() {
        let model = SpaceListModel()
        #expect(model.spaces.isEmpty)
        #expect(model.error == nil)
        #expect(model.isLoading == false)
    }

    @MainActor
    @Test("SpaceListModel initialized with custom items and error")
    func testSpaceListModelCustomInit() throws {
        let item = try SpaceItem(
            uriString: "at://did:plc:custom1/space/com.example.space/self",
            accountDID: "did:plc:custom1"
        )
        let modelWithSpaces = SpaceListModel(spaces: [item])
        #expect(modelWithSpaces.spaces.count == 1)
        #expect(modelWithSpaces.spaces.first == item)
        #expect(modelWithSpaces.error == nil)

        let modelWithError = SpaceListModel(spaces: [], error: "Test error message")
        #expect(modelWithError.spaces.isEmpty)
        #expect(modelWithError.error == "Test error message")
    }

    @Test("fetchAllSpaces accumulates across multiple pages using cursor")
    func testFetchAllSpacesPagination() async throws {
        let ref1 = try SpaceRef(uriString: "at://did:plc:alice/space/com.example.type/space1")
        let ref2 = try SpaceRef(uriString: "at://did:plc:alice/space/com.example.type/space2")
        let ref3 = try SpaceRef(uriString: "at://did:plc:alice/space/com.example.type/space3")

        let page1 = ComAtprotoSpaceListSpaces.Output(
            cursor: "cursor_page_2",
            spaces: [ComAtprotoSpaceListSpaces.SpaceView(uri: ref1), ComAtprotoSpaceListSpaces.SpaceView(uri: ref2)]
        )
        let page2 = ComAtprotoSpaceListSpaces.Output(
            cursor: nil,
            spaces: [ComAtprotoSpaceListSpaces.SpaceView(uri: ref3)]
        )

        var requestedCursors: [String?] = []

        let result = try await SpaceListModel.fetchAllSpaces(accountDID: "did:plc:alice") { cursor in
            requestedCursors.append(cursor)
            if cursor == nil {
                return (200, page1)
            } else if cursor == "cursor_page_2" {
                return (200, page2)
            } else {
                return (404, nil)
            }
        }

        #expect(requestedCursors == [nil, "cursor_page_2"])
        #expect(result.count == 3)
        #expect(result[0].skey == "space1")
        #expect(result[1].skey == "space2")
        #expect(result[2].skey == "space3")
        #expect(result[0].isOwnAuthority == true)
    }

    @Test("fetchAllSpaces protects against duplicate cursor cycle loops")
    func testFetchAllSpacesCycleProtection() async throws {
        let ref = try SpaceRef(uriString: "at://did:plc:alice/space/com.example.type/space1")
        let loopingPage = ComAtprotoSpaceListSpaces.Output(
            cursor: "loop_cursor",
            spaces: [ComAtprotoSpaceListSpaces.SpaceView(uri: ref)]
        )

        var requestCount = 0
        let result = try await SpaceListModel.fetchAllSpaces(accountDID: "did:plc:alice") { _ in
            requestCount += 1
            return (200, loopingPage)
        }

        // Second time "loop_cursor" is seen, it stops rather than infinite looping
        #expect(requestCount == 2)
        #expect(result.count == 2)
    }

    @Test("fetchAllSpaces propagates non-200 and XRPC errors")
    func testFetchAllSpacesErrorPropagation() async {
        await #expect(throws: Error.self) {
            try await SpaceListModel.fetchAllSpaces(accountDID: "did:plc:alice") { _ in
                throw ATProtoXRPCError(error: "SpaceNotFound", message: "The requested space does not exist", statusCode: 404)
            }
        }
    }
}
