import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("Public blob enumeration")
struct BlobServiceTests {
    @Test("passes opaque cursor to the resolved PDS and requires output")
    func listPage() async throws {
        let cid = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let service = PublicBlobService(operations: .init { url, input in
            #expect(url == ResolvedRepository.fixture.pdsURL)
            #expect(input.cursor == "opaque+/=")
            #expect(input.limit == 1_000)
            return (200, .init(cursor: "next", cids: [cid]))
        })
        let page = try await service.listBlobs(in: .fixture, cursor: "opaque+/=", limit: 1_000)
        #expect(page == .init(cids: [cid.string], cursor: "next"))
    }

    @Test("rejects successful status without a decoded body")
    func missingOutput() async {
        let service = PublicBlobService(operations: .init { _, _ in (200, nil) })
        await #expect(throws: BrowserFailure.decodeFailure(
            endpoint: ComAtprotoSyncListBlobs.typeIdentifier, statusCode: 200
        )) {
            try await service.listBlobs(in: .fixture, cursor: nil, limit: 100)
        }
    }

    @Test("rejects non-success status even when an output was decoded")
    func nonSuccessWithOutput() async throws {
        let cid = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let service = PublicBlobService(operations: .init { _, _ in
            (503, .init(cids: [cid]))
        })
        await #expect(throws: BrowserFailure.http(
            endpoint: ComAtprotoSyncListBlobs.typeIdentifier, statusCode: 503
        )) {
            try await service.listBlobs(in: .fixture, cursor: nil, limit: 100)
        }
    }
}
