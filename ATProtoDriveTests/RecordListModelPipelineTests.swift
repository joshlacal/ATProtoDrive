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

    @Test("Model load handles foreign commit non-2xx failure: sets errorState and leaves commit == nil")
    @MainActor
    func testForeignCommitRawErrorInModelLoad() async throws {
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

        let model = RecordListModel()
        await model.load(
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

        #expect(model.commit == nil)
        #expect(model.rows.isEmpty)
        #expect(model.error == "RepoNotFound: Member repo does not exist")
        #expect(model.errorState == .repoNotFound("RepoNotFound: Member repo does not exist"))
    }

    @Test("Model load handles own repo commit thrown error: sets errorState and leaves commit == nil")
    @MainActor
    func testOwnCommitThrownErrorInModelLoad() async throws {
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

        let model = RecordListModel()
        await model.load(
            space: spaceItem,
            repo: ownRepo,
            accountDID: "did:plc:alice123",
            clientListRecords: { _ in
                (200, ComAtprotoSpaceListRecords.Output(cursor: nil, records: [rec]))
            },
            clientGetLatestCommit: {
                throw ATProtoXRPCError(
                    error: "XRPCError_500",
                    message: "Internal server error during commit fetch",
                    statusCode: 500
                )
            },
            resolveDIDToPDS: { _ in URL(string: "https://foreign.pds")! },
            credentialGet: { _, _ in (200, Data()) }
        )

        #expect(model.commit == nil)
        #expect(model.rows.isEmpty)
        #expect(model.error == "XRPCError_500: Internal server error during commit fetch")
        #expect(model.errorState == .general("XRPCError_500: Internal server error during commit fetch"))
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

    // MARK: - Task 11: Blob Fetch Dual Routing & Context Menu Helper Tests

    @Test("Dual-path blob routing: own repo exclusively invokes clientGetBlob")
    func testGetBlobOwnRepoRoutingExclusivity() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:space1/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let ownRepo = RepoEntry(did: "did:plc:alice123", rev: "rev1", hash: "hash1")
        let targetCID = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let expectedData = Data("hello blob data".utf8)

        let clientGetBlobCalled = TestCallTracker()
        let didResolverCalled = TestCallTracker()
        let credentialGetCalled = TestCallTracker()

        let fetchedData = try await RecordListModel.getBlobPipeline(
            space: spaceItem,
            repo: ownRepo,
            cid: targetCID,
            accountDID: "did:plc:alice123",
            clientGetBlob: { cid in
                await clientGetBlobCalled.record(cursor: nil)
                #expect(cid == targetCID)
                return (200, expectedData)
            },
            resolveDIDToPDS: { _ in
                await didResolverCalled.record(cursor: nil)
                return URL(string: "https://pds.example.com")!
            },
            credentialGet: { _, _ in
                await credentialGetCalled.record(cursor: nil)
                return (200, Data())
            }
        )

        #expect(fetchedData == expectedData)
        let clientBlobCount = await clientGetBlobCalled.count
        let didResCount = await didResolverCalled.count
        let credGetCount = await credentialGetCalled.count

        #expect(clientBlobCount == 1)
        #expect(didResCount == 0)
        #expect(credGetCount == 0)
    }

    @Test("Dual-path blob routing: foreign repo exclusively invokes resolveDIDToPDS and credentialGet")
    func testGetBlobForeignRepoRoutingExclusivity() async throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:space1/space/com.atproto.feed/main",
            accountDID: "did:plc:alice123"
        )
        let foreignRepo = RepoEntry(did: "did:plc:bob456", rev: "rev1", hash: "hash1")
        let targetCID = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let expectedData = Data("foreign blob content".utf8)

        let clientGetBlobCalled = TestCallTracker()
        let didResolverCalled = TestCallTracker()
        let credentialGetCalled = TestCallTracker()

        let fetchedData = try await RecordListModel.getBlobPipeline(
            space: spaceItem,
            repo: foreignRepo,
            cid: targetCID,
            accountDID: "did:plc:alice123",
            clientGetBlob: { _ in
                await clientGetBlobCalled.record(cursor: nil)
                return (200, Data())
            },
            resolveDIDToPDS: { did in
                await didResolverCalled.record(cursor: nil)
                #expect(did == "did:plc:bob456")
                return URL(string: "https://bob.pds.place")!
            },
            credentialGet: { url, spaceRef in
                await credentialGetCalled.record(cursor: nil)
                #expect(spaceRef == spaceItem.ref)
                #expect(url.host == "bob.pds.place")
                #expect(url.path.contains("/xrpc/com.atproto.space.getBlob"))
                let query = url.query ?? ""
                #expect(query.contains("space=at%3A%2F%2Fdid%3Aplc%3Aspace1%2Fspace%2Fcom.atproto.feed%2Fmain") || query.contains("space=at://did:plc:space1/space/com.atproto.feed/main"))
                #expect(query.contains("repo=did:plc:bob456") || query.contains("repo=did%3Aplc%3Abob456"))
                #expect(query.contains("cid=\(targetCID)"))
                return (200, expectedData)
            }
        )

        #expect(fetchedData == expectedData)
        let clientBlobCount = await clientGetBlobCalled.count
        let didResCount = await didResolverCalled.count
        let credGetCount = await credentialGetCalled.count

        #expect(clientBlobCount == 0)
        #expect(didResCount == 1)
        #expect(credGetCount == 1)
    }

    @Test("makeGetBlobURL constructs valid XRPC query parameters")
    func testMakeGetBlobURL() throws {
        let spaceRef = try SpaceRef(uriString: "at://did:plc:space1/space/com.atproto.feed/main")
        let pdsHost = URL(string: "https://pds.example.com/subpath/")!
        let blobURL = try #require(RecordListModel.makeGetBlobURL(
            pdsHost: pdsHost,
            space: spaceRef,
            repoDID: "did:plc:alice",
            cid: "bafyreih321"
        ))

        #expect(blobURL.scheme == "https")
        #expect(blobURL.host == "pds.example.com")
        #expect(blobURL.path == "/subpath/xrpc/com.atproto.space.getBlob")
        let query = try #require(blobURL.query)
        #expect(query.contains("space="))
        #expect(query.contains("repo=did%3Aplc%3Aalice") || query.contains("repo=did:plc:alice"))
        #expect(query.contains("cid=bafyreih321"))
    }

    @Test("BlobFileHelper derives correct extensions and suggested filenames")
    func testBlobFileHelperExtensions() throws {
        #expect(BlobFileHelper.fileExtension(forMimeType: "image/png") == "png")
        #expect(BlobFileHelper.fileExtension(forMimeType: "image/jpeg") == "jpeg" || BlobFileHelper.fileExtension(forMimeType: "image/jpeg") == "jpg")
        #expect(BlobFileHelper.fileExtension(forMimeType: "application/json") == "json")
        #expect(BlobFileHelper.fileExtension(forMimeType: "application/pdf") == "pdf")
        #expect(BlobFileHelper.fileExtension(forMimeType: "text/plain") == "txt")
        #expect(BlobFileHelper.fileExtension(forMimeType: nil) == nil)
        #expect(BlobFileHelper.fileExtension(forMimeType: "") == nil)

        let filenamePNG = BlobFileHelper.suggestedFilename(cid: "bafy123", mimeType: "image/png")
        #expect(filenamePNG == "bafy123.png")

        let filenameUnknown = BlobFileHelper.suggestedFilename(cid: "bafy123", mimeType: nil)
        #expect(filenameUnknown == "bafy123")
    }

    @Test("BlobFileHelper writes temp file atomically with proper extension")
    func testBlobFileHelperWriteTemp() throws {
        let testData = Data("temporary file content test".utf8)
        let tempURL = try BlobFileHelper.writeTempFile(
            cid: "bafytesttemp123",
            mimeType: "text/plain",
            data: testData
        )
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        #expect(tempURL.lastPathComponent == "bafytesttemp123.txt")
        let readBack = try Data(contentsOf: tempURL)
        #expect(readBack == testData)
    }
    @Test("BlobFileHelper saves blob data atomically and handles security-scoped access")
    func testBlobFileHelperSaveBlobData() throws {
        let testData = Data("verified synthesized blob content bytes".utf8)
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent("atproto_save_blob_test_\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try BlobFileHelper.saveBlobData(testData, to: destinationURL)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
        let readBack = try Data(contentsOf: destinationURL)
        #expect(readBack == testData)
        #expect(readBack.count == 39)
    }

    @Test("RecordCopyAction routes each menu action to the exact model field on an isolated pasteboard")
    func testRecordCopyActionsIsolatedPasteboard() throws {
        let spaceItem = try SpaceItem(
            uriString: "at://did:plc:space1/space/com.atproto.feed/main",
            accountDID: "did:plc:space1"
        )

        let blob = BlobRefEntry(
            cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a",
            mimeType: "image/png",
            size: 12345
        )

        let record = RecordRow(
            uri: "at://did:plc:space1/space/com.atproto.feed/main/did:plc:alice/app.bsky.feed.post/3l3vbfz",
            collection: "app.bsky.feed.post",
            rkey: "3l3vbfz",
            cid: "bafyreih321cid",
            json: "{\n  \"text\": \"Hello ATProto\"\n}",
            blobEntries: [blob]
        )

        let isolatedPasteboard = InMemoryPasteboard()

        // 1. Copy at:// URI
        RecordCopyAction.copyRecordURI(record, pasteboard: isolatedPasteboard)
        #expect(isolatedPasteboard.readString() == "at://did:plc:space1/space/com.atproto.feed/main/did:plc:alice/app.bsky.feed.post/3l3vbfz")
        #expect(isolatedPasteboard.readString() == record.uri)

        // 2. Copy CID
        RecordCopyAction.copyRecordCID(record, pasteboard: isolatedPasteboard)
        #expect(isolatedPasteboard.readString() == "bafyreih321cid")
        #expect(isolatedPasteboard.readString() == record.cid)

        // 3. Copy JSON
        RecordCopyAction.copyRecordJSON(record, pasteboard: isolatedPasteboard)
        #expect(isolatedPasteboard.readString() == "{\n  \"text\": \"Hello ATProto\"\n}")
        #expect(isolatedPasteboard.readString() == record.json)

        // 4. Copy Blob CID
        RecordCopyAction.copyBlobCID(blob, pasteboard: isolatedPasteboard)
        #expect(isolatedPasteboard.readString() == "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        #expect(isolatedPasteboard.readString() == blob.cid)

        // 5. Copy Space Ref
        RecordCopyAction.copySpaceRef(spaceItem, pasteboard: isolatedPasteboard)
        #expect(isolatedPasteboard.readString() == "at://did:plc:space1/space/com.atproto.feed/main")
        #expect(isolatedPasteboard.readString() == spaceItem.ref.uriString())
    }
    @Test("extractBlobEntries extracts rich BlobRefEntry metadata including mimeType and size")
    func testExtractBlobEntriesRich() throws {
        let multiBlobJSON = """
        {
          "$type": "app.bsky.feed.post",
          "text": "Rich blob test",
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
                  "size": 12345
                }
              }
            ]
          }
        }
        """
        let data = try #require(multiBlobJSON.data(using: .utf8))
        let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)

        let entries = RecordListModel.extractBlobEntries(from: container)
        #expect(entries.count == 1)
        #expect(entries[0].cid == "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        #expect(entries[0].mimeType == "image/png")
        #expect(entries[0].size == 12345)
    }
}
