import Foundation
import Testing
import Petrel
@testable import ATProtoDrive

private let fixtureDID = "did:plc:4hqjfn7m6n5hno3doamuhgef"

@Suite("Public repository service")
struct PublicRepositoryServiceTests {
    @Test("handle and direct DID both route describe to the resolved PDS")
    func targetPDSRouting() async throws {
        let calls = PublicCallRecorder()
        let resolver = StubPDSResolver(result: .init(
            did: fixtureDID,
            pdsURL: URL(string: "https://alice.example")!,
            declaredHandle: nil
        ))
        let service = PublicRepositoryService(
            operations: try .fixture(calls: calls, did: fixtureDID),
            pdsResolver: resolver
        )

        for target in [RepositoryTarget.publicIdentifier("alice.test"), .publicIdentifier(fixtureDID)] {
            let resolved = try await service.resolve(target: target)
            _ = try await service.describe(resolved)
        }

        #expect(await calls.describeURLs == [
            URL(string: "https://alice.example")!,
            URL(string: "https://alice.example")!
        ])
        #expect(await calls.resolvedHandles == ["alice.test"])
    }

    @Test("2xx nil output is a decode failure")
    func nilSuccessFails() async throws {
        let service = PublicRepositoryService(
            operations: try .nilDescribeFixture(did: fixtureDID),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.decodeFailure(
            endpoint: "com.atproto.repo.describeRepo",
            statusCode: 200
        )) {
            _ = try await service.describe(.fixture)
        }
    }

    @Test("Petrel public clients have no auth mode")
    func anonymousPetrelClient() async {
        let client = await ATProtoClient(baseURL: URL(string: "https://pds.example")!)
        #expect(await client.authMode == .none)
    }

    // MARK: - Resolution Tests

    @Test("connectedAccount target preserves connectedAccountDID")
    func connectedAccountTarget() async throws {
        let resolver = StubPDSResolver(result: .init(
            did: fixtureDID,
            pdsURL: URL(string: "https://alice.example")!,
            declaredHandle: "alice.test"
        ))
        let service = PublicRepositoryService(
            operations: try .fixture(calls: PublicCallRecorder(), did: fixtureDID),
            pdsResolver: resolver
        )
        let resolved = try await service.resolve(target: .connectedAccount(did: fixtureDID))
        #expect(resolved.did == fixtureDID)
        #expect(resolved.connectedAccountDID == fixtureDID)
        #expect(resolved.handle == "alice.test")
        #expect(resolved.pdsURL.absoluteString == "https://alice.example")
    }

    @Test(arguments: ["", "   ", "not-a-valid handle with spaces", "@invalid", "did:bad"])
    func resolveRejectsInvalidIdentifiers(invalidIdentifier: String) async throws {
        let service = PublicRepositoryService(
            operations: try .fixture(calls: PublicCallRecorder(), did: fixtureDID),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.self) {
            _ = try await service.resolve(target: .publicIdentifier(invalidIdentifier))
        }
    }

    @Test(arguments: [199, 300, 401, 404, 429, 503])
    func resolveHandleHTTPStatusErrors(statusCode: Int) async throws {
        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (statusCode, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.http(
            endpoint: "com.atproto.identity.resolveHandle",
            statusCode: statusCode
        )) {
            _ = try await service.resolve(target: .publicIdentifier("alice.test"))
        }
    }

    // MARK: - Describe Tests

    @Test(arguments: [199, 300, 401, 404, 429, 503])
    func describeHTTPStatusErrors(statusCode: Int) async throws {
        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (statusCode, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.http(
            endpoint: "com.atproto.repo.describeRepo",
            statusCode: statusCode
        )) {
            _ = try await service.describe(.fixture)
        }
    }

    @Test("describe 299 with nil output is a decode failure")
    func describe299NilOutput() async throws {
        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (299, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.decodeFailure(
            endpoint: "com.atproto.repo.describeRepo",
            statusCode: 299
        )) {
            _ = try await service.describe(.fixture)
        }
    }

    @Test("describe repo identity and doc mismatches are rejected")
    func describeIdentityMismatches() async throws {
        let didValue = try DID(didString: fixtureDID)
        let otherDID = try DID(didString: "did:plc:z72i7hdynmk6r22z27h6tvur")

        // DID mismatch
        let mismatchedDIDOutput = ComAtprotoRepoDescribeRepo.Output(
            handle: try Handle(handleString: "alice.test"),
            did: otherDID,
            didDoc: DIDDocument(
                id: fixtureDID,
                service: [.init(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://alice.example"
                )]
            ),
            collections: [],
            handleIsCorrect: true
        )
        let mismatchedDIDService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (200, mismatchedDIDOutput) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.identityMismatch(
            expected: fixtureDID,
            actual: "did:plc:z72i7hdynmk6r22z27h6tvur"
        )) {
            _ = try await mismatchedDIDService.describe(.fixture)
        }

        // didDoc.id mismatch
        let mismatchedDocOutput = ComAtprotoRepoDescribeRepo.Output(
            handle: try Handle(handleString: "alice.test"),
            did: didValue,
            didDoc: DIDDocument(
                id: "did:plc:z72i7hdynmk6r22z27h6tvur",
                service: [.init(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://alice.example"
                )]
            ),
            collections: [],
            handleIsCorrect: true
        )
        let mismatchedDocService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (200, mismatchedDocOutput) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.identityMismatch(
            expected: fixtureDID,
            actual: "did:plc:z72i7hdynmk6r22z27h6tvur"
        )) {
            _ = try await mismatchedDocService.describe(.fixture)
        }
    }

    @Test("describe deduplicates collections preserving server order")
    func describeDeduplicatesCollections() async throws {
        let didValue = try DID(didString: fixtureDID)
        let output = ComAtprotoRepoDescribeRepo.Output(
            handle: try Handle(handleString: "alice.test"),
            did: didValue,
            didDoc: DIDDocument(
                id: fixtureDID,
                service: [.init(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://alice.example"
                )]
            ),
            collections: [
                try NSID(nsidString: "app.bsky.feed.post"),
                try NSID(nsidString: "app.bsky.feed.like"),
                try NSID(nsidString: "app.bsky.feed.post"),
                try NSID(nsidString: "app.bsky.graph.follow")
            ],
            handleIsCorrect: true
        )
        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (200, output) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        let desc = try await service.describe(.fixture)
        #expect(desc.collections == [
            "app.bsky.feed.post",
            "app.bsky.feed.like",
            "app.bsky.graph.follow"
        ])
    }

    // MARK: - ListRecords Tests

    @Test("listRecords validates inputs before operation")
    func listRecordsInputValidation() async throws {
        let service = PublicRepositoryService(
            operations: try .fixture(calls: PublicCallRecorder(), did: fixtureDID),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.invalidIdentifier("invalid-nsid")) {
            _ = try await service.listRecords(
                in: .fixture,
                collection: "invalid-nsid",
                cursor: nil,
                limit: 50,
                reverse: false
            )
        }
    }

    @Test(arguments: [199, 300, 401, 404, 429, 503])
    func listRecordsHTTPStatusErrors(statusCode: Int) async throws {
        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (statusCode, nil) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.http(
            endpoint: "com.atproto.repo.listRecords",
            statusCode: statusCode
        )) {
            _ = try await service.listRecords(
                in: .fixture,
                collection: "app.test.item",
                cursor: nil,
                limit: 50,
                reverse: false
            )
        }
    }

    @Test("listRecords preserves cursors with +, /, = and maps rows")
    func listRecordsCursorAndMapping() async throws {
        let testURI = try ATProtocolURI(uriString: "at://\(fixtureDID)/app.test.item/3k2v5q")
        let testCID = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        let complexCursor = "cursor+with/special=chars=="

        let record = ComAtprotoRepoListRecords.Record(
            uri: testURI,
            cid: testCID,
            value: .object(["customKey": .string("customValue"), "num": .number(42)])
        )
        let output = ComAtprotoRepoListRecords.Output(
            cursor: complexCursor,
            records: [record]
        )

        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, params in
                    #expect(params.cursor == complexCursor)
                    return (200, output)
                },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )

        let page = try await service.listRecords(
            in: .fixture,
            collection: "app.test.item",
            cursor: complexCursor,
            limit: 50,
            reverse: false
        )

        #expect(page.cursor == complexCursor)
        #expect(page.records.count == 1)
        let row = page.records[0]
        #expect(row.uri == "at://\(fixtureDID)/app.test.item/3k2v5q")
        #expect(row.collection == "app.test.item")
        #expect(row.rkey == "3k2v5q")
        #expect(row.cid == "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")
        #expect(row.origin == .publicRepository(did: fixtureDID))
        #expect(row.json.contains("customKey"))
    }

    @Test("listRecords rejects URI authority and collection mismatches")
    func listRecordsURIMismatches() async throws {
        let wrongAuthorityURI = try ATProtocolURI(uriString: "at://did:plc:other/app.test.item/one")
        let wrongCollectionURI = try ATProtocolURI(uriString: "at://\(fixtureDID)/app.wrong.item/one")
        let testCID = try CID.parse("bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")

        let wrongAuthRecord = ComAtprotoRepoListRecords.Record(
            uri: wrongAuthorityURI,
            cid: testCID,
            value: .null
        )
        let wrongAuthService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (200, .init(cursor: nil, records: [wrongAuthRecord])) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.identityMismatch(
            expected: fixtureDID,
            actual: "did:plc:other"
        )) {
            _ = try await wrongAuthService.listRecords(
                in: .fixture,
                collection: "app.test.item",
                cursor: nil,
                limit: 50,
                reverse: false
            )
        }

        let wrongColRecord = ComAtprotoRepoListRecords.Record(
            uri: wrongCollectionURI,
            cid: testCID,
            value: .null
        )
        let wrongColService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (200, .init(cursor: nil, records: [wrongColRecord])) },
                getRecord: { _, _ in (500, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.identityMismatch(
            expected: "app.test.item",
            actual: "app.wrong.item"
        )) {
            _ = try await wrongColService.listRecords(
                in: .fixture,
                collection: "app.test.item",
                cursor: nil,
                limit: 50,
                reverse: false
            )
        }
    }

    // MARK: - GetRecord Tests

    @Test("getRecord validates inputs before operation")
    func getRecordInputValidation() async throws {
        let service = PublicRepositoryService(
            operations: try .fixture(calls: PublicCallRecorder(), did: fixtureDID),
            pdsResolver: StubPDSResolver.fixture
        )
        // Invalid NSID
        await #expect(throws: BrowserFailure.invalidIdentifier("bad-collection")) {
            _ = try await service.getRecord(in: .fixture, collection: "bad-collection", rkey: "one", cid: nil)
        }
        // Invalid rkey
        await #expect(throws: BrowserFailure.invalidIdentifier("")) {
            _ = try await service.getRecord(in: .fixture, collection: "app.test.item", rkey: "", cid: nil)
        }
        // Invalid CID
        await #expect(throws: BrowserFailure.invalidIdentifier("not-a-cid")) {
            _ = try await service.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: "not-a-cid")
        }
    }

    @Test(arguments: [199, 300, 401, 404, 429, 503])
    func getRecordHTTPStatusErrors(statusCode: Int) async throws {
        let service = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (statusCode, nil) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.http(
            endpoint: "com.atproto.repo.getRecord",
            statusCode: statusCode
        )) {
            _ = try await service.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: nil)
        }
    }

    @Test("getRecord CID matching, fallback, and mismatch rules")
    func getRecordCIDRules() async throws {
        let validCIDStr = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        let validCID = try CID.parse(validCIDStr)
        let otherCIDStr = "bafyreib2rxk3rybk4a4v2w2w4fepzg2k3wve2q25x4bwhu5f2e6q5khezu"
        let otherCID = try CID.parse(otherCIDStr)
        let recordURI = try ATProtocolURI(uriString: "at://\(fixtureDID)/app.test.item/one")

        // Exact match
        let matchOutput = ComAtprotoRepoGetRecord.Output(
            uri: recordURI,
            cid: validCID,
            value: .object(["test": .string("value")])
        )
        let matchService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (200, matchOutput) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        let row1 = try await matchService.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: validCIDStr)
        #expect(row1.cid == validCIDStr)

        // Fallback to requested when response CID is nil
        let nilCIDOutput = ComAtprotoRepoGetRecord.Output(
            uri: recordURI,
            cid: nil,
            value: .object(["test": .string("value")])
        )
        let fallbackService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (200, nilCIDOutput) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        let row2 = try await fallbackService.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: validCIDStr)
        #expect(row2.cid == validCIDStr)

        // CID mismatch throws identityMismatch
        let mismatchOutput = ComAtprotoRepoGetRecord.Output(
            uri: recordURI,
            cid: otherCID,
            value: .object(["test": .string("value")])
        )
        let mismatchService = PublicRepositoryService(
            operations: .init(
                resolveHandle: { _ in (500, nil) },
                describe: { _, _ in (500, nil) },
                listRecords: { _, _ in (500, nil) },
                getRecord: { _, _ in (200, mismatchOutput) }
            ),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.identityMismatch(expected: validCIDStr, actual: otherCIDStr)) {
            _ = try await mismatchService.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: validCIDStr)
        }

        // No CID requested, response contains CID -> success
        let row3 = try await matchService.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: nil)
        #expect(row3.cid == validCIDStr)

        // No CID requested, response has nil CID -> decodeFailure
        await #expect(throws: BrowserFailure.decodeFailure(endpoint: "com.atproto.repo.getRecord", statusCode: 200)) {
            _ = try await fallbackService.getRecord(in: .fixture, collection: "app.test.item", rkey: "one", cid: nil)
        }
    }
}

actor PublicCallRecorder {
    private(set) var describeURLs: [URL] = []
    private(set) var resolvedHandles: [String] = []
    func recordDescribe(_ url: URL) { describeURLs.append(url) }
    func recordHandle(_ handle: String) { resolvedHandles.append(handle) }
}

struct StubPDSResolver: DIDDocumentPDSResolving {
    let result: ResolvedPDSIdentity
    static let fixture = Self(result: .init(
        did: ResolvedRepository.fixture.did,
        pdsURL: ResolvedRepository.fixture.pdsURL,
        declaredHandle: nil
    ))
    func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity {
        guard did == result.did else {
            throw BrowserFailure.identityMismatch(expected: result.did, actual: did)
        }
        return result
    }
    func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity {
        try DIDDocumentPDSResolver.validatedIdentity(
            from: document,
            expectedDID: expectedDID
        )
    }
}

extension PublicRepositoryService.Operations {
    static func fixture(calls: PublicCallRecorder, did: String) throws -> Self {
        let didValue = try DID(didString: did)
        let output = ComAtprotoRepoDescribeRepo.Output(
            handle: try Handle(handleString: "alice.test"),
            did: didValue,
            didDoc: DIDDocument(
                id: did,
                service: [.init(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://alice.example"
                )]
            ),
            collections: [try NSID(nsidString: "app.test.item")],
            handleIsCorrect: true
        )
        return .init(
            resolveHandle: { handle in
                await calls.recordHandle(handle)
                return (200, .init(did: didValue))
            },
            describe: { url, _ in
                await calls.recordDescribe(url)
                return (200, output)
            },
            listRecords: { _, _ in (200, .init(cursor: nil, records: [])) },
            getRecord: { _, _ in (404, nil) }
        )
    }

    static func nilDescribeFixture(did: String) throws -> Self {
        let didValue = try DID(didString: did)
        return .init(
            resolveHandle: { _ in (200, .init(did: didValue)) },
            describe: { _, _ in (200, nil) },
            listRecords: { _, _ in (500, nil) },
            getRecord: { _, _ in (500, nil) }
        )
    }
}
