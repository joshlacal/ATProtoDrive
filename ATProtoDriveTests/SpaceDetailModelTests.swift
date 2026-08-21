//
//  SpaceDetailModelTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

actor TestCallTracker {
    private(set) var count: Int = 0
    private(set) var cursors: [String?] = []

    func record(cursor: String?) {
        cursors.append(cursor)
        count += 1
    }
}

@Suite("SpaceDetailModel and RepoEntry Tests")
struct SpaceDetailModelTests {

    // MARK: - RepoEntry Tests

    @Test("RepoEntry properties and Identifiable/Hashable conformance")
    func testRepoEntryProperties() {
        let entry1 = RepoEntry(
            did: "did:plc:alice123",
            rev: "3l3vbfz2zsk22",
            hash: "aGVsbG8gd29ybGQ="
        )
        let entry2 = RepoEntry(
            did: "did:plc:alice123",
            rev: "3l3vbfz2zsk22",
            hash: "aGVsbG8gd29ybGQ="
        )
        let entry3 = RepoEntry(
            did: "did:plc:bob456",
            rev: "3l3vbfz2zsk23",
            hash: "b3RoZXIgaGFzaA=="
        )

        #expect(entry1.id == "did:plc:alice123")
        #expect(entry1.did == "did:plc:alice123")
        #expect(entry1.rev == "3l3vbfz2zsk22")
        #expect(entry1.hash == "aGVsbG8gd29ybGQ=")
        #expect(entry1 == entry2)
        #expect(entry1.hashValue == entry2.hashValue)
        #expect(entry1 != entry3)
    }

    // MARK: - makeListReposURL Tests

    @Test("makeListReposURL builds correct endpoint URL with space query item")
    func testMakeListReposURLStandard() throws {
        let spaceHost = URL(string: "https://pds.example.com")!
        let ref = try SpaceRef(uriString: "at://did:plc:alice123/space/com.atproto.feed/main")

        let url = try #require(SpaceDetailModel.makeListReposURL(spaceHost: spaceHost, space: ref))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "pds.example.com")
        #expect(comps.path == "/xrpc/com.atproto.space.listRepos")
        #expect(comps.queryItems?.contains(URLQueryItem(name: "space", value: "at://did:plc:alice123/space/com.atproto.feed/main")) == true)
        #expect(comps.queryItems?.contains(where: { $0.name == "cursor" }) == false)
    }

    @Test("makeListReposURL handles trailing slash in host and appends cursor when present")
    func testMakeListReposURLWithCursorAndTrailingSlash() throws {
        let spaceHost = URL(string: "https://space.swan.place/")!
        let ref = try SpaceRef(uriString: "at://did:plc:alice123/space/com.atproto.simplespace/my-space")

        let url = try #require(SpaceDetailModel.makeListReposURL(spaceHost: spaceHost, space: ref, cursor: "cursor_page_2"))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/xrpc/com.atproto.space.listRepos")
        #expect(comps.queryItems?.first(where: { $0.name == "space" })?.value == "at://did:plc:alice123/space/com.atproto.simplespace/my-space")
        #expect(comps.queryItems?.first(where: { $0.name == "cursor" })?.value == "cursor_page_2")
    }

    @Test("makeListReposURL preserves subpaths in space host")
    func testMakeListReposURLWithSubpath() throws {
        let spaceHost = URL(string: "http://127.0.0.1:8080/custom/prefix")!
        let ref = try SpaceRef(uriString: "at://did:plc:bob456/space/com.example.drive/root")

        let url = try #require(SpaceDetailModel.makeListReposURL(spaceHost: spaceHost, space: ref))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/custom/prefix/xrpc/com.atproto.space.listRepos")
        #expect(comps.queryItems?.first(where: { $0.name == "space" })?.value == "at://did:plc:bob456/space/com.example.drive/root")
    }

    // MARK: - mapRepoEntries Tests

    @Test("mapRepoEntries converts lexicon Repo to UI RepoEntry with base64 hash")
    func testMapRepoEntries() throws {
        let did = try DID(didString: "did:plc:alice123")
        let rev = try TID(tidString: "3l3vbfz2zsk22")
        let rawData = "sample commit hash".data(using: .utf8)!
        let hash = Bytes(data: rawData)

        let repo = ComAtprotoSpaceListRepos.Repo(did: did, rev: rev, hash: hash)
        let entries = SpaceDetailModel.mapRepoEntries(from: [repo])

        #expect(entries.count == 1)
        #expect(entries[0].did == "did:plc:alice123")
        #expect(entries[0].rev == "3l3vbfz2zsk22")
        #expect(entries[0].hash == rawData.base64EncodedString())
    }

    // MARK: - classifyError Tests

    @Test("classifyError identifies SpaceDeleted as tombstone")
    func testClassifyErrorSpaceDeleted() {
        let xrpcError = ATProtoXRPCError(
            error: "SpaceDeleted",
            message: "The space was deleted by its authority",
            statusCode: 404
        )
        let state1 = SpaceDetailModel.classifyError(xrpcError)
        #expect(state1 == .tombstone("SpaceDeleted: The space was deleted by its authority"))

        let genericError = NSError(
            domain: "TestDomain",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Space has been deleted"]
        )
        let state2 = SpaceDetailModel.classifyError(genericError)
        #expect(state2 == .tombstone("Space has been deleted"))
    }

    @Test("classifyError identifies scope and auth errors as reconsentNeeded")
    func testClassifyErrorReconsentNeeded() {
        let missingScopeXRPC = ATProtoXRPCError(
            error: "MissingScope",
            message: "Missing required space scope",
            statusCode: 403
        )
        let state1 = SpaceDetailModel.classifyError(missingScopeXRPC)
        #expect(state1 == .reconsentNeeded("MissingScope: Missing required space scope"))

        let insufficientScopeXRPC = ATProtoXRPCError(
            error: "InsufficientScope",
            message: "Scope scope:*?authority=* required",
            statusCode: 403
        )
        let state2 = SpaceDetailModel.classifyError(insufficientScopeXRPC)
        #expect(state2 == .reconsentNeeded("InsufficientScope: Scope scope:*?authority=* required"))

        let reconsentMsg = NSError(
            domain: "Auth",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Account re-consent needed for space access"]
        )
        let state3 = SpaceDetailModel.classifyError(reconsentMsg)
        #expect(state3 == .reconsentNeeded("Account re-consent needed for space access"))
    }

    @Test("classifyError identifies general errors")
    func testClassifyErrorGeneral() {
        let networkError = NSError(
            domain: NSURLErrorDomain,
            code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        let state = SpaceDetailModel.classifyError(networkError)
        #expect(state == .general("The Internet connection appears to be offline."))
    }

    // MARK: - fetchAllRepos Pagination Tests

    @Test("fetchAllRepos accumulates across multiple pages using cursor")
    func testFetchAllReposPagination() async throws {
        let did1 = try DID(didString: "did:plc:alice123")
        let did2 = try DID(didString: "did:plc:bob456")
        let rev = try TID(tidString: "3l3vbfz2zsk22")
        let hash = Bytes(data: "hash1".data(using: .utf8)!)

        let page1 = ComAtprotoSpaceListRepos.Output(
            cursor: "page_2_cursor",
            repos: [ComAtprotoSpaceListRepos.Repo(did: did1, rev: rev, hash: hash)]
        )
        let page2 = ComAtprotoSpaceListRepos.Output(
            cursor: nil,
            repos: [ComAtprotoSpaceListRepos.Repo(did: did2, rev: rev, hash: hash)]
        )

        let encoder = JSONEncoder()
        let page1Data = try encoder.encode(page1)
        let page2Data = try encoder.encode(page2)

        let tracker = TestCallTracker()

        let result = try await SpaceDetailModel.fetchAllRepos { cursor in
            await tracker.record(cursor: cursor)
            if cursor == nil {
                return (200, page1Data)
            } else if cursor == "page_2_cursor" {
                return (200, page2Data)
            } else {
                return (404, Data())
            }
        }

        let requestedCursors = await tracker.cursors
        #expect(requestedCursors == [nil, "page_2_cursor"])
        #expect(result.count == 2)
        #expect(result[0].did == "did:plc:alice123")
        #expect(result[1].did == "did:plc:bob456")
    }

    @Test("fetchAllRepos protects against duplicate cursor cycle loops")
    func testFetchAllReposCycleProtection() async throws {
        let did = try DID(didString: "did:plc:alice123")
        let rev = try TID(tidString: "3l3vbfz2zsk22")
        let hash = Bytes(data: "hash".data(using: .utf8)!)

        let loopingPage = ComAtprotoSpaceListRepos.Output(
            cursor: "loop_cursor",
            repos: [ComAtprotoSpaceListRepos.Repo(did: did, rev: rev, hash: hash)]
        )

        let pageData = try JSONEncoder().encode(loopingPage)
        let tracker = TestCallTracker()

        let result = try await SpaceDetailModel.fetchAllRepos { cursor in
            await tracker.record(cursor: cursor)
            return (200, pageData)
        }

        let callCount = await tracker.count
        #expect(callCount == 2)
        #expect(result.count == 2)
    }

    @Test("fetchAllRepos propagates non-200 XRPC errors")
    func testFetchAllReposErrorPropagation() async {
        let errorJSON = "{\"error\":\"SpaceNotFound\",\"message\":\"The requested space does not exist\"}".data(using: .utf8)!

        await #expect(throws: ATProtoXRPCError.self) {
            try await SpaceDetailModel.fetchAllRepos { _ in
                return (404, errorJSON)
            }
        }
    }

    // MARK: - fetchAllMembers Pagination Tests

    @Test("fetchAllMembers accumulates across pages using cursor")
    func testFetchAllMembersPagination() async throws {
        let did1 = try DID(didString: "did:plc:member1")
        let did2 = try DID(didString: "did:plc:member2")

        let page1 = ComAtprotoSimplespaceListMembers.Output(
            cursor: "member_cursor_2",
            members: [ComAtprotoSimplespaceListMembers.Member(did: did1)]
        )
        let page2 = ComAtprotoSimplespaceListMembers.Output(
            cursor: nil,
            members: [ComAtprotoSimplespaceListMembers.Member(did: did2)]
        )

        let tracker = TestCallTracker()

        let result = try await SpaceDetailModel.fetchAllMembers { cursor in
            await tracker.record(cursor: cursor)
            if cursor == nil {
                return (200, page1)
            } else if cursor == "member_cursor_2" {
                return (200, page2)
            } else {
                return (404, nil)
            }
        }

        let requestedCursors = await tracker.cursors
        #expect(requestedCursors == [nil, "member_cursor_2"])
        #expect(result == ["did:plc:member1", "did:plc:member2"])
    }

    @Test("fetchAllMembers protects against duplicate cursor cycle loops")
    func testFetchAllMembersCycleProtection() async throws {
        let did = try DID(didString: "did:plc:member1")
        let loopingPage = ComAtprotoSimplespaceListMembers.Output(
            cursor: "member_loop_cursor",
            members: [ComAtprotoSimplespaceListMembers.Member(did: did)]
        )

        let tracker = TestCallTracker()
        let result = try await SpaceDetailModel.fetchAllMembers { cursor in
            await tracker.record(cursor: cursor)
            return (200, loopingPage)
        }

        let callCount = await tracker.count
        #expect(callCount == 2)
        #expect(result.count == 2)
    }
    // MARK: - isMemberListNotReadableError Tests

    @Test("isMemberListNotReadableError correctly identifies unreadable member list vs genuine XRPC error")
    func testIsMemberListNotReadableError() {
        let methodNotImplemented = ATProtoXRPCError(
            error: "MethodNotImplemented",
            message: "Method com.atproto.simplespace.listMembers not implemented",
            statusCode: 501
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(methodNotImplemented) == true)

        let methodNotFound = ATProtoXRPCError(
            error: "MethodNotFound",
            message: "Method com.atproto.simplespace.listMembers not found",
            statusCode: 404
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(methodNotFound) == true)

        let xrpcNotSupported = ATProtoXRPCError(
            error: "XRPCNotSupported",
            message: "XRPC endpoint not supported",
            statusCode: 400
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(xrpcNotSupported) == true)

        let messageContainsNotImplemented = ATProtoXRPCError(
            error: "CustomError",
            message: "This server has not implemented member listing",
            statusCode: 400
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(messageContainsNotImplemented) == true)

        // Genuine XRPC errors that MUST NOT be suppressed:
        let notFound = ATProtoXRPCError(
            error: "NotFound",
            message: "Space not found",
            statusCode: 404
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(notFound) == false)

        let invalidRequest404 = ATProtoXRPCError(
            error: "InvalidRequest",
            message: "Could not find space record",
            statusCode: 404
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(invalidRequest404) == false)

        let invalidRequest400 = ATProtoXRPCError(
            error: "InvalidRequest",
            message: "Invalid space parameter",
            statusCode: 400
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(invalidRequest400) == false)

        let authError = ATProtoXRPCError(
            error: "AuthError",
            message: "Invalid token",
            statusCode: 401
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(authError) == false)

        let missingScope = ATProtoXRPCError(
            error: "MissingScope",
            message: "Scope missing",
            statusCode: 403
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(missingScope) == false)
    }

    // MARK: - Members Gate & Pipeline Tests

    @Test("shouldFetchMembers gates on isOwnAuthority regardless of spaceType NSID")
    func testShouldFetchMembersGate() throws {
        let accountDID = "did:plc:alice"

        let ownSimplespace = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:alice/space/com.atproto.simplespace/my-space"),
            accountDID: accountDID
        )
        let ownArbitraryType = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:alice/space/com.example.customdrive/work-drive"),
            accountDID: accountDID
        )
        let foreignSimplespace = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:bob/space/com.atproto.simplespace/shared-space"),
            accountDID: accountDID
        )
        let foreignArbitraryType = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:bob/space/com.example.customdrive/shared-drive"),
            accountDID: accountDID
        )

        #expect(SpaceDetailModel.shouldFetchMembers(space: ownSimplespace) == true)
        #expect(SpaceDetailModel.shouldFetchMembers(space: ownArbitraryType) == true)
        #expect(SpaceDetailModel.shouldFetchMembers(space: foreignSimplespace) == false)
        #expect(SpaceDetailModel.shouldFetchMembers(space: foreignArbitraryType) == false)
    }

    @Test("loadSpaceDetails invokes fetchMembers for owned space with arbitrary type NSID")
    func testLoadSpaceDetailsInvokesMembersForOwnedArbitraryType() async throws {
        let accountDID = "did:plc:alice"
        let space = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:alice/space/org.custom.workspace/project1"),
            accountDID: accountDID
        )

        let membersTracker = TestCallTracker()
        let expectedRepo = RepoEntry(did: "did:plc:alice", rev: "3l3vbfz2zsk22", hash: "hash123")

        let result = try await SpaceDetailModel.loadSpaceDetails(
            space: space,
            fetchRepos: { [expectedRepo] },
            fetchMembers: {
                await membersTracker.record(cursor: nil)
                return ["did:plc:alice", "did:plc:bob"]
            }
        )

        let memberFetchCount = await membersTracker.count
        #expect(memberFetchCount == 1)
        #expect(result.repos == [expectedRepo])
        #expect(result.members == ["did:plc:alice", "did:plc:bob"])
    }

    @Test("loadSpaceDetails does not invoke fetchMembers for foreign space with arbitrary type NSID")
    func testLoadSpaceDetailsSkipsMembersForForeignArbitraryType() async throws {
        let accountDID = "did:plc:alice"
        let space = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:bob/space/org.custom.workspace/project1"),
            accountDID: accountDID
        )

        let membersTracker = TestCallTracker()
        let expectedRepo = RepoEntry(did: "did:plc:bob", rev: "3l3vbfz2zsk22", hash: "hash123")

        let result = try await SpaceDetailModel.loadSpaceDetails(
            space: space,
            fetchRepos: { [expectedRepo] },
            fetchMembers: {
                await membersTracker.record(cursor: nil)
                return ["did:plc:bob"]
            }
        )

        let memberFetchCount = await membersTracker.count
        #expect(memberFetchCount == 0)
        #expect(result.repos == [expectedRepo])
        #expect(result.members == nil)
    }

    @Test("loadSpaceDetails suppresses unimplemented member list but throws genuine XRPC errors with raw description")
    func testLoadSpaceDetailsErrorBehavior() async throws {
        let accountDID = "did:plc:alice"
        let space = SpaceItem(
            ref: try SpaceRef(uriString: "at://did:plc:alice/space/com.example.drive/main"),
            accountDID: accountDID
        )

        // Suppressed: MethodNotImplemented returns members = nil without error
        let suppressedResult = try await SpaceDetailModel.loadSpaceDetails(
            space: space,
            fetchRepos: { [] },
            fetchMembers: {
                throw ATProtoXRPCError(error: "MethodNotImplemented", message: "Not implemented", statusCode: 501)
            }
        )
        #expect(suppressedResult.members == nil)

        // Not suppressed: genuine 404 InvalidRequest throws and preserves exact raw error text
        do {
            _ = try await SpaceDetailModel.loadSpaceDetails(
                space: space,
                fetchRepos: { [] },
                fetchMembers: {
                    throw ATProtoXRPCError(
                        error: "InvalidRequest",
                        message: "Could not find space record",
                        statusCode: 404
                    )
                }
            )
            Issue.record("Expected 404 InvalidRequest to throw but succeeded")
        } catch let xrpc as ATProtoXRPCError {
            #expect(xrpc.error == "InvalidRequest")
            #expect(xrpc.statusCode == 404)
            #expect(xrpc.message == "Could not find space record")
            #expect(xrpc.errorDescription == "InvalidRequest: Could not find space record")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // Not suppressed: genuine 404 NotFound throws and preserves exact raw error text
        do {
            _ = try await SpaceDetailModel.loadSpaceDetails(
                space: space,
                fetchRepos: { [] },
                fetchMembers: {
                    throw ATProtoXRPCError(
                        error: "NotFound",
                        message: "Record not found",
                        statusCode: 404
                    )
                }
            )
            Issue.record("Expected 404 NotFound to throw but succeeded")
        } catch let xrpc as ATProtoXRPCError {
            #expect(xrpc.error == "NotFound")
            #expect(xrpc.statusCode == 404)
            #expect(xrpc.message == "Record not found")
            #expect(xrpc.errorDescription == "NotFound: Record not found")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - SpaceDetailModel State Tests

    @MainActor
    @Test("SpaceDetailModel initial state")
    func testSpaceDetailModelInitialState() {
        let model = SpaceDetailModel()
        #expect(model.repos.isEmpty)
        #expect(model.members == nil)
        #expect(model.isLoading == false)
        #expect(model.error == nil)
        #expect(model.errorState == nil)
    }

    @MainActor
    @Test("SpaceDetailModel custom initialization")
    func testSpaceDetailModelCustomInit() {
        let repo = RepoEntry(did: "did:plc:alice", rev: "rev1", hash: "hash1")
        let model = SpaceDetailModel(
            repos: [repo],
            members: ["did:plc:alice", "did:plc:bob"],
            isLoading: false,
            error: "Error message",
            errorState: .general("Error message")
        )

        #expect(model.repos == [repo])
        #expect(model.members == ["did:plc:alice", "did:plc:bob"])
        #expect(model.error == "Error message")
        #expect(model.errorState == .general("Error message"))
    }
}
