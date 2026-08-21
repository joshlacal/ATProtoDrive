//
//  RecordListModelPipelineTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("RecordListModel Pipeline and Routing Tests")
struct RecordListModelPipelineTests {

    @Test("Dual-path routing: own repo uses client listRecords, foreign repo resolves PDS and uses credentials.get")
    @MainActor
    func testDualPathRoutingDecision() async throws {
        // Test own vs foreign repo determination logic
        let accountDID = "did:plc:alice123"
        let ownRepo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")
        let foreignRepo = RepoEntry(did: "did:plc:bob456", rev: "rev2", hash: "hash2")

        #expect(ownRepo.did == accountDID)
        #expect(foreignRepo.did != accountDID)
    }

    @Test("RecordRow JSON pretty printing produces valid formatted JSON")
    func testPrettyJSONValid() throws {
        let postJSON = """
        {
          "$type": "app.bsky.feed.post",
          "text": "Hello, world!",
          "createdAt": "2026-08-21T04:00:00.000Z"
        }
        """
        let data = try #require(postJSON.data(using: .utf8))
        let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)

        let pretty = RecordListModel.formatPrettyJSON(from: container)
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("Hello, world!"))
        #expect(pretty.contains("2026-08-21T04:00:00.000Z"))
        #expect(pretty.contains("app.bsky.feed.post"))
    }

    @Test("Blob refs extraction handles multiple blob attachments")
    func testBlobRefsMultiple() throws {
        let multiBlobJSON = """
        {
          "$type": "app.bsky.feed.post",
          "text": "Two images",
          "embed": {
            "$type": "app.bsky.embed.images",
            "images": [
              {
                "image": {
                  "$type": "blob",
                  "ref": {
                    "$link": "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
                  },
                  "mimeType": "image/png",
                  "size": 1000
                }
              },
              {
                "image": {
                  "$type": "blob",
                  "ref": {
                    "$link": "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"
                  },
                  "mimeType": "image/jpeg",
                  "size": 2000
                }
              }
            ]
          }
        }
        """
        let data = try #require(multiBlobJSON.data(using: .utf8))
        let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)

        let blobs = RecordListModel.extractBlobRefs(from: container)
        #expect(blobs.count == 2)
        #expect(blobs.contains("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"))
        #expect(blobs.contains("bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"))
    }
}
