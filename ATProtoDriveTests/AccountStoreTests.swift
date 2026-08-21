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
        #expect(AccountStore.redirectUri == "place.swan.cab:/callback")
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
    @Test("Live PAR against swan.place generates valid authorization URL")
    func testBeginLoginSwanPlace() async throws {
        let store = AccountStore()
        let authURL = try await store.beginLogin(handle: "josh.swan.place")
        print("SWAN.PLACE AUTH URL: \(authURL.absoluteString)")
        #expect(authURL.absoluteString.starts(with: "https://swan.place/oauth/authorize"))
        #expect(authURL.query?.contains("request_uri=") == true)
    }

    @MainActor
    @Test("Live PAR against bsky.social falls back to public OAuth and generates valid authorization URL")
    func testBeginLoginBskySocial() async throws {
        let store = AccountStore()
        let authURL = try await store.beginLogin(handle: "jay.bsky.team")
        print("BSKY.SOCIAL AUTH URL: \(authURL.absoluteString)")
        #expect(authURL.absoluteString.starts(with: "https://bsky.social/oauth/authorize"))
        #expect(authURL.query?.contains("request_uri=") == true)
    }
}
