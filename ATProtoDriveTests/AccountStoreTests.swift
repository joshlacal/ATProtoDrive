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
    func testOAuthConstants() throws {
        #expect(AccountStore.cabClientId == "https://atprotodrive.catbird.blue/oauth-client-metadata.json")
        #expect(AccountStore.publicClientId == "https://atprotodrive.catbird.blue/public-client-metadata.json")
        #expect(AccountStore.cabBackendURL == URL(string: "https://atprotodrive.catbird.blue")!)
        #expect(AccountStore.redirectUri == "blue.catbird.atprotodrive:/callback")
        #expect(AccountStore.scope == "atproto space:*?authority=*&collection=*&manage=create&manage=update&manage=delete")

        // Private-use URI scheme redirect URI for discoverable client metadata must be the FQDN reversed
        let cabHost = try #require(URL(string: AccountStore.cabClientId)?.host)
        let publicHost = try #require(URL(string: AccountStore.publicClientId)?.host)
        let expectedScheme = cabHost.split(separator: ".").reversed().joined(separator: ".")
        let publicExpectedScheme = publicHost.split(separator: ".").reversed().joined(separator: ".")

        let redirectURL = try #require(URL(string: AccountStore.redirectUri))
        let redirectScheme = try #require(redirectURL.scheme)

        #expect(redirectScheme == expectedScheme)
        #expect(redirectScheme == publicExpectedScheme)
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
    @Test("resolveDetailAccount returns owning account when present, nil (never fallback) when absent")
    func testResolveDetailAccount() async throws {
        let dummyClient = await ATProtoClient(baseURL: URL(string: "https://bsky.social")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: dummyClient))
        let creds = SpaceCredentialManager(client: dummyClient, resolver: resolver)

        let accountAlice = AccountStore.Account(id: "did:plc:alice", handle: "alice.bsky.social", client: dummyClient, credentials: creds, authMode: .cab)
        let accountBob = AccountStore.Account(id: "did:plc:bob", handle: "bob.bsky.social", client: dummyClient, credentials: creds, authMode: .cab)
        let accounts = [accountAlice, accountBob]

        let spaceAlice = SpaceItem(
            ref: try SpaceRef(uriString: "at:space/did:plc:alice/com.atproto.simplespace/my-space"),
            accountDID: "did:plc:alice"
        )
        let spaceBob = SpaceItem(
            ref: try SpaceRef(uriString: "at:space/did:plc:bob/com.atproto.simplespace/shared-space"),
            accountDID: "did:plc:bob"
        )
        let spaceCharlie = SpaceItem(
            ref: try SpaceRef(uriString: "at:space/did:plc:charlie/com.atproto.simplespace/orphaned-space"),
            accountDID: "did:plc:charlie"
        )

        // Owning account present -> returns matching account
        let resolvedAlice = AccountStore.resolveDetailAccount(for: spaceAlice, in: accounts)
        #expect(resolvedAlice?.id == "did:plc:alice")

        let resolvedBob = AccountStore.resolveDetailAccount(for: spaceBob, in: accounts)
        #expect(resolvedBob?.id == "did:plc:bob")

        // Owning account absent -> returns nil (NEVER falls back to first/active account)
        let resolvedCharlie = AccountStore.resolveDetailAccount(for: spaceCharlie, in: accounts)
        #expect(resolvedCharlie == nil)

        let resolvedEmpty = AccountStore.resolveDetailAccount(for: spaceAlice, in: [])
        #expect(resolvedEmpty == nil)
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

    @MainActor
    @Test("Live Spaces alpha consent requires a signed test host and explicit opt-in",
          .enabled(if: ProcessInfo.processInfo.environment["ATPROTODRIVE_RUN_LIVE_OAUTH"] == "1"))
    func testLiveLoginSpacesAlpha() async throws {
        let store = AccountStore()
        let authURL = try await store.beginLogin(handle: "josh.spaces-alpha.bsky.network")
        #expect(authURL.host?.contains("bsky") == true || authURL.host?.contains("spaces-alpha") == true || authURL.host?.contains("swan") == true)
        let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
        let clientIdItem = components?.queryItems?.first(where: { $0.name == "client_id" })
        #expect(clientIdItem?.value == AccountStore.publicClientId || clientIdItem?.value == AccountStore.cabClientId)
    }

    @MainActor
    @Test("restore discards persisted accounts if stored DID mismatches persisted entry")
    func testRestoreValidatesActiveDID() async {
        let userDefaultsKey = "blue.catbird.atprotodrive.accounts"
        let mismatchedAccounts = [
            AccountStore.PersistedAccount(id: "did:plc:alice_persisted", handle: "alice.test", authMode: .publicOAuth)
        ]
        if let data = try? JSONEncoder().encode(mismatchedAccounts) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        defer {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }

        let store = AccountStore()
        await store.restore()

        // Since no actual keychain session exists for did:plc:alice_persisted, client.getActiveAccountInfo() storedDID is nil or mismatch -> accounts is empty
        #expect(store.accounts.isEmpty)
        #expect(store.activeAccountID == nil)
    }
}
