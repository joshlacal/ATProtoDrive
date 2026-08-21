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

    @Test("Dual-path routing: own repo exclusively invokes clientListRecords and clientGetLatestCommit")
    func testOwnRepoRoutingExclusivity() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let ownRepo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")

        let clientRecordsCalled = TestCallTracker()
        let clientCommitCalled = TestCallTracker()
        let didResolverCalled = TestCallTracker()
        let credentialGetCalled = TestCallTracker()

        let rec = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "1"),
            cid: try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"),
            value: nil
        )

        let signedCommit = ComAtprotoSpaceDefs.SignedCommit(
            ver: 1,
            hash: Bytes(data: Data([1, 2, 3])),
            ikm: Bytes(data: Data()),
            sig: Bytes(data: Data()),
            mac: Bytes(data: Data()),
            rev: try TID(tidString: "3l3vbfz2zsk22")
        )

        let (records, commit) = try await RecordListModel.loadRecordsPipeline(
            space: spaceItem,
            repo: ownRepo,
            accountDID: "did:plc:alice123",
            clientListRecords: { _ in
                await clientRecordsCalled.record(cursor: nil)
                return (200, ComAtprotoSpaceListRecords.Output(cursor: nil, records: [rec]))
            },
            clientGetLatestCommit: {
                await clientCommitCalled.record(cursor: nil)
                return (200, ComAtprotoSpaceGetLatestCommit.Output(commit: signedCommit))
            },
            resolveDIDToPDS: { _ in
                await didResolverCalled.record(cursor: nil)
                return URL(string: "https://foreign.pds")!
            },
            credentialGet: { _, _ in
                await credentialGetCalled.record(cursor: nil)
                return (200, Data())
            }
        )

        #expect(records.count == 1)
        #expect(commit.rev == "3l3vbfz2zsk22")
        #expect(commit.hash == Data([1, 2, 3]).base64EncodedString())

        let clientRecCount = await clientRecordsCalled.count
        let clientComCount = await clientCommitCalled.count
        let didResCount = await didResolverCalled.count
        let credGetCount = await credentialGetCalled.count

        #expect(clientRecCount == 1)
        #expect(clientComCount == 1)
        #expect(didResCount == 0)
        #expect(credGetCount == 0)
    }

    @Test("Dual-path routing: foreign repo exclusively invokes resolveDIDToPDS and credentialGet")
    func testForeignRepoRoutingExclusivity() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let foreignRepo = RepoEntry(did: "did:plc:bob456", rev: "rev2", hash: "hash2")

        let clientRecordsCalled = TestCallTracker()
        let clientCommitCalled = TestCallTracker()
        let didResolverCalled = TestCallTracker()
        let credentialGetCalled = TestCallTracker()

        let rec = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.like"),
            rkey: try RecordKey(keyString: "2"),
            cid: try CID.parse("bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"),
            value: nil
        )

        let signedCommit = ComAtprotoSpaceDefs.SignedCommit(
            ver: 1,
            hash: Bytes(data: Data([4, 5, 6])),
            ikm: Bytes(data: Data()),
            sig: Bytes(data: Data()),
            mac: Bytes(data: Data()),
            rev: try TID(tidString: "3l3vbfz2zsk23")
        )
        let commitOutputJSON = try JSONEncoder().encode(ComAtprotoSpaceGetLatestCommit.Output(commit: signedCommit))
        let recordsOutputJSON = try JSONEncoder().encode(ComAtprotoSpaceListRecords.Output(cursor: nil, records: [rec]))

        let (records, commit) = try await RecordListModel.loadRecordsPipeline(
            space: spaceItem,
            repo: foreignRepo,
            accountDID: "did:plc:alice123",
            clientListRecords: { _ in
                await clientRecordsCalled.record(cursor: nil)
                return (200, nil)
            },
            clientGetLatestCommit: {
                await clientCommitCalled.record(cursor: nil)
                return (200, nil)
            },
            resolveDIDToPDS: { did in
                await didResolverCalled.record(cursor: did)
                return URL(string: "https://bob.pds.example.com")!
            },
            credentialGet: { url, _ in
                await credentialGetCalled.record(cursor: url.absoluteString)
                if url.path.contains("getLatestCommit") {
                    return (200, commitOutputJSON)
                } else {
                    return (200, recordsOutputJSON)
                }
            }
        )

        #expect(records.count == 1)
        #expect(commit.rev == "3l3vbfz2zsk23")
        #expect(commit.hash == Data([4, 5, 6]).base64EncodedString())

        let clientRecCount = await clientRecordsCalled.count
        let clientComCount = await clientCommitCalled.count
        let didResCount = await didResolverCalled.count
        let credGetCount = await credentialGetCalled.count

        #expect(clientRecCount == 0)
        #expect(clientComCount == 0)
        #expect(didResCount == 1)
        #expect(credGetCount == 2) // listRecords + getLatestCommit
    }

    @Test("Raw foreign commit non-2xx failure triggers parseGeneric and propagates exact error")
    func testForeignCommitRawErrorPropagation() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let foreignRepo = RepoEntry(did: "did:plc:bob456", rev: "rev2", hash: "hash2")

        let errorJSON = """
        {
          "error": "RepoNotFound",
          "message": "Member repo does not exist"
        }
        """.data(using: .utf8)!

        let rec = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.like"),
            rkey: try RecordKey(keyString: "2"),
            cid: try CID.parse("bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"),
            value: nil
        )
        let recordsOutputJSON = try JSONEncoder().encode(ComAtprotoSpaceListRecords.Output(cursor: nil, records: [rec]))

        do {
            _ = try await RecordListModel.loadRecordsPipeline(
                space: spaceItem,
                repo: foreignRepo,
                accountDID: "did:plc:alice123",
                clientListRecords: { _ in (200, nil) },
                clientGetLatestCommit: { (200, nil) },
                resolveDIDToPDS: { _ in URL(string: "https://bob.pds")! },
                credentialGet: { url, _ in
                    if url.path.contains("getLatestCommit") {
                        return (404, errorJSON)
                    } else {
                        return (200, recordsOutputJSON)
                    }
                }
            )
            Issue.record("Expected loadRecordsPipeline to throw on commit failure")
        } catch let xrpc as ATProtoXRPCError {
            #expect(xrpc.error == "RepoNotFound")
            #expect(xrpc.message == "Member repo does not exist")
            #expect(xrpc.statusCode == 404)
            #expect(xrpc.errorDescription == "RepoNotFound: Member repo does not exist")

            let classified = RecordListModel.classifyError(xrpc)
            #expect(classified == .repoNotFound("RepoNotFound: Member repo does not exist"))
        } catch {
            Issue.record("Expected ATProtoXRPCError, got \(error)")
        }
    }

    @Test("Raw own repo commit failure propagates exact error")
    func testOwnCommitRawErrorPropagation() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:alice123/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let ownRepo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")

        let rec = ComAtprotoSpaceListRecords.Record(
            collection: try NSID(nsidString: "app.bsky.feed.post"),
            rkey: try RecordKey(keyString: "1"),
            cid: try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"),
            value: nil
        )

        do {
            _ = try await RecordListModel.loadRecordsPipeline(
                space: spaceItem,
                repo: ownRepo,
                accountDID: "did:plc:alice123",
                clientListRecords: { _ in
                    (200, ComAtprotoSpaceListRecords.Output(cursor: nil, records: [rec]))
                },
                clientGetLatestCommit: {
                    (500, nil)
                },
                resolveDIDToPDS: { _ in URL(string: "https://foreign.pds")! },
                credentialGet: { _, _ in (200, Data()) }
            )
            Issue.record("Expected loadRecordsPipeline to throw on own commit failure")
        } catch let xrpc as ATProtoXRPCError {
            #expect(xrpc.error == "XRPCError_500")
            #expect(xrpc.statusCode == 500)
            let classified = RecordListModel.classifyError(xrpc)
            #expect(classified == .general("XRPCError_500: HTTP 500"))
        } catch {
            Issue.record("Expected ATProtoXRPCError, got \(error)")
        }
    }

    @Test("RecordRow JSON pretty printing produces exact canonical byte-for-byte formatted JSON")
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

        // Exact expected canonical formatted JSON with 2-space indentation and alphabetical key ordering
        let expectedJSON = """
        {
          "a_first" : "first",
          "nested" : {
            "a_item" : 1,
            "b_item" : 2,
            "c_item" : 3
          },
          "url" : "https://example.com/a/b/c",
          "z_last" : "last"
        }
        """

        #expect(pretty == expectedJSON)

        // Decode back and verify round-trip semantic equality
        let redecoded = try JSONDecoder().decode(ATProtocolValueContainer.self, from: pretty.data(using: .utf8)!)
        #expect(redecoded == container)
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
