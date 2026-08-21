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

    @Test("Dual-path routing: own repo exclusively invokes own records and commit closures")
    func testOwnRepoRoutingExclusivity() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let ownRepo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")

        let ownRecordsCalled = TestCallTracker()
        let ownCommitCalled = TestCallTracker()
        let foreignPDSResolved = TestCallTracker()
        let foreignRecordsCalled = TestCallTracker()
        let foreignCommitCalled = TestCallTracker()

        let rec = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "1"),
            cid: try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"),
            value: nil
        )

        let (records, commit) = try await RecordListModel.loadRecordsPipeline(
            space: spaceItem,
            repo: ownRepo,
            accountDID: "did:plc:alice123",
            fetchOwnRecords: {
                await ownRecordsCalled.record(cursor: nil)
                return [rec]
            },
            fetchOwnCommit: {
                await ownCommitCalled.record(cursor: nil)
                return (rev: "rev1", hash: "hash1")
            },
            resolveForeignPDS: {
                await foreignPDSResolved.record(cursor: nil)
                return URL(string: "https://foreign.pds")!
            },
            fetchForeignRecords: { _ in
                await foreignRecordsCalled.record(cursor: nil)
                return []
            },
            fetchForeignCommit: { _ in
                await foreignCommitCalled.record(cursor: nil)
                return (rev: "foreignRev", hash: "foreignHash")
            }
        )

        #expect(records.count == 1)
        #expect(commit.rev == "rev1")
        #expect(commit.hash == "hash1")

        let ownRecCount = await ownRecordsCalled.count
        let ownComCount = await ownCommitCalled.count
        let foreignPDSCount = await foreignPDSResolved.count
        let foreignRecCount = await foreignRecordsCalled.count
        let foreignComCount = await foreignCommitCalled.count

        #expect(ownRecCount == 1)
        #expect(ownComCount == 1)
        #expect(foreignPDSCount == 0)
        #expect(foreignRecCount == 0)
        #expect(foreignComCount == 0)
    }

    @Test("Dual-path routing: foreign repo exclusively resolves PDS and invokes foreign records/commit closures")
    func testForeignRepoRoutingExclusivity() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let foreignRepo = RepoEntry(did: "did:plc:bob456", rev: "rev2", hash: "hash2")

        let ownRecordsCalled = TestCallTracker()
        let ownCommitCalled = TestCallTracker()
        let foreignPDSResolved = TestCallTracker()
        let foreignRecordsCalled = TestCallTracker()
        let foreignCommitCalled = TestCallTracker()

        let rec = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.like"),
            rkey: try RecordKey(keyString: "2"),
            cid: try CID.parse("bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"),
            value: nil
        )

        let (records, commit) = try await RecordListModel.loadRecordsPipeline(
            space: spaceItem,
            repo: foreignRepo,
            accountDID: "did:plc:alice123",
            fetchOwnRecords: {
                await ownRecordsCalled.record(cursor: nil)
                return []
            },
            fetchOwnCommit: {
                await ownCommitCalled.record(cursor: nil)
                return (rev: "ownRev", hash: "ownHash")
            },
            resolveForeignPDS: {
                await foreignPDSResolved.record(cursor: nil)
                return URL(string: "https://bob.pds.example.com")!
            },
            fetchForeignRecords: { pdsURL in
                await foreignRecordsCalled.record(cursor: pdsURL.absoluteString)
                return [rec]
            },
            fetchForeignCommit: { pdsURL in
                await foreignCommitCalled.record(cursor: pdsURL.absoluteString)
                return (rev: "bobRev", hash: "bobHash")
            }
        )

        #expect(records.count == 1)
        #expect(commit.rev == "bobRev")
        #expect(commit.hash == "bobHash")

        let ownRecCount = await ownRecordsCalled.count
        let ownComCount = await ownCommitCalled.count
        let foreignPDSCount = await foreignPDSResolved.count
        let foreignRecCount = await foreignRecordsCalled.count
        let foreignComCount = await foreignCommitCalled.count

        #expect(ownRecCount == 0)
        #expect(ownComCount == 0)
        #expect(foreignPDSCount == 1)
        #expect(foreignRecCount == 1)
        #expect(foreignComCount == 1)
    }

    @Test("getLatestCommit errors in pipeline propagate without silent fallback")
    func testCommitErrorPropagates() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let foreignRepo = RepoEntry(did: "did:plc:bob456", rev: "rev2", hash: "hash2")

        await #expect(throws: ATProtoXRPCError.self) {
            _ = try await RecordListModel.loadRecordsPipeline(
                space: spaceItem,
                repo: foreignRepo,
                accountDID: "did:plc:alice123",
                fetchOwnRecords: { [] },
                fetchOwnCommit: { (rev: "", hash: "") },
                resolveForeignPDS: { URL(string: "https://bob.pds")! },
                fetchForeignRecords: { _ in [] },
                fetchForeignCommit: { _ in
                    throw ATProtoXRPCError(error: "CommitNotFound", message: "Commit not found", statusCode: 404)
                }
            )
        }
    }

    @Test("RecordRow JSON pretty printing produces deterministic canonical sorted and formatted JSON")
    func testPrettyJSONDeterministicOutput() throws {
        let postJSON = """
        {
          "z_last": "last",
          "a_first": "first",
          "nested": {
            "c_item": 3,
            "a_item": 1,
            "b_item": 2
          },
          "url": "https://example.com/a/b/c"
        }
        """
        let data = try #require(postJSON.data(using: .utf8))
        let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)

        let pretty = RecordListModel.formatPrettyJSON(from: container)

        // Decode back and verify round-trip semantic equality
        let redecoded = try JSONDecoder().decode(ATProtocolValueContainer.self, from: pretty.data(using: .utf8)!)
        #expect(redecoded == container)

        // Verify unescaped slashes
        #expect(pretty.contains("https://example.com/a/b/c"))
        #expect(!pretty.contains("https:\\/\\/example.com"))

        // Verify sorted keys at top level and nested level
        let firstIndex = try #require(pretty.range(of: "\"a_first\"")?.lowerBound)
        let nestedIndex = try #require(pretty.range(of: "\"nested\"")?.lowerBound)
        let lastIndex = try #require(pretty.range(of: "\"z_last\"")?.lowerBound)
        #expect(firstIndex < nestedIndex)
        #expect(nestedIndex < lastIndex)

        let nestedAIndex = try #require(pretty.range(of: "\"a_item\"")?.lowerBound)
        let nestedBIndex = try #require(pretty.range(of: "\"b_item\"")?.lowerBound)
        let nestedCIndex = try #require(pretty.range(of: "\"c_item\"")?.lowerBound)
        #expect(nestedAIndex < nestedBIndex)
        #expect(nestedBIndex < nestedCIndex)
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
