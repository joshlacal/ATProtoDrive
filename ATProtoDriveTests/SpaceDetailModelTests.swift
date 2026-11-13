//
//  SpaceDetailModelTests.swift
//  ATProtoDriveTests
//

import Foundation
@testable import Petrel
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

@Suite("SpaceDetailModel and RepoEntry Tests", .serialized)
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

    // MARK: - makeListWritersURL Tests

    @Test("makeListWritersURL builds correct endpoint URL with space query item")
    func testMakeListWritersURLStandard() throws {
        let spaceHost = URL(string: "https://pds.example.com")!
        let ref = try SpaceRef(uriString: "at://did:plc:alice123/space/com.atproto.feed/main")

        let url = try #require(SpaceDetailModel.makeListWritersURL(spaceHost: spaceHost, space: ref))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "pds.example.com")
        #expect(comps.path == "/xrpc/com.atproto.space.listWriters")
        #expect(comps.queryItems?.contains(URLQueryItem(name: "space", value: "at://did:plc:alice123/space/com.atproto.feed/main")) == true)
        #expect(comps.queryItems?.contains(where: { $0.name == "cursor" }) == false)
    }

    @Test("makeListWritersURL handles trailing slash in host and appends cursor when present")
    func testMakeListWritersURLWithCursorAndTrailingSlash() throws {
        let spaceHost = URL(string: "https://space.swan.place/")!
        let ref = try SpaceRef(uriString: "at://did:plc:alice123/space/com.atproto.simplespace/my-space")

        let url = try #require(SpaceDetailModel.makeListWritersURL(spaceHost: spaceHost, space: ref, cursor: "cursor_page_2"))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/xrpc/com.atproto.space.listWriters")
        #expect(comps.queryItems?.first(where: { $0.name == "space" })?.value == "at://did:plc:alice123/space/com.atproto.simplespace/my-space")
        #expect(comps.queryItems?.first(where: { $0.name == "cursor" })?.value == "cursor_page_2")
    }

    @Test("makeListWritersURL preserves subpaths in space host")
    func testMakeListWritersURLWithSubpath() throws {
        let spaceHost = URL(string: "http://127.0.0.1:8080/custom/prefix")!
        let ref = try SpaceRef(uriString: "at://did:plc:bob456/space/com.example.drive/root")

        let url = try #require(SpaceDetailModel.makeListWritersURL(spaceHost: spaceHost, space: ref))

        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/custom/prefix/xrpc/com.atproto.space.listWriters")
        #expect(comps.queryItems?.first(where: { $0.name == "space" })?.value == "at://did:plc:bob456/space/com.example.drive/root")
    }

    // MARK: - mapWriterEntries Tests

    @Test("mapWriterEntries maps current writers and skips removed repositories")
    func testMapWriterEntries() throws {
        let did = try DID(didString: "did:plc:alice123")
        let removedDID = try DID(didString: "did:plc:removed")
        let rev = try TID(tidString: "3l3vbfz2zsk22")
        let rawData = "sample commit hash".data(using: .utf8)!
        let hash = Bytes(data: rawData)

        let write = ComAtprotoSpaceDefs.RepoWrite(repo: did, repoRev: rev, data: hash, spaceRev: rev)
        let removed = ComAtprotoSpaceDefs.RepoRemoved(repo: removedDID, spaceRev: rev)
        let entries = SpaceDetailModel.mapWriterEntries(from: [
            .comAtprotoSpaceDefsRepoWrite(write),
            .comAtprotoSpaceDefsRepoRemoved(removed),
        ])

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
            statusCode: 400
        )
        let state1 = SpaceDetailModel.classifyError(xrpcError)
        #expect(state1 == .tombstone("SpaceDeleted: The space was deleted by its authority"))

        let genericError = NSError(
            domain: "TestDomain",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Space has been deleted"]
        )
        let state2 = SpaceDetailModel.classifyError(genericError)
        #expect(state2 == .general("Space has been deleted"))
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

    @Test("classifyError identifies token rejected errors")
    func testClassifyErrorTokenRejected() {
        let tokenXRPC = ATProtoXRPCError(
            error: "InvalidDelegationToken",
            message: "Token signature invalid",
            statusCode: 401
        )
        let state1 = SpaceDetailModel.classifyError(tokenXRPC)
        #expect(state1 == .tokenRejected("InvalidDelegationToken: Token signature invalid"))

        let credError = SpaceCredentialError.tokenRejected(
            host: "swan.place",
            error: "InvalidDelegationToken",
            message: nil
        )
        let state2 = SpaceDetailModel.classifyError(credError)
        #expect(state2 == .tokenRejected("swan.place rejected the delegation token as invalid (not an access denial; membership is unaffected)."))

        let credErrorWithEvidence = SpaceCredentialError.tokenRejected(
            host: "swan.place",
            error: "InvalidDelegationToken",
            message: nil,
            evidence: "swanProfile=permissioned-data-0016-2026-07-30"
        )
        let state3 = SpaceDetailModel.classifyError(credErrorWithEvidence)
        #expect(state3 == .tokenRejected("swan.place rejected the delegation token as invalid (not an access denial; membership is unaffected). swan.place reports: swanProfile=permissioned-data-0016-2026-07-30."))
    }

    @Test("classifyError identifies November 12 authorization and transient states")
    func testClassifyErrorAuthorizationAndTransientStates() {
        let authRefusedXRPC = ATProtoXRPCError(
            error: "AccountNotAuthorized",
            message: "Account is not a member",
            statusCode: 403
        )
        let state1 = SpaceDetailModel.classifyError(authRefusedXRPC)
        #expect(state1 == .authorizationRefused("AccountNotAuthorized: Account is not a member"))

        let credError = SpaceCredentialError.authorizationRefused(
            host: "swan.place",
            error: "AccountNotAuthorized",
            message: "Account is not a member"
        )
        let state2 = SpaceDetailModel.classifyError(credError)
        #expect(state2 == .authorizationRefused("You no longer have access to this space (swan.place refused authorization: Account is not a member)"))

        let notFoundOrNotAuthorized = SpaceCredentialError.authorizationRefused(
            host: "swan.place",
            error: "SpaceNotFound",
            message: nil
        )
        guard case .authorizationRefused = SpaceDetailModel.classifyError(notFoundOrNotAuthorized) else {
            Issue.record("Expected SpaceNotFound from the credential exchange to classify as authorizationRefused")
            return
        }

        let suspended = ATProtoXRPCError(error: "RepoTakendown", message: "Authority suspended", statusCode: 400)
        #expect(SpaceDetailModel.classifyError(suspended) == .general("Space suspended: RepoTakendown: Authority suspended"))

        let upstream = ATProtoXRPCError(error: "UpstreamFailure", message: "Managing app unavailable", statusCode: 502)
        #expect(SpaceDetailModel.classifyError(upstream) == .general("Temporary upstream failure: UpstreamFailure: Managing app unavailable"))
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

        let generalCredError = SpaceCredentialError.exchangeFailed(statusCode: 500, message: "Internal Server Error")
        let state2 = SpaceDetailModel.classifyError(generalCredError)
        #expect(state2 == .general("Space credential exchange failed with status 500: Internal Server Error"))
    }
    // MARK: - fetchAllWriters Pagination Tests

    @Test("fetchAllWriters accumulates current writers across pages using cursor")
    func testFetchAllWritersPagination() async throws {
        let did1 = try DID(didString: "did:plc:alice123")
        let did2 = try DID(didString: "did:plc:bob456")
        let rev = try TID(tidString: "3l3vbfz2zsk22")
        let hash = Bytes(data: "hash1".data(using: .utf8)!)

        let page1 = ComAtprotoSpaceListWriters.Output(
            repos: [.comAtprotoSpaceDefsRepoWrite(
                ComAtprotoSpaceDefs.RepoWrite(repo: did1, repoRev: rev, data: hash, spaceRev: rev)
            )],
            cursor: "page_2_cursor"
        )
        let page2 = ComAtprotoSpaceListWriters.Output(
            repos: [.comAtprotoSpaceDefsRepoWrite(
                ComAtprotoSpaceDefs.RepoWrite(repo: did2, repoRev: rev, data: hash, spaceRev: rev)
            )],
            cursor: nil
        )
        let encoder = JSONEncoder()
        let page1Data = try encoder.encode(page1)
        let page2Data = try encoder.encode(page2)

        let tracker = TestCallTracker()

        let result = try await SpaceDetailModel.fetchAllWriters { cursor in
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

    @Test("fetchAllWriters protects against duplicate cursor cycle loops")
    func testFetchAllWritersCycleProtection() async throws {
        let did = try DID(didString: "did:plc:alice123")
        let rev = try TID(tidString: "3l3vbfz2zsk22")
        let hash = Bytes(data: "hash".data(using: .utf8)!)

        let loopingPage = ComAtprotoSpaceListWriters.Output(
            repos: [.comAtprotoSpaceDefsRepoWrite(
                ComAtprotoSpaceDefs.RepoWrite(repo: did, repoRev: rev, data: hash, spaceRev: rev)
            )],
            cursor: "loop_cursor"
        )

        let pageData = try JSONEncoder().encode(loopingPage)
        let tracker = TestCallTracker()

        let result = try await SpaceDetailModel.fetchAllWriters { cursor in
            await tracker.record(cursor: cursor)
            return (200, pageData)
        }

        let callCount = await tracker.count
        #expect(callCount == 2)
        #expect(result.count == 2)
    }

    @Test("fetchAllWriters propagates non-200 XRPC errors")
    func testFetchAllWritersErrorPropagation() async {
        let errorJSON = "{\"error\":\"SpaceNotFound\",\"message\":\"The requested space does not exist\"}".data(using: .utf8)!

        await #expect(throws: ATProtoXRPCError.self) {
            try await SpaceDetailModel.fetchAllWriters { _ in
                return (404, errorJSON)
            }
        }
    }

    // MARK: - fetchAllMembers Pagination Tests

    @Test("fetchAllMembers accumulates across pages using cursor")
    func testFetchAllMembersPagination() async throws {
        let did1 = try DID(didString: "did:plc:member1")
        let did2 = try DID(didString: "did:plc:member2")

        let page1 = ComAtprotoMemberspaceListMembers.Output(
            cursor: "member_cursor_2",
            members: [ComAtprotoMemberspaceDefs.Member(did: did1, read: true, write: true)]
        )
        let page2 = ComAtprotoMemberspaceListMembers.Output(
            cursor: nil,
            members: [ComAtprotoMemberspaceDefs.Member(did: did2, read: true, write: true)]
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
        let loopingPage = ComAtprotoMemberspaceListMembers.Output(
            cursor: "member_loop_cursor",
            members: [ComAtprotoMemberspaceDefs.Member(did: did, read: true, write: true)]
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
            message: "Method com.atproto.memberspace.listMembers not implemented",
            statusCode: 501
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(methodNotImplemented) == true)

        let methodNotFound = ATProtoXRPCError(
            error: "MethodNotFound",
            message: "Method com.atproto.memberspace.listMembers not found",
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

        // A space under a personalspace or managedspace policy answers PolicyMismatch.
        let typedPolicyMismatch = ATProtoError<ComAtprotoMemberspaceListMembers.Error>(
            error: .policyMismatch,
            message: "Space is not governed by the memberspace policy",
            statusCode: 400
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(typedPolicyMismatch) == true)

        let genericPolicyMismatch = ATProtoXRPCError(
            error: "PolicyMismatch",
            message: "Space is not governed by the memberspace policy",
            statusCode: 400
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(genericPolicyMismatch) == true)

        let typedSpaceNotFound = ATProtoError<ComAtprotoMemberspaceListMembers.Error>(
            error: .spaceNotFound,
            message: "Space not found",
            statusCode: 400
        )
        #expect(SpaceDetailModel.isMemberListNotReadableError(typedSpaceNotFound) == false)

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

        // Suppressed: a personalspace or managedspace answers PolicyMismatch; repos still load
        let repo = RepoEntry(did: "did:plc:alice", rev: "rev1", hash: "abc123")
        let policyMismatchResult = try await SpaceDetailModel.loadSpaceDetails(
            space: space,
            fetchRepos: { [repo] },
            fetchMembers: {
                throw ATProtoError<ComAtprotoMemberspaceListMembers.Error>(
                    error: .policyMismatch,
                    message: nil,
                    statusCode: 400
                )
            }
        )
        #expect(policyMismatchResult.members == nil)
        #expect(policyMismatchResult.repos.count == 1)

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

    // MARK: - Production Path Error Classification Tests

    private final class ModelMockURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        static func setHandler(_ newHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
            lock.lock()
            defer { lock.unlock() }
            handler = newHandler
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            ModelMockURLProtocol.lock.lock()
            let currentHandler = ModelMockURLProtocol.handler
            ModelMockURLProtocol.lock.unlock()

            guard let currentHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try currentHandler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private static func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static let swanDIDDocJSON = """
    {
      "@context": ["https://www.w3.org/ns/did/v1"],
      "id": "did:plc:6u6rzv6fk3ga37kgs3tybgdk",
      "verificationMethod": [
        {
          "id": "did:plc:6u6rzv6fk3ga37kgs3tybgdk#atproto",
          "type": "Multikey",
          "controller": "did:plc:6u6rzv6fk3ga37kgs3tybgdk",
          "publicKeyMultibase": "zQ3shb9WV8D4wR8m2C7q8sT2x6b6Z9p"
        }
      ],
      "service": [
        {
          "id": "#atproto_pds",
          "type": "AtprotoPersonalDataServer",
          "serviceEndpoint": "https://swan.place"
        }
      ]
    }
    """

    @MainActor
    @Test("Case 3: Production path handles 400 InvalidDelegationToken: names swan.place, preserves sidebar & persisted state")
    func testProductionPathCase3TokenRejected() async throws {
        URLProtocol.registerClass(ModelMockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(ModelMockURLProtocol.self)
            ModelMockURLProtocol.setHandler(nil)
        }

        let session = Self.makeMockSession()
        let accountDID = "did:plc:user123"
        let authorityDID = "did:plc:6u6rzv6fk3ga37kgs3tybgdk"
        let spaceURI = "at://\(authorityDID)/space/my.bulletin.board/self"

        UserDefaults.standard.removeObject(forKey: SpaceListModel.customSpacesKey(for: accountDID))
        defer {
            UserDefaults.standard.removeObject(forKey: SpaceListModel.customSpacesKey(for: accountDID))
        }

        SpaceListModel.saveCustomSpaceURIs([spaceURI], for: accountDID)

        let client = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client), urlSession: session)
        let credentials = SpaceCredentialManager(
            client: client,
            resolver: resolver,
            urlSession: session,
            delegationTokenProvider: { _ in "mock-delegation-token" }
        )

        let account = AccountStore.Account(
            id: accountDID,
            handle: "user.test",
            client: client,
            credentials: credentials,
            authMode: .cab
        )

        ModelMockURLProtocol.setHandler { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains("plc.directory") || urlString.contains(".well-known/did.json") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(Self.swanDIDDocJSON.utf8))
            }
            if urlString.contains("com.atproto.space.getDelegationToken") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let body = #"{"token":"mock-delegation-token"}"#.data(using: .utf8)!
                return (resp, body)
            }
            if urlString == "https://swan.place/xrpc/com.atproto.space.authorizeSpaceSync" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let body = #"{"error":"InvalidDelegationToken"}"#.data(using: .utf8)!
                return (resp, body)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let spaceItem = try SpaceItem(uriString: spaceURI, accountDID: accountDID)
        let spaceListModel = SpaceListModel()
        await spaceListModel.load(accountDID: accountDID) { _ in (200, ComAtprotoSpaceListSpaces.Output(spaces: [])) }

        // Verify space exists in sidebar before load
        #expect(spaceListModel.spaces.contains(where: { $0.ref.uriString() == spaceURI }))

        let detailModel = SpaceDetailModel()
        // Run the real production load path (no injected fetchRepos closure)
        await detailModel.load(space: spaceItem, account: account, authorityResolver: resolver)

        // Assert the user-visible state
        guard case .tokenRejected(let message) = detailModel.errorState else {
            Issue.record("Expected .tokenRejected errorState, got \(String(describing: detailModel.errorState))")
            return
        }

        // Assert authority host is named in message
        #expect(message.contains("swan.place"))
        #expect(message.contains("rejected the delegation token as invalid (not an access denial; membership is unaffected)"))
        #expect(!message.contains("usually means"))
        #expect(!message.contains("different permissioned-data profile"))
        #expect(detailModel.error == message)
        #expect(detailModel.repos.isEmpty)

        // Assert persisted space state in UserDefaults SURVIVED
        let persistedURIs = SpaceListModel.loadCustomSpaceURIs(for: accountDID)
        #expect(persistedURIs.contains(spaceURI))

        // Assert sidebar entry in SpaceListModel SURVIVED
        await spaceListModel.load(accountDID: accountDID) { _ in (200, ComAtprotoSpaceListSpaces.Output(spaces: [])) }
        #expect(spaceListModel.spaces.contains(where: { $0.ref.uriString() == spaceURI }))
    }
    @MainActor
    @Test("Case 1: Production path handles SpaceDeleted: shows tombstone and removes state on delete")
    func testProductionPathCase1SpaceDeleted() async throws {
        URLProtocol.registerClass(ModelMockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(ModelMockURLProtocol.self)
            ModelMockURLProtocol.setHandler(nil)
        }

        let session = Self.makeMockSession()
        let accountDID = "did:plc:user1"
        let authorityDID = "did:plc:case1deletedauthority"
        let spaceURI = "at://\(authorityDID)/space/my.bulletin.board/self"

        UserDefaults.standard.removeObject(forKey: SpaceListModel.customSpacesKey(for: accountDID))
        defer {
            UserDefaults.standard.removeObject(forKey: SpaceListModel.customSpacesKey(for: accountDID))
        }
        SpaceListModel.saveCustomSpaceURIs([spaceURI], for: accountDID)

        let client = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client), urlSession: session)
        let credentials = SpaceCredentialManager(
            client: client,
            resolver: resolver,
            urlSession: session,
            delegationTokenProvider: { _ in "mock-delegation-token" }
        )

        let account = AccountStore.Account(
            id: accountDID,
            handle: "user.test",
            client: client,
            credentials: credentials,
            authMode: .cab
        )

        let didDoc = """
        {
          "@context": ["https://www.w3.org/ns/did/v1"],
          "id": "\(authorityDID)",
          "verificationMethod": [{ "id": "\(authorityDID)#atproto", "type": "Multikey", "controller": "\(authorityDID)", "publicKeyMultibase": "zQ3shb9WV8D4wR8m2C7q8sT2x6b6Z9p" }],
          "service": [{ "id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://swan.place" }]
        }
        """

        ModelMockURLProtocol.setHandler { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains(authorityDID) || urlString.contains("did:plc") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(didDoc.utf8))
            }
            if urlString == "https://swan.place/xrpc/com.atproto.space.authorizeSpaceSync" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let body = #"{"error":"SpaceDeleted","message":"Space was deleted by owner"}"#.data(using: .utf8)!
                return (resp, body)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let spaceItem = try SpaceItem(uriString: spaceURI, accountDID: accountDID)
        let detailModel = SpaceDetailModel()
        await detailModel.load(space: spaceItem, account: account, authorityResolver: resolver)

        guard case .tombstone(let message) = detailModel.errorState else {
            Issue.record("Expected .tombstone, got \(String(describing: detailModel.errorState))")
            return
        }
        #expect(message.contains("SpaceDeleted"))
        #expect(message.contains("Space was deleted by owner"))

        // Delete space removes it from persistence
        let spaceListModel = SpaceListModel()
        try await spaceListModel.deleteSpace(space: spaceItem, account: account, transport: { _ in 200 })
        let persistedURIs = SpaceListModel.loadCustomSpaceURIs(for: accountDID)
        #expect(!persistedURIs.contains(spaceURI))
    }

    @MainActor
    @Test("Case 2: Production path handles 403 AccountNotAuthorized: shows access denied message")
    func testProductionPathCase2AuthorizationRefused() async throws {
        URLProtocol.registerClass(ModelMockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(ModelMockURLProtocol.self)
            ModelMockURLProtocol.setHandler(nil)
        }

        let session = Self.makeMockSession()
        let accountDID = "did:plc:user2"
        let authorityDID = "did:plc:case2refusedauthority"
        let spaceURI = "at://\(authorityDID)/space/my.bulletin.board/self"

        let client = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client), urlSession: session)
        let credentials = SpaceCredentialManager(
            client: client,
            resolver: resolver,
            urlSession: session,
            delegationTokenProvider: { _ in "mock-delegation-token" }
        )

        let account = AccountStore.Account(
            id: accountDID,
            handle: "user.test",
            client: client,
            credentials: credentials,
            authMode: .cab
        )

        let didDoc = """
        {
          "@context": ["https://www.w3.org/ns/did/v1"],
          "id": "\(authorityDID)",
          "verificationMethod": [{ "id": "\(authorityDID)#atproto", "type": "Multikey", "controller": "\(authorityDID)", "publicKeyMultibase": "zQ3shb9WV8D4wR8m2C7q8sT2x6b6Z9p" }],
          "service": [{ "id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://swan.place" }]
        }
        """

        ModelMockURLProtocol.setHandler { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains(authorityDID) || urlString.contains("did:plc") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(didDoc.utf8))
            }
            if urlString == "https://swan.place/xrpc/com.atproto.space.authorizeSpaceSync" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let body = #"{"error":"AccountNotAuthorized","message":"Account is not a member of this space"}"#.data(using: .utf8)!
                return (resp, body)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let spaceItem = try SpaceItem(uriString: spaceURI, accountDID: accountDID)
        let detailModel = SpaceDetailModel()
        await detailModel.load(space: spaceItem, account: account, authorityResolver: resolver)

        guard case .authorizationRefused(let message) = detailModel.errorState else {
            Issue.record("Expected .authorizationRefused, got \(String(describing: detailModel.errorState))")
            return
        }
        #expect(message.contains("You no longer have access to this space"))
        #expect(message.contains("swan.place refused authorization"))
        #expect(detailModel.error == message)
    }

    @MainActor
    @Test("Case 4: Production path handles opaque 500 error: shows general error with raw text")
    func testProductionPathCase4Opaque500() async throws {
        URLProtocol.registerClass(ModelMockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(ModelMockURLProtocol.self)
            ModelMockURLProtocol.setHandler(nil)
        }

        let session = Self.makeMockSession()
        let accountDID = "did:plc:user4"
        let authorityDID = "did:plc:case4opaqueauthority"
        let spaceURI = "at://\(authorityDID)/space/my.bulletin.board/self"

        let client = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client), urlSession: session)
        let credentials = SpaceCredentialManager(
            client: client,
            resolver: resolver,
            urlSession: session,
            delegationTokenProvider: { _ in "mock-delegation-token" }
        )

        let account = AccountStore.Account(
            id: accountDID,
            handle: "user.test",
            client: client,
            credentials: credentials,
            authMode: .cab
        )

        let didDoc = """
        {
          "@context": ["https://www.w3.org/ns/did/v1"],
          "id": "\(authorityDID)",
          "verificationMethod": [{ "id": "\(authorityDID)#atproto", "type": "Multikey", "controller": "\(authorityDID)", "publicKeyMultibase": "zQ3shb9WV8D4wR8m2C7q8sT2x6b6Z9p" }],
          "service": [{ "id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://swan.place" }]
        }
        """

        ModelMockURLProtocol.setHandler { request in
            let urlString = request.url?.absoluteString ?? ""
            if urlString.contains(authorityDID) || urlString.contains("did:plc") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(didDoc.utf8))
            }
            if urlString == "https://swan.place/xrpc/com.atproto.space.authorizeSpaceSync" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!
                let body = "Internal Server Error Occurred".data(using: .utf8)!
                return (resp, body)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let spaceItem = try SpaceItem(uriString: spaceURI, accountDID: accountDID)
        let detailModel = SpaceDetailModel()
        await detailModel.load(space: spaceItem, account: account, authorityResolver: resolver)

        guard case .general(let message) = detailModel.errorState else {
            Issue.record("Expected .general, got \(String(describing: detailModel.errorState))")
            return
        }
        #expect(message.contains("500"))
        #expect(message.contains("Internal Server Error Occurred"))
        #expect(detailModel.error == message)
    }

}
