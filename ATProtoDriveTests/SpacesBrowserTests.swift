//
//  SpacesBrowserTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("Spaces Browser and Nov 12 Policy Tests")
struct SpacesBrowserTests {
    private func makeTestAccount(
        id: String = "did:plc:alice123",
        handle: String = "alice.test"
    ) async -> AccountStore.Account {
        let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client))
        let creds = SpaceCredentialManager(client: client, resolver: resolver)
        return AccountStore.Account(id: id, handle: handle, client: client, credentials: creds, authMode: .cab)
    }

    @Test("fetchAllSpaces captures repoRev, data hash, spaceRev, and ownRepoEntry")
    func testFetchAllSpacesCapturesMetadata() async throws {
        let ref = try SpaceRef(uriString: "at://did:plc:alice123/space/space.swan.drive/main")
        let repoRev = try TID(tidString: "3l3vbfz2zsk22")
        let spaceRev = try TID(tidString: "3l3vbfz2zsk77")
        let rawHash = Data("commit-digest".utf8)

        let output = ComAtprotoSpaceListSpaces.Output(
            cursor: nil,
            spaces: [
                ComAtprotoSpaceListSpaces.SpaceView(
                    space: ref,
                    repoRev: repoRev,
                    data: Bytes(data: rawHash),
                    spaceRev: spaceRev
                )
            ]
        )

        let items = try await SpaceListModel.fetchAllSpaces(accountDID: "did:plc:alice123") { _ in
            (200, output)
        }

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.repoRev == "3l3vbfz2zsk22")
        #expect(item.repoDataHash == rawHash.base64EncodedString())
        #expect(item.spaceRev == "3l3vbfz2zsk77")

        let ownRepo = try #require(item.ownRepoEntry)
        #expect(ownRepo.did == "did:plc:alice123")
        #expect(ownRepo.rev == "3l3vbfz2zsk22")
        #expect(ownRepo.hash == rawHash.base64EncodedString())
    }

    @MainActor
    @Test("removeCustomSpace removes saved reference only for the target account")
    func testRemoveCustomSpaceAccountIsolation() throws {
        let suiteName = "SpacesBrowserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let uri = "at://did:plc:owner/space/space.swan.drive/shared"
        let itemA = try SpaceItem(uriString: uri, accountDID: "did:plc:alice")
        SpaceListModel.saveCustomSpaceURIs([uri], for: "did:plc:alice", userDefaults: defaults)
        SpaceListModel.saveCustomSpaceURIs([uri], for: "did:plc:bob", userDefaults: defaults)

        let model = SpaceListModel(spaces: [itemA])
        #expect(model.isCustomSpace(itemA, accountDID: "did:plc:alice", userDefaults: defaults) == true)

        model.removeCustomSpace(itemA, accountDID: "did:plc:alice", userDefaults: defaults)

        #expect(model.spaces.isEmpty)
        #expect(SpaceListModel.loadCustomSpaceURIs(for: "did:plc:alice", userDefaults: defaults).isEmpty)
        #expect(SpaceListModel.loadCustomSpaceURIs(for: "did:plc:bob", userDefaults: defaults) == [uri])
    }

    @Test("makeCreateSpaceInput encodes personal policy as com.atproto.personalspace.policy")
    func testCreatePersonalSpaceInput() throws {
        let input = try SpaceDetailModel.makeCreateSpaceInput(
            spaceType: "space.swan.notes",
            skey: "journal",
            policy: .personal
        )

        #expect(input.spaceType.description == "space.swan.notes")
        #expect(input.skey?.description == "journal")
        guard case .comAtprotoPersonalspacePolicy = input.policy else {
            Issue.record("Expected personalspace policy")
            return
        }

        let data = try JSONEncoder().encode(input)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let policy = try #require(object["policy"] as? [String: Any])
        #expect(policy["$type"] as? String == "com.atproto.personalspace.policy")
    }

    @Test("summarizePolicy projects personal, memberList, and managed policies")
    func testSummarizePolicy() throws {
        #expect(
            SpaceDetailModel.summarizePolicy(.comAtprotoPersonalspacePolicy(.init())) == .personal
        )

        let appURI = try URI(uriString: "https://catbird.blue/oauth-client-metadata.json")
        let memberSummary = SpaceDetailModel.summarizePolicy(
            .comAtprotoMemberspacePolicy(
                ComAtprotoMemberspacePolicy(
                    publicRead: true,
                    publicWrite: false,
                    allowedApps: [appURI],
                    publishPolicy: true,
                    publishMembers: false
                )
            )
        )
        #expect(
            memberSummary == .memberList(
                publicRead: true,
                publicWrite: false,
                allowedApps: ["https://catbird.blue/oauth-client-metadata.json"],
                publishPolicy: true,
                publishMembers: false
            )
        )
        #expect(memberSummary.title == "Member Space (Public Read)")

        let managedSummary = SpaceDetailModel.summarizePolicy(
            .comAtprotoManagedspacePolicy(
                ComAtprotoManagedspacePolicy(managingApp: "did:web:chat.catbird.blue#atproto_chat", publishPolicy: true)
            )
        )
        #expect(
            managedSummary == .managed(
                managingApp: "did:web:chat.catbird.blue#atproto_chat",
                publishPolicy: true
            )
        )
    }

    @MainActor
    @Test("SpaceDetailModel.load populates policySummary and memberEntries, and preserves policy when writers fail")
    func testLoadPopulatesPolicyAndMemberEntries() async throws {
        let account = await makeTestAccount(id: "did:plc:alice123")
        let space = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123",
            repoRev: "3l3vbfz2zsk22"
        )
        let bobDID = try DID(didString: "did:plc:bob456")
        let appURI = try URI(uriString: "https://catbird.blue/oauth-client-metadata.json")

        let model = SpaceDetailModel()
        await model.load(
            space: space,
            account: account,
            fetchRepos: {
                [RepoEntry(did: "did:plc:alice123", rev: "3l3vbfz2zsk22", hash: "YWJj")]
            },
            listMembersTransport: { _ in
                (
                    200,
                    ComAtprotoMemberspaceListMembers.Output(
                        cursor: nil,
                        members: [ComAtprotoMemberspaceDefs.Member(did: bobDID, read: true, write: false)]
                    )
                )
            },
            getSpaceTransport: {
                (
                    200,
                    ComAtprotoSpaceGetSpace.Output(
                        space: space.ref,
                        policy: .comAtprotoMemberspacePolicy(
                            ComAtprotoMemberspacePolicy(publicRead: false, publicWrite: false, allowedApps: [appURI])
                        )
                    )
                )
            }
        )

        #expect(model.error == nil)
        #expect(model.policySummary?.allowedApps == ["https://catbird.blue/oauth-client-metadata.json"])
        #expect(model.members == ["did:plc:bob456"])
        #expect(model.memberEntries == [SpaceMemberEntry(did: "did:plc:bob456", read: true, write: false)])

        // Even when credential-based writer listing is refused (e.g. AppNotAuthorized),
        // policySummary from own getSpace is still preserved for diagnostics.
        await model.load(
            space: space,
            account: account,
            fetchRepos: {
                throw SpaceCredentialError.authorizationRefused(
                    host: "spaces-alpha.host.bsky.network",
                    error: "AppNotAuthorized",
                    message: "Client not in allowedApps"
                )
            },
            listMembersTransport: { _ in (200, ComAtprotoMemberspaceListMembers.Output(cursor: nil, members: [])) },
            getSpaceTransport: {
                (
                    200,
                    ComAtprotoSpaceGetSpace.Output(
                        space: space.ref,
                        policy: .comAtprotoMemberspacePolicy(
                            ComAtprotoMemberspacePolicy(allowedApps: [appURI])
                        )
                    )
                )
            }
        )

        if case .authorizationRefused = model.errorState {
            // Expected
        } else {
            Issue.record("Expected authorizationRefused errorState")
        }
        #expect(model.policySummary?.allowedApps == ["https://catbird.blue/oauth-client-metadata.json"])
        #expect(model.repos.isEmpty)
    }

    @Test("classifyError recognizes Petrel 2.0 typed ATProtoError suspension states")
    func testClassifyTypedATProtoErrors() {
        let takenDown = ATProtoError<ComAtprotoSpaceListWriters.Error>(
            error: .repoTakendown,
            message: "Account taken down",
            statusCode: 400
        )
        let state = SpaceDetailModel.classifyError(takenDown)
        #expect(state == .general("Space suspended: RepoTakendown: Account taken down"))
    }

    @Test("SpacesBrowserView.filterSpaces matches skey, spaceType, authority, and URI")
    func testFilterSpaces() throws {
        let s1 = try SpaceItem(uriString: "at://did:plc:alice/space/blue.catbird.circle/friends", accountDID: "did:plc:alice")
        let s2 = try SpaceItem(uriString: "at://did:plc:bob/space/space.swan.drive/work-docs", accountDID: "did:plc:alice")

        #expect(SpacesBrowserView.filterSpaces([s1, s2], query: "").count == 2)
        #expect(SpacesBrowserView.filterSpaces([s1, s2], query: "FRIENDS") == [s1])
        #expect(SpacesBrowserView.filterSpaces([s1, s2], query: "swan.drive") == [s2])
        #expect(SpacesBrowserView.filterSpaces([s1, s2], query: "did:plc:bob") == [s2])
        #expect(SpacesBrowserView.filterSpaces([s1, s2], query: "nomatch").isEmpty)
    }

    @MainActor
    @Test("SpaceDetailModel.load ignores CancellationError without surfacing a UI error")
    func testLoadIgnoresCancellationError() async throws {
        let account = await makeTestAccount(id: "did:plc:alice123")
        let space = try SpaceItem(
            uriString: "at://did:plc:alice123/space/space.swan.drive/self",
            accountDID: "did:plc:alice123"
        )
        let model = SpaceDetailModel()
        await model.load(
            space: space,
            account: account,
            fetchRepos: { throw CancellationError() },
            listMembersTransport: { _ in (200, ComAtprotoMemberspaceListMembers.Output(cursor: nil, members: [])) }
        )

        #expect(model.error == nil)
        #expect(model.errorState == nil)
        #expect(!model.isLoading)
    }

    @MainActor
    @Test("SpaceDetailModel.load skips listMembers when getSpace reports a managed or personal policy")
    func testLoadSkipsListMembersForNonMemberPolicies() async throws {
        let account = await makeTestAccount(id: "did:plc:alice123")
        let space = try SpaceItem(
            uriString: "at://did:plc:alice123/space/at.secretsky.connections/self",
            accountDID: "did:plc:alice123"
        )

        actor CallFlag {
            var called = false
            func mark() { called = true }
        }
        let flag = CallFlag()

        let model = SpaceDetailModel()
        await model.load(
            space: space,
            account: account,
            fetchRepos: { [RepoEntry(did: "did:plc:alice123", rev: "3l3vbfz2zsk22", hash: "YWJj")] },
            listMembersTransport: { _ in
                await flag.mark()
                return (400, nil)
            },
            getSpaceTransport: {
                (
                    200,
                    ComAtprotoSpaceGetSpace.Output(
                        space: space.ref,
                        policy: .comAtprotoManagedspacePolicy(
                            ComAtprotoManagedspacePolicy(managingApp: "did:web:secretsky.app", publishPolicy: false)
                        )
                    )
                )
            }
        )

        #expect(model.error == nil)
        #expect(model.policySummary == .managed(managingApp: "did:web:secretsky.app", publishPolicy: false))
        #expect(model.members == nil)
        #expect(await flag.called == false)
    }
}
