//
//  AccountStoreTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import Testing
@testable import ATProtoDrive

@Suite("AccountStore Tests")
struct AccountStoreTests {
    @Test("Namespace derivation is isolated per DID")
    func testNamespaceDerivation() {
        let did1 = "did:plc:abc"
        let did2 = "did:plc:xyz"

        #expect(AccountStore.namespace(for: did1) == "atprotodrive.did:plc:abc")
        #expect(AccountStore.namespace(for: did2) == "atprotodrive.did:plc:xyz")
        #expect(AccountStore.namespace(for: did1) != AccountStore.namespace(for: did2))
    }

    @Test("OAuth constants match protocol requirements")
    func testOAuthConstants() {
        #expect(AccountStore.cabClientId == "https://cab.swan.place/oauth-client-metadata.json")
        #expect(AccountStore.publicClientId == "https://cab.swan.place/public-client-metadata.json")
        #expect(AccountStore.cabBackendURL == URL(string: "https://cab.swan.place")!)
        #expect(AccountStore.redirectUri == "blue.catbird.atprotodrive:/callback")
        #expect(AccountStore.scope == "atproto space:*?authority=*")
    }

    @MainActor
    @Test("AccountStore initial state")
    func testInitialState() {
        let store = AccountStore()
        #expect(store.accounts.isEmpty)
        #expect(store.activeAccountID == nil)
        #expect(store.activeAccount == nil)
    }
    @MainActor
    @Test("account(for:) resolves the proper account by DID regardless of activeAccountID")
    func testAccountLookupByDID() async {
        let store = AccountStore()
        let dummyClient = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: dummyClient))
        let creds = SpaceCredentialManager(client: dummyClient, resolver: resolver)

        let accountA = AccountStore.Account(id: "did:plc:alice", handle: "alice.bsky.social", client: dummyClient, credentials: creds, authMode: .cab)
        let accountB = AccountStore.Account(id: "did:plc:bob", handle: "bob.bsky.social", client: dummyClient, credentials: creds, authMode: .cab)

        store.setAccountsForTesting([accountA, accountB])
        store.activeAccountID = accountA.id

        #expect(store.activeAccount?.id == "did:plc:alice")
        #expect(store.account(for: "did:plc:bob")?.id == "did:plc:bob")
        #expect(store.account(for: "did:plc:bob")?.handle == "bob.bsky.social")
        #expect(store.account(for: "did:plc:nonexistent") == nil)
    }


    @MainActor
    @Test("AccountStore remove updates accounts and activeAccountID")
    func testRemoveAccount() async {
        let store = AccountStore()
        await store.remove("did:plc:nonexistent")
        #expect(store.accounts.isEmpty)
        #expect(store.activeAccountID == nil)
    }

    @MainActor
    @Test("handleCallback rejects unknown or missing state parameter while preserving legitimate pending entries")
    func testHandleCallbackPreservesPendingLoginsOnInvalidState() async throws {
        let store = AccountStore()
        let dummyClient = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let legitimateState = "legitimate_state_token_123"

        // Arrange: Register a legitimate pending login flow
        store.registerPendingLoginForTesting(
            state: legitimateState,
            client: dummyClient,
            did: "did:plc:testuser",
            handle: "testuser.bsky.social",
            authMode: .cab
        )

        #expect(store.pendingLoginCount == 1)
        #expect(store.hasPendingLogin(for: legitimateState))

        // Act & Assert 1: Missing state parameter in callback
        let noStateURL = URL(string: "blue.catbird.atprotodrive:/callback?code=testcode")!
        await #expect(throws: Error.self) {
            try await store.handleCallback(noStateURL)
        }
        #expect(store.hasPendingLogin(for: legitimateState))
        #expect(store.pendingLoginCount == 1)

        // Act & Assert 2: Unknown / mismatched state parameter in callback
        let unknownStateURL = URL(string: "blue.catbird.atprotodrive:/callback?code=testcode&state=unknown_unrelated_state")!
        await #expect(throws: Error.self) {
            try await store.handleCallback(unknownStateURL)
        }
        #expect(store.hasPendingLogin(for: legitimateState))
        #expect(store.pendingLoginCount == 1)

        #expect(store.accounts.isEmpty)
    }
}
