//
//  RecordListModelTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("RecordListModel and RecordRow Tests")
struct RecordListModelTests {

    // MARK: - RecordRow and Model State Tests

    @Test("RecordRow properties, Identifiable, and Hashable conformance")
    func testRecordRowProperties() {
        let row1 = RecordRow(
            uri: "at://did:plc:space1/com.atproto.feed/main/did:plc:alice/app.bsky.feed.post/3l3vbfz",
            collection: "app.bsky.feed.post",
            rkey: "3l3vbfz",
            cid: "bafyreih321",
            json: "{\n  \"text\": \"Hello World\"\n}",
            blobRefs: ["bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"]
        )
        let row2 = RecordRow(
            uri: "at://did:plc:space1/com.atproto.feed/main/did:plc:alice/app.bsky.feed.post/3l3vbfz",
            collection: "app.bsky.feed.post",
            rkey: "3l3vbfz",
            cid: "bafyreih321",
            json: "{\n  \"text\": \"Hello World\"\n}",
            blobRefs: ["bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"]
        )
        let row3 = RecordRow(
            uri: "at://did:plc:space1/com.atproto.feed/main/did:plc:bob/app.bsky.feed.post/3l3vbf9",
            collection: "app.bsky.feed.post",
            rkey: "3l3vbf9",
            cid: "bafyreih999",
            json: "{}",
            blobRefs: []
        )

        #expect(row1.id == row1.uri)
        #expect(row1.collection == "app.bsky.feed.post")
        #expect(row1.rkey == "3l3vbfz")
        #expect(row1.cid == "bafyreih321")
        #expect(row1.blobRefs == ["bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"])
        #expect(row1 == row2)
        #expect(row1.hashValue == row2.hashValue)
        #expect(row1 != row3)
    }

    @Test("RecordListModel initial state and sorting")
    @MainActor
    func testRecordListModelSorting() {
        let rowA = RecordRow(
            uri: "at://did:plc:space1/com.atproto.feed/main/did:plc:alice/app.bsky.feed.like/1",
            collection: "app.bsky.feed.like",
            rkey: "1",
            cid: "cid1",
            json: "{}"
        )
        let rowB = RecordRow(
            uri: "at://did:plc:space1/com.atproto.feed/main/did:plc:alice/app.bsky.feed.post/2",
            collection: "app.bsky.feed.post",
            rkey: "2",
            cid: "cid2",
            json: "{}"
        )
        let rowC = RecordRow(
            uri: "at://did:plc:space1/com.atproto.feed/main/did:plc:alice/app.bsky.feed.post/1",
            collection: "app.bsky.feed.post",
            rkey: "1",
            cid: "cid3",
            json: "{}"
        )

        let model = RecordListModel(rows: [rowB, rowA, rowC])
        #expect(model.rows.count == 3)
        #expect(model.rows[0].collection == "app.bsky.feed.like")
        #expect(model.rows[1].collection == "app.bsky.feed.post" && model.rows[1].rkey == "1")
        #expect(model.rows[2].collection == "app.bsky.feed.post" && model.rows[2].rkey == "2")

        // Change sort order to reverse collection
        model.sortOrder = [KeyPathComparator(\.collection, order: .reverse)]
        #expect(model.rows[0].collection == "app.bsky.feed.post")
        #expect(model.rows[2].collection == "app.bsky.feed.like")
    }

    // MARK: - Pretty JSON formatting

    @Test("formatPrettyJSON outputs formatted JSON with sorted keys and no escaping slashes")
    func testFormatPrettyJSON() throws {
        let jsonString = """
        {
          "text": "https://example.com/test",
          "nested": {
            "zebra": 1,
            "apple": 2
          }
        }
        """
        let data = try #require(jsonString.data(using: .utf8))
        let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)

        let pretty = RecordListModel.formatPrettyJSON(from: container)
        #expect(pretty.contains("https://example.com/test")) // without escaping slashes
        #expect(pretty.contains("\"text\""))
        #expect(pretty.contains("\"nested\""))

        // Nil container yields empty JSON object
        #expect(RecordListModel.formatPrettyJSON(from: nil) == "{}")
    }

    // MARK: - Blob extraction

    @Test("extractBlobRefs finds blob references in standard atproto blob shapes")
    func testExtractBlobRefs() throws {
        let jsonString = """
        {
          "$type": "app.bsky.feed.post",
          "text": "Post with image",
          "embed": {
            "$type": "app.bsky.embed.images",
            "images": [
              {
                "alt": "Photo",
                "image": {
                  "$type": "blob",
                  "ref": {
                    "$link": "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
                  },
                  "mimeType": "image/jpeg",
                  "size": 123456
                }
              }
            ]
          }
        }
        """
        let data = try #require(jsonString.data(using: .utf8))
        let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)

        let blobs = RecordListModel.extractBlobRefs(from: container)
        #expect(blobs.count == 1)
        #expect(blobs.first == "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")

        // Value with no blobs returns empty array
        let emptyContainer = try JSONDecoder().decode(ATProtocolValueContainer.self, from: "{\"text\":\"no blobs\"}".data(using: .utf8)!)
        #expect(RecordListModel.extractBlobRefs(from: emptyContainer).isEmpty)
    }

    // MARK: - makeRecordURI and mapRecordRow Tests

    @Test("makeRecordURI formats space record at:// URI correctly")
    func testMakeRecordURI() throws {
        let ref = try SpaceRef(uriString: "at://did:plc:authority123/space/com.atproto.feed/main")
        let uri = RecordListModel.makeRecordURI(
            space: ref,
            repoDID: "did:plc:author456",
            collection: "app.bsky.feed.post",
            rkey: "3l3vbfz"
        )
        #expect(uri == "at://did:plc:authority123/com.atproto.feed/main/did:plc:author456/app.bsky.feed.post/3l3vbfz")
    }

    @Test("mapRecordRow maps ComAtprotoSpaceListRecords.Record to UI RecordRow")
    func testMapRecordRow() throws {
        let ref = try SpaceRef(uriString: "at://did:plc:authority123/space/com.atproto.feed/main")
        let valData = "{\"text\":\"Hello\",\"createdAt\":\"2026-08-21T00:00:00Z\"}".data(using: .utf8)!
        let valContainer = try JSONDecoder().decode(ATProtocolValueContainer.self, from: valData)

        let record = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "3l3vbfz"),
            cid: try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"),
            value: valContainer
        )

        let row = RecordListModel.mapRecordRow(from: record, space: ref, repoDID: "did:plc:author456")
        #expect(row.uri == "at://did:plc:authority123/com.atproto.feed/main/did:plc:author456/app.bsky.feed.post/3l3vbfz")
        #expect(row.collection == "app.bsky.feed.post")
        #expect(row.rkey == "3l3vbfz")
        #expect(row.cid == "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        #expect(row.json.contains("\"text\""))
        #expect(row.json.contains("Hello"))
        #expect(row.blobRefs.isEmpty)
    }

    // MARK: - makeListRecordsURL Tests

    @Test("makeListRecordsURL constructs full URL with query parameters")
    func testMakeListRecordsURL() throws {
        let pdsHost = URL(string: "https://pds.example.com")!
        let ref = try SpaceRef(uriString: "at://did:plc:authority123/space/com.atproto.feed/main")

        let url = try #require(RecordListModel.makeListRecordsURL(
            pdsHost: pdsHost,
            space: ref,
            repoDID: "did:plc:author456",
            collection: "app.bsky.feed.post",
            cursor: "cur123",
            limit: 50
        ))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "pds.example.com")
        #expect(comps.path == "/xrpc/com.atproto.space.listRecords")

        let queryMap = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(queryMap["space"] == ref.uriString())
        #expect(queryMap["repo"] == "did:plc:author456")
        #expect(queryMap["collection"] == "app.bsky.feed.post")
        #expect(queryMap["cursor"] == "cur123")
        #expect(queryMap["limit"] == "50")
    }

    @Test("makeGetLatestCommitURL constructs full URL")
    func testMakeGetLatestCommitURL() throws {
        let pdsHost = URL(string: "https://pds.example.com")!
        let ref = try SpaceRef(uriString: "at://did:plc:authority123/space/com.atproto.feed/main")

        let url = try #require(RecordListModel.makeGetLatestCommitURL(
            pdsHost: pdsHost,
            space: ref,
            repoDID: "did:plc:author456"
        ))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/xrpc/com.atproto.space.getLatestCommit")
        let queryMap = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(queryMap["space"] == ref.uriString())
        #expect(queryMap["repo"] == "did:plc:author456")
    }

    // MARK: - Pagination and Error Tests

    @Test("fetchAllRecords accumulates across pages with cursor")
    func testFetchAllRecordsPagination() async throws {
        let tracker = TestCallTracker()

        let rec1 = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "1"),
            cid: try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"),
            value: nil
        )
        let rec2 = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "2"),
            cid: try CID.parse("bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"),
            value: nil
        )
        let rec3 = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.like"),
            rkey: try RecordKey(keyString: "3"),
            cid: try CID.parse("bafyreid7qjxf7f4pszgnjj6x7v7dcxpehbxvqfxvlazmnhp26g5qbgzxqe"),
            value: nil
        )

        let out1 = ComAtprotoSpaceListRecords.Output(cursor: "cursor_page2", records: [rec1, rec2])
        let out2 = ComAtprotoSpaceListRecords.Output(cursor: nil, records: [rec3])

        let data1 = try JSONEncoder().encode(out1)
        let data2 = try JSONEncoder().encode(out2)

        let records = try await RecordListModel.fetchAllRecords { cursor in
            await tracker.record(cursor: cursor)
            if cursor == nil {
                return (200, data1)
            } else if cursor == "cursor_page2" {
                return (200, data2)
            } else {
                return (400, Data())
            }
        }

        #expect(records.count == 3)
        #expect(records[0].rkey.description == "1")
        #expect(records[1].rkey.description == "2")
        #expect(records[2].rkey.description == "3")
        let count = await tracker.count
        #expect(count == 2)
    }

    @Test("fetchAllRecords protects against duplicate cursor cycle loops")
    func testFetchAllRecordsCursorCycleProtection() async throws {
        let tracker = TestCallTracker()

        let rec1 = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "1"),
            cid: try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"),
            value: nil
        )
        let out = ComAtprotoSpaceListRecords.Output(cursor: "loop_cursor", records: [rec1])
        let data = try JSONEncoder().encode(out)

        let records = try await RecordListModel.fetchAllRecords { cursor in
            await tracker.record(cursor: cursor)
            return (200, data)
        }

        #expect(records.count == 2) // page 0 (cursor nil) + page 1 (cursor "loop_cursor"), then detected duplicate and stops
        let count = await tracker.count
        #expect(count == 2)
    }

    @Test("fetchAllRecords propagates XRPC errors with raw description")
    func testFetchAllRecordsErrorPropagation() async throws {
        let errorJSON = """
        {
          "error": "RepoNotFound",
          "message": "Repository did:plc:123 not found in space"
        }
        """.data(using: .utf8)!

        await #expect(throws: ATProtoXRPCError.self) {
            try await RecordListModel.fetchAllRecords { _ in
                (400, errorJSON)
            }
        }
    }

    // MARK: - Error Classification Tests

    @Test("classifyError categorizes RepoNotFound, Tombstone, Reconsent, and General")
    func testClassifyError() {
        let repoErr = ATProtoXRPCError(error: "RepoNotFound", message: "Not found", statusCode: 404)
        let state1 = RecordListModel.classifyError(repoErr)
        #expect(state1 == .repoNotFound("RepoNotFound: Not found"))

        let spaceErr = ATProtoXRPCError(error: "SpaceNotFound", message: "Deleted", statusCode: 404)
        let state2 = RecordListModel.classifyError(spaceErr)
        #expect(state2 == .tombstone("SpaceNotFound: Deleted"))

        let authErr = ATProtoXRPCError(error: "AuthError", message: "invalid_token or expired auth", statusCode: 401)
        let state3 = RecordListModel.classifyError(authErr)
        #expect(state3 == .reconsentNeeded("AuthError: invalid_token or expired auth"))

        let genericErr = ATProtoXRPCError(error: "Unknown", message: "Internal server error", statusCode: 500)
        let state4 = RecordListModel.classifyError(genericErr)
        #expect(state4 == .general("Unknown: Internal server error"))
    }
}
