//
//  AccountStoreTests.swift
//  ATProtoDriveTests
//

import Foundation
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
    @Test("AccountStore remove updates accounts and activeAccountID")
    func testRemoveAccount() async {
        let store = AccountStore()
        await store.remove("did:plc:nonexistent")
        #expect(store.accounts.isEmpty)
        #expect(store.activeAccountID == nil)
    }

    @MainActor
    @Test("handleCallback rejects unknown or missing state parameter without affecting state")
    func testHandleCallbackRejectsInvalidState() async {
        let store = AccountStore()

        // Missing state
        let noStateURL = URL(string: "blue.catbird.atprotodrive:/callback?code=testcode")!
        await #expect(throws: Error.self) {
            try await store.handleCallback(noStateURL)
        }

        // Unknown state
        let unknownStateURL = URL(string: "blue.catbird.atprotodrive:/callback?code=testcode&state=nonexistent_state")!
        await #expect(throws: Error.self) {
            try await store.handleCallback(unknownStateURL)
        }

        #expect(store.accounts.isEmpty)
    }
}
