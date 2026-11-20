import CryptoKit
import Foundation
import os
import PetrelCore
import Testing
@testable import ATProtoDrive

private actor TransportCallRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}

@Suite("Blob payload service")
struct BlobPayloadServiceTests {
    private static func sha256Hex(_ data: Data) -> String {
        Data(CryptoKit.SHA256.hash(data: data))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @Test("builds canonical unauthenticated com.atproto.sync.getBlob URL")
    func buildsPublicGetBlobURL() throws {
        let pdsURL = try #require(URL(string: "https://pds.example.com"))
        let url = try BlobPayloadService.buildPublicGetBlobURL(
            did: "did:plc:alice123",
            pdsURL: pdsURL,
            cid: "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "pds.example.com")
        #expect(components.path == "/xrpc/com.atproto.sync.getBlob")
        #expect(components.queryItems == [
            URLQueryItem(name: "did", value: "did:plc:alice123"),
            URLQueryItem(name: "cid", value: "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        ])
    }

    @Test("rejects permissioned Space scope before touching transport across all entry points")
    func rejectsSpaceScopeWithoutTransportFallback() async throws {
        let root = try FixtureRoot.make(prefix: "blob-payload-space-guard")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = TransportCallRecorder()
        let service = BlobPayloadService(previewRootDirectory: root) { url, _ in
            await recorder.record(url)
            return BlobPayloadResponse(data: Data("should-never-fetch".utf8))
        }

        let spaceLocator = BlobLocator.fixtureSpace(
            cid: CID.fromBlob(Data("secret-space-blob".utf8)).string
        )

        await #expect(throws: BlobPayloadError.unsupportedScope) {
            _ = try await service.fetchVerifiedBlob(spaceLocator)
        }
        await #expect(throws: BlobPayloadError.unsupportedScope) {
            _ = try await service.materializePreview(for: spaceLocator, mimeType: "image/png")
        }
        await #expect(throws: BlobPayloadError.unsupportedScope) {
            _ = try await service.downloadBlob(
                spaceLocator,
                to: root.appendingPathComponent("should-not-exist.png")
            )
        }

        #expect(await recorder.urls.isEmpty)
    }

    @Test("verifies valid CIDv1 raw SHA-256 payload and reports exact SHA-256 hex digest")
    func verifiesValidCIDv1Payload() async throws {
        let payload = Data("hello verified atproto blob".utf8)
        let cid = CID.fromBlob(payload).string
        let expectedHex = Self.sha256Hex(payload)

        let recorder = TransportCallRecorder()
        let service = BlobPayloadService { url, onProgress in
            await recorder.record(url)
            onProgress(Int64(payload.count), Int64(payload.count))
            return BlobPayloadResponse(data: payload, contentType: "text/plain; charset=utf-8")
        }

        let locator = BlobLocator.fixturePublic(cid: cid)
        let verified = try await service.fetchVerifiedBlob(locator)

        #expect(verified.data == payload)
        #expect(verified.contentType == "text/plain")
        #expect(verified.verification.cid == cid)
        #expect(verified.verification.sha256Hex == expectedHex)
        #expect(verified.verification.byteCount == Int64(payload.count))
        #expect(verified.verification.state == .hashVerified(sha256: expectedHex))

        let calls = await recorder.urls
        #expect(calls.count == 1)
        #expect(calls[0].path == "/xrpc/com.atproto.sync.getBlob")
    }

    @Test("fails closed on CIDv1 SHA-256 digest mismatch and writes nothing to disk")
    func failsClosedOnDigestMismatch() async throws {
        let root = try FixtureRoot.make(prefix: "blob-payload-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedData = Data("authentic bytes".utf8)
        let tamperedData = Data("tampered bytes!".utf8)
        let expectedCID = CID.fromBlob(expectedData).string
        let expectedHex = Self.sha256Hex(expectedData)
        let actualHex = Self.sha256Hex(tamperedData)

        let service = BlobPayloadService(previewRootDirectory: root) { _, _ in
            BlobPayloadResponse(data: tamperedData, contentType: "image/png")
        }

        let locator = BlobLocator.fixturePublic(cid: expectedCID)
        let expectedError = BlobPayloadError.cidDigestMismatch(
            cid: expectedCID,
            expectedSHA256: expectedHex,
            actualSHA256: actualHex
        )

        await #expect(throws: expectedError) {
            _ = try await service.fetchVerifiedBlob(locator)
        }

        let previewURL = try await service.previewFileURL(for: locator, mimeType: "image/png")
        await #expect(throws: expectedError) {
            _ = try await service.materializePreview(for: locator, mimeType: "image/png")
        }
        #expect(!FileManager.default.fileExists(atPath: previewURL.path))

        let downloadURL = root.appendingPathComponent("download.png")
        await #expect(throws: expectedError) {
            _ = try await service.downloadBlob(locator, to: downloadURL)
        }
        #expect(!FileManager.default.fileExists(atPath: downloadURL.path))
    }

    @Test("rejects CIDv0, non-raw codecs, and malformed base32 CIDs")
    func rejectsMalformedAndUnsupportedCIDs() throws {
        let sample = Data("sample".utf8)

        #expect(throws: BlobPayloadError.self) {
            _ = try BlobPayloadService.verify(
                data: sample,
                expectedCID: "QmYwAPJzv5CZsnAzt8auVZRnA2P3b8aJ7hT9aQ2bQ3bQ3b"
            )
        }

        let dagCBORCID = CID.fromDAGCBOR(sample).string
        #expect(throws: BlobPayloadError.self) {
            _ = try BlobPayloadService.verify(data: sample, expectedCID: dagCBORCID)
        }

        let validCID = CID.fromBlob(sample).string
        #expect(throws: BlobPayloadError.self) {
            _ = try BlobPayloadService.verify(data: sample, expectedCID: validCID.uppercased())
        }

        #expect(throws: BlobPayloadError.self) {
            _ = try BlobPayloadService.verify(data: sample, expectedCID: "bafkreiINVALID!!!")
        }
    }

    @Test("materializes previews into qualified DID-sanitized temp directories")
    func materializesQualifiedPreviewPaths() async throws {
        let root = try FixtureRoot.make(prefix: "blob-payload-previews")
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let cid = CID.fromBlob(payload).string

        let service = BlobPayloadService(previewRootDirectory: root) { _, _ in
            BlobPayloadResponse(data: payload, contentType: "image/png")
        }

        let aliceLocator = BlobLocator.fixturePublic(did: "did:plc:alice", cid: cid)
        let bobLocator = BlobLocator.fixturePublic(did: "did:plc:bob", cid: cid)

        let alicePreview = try await service.materializePreview(for: aliceLocator, mimeType: "image/png")
        let bobPreview = try await service.materializePreview(for: bobLocator, mimeType: "image/png")

        #expect(alicePreview.fileURL != bobPreview.fileURL)
        #expect(alicePreview.fileURL.deletingLastPathComponent().lastPathComponent == "did_plc_alice")
        #expect(bobPreview.fileURL.deletingLastPathComponent().lastPathComponent == "did_plc_bob")
        #expect(alicePreview.fileURL.lastPathComponent == "\(cid).png")
        #expect(try Data(contentsOf: alicePreview.fileURL) == payload)
        #expect(try Data(contentsOf: bobPreview.fileURL) == payload)
    }

    @Test("downloads verified bytes atomically to destination URL and emits running/verifying progress")
    func downloadsAtomicallyAndReportsProgress() async throws {
        let root = try FixtureRoot.make(prefix: "blob-payload-download")
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0x2A, count: 4_096)
        let cid = CID.fromBlob(payload).string
        let destination = root.appendingPathComponent("nested/output.bin")

        let progressEvents = OSAllocatedUnfairLock(initialState: [(TransferState, Int64, Int64?)]())
        let service = BlobPayloadService(previewRootDirectory: root) { _, onProgress in
            onProgress(2_048, 4_096)
            onProgress(4_096, 4_096)
            return BlobPayloadResponse(data: payload, contentType: "application/octet-stream")
        }

        let result = try await service.downloadBlob(
            .fixturePublic(cid: cid),
            to: destination
        ) { state, done, total in
            progressEvents.withLock { $0.append((state, done, total)) }
        }

        #expect(result.destinationURL == destination)
        #expect(result.verification.byteCount == 4_096)
        #expect(try Data(contentsOf: destination) == payload)

        let states = progressEvents.withLock { $0.map(\.0) }
        #expect(states.contains(.running))
        #expect(states.contains(.verifying))
    }

    @Test("flags HTML and SVG as active download-only formats and allows safe raster images inline")
    func activeFormatSafetyPolicy() async throws {
        let root = try FixtureRoot.make(prefix: "blob-payload-active-formats")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(BlobPayloadService.isActiveDownloadOnlyFormat(mimeType: "text/html"))
        #expect(BlobPayloadService.isActiveDownloadOnlyFormat(mimeType: "text/html; charset=utf-8"))
        #expect(BlobPayloadService.isActiveDownloadOnlyFormat(mimeType: "application/xhtml+xml"))
        #expect(BlobPayloadService.isActiveDownloadOnlyFormat(mimeType: "image/svg+xml"))
        #expect(!BlobPayloadService.isInlinePreviewableImage(mimeType: "image/svg+xml"))

        #expect(!BlobPayloadService.isActiveDownloadOnlyFormat(mimeType: "image/png"))
        #expect(BlobPayloadService.isInlinePreviewableImage(mimeType: "image/png"))
        #expect(BlobPayloadService.isInlinePreviewableImage(mimeType: "image/jpeg"))
        #expect(BlobPayloadService.isInlinePreviewableImage(mimeType: "image/webp"))

        let svgBytes = Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8)
        let svgCID = CID.fromBlob(svgBytes).string
        let recorder = TransportCallRecorder()
        let service = BlobPayloadService(previewRootDirectory: root) { url, _ in
            await recorder.record(url)
            return BlobPayloadResponse(data: svgBytes, contentType: "image/svg+xml")
        }

        await #expect(throws: BlobPayloadError.activeFormatDownloadOnly(mimeType: "image/svg+xml")) {
            _ = try await service.materializePreview(
                for: .fixturePublic(cid: svgCID),
                mimeType: "image/svg+xml"
            )
        }
        #expect(await recorder.urls.isEmpty)
    }
}
