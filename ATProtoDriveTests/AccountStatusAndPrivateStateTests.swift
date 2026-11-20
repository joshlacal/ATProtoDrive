//
//  AccountStatusAndPrivateStateTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import SwiftUI
import Testing
@testable import ATProtoDrive

private let fixtureAliceDID = "did:plc:4hqjfn7m6n5hno3doamuhgef"
private let fixtureBobDID = "did:plc:z72i7hdynmk6r22z27h6tvur"
private let validLegacyP256Multibase = "zNpRHmahHk2CgHtnsGscfUtaihjkpeHYrumpa7jpdhzf5SJUXHQDjE4dyvtDcdjSs3dJ1mNiTw3xLcUXqauy5WNBP"

private func makeTestAccount(
    did: String = fixtureAliceDID,
    handle: String = "alice.spaces-alpha.bsky.network",
    authMode: AccountStore.AuthModeType = .cab
) async -> AccountStore.Account {
    let client = await ATProtoClient(baseURL: URL(string: "https://spaces-alpha.host.bsky.network")!)
    let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client))
    let credentials = SpaceCredentialManager(client: client, resolver: resolver)
    return AccountStore.Account(
        id: did,
        handle: handle,
        client: client,
        credentials: credentials,
        authMode: authMode
    )
}

private func encodeDIDDocument(_ document: DIDDocument) throws -> Data {
    try JSONEncoder().encode(document)
}

// MARK: - Exact-DID Account Diagnostics Tests

@Suite("Account Status & Exact-DID Diagnostics")
struct AccountStatusDiagnosticsTests {
    @MainActor
    @Test("verifies exact DID document with #atproto_pds, #atproto_kem, and #atproto_space_host")
    func exactDIDWithKEMAndSpaceHost() async throws {
        let account = await makeTestAccount(did: fixtureAliceDID, handle: "alice.spaces-alpha.bsky.network", authMode: .cab)

        // Derive a genuine Multikey P-256 multibase string from Petrel's validator
        let legacyDoc = DIDDocument(
            id: fixtureAliceDID,
            verificationMethod: [
                VerificationMethod(
                    id: "#atproto_kem",
                    type: "EcdsaSecp256r1VerificationKey2019",
                    controller: fixtureAliceDID,
                    publicKeyMultibase: validLegacyP256Multibase
                )
            ]
        )
        let kemDIDKey = try SpaceHostResolver.authorKEMKey(from: legacyDoc, expectedDID: fixtureAliceDID)
        let multikeyMultibase = String(kemDIDKey.dropFirst("did:key:".count))

        let fullDocument = DIDDocument(
            id: fixtureAliceDID,
            alsoKnownAs: ["at://alice.spaces-alpha.bsky.network"],
            verificationMethod: [
                VerificationMethod(
                    id: "\(fixtureAliceDID)#atproto_kem",
                    type: "Multikey",
                    controller: fixtureAliceDID,
                    publicKeyMultibase: multikeyMultibase
                )
            ],
            service: [
                Service(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://spaces-alpha.host.bsky.network/"
                ),
                Service(
                    id: "#atproto_space_host",
                    type: "AtprotoSpaceHost",
                    serviceEndpoint: "https://space-host.example:443/"
                )
            ]
        )
        let payload = try encodeDIDDocument(fullDocument)
        let fixedDate = Date(timeIntervalSince1970: 1_762_905_600)

        let model = AccountStatusModel(
            fetchDocument: { url in
                #expect(url.absoluteString == "https://plc.directory/\(fixtureAliceDID)")
                return (200, payload)
            },
            sessionInspector: { inspected in
                #expect(inspected.id == fixtureAliceDID)
                return AccountSessionDiagnosticInfo(
                    activeDID: fixtureAliceDID,
                    activeHandle: "alice.spaces-alpha.bsky.network",
                    activePDSURL: URL(string: "https://spaces-alpha.host.bsky.network")!,
                    grantedScopes: ["atproto", "space:*?authority=*&collection=*&manage=create&manage=update&manage=delete"]
                )
            },
            now: { fixedDate }
        )

        await model.load(account: account)

        let snapshot = try #require(model.snapshot(for: fixtureAliceDID))
        #expect(model.snapshot == snapshot)
        #expect(snapshot.did == fixtureAliceDID)
        #expect(snapshot.handle == "alice.spaces-alpha.bsky.network")
        #expect(snapshot.authMode == .cab)
        #expect(snapshot.resolvedPDSURL == URL(string: "https://spaces-alpha.host.bsky.network")!)
        #expect(snapshot.declaredHandle == "alice.spaces-alpha.bsky.network")
        #expect(snapshot.hasSpaceKEMKey == true)
        #expect(snapshot.hasSpaceHostService == true)
        #expect(snapshot.spaceHostURL == URL(string: "https://space-host.example")!)
        #expect(snapshot.spaceProtocolProfile == "2026-11-12 alpha")
        #expect(snapshot.status == .connected)
        #expect(snapshot.checkedAt == fixedDate)
        #expect(snapshot.diagnosticNote == nil)
        #expect(snapshot.requestedScopes == AccountStatusModel.parseScopes(from: AccountStore.scope))
        #expect(snapshot.grantedScopes.contains("atproto"))
    }

    @MainActor
    @Test("verifies exact DID document without #atproto_kem or #atproto_space_host")
    func exactDIDWithoutKEMOrSpaceHost() async throws {
        let account = await makeTestAccount(did: fixtureAliceDID, handle: "alice.example", authMode: .publicOAuth)
        let pdsOnlyDoc = DIDDocument(
            id: fixtureAliceDID,
            alsoKnownAs: ["at://alice.example"],
            service: [
                Service(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://pds.example"
                )
            ]
        )
        let payload = try encodeDIDDocument(pdsOnlyDoc)

        let model = AccountStatusModel(
            fetchDocument: { _ in (200, payload) },
            sessionInspector: { _ in
                AccountSessionDiagnosticInfo(activeDID: fixtureAliceDID, grantedScopes: [])
            }
        )

        await model.load(account: account)

        let snapshot = try #require(model.snapshot(for: fixtureAliceDID))
        #expect(snapshot.status == .connected)
        #expect(snapshot.authMode == .publicOAuth)
        #expect(snapshot.resolvedPDSURL == URL(string: "https://pds.example")!)
        #expect(snapshot.declaredHandle == "alice.example")
        #expect(snapshot.hasSpaceKEMKey == false)
        #expect(snapshot.hasSpaceHostService == false)
        #expect(snapshot.spaceHostURL == nil)
        #expect(snapshot.grantedScopes.isEmpty)
        #expect(snapshot.diagnosticNote?.contains("#atproto_kem") == true)
    }

    @Test("malformed #atproto_kem and #atproto_space_host fail closed")
    func malformedKEMAndSpaceHostFailClosed() {
        let doc = DIDDocument(
            id: fixtureAliceDID,
            verificationMethod: [
                VerificationMethod(
                    id: "#atproto_kem",
                    type: "EcdsaSecp256r1VerificationKey2019",
                    controller: fixtureBobDID, // Wrong controller
                    publicKeyMultibase: validLegacyP256Multibase
                )
            ],
            service: [
                Service(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://pds.example"
                ),
                Service(
                    id: "#atproto_space_host",
                    type: "AtprotoSpaceHost",
                    serviceEndpoint: "https://space-host.example/non-root-path"
                )
            ]
        )

        let snapshot = AccountStatusModel.evaluateDocument(
            doc,
            expectedDID: fixtureAliceDID,
            handle: "alice.example",
            authMode: .cab,
            requestedScopes: ["atproto"]
        )

        #expect(snapshot.status == .connected)
        #expect(snapshot.resolvedPDSURL == URL(string: "https://pds.example")!)
        #expect(snapshot.hasSpaceKEMKey == false)
        #expect(snapshot.hasSpaceHostService == false)
        #expect(snapshot.spaceHostURL == nil)
        #expect(snapshot.diagnosticNote?.contains("#atproto_space_host") == true)
    }

    @MainActor
    @Test("DID identity mismatch, missing #atproto_pds, HTTP error, and session mismatch surface needsAttention")
    func failureStatesNeedAttention() async throws {
        let account = await makeTestAccount(did: fixtureAliceDID, handle: "alice.example", authMode: .cab)

        // 1. Wrong document DID
        let mismatchedDoc = DIDDocument(
            id: fixtureBobDID,
            service: [
                Service(id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://bob.example")
            ]
        )
        let mismatchPayload = try encodeDIDDocument(mismatchedDoc)
        let mismatchModel = AccountStatusModel(
            fetchDocument: { _ in (200, mismatchPayload) },
            sessionInspector: { _ in AccountSessionDiagnosticInfo(activeDID: fixtureAliceDID) }
        )
        await mismatchModel.load(account: account)
        let mismatchSnapshot = try #require(mismatchModel.snapshot(for: fixtureAliceDID))
        #expect(mismatchSnapshot.status == .needsAttention)
        #expect(mismatchSnapshot.resolvedPDSURL == nil)
        #expect(mismatchSnapshot.hasSpaceKEMKey == false)
        #expect(mismatchSnapshot.diagnosticNote?.contains("identity mismatch") == true)

        // 2. Missing #atproto_pds
        let missingPDSDoc = DIDDocument(id: fixtureAliceDID, service: [])
        let missingPDSPayload = try encodeDIDDocument(missingPDSDoc)
        let missingPDSModel = AccountStatusModel(
            fetchDocument: { _ in (200, missingPDSPayload) },
            sessionInspector: { _ in AccountSessionDiagnosticInfo(activeDID: fixtureAliceDID) }
        )
        await missingPDSModel.load(account: account)
        let missingPDSSnapshot = try #require(missingPDSModel.snapshot(for: fixtureAliceDID))
        #expect(missingPDSSnapshot.status == .needsAttention)
        #expect(missingPDSSnapshot.resolvedPDSURL == nil)

        // 3. HTTP 404 from DID directory
        let httpErrorModel = AccountStatusModel(
            fetchDocument: { _ in (404, Data()) },
            sessionInspector: { _ in AccountSessionDiagnosticInfo(activeDID: fixtureAliceDID) }
        )
        await httpErrorModel.load(account: account)
        let httpErrorSnapshot = try #require(httpErrorModel.snapshot(for: fixtureAliceDID))
        #expect(httpErrorSnapshot.status == .needsAttention)
        #expect(httpErrorSnapshot.diagnosticNote?.contains("404") == true)

        // 4. Session DID mismatch
        let validDoc = DIDDocument(
            id: fixtureAliceDID,
            service: [
                Service(id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://alice.example")
            ]
        )
        let validPayload = try encodeDIDDocument(validDoc)
        let sessionMismatchModel = AccountStatusModel(
            fetchDocument: { _ in (200, validPayload) },
            sessionInspector: { _ in AccountSessionDiagnosticInfo(activeDID: fixtureBobDID) }
        )
        await sessionMismatchModel.load(account: account)
        let sessionMismatchSnapshot = try #require(sessionMismatchModel.snapshot(for: fixtureAliceDID))
        #expect(sessionMismatchSnapshot.status == .needsAttention)
        #expect(sessionMismatchSnapshot.diagnosticNote?.contains(fixtureBobDID) == true)
    }

    @MainActor
    @Test("multi-account status snapshots remain isolated by exact DID")
    func multiAccountSnapshotIsolation() async throws {
        let alice = await makeTestAccount(did: fixtureAliceDID, handle: "alice.example", authMode: .cab)
        let bob = await makeTestAccount(did: fixtureBobDID, handle: "bob.example", authMode: .publicOAuth)

        let aliceData = try encodeDIDDocument(DIDDocument(
            id: fixtureAliceDID,
            service: [Service(id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://alice.example")]
        ))
        let bobData = try encodeDIDDocument(DIDDocument(
            id: fixtureBobDID,
            service: [Service(id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://bob.example")]
        ))

        let model = AccountStatusModel(
            fetchDocument: { url in
                if url.absoluteString.contains(fixtureAliceDID) {
                    return (200, aliceData)
                }
                return (200, bobData)
            },
            sessionInspector: { account in
                AccountSessionDiagnosticInfo(activeDID: account.id)
            }
        )

        await model.load(account: alice)
        await model.load(account: bob)

        #expect(model.snapshot(for: fixtureAliceDID)?.resolvedPDSURL == URL(string: "https://alice.example")!)
        #expect(model.snapshot(for: fixtureBobDID)?.resolvedPDSURL == URL(string: "https://bob.example")!)
        #expect(model.snapshot(for: fixtureAliceDID)?.authMode == .cab)
        #expect(model.snapshot(for: fixtureBobDID)?.authMode == .publicOAuth)
    }

    @Test("parses and summarizes OAuth scopes cleanly")
    func scopeParsingAndSummarization() {
        let parsed = AccountStatusModel.parseScopes(from: AccountStore.scope)
        #expect(parsed == [
            "atproto",
            "space:*?authority=*&collection=*&manage=create&manage=update&manage=delete"
        ])

        let deduped = AccountStatusModel.parseScopes(from: "  atproto   repo:app.bsky.feed.post?action=create\n atproto  blob:image/png ")
        #expect(deduped == [
            "atproto",
            "repo:app.bsky.feed.post?action=create",
            "blob:image/png"
        ])

        #expect(AccountStatusModel.summarizeScope("atproto").category == "Core")
        #expect(AccountStatusModel.summarizeScope("space:*?authority=*&manage=create").category == "Spaces")
        #expect(AccountStatusModel.summarizeScope("repo:app.example.note?action=create").category == "Repository")
        #expect(AccountStatusModel.summarizeScope("blob:image/png").category == "Blobs")
        #expect(AccountStatusModel.summarizeScope("rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23bsky_appview").category == "RPC")
    }
}

// MARK: - Private App State Tests

@Suite("Private App State (Read-Only Bluesky Preferences)")
struct PrivateAppStateTests {
    @Test("projects known preferences and preserves unknown union items verbatim in raw JSON")
    func projectsKnownAndUnknownPreferences() async throws {
        let account = await makeTestAccount(did: fixtureAliceDID, handle: "alice.example")
        let fixtureJSON = """
        [
          {
            "$type": "app.bsky.actor.defs#adultContentPref",
            "enabled": true
          },
          {
            "$type": "app.bsky.actor.defs#contentLabelPref",
            "label": "nsfw",
            "visibility": "warn"
          },
          {
            "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
            "items": [
              {
                "id": "feed-1",
                "type": "timeline",
                "value": "following",
                "pinned": true
              },
              {
                "id": "feed-2",
                "type": "feed",
                "value": "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot",
                "pinned": false
              }
            ]
          },
          {
            "$type": "app.bsky.actor.defs#mutedWordsPref",
            "items": [
              {
                "value": "spoilers",
                "targets": ["content", "tag"]
              }
            ]
          },
          {
            "$type": "app.bsky.actor.defs#threadViewPref",
            "sort": "newest"
          },
          {
            "$type": "app.bsky.actor.defs#interestsPref",
            "tags": ["swift", "atproto"]
          },
          {
            "$type": "app.example.futurePref",
            "experimentalFlag": true,
            "nested": { "version": 2 }
          }
        ]
        """

        let decodedPreferences = try JSONDecoder().decode(
            AppBskyActorDefs.Preferences.self,
            from: Data(fixtureJSON.utf8)
        )
        let output = AppBskyActorGetPreferences.Output(preferences: decodedPreferences)

        let service = PrivateAppStateService(transport: { receivedAccount in
            #expect(receivedAccount.id == fixtureAliceDID)
            return (200, output)
        })

        let result = await service.fetchPreferences(for: account)
        guard case .loaded(let items, let rawJSON) = result else {
            Issue.record("Expected .loaded result, got \(result)")
            return
        }

        #expect(items.count == 7)
        #expect(items[0].title == "Adult Content")
        #expect(items[0].subtitle == "Enabled")

        #expect(items[1].title == "Content Label")
        #expect(items[1].subtitle == "nsfw → warn")

        #expect(items[2].title == "Saved Feeds")
        #expect(items[2].subtitle == "2 feeds (1 pinned)")

        #expect(items[3].title == "Muted Words")
        #expect(items[3].subtitle == "1 muted word")
        #expect(items[3].details.first?.contains("spoilers") == true)

        #expect(items[4].title == "Thread View Preferences")
        #expect(items[4].subtitle == "Sort: newest")

        #expect(items[5].title == "Interests")
        #expect(items[5].details == ["#swift", "#atproto"])

        #expect(items[6].typeIdentifier == "app.example.futurePref")
        #expect(items[6].title == "futurePref")

        // Pretty-printed JSON preserves both known and future unknown entries verbatim
        #expect(rawJSON.contains("app.example.futurePref"))
        #expect(rawJSON.contains("experimentalFlag"))
        #expect(rawJSON.contains("app.bsky.actor.defs#savedFeedsPrefV2"))
    }

    @Test("gracefully reports unsupported for 400, 403, 404, 405, 501, and unsupported XRPC errors without public fallback")
    func gracefulUnsupportedHandling() async {
        let account = await makeTestAccount(did: fixtureAliceDID)

        let statusCodes = [400, 403, 404, 405, 501]
        for code in statusCodes {
            let service = PrivateAppStateService(transport: { _ in (code, nil) })
            let result = await service.fetchPreferences(for: account)
            guard case .unsupported(let reason) = result else {
                Issue.record("Expected .unsupported for HTTP \(code), got \(result)")
                continue
            }
            #expect(!reason.isEmpty)
        }

        let xrpcErrors: [ATProtoXRPCError] = [
            ATProtoXRPCError(error: "MethodNotImplemented", message: "Not implemented on alpha PDS", statusCode: 501),
            ATProtoXRPCError(error: "XRPCNotSupported", message: "No AppView configured", statusCode: 400),
            ATProtoXRPCError(error: "ScopeMissing", message: "Missing required scope for app.bsky.actor.getPreferences", statusCode: 403),
            ATProtoXRPCError(error: "InvalidRequest", message: "Unable to proxy request to AppView", statusCode: 400),
            ATProtoXRPCError(error: "UpstreamFailure", message: "AppView unavailable", statusCode: 502)
        ]

        for error in xrpcErrors {
            let service = PrivateAppStateService(transport: { _ in throw error })
            let result = await service.fetchPreferences(for: account)
            guard case .unsupported(let reason) = result else {
                Issue.record("Expected .unsupported for \(error.error), got \(result)")
                continue
            }
            #expect(!reason.isEmpty)
        }

        let network501 = PrivateAppStateService(transport: { _ in throw NetworkError.responseError(statusCode: 501) })
        if case .unsupported = await network501.fetchPreferences(for: account) {
            // Expected
        } else {
            Issue.record("Expected .unsupported for NetworkError.responseError(501)")
        }
    }

    @Test("genuine auth, transport, 500, and 2xx-nil errors return .failed")
    func genuineFailuresReturnFailed() async {
        let account = await makeTestAccount(did: fixtureAliceDID)

        let failures: [any Error] = [
            ATProtoXRPCError(error: "ExpiredToken", message: "Token has expired", statusCode: 400),
            ATProtoXRPCError(error: "AuthenticationRequired", message: "Invalid bearer token", statusCode: 401),
            ATProtoXRPCError(error: "InternalServerError", message: "Database timeout", statusCode: 500),
            NetworkError.expiredToken,
            URLError(.notConnectedToInternet)
        ]

        for error in failures {
            let service = PrivateAppStateService(transport: { _ in throw error })
            let result = await service.fetchPreferences(for: account)
            guard case .failed(let message) = result else {
                Issue.record("Expected .failed for \(error), got \(result)")
                continue
            }
            #expect(!message.isEmpty)
        }

        // 2xx with nil decoded output violates protocol contract and must fail
        let nilBodyService = PrivateAppStateService(transport: { _ in (200, nil) })
        let nilBodyResult = await nilBodyService.fetchPreferences(for: account)
        guard case .failed = nilBodyResult else {
            Issue.record("Expected .failed for 200 with nil body, got \(nilBodyResult)")
            return
        }
    }

    @MainActor
    @Test("PrivateAppStateModel isolates cached state by exact account DID")
    func privateAppStateModelPerDIDIsolation() async throws {
        let alice = await makeTestAccount(did: fixtureAliceDID, handle: "alice.example")
        let bob = await makeTestAccount(did: fixtureBobDID, handle: "bob.example")

        let alicePrefs = AppBskyActorGetPreferences.Output(
            preferences: AppBskyActorDefs.Preferences(items: [
                .adultContentPref(.init(enabled: false))
            ])
        )

        let service = PrivateAppStateService(transport: { account in
            if account.id == fixtureAliceDID {
                return (200, alicePrefs)
            }
            throw ATProtoXRPCError(error: "XRPCNotSupported", message: "No AppView", statusCode: 501)
        })
        let model = PrivateAppStateModel(service: service)

        await model.load(account: alice)
        await model.load(account: bob)

        guard case .loaded(let aliceItems, _) = model.result(for: fixtureAliceDID) else {
            Issue.record("Expected loaded state for Alice")
            return
        }
        #expect(aliceItems.count == 1)

        guard case .unsupported = model.result(for: fixtureBobDID) else {
            Issue.record("Expected unsupported state for Bob")
            return
        }

        #expect(
            model.accessClassification(for: fixtureAliceDID) == .privateAppState(
                provider: "app.bsky.actor.getPreferences",
                accountDID: fixtureAliceDID
            )
        )
    }
}

// MARK: - ServerAndAccount Two-Action Contract Audit Tests

@Suite("Server & Account Two-Action Invariant")
struct ServerAndAccountControlInvariantTests {
    @Test("AccountControlCatalog and ServerAndAccountView expose strictly reconnect and remove")
    func strictlyTwoAllowedActions() {
        #expect(Set(AccountControlAction.allCases) == [.reconnect, .removeFromApp])
        #expect(AccountControlCatalog.actions.count == 2)
        #expect(AccountControlCatalog.actions.map(\.action) == [.reconnect, .removeFromApp])
        #expect(AccountControlCatalog.actions.map(\.title) == [
            "Reconnect Account",
            "Remove from ATProtoDrive"
        ])
        #expect(ServerAndAccountView.exposedControlActions == [.reconnect, .removeFromApp])

        // Ensure zero prohibited account-management wording exists in catalog titles or subtitles
        let combinedCopy = AccountControlCatalog.actions
            .map { "\($0.title) \($0.subtitle)".lowercased() }
            .joined(separator: " ")
        let prohibitedTerms = [
            "migrate",
            "import repository",
            "change email",
            "change handle",
            "password",
            "deactivate",
            "delete account"
        ]
        for term in prohibitedTerms {
            #expect(!combinedCopy.contains(term), "Prohibited term '\(term)' appeared in AccountControlCatalog")
        }
    }

    @Test("Remove confirmation copy clearly states local-only removal without affecting remote account")
    func removeConfirmationCopyIsLocalOnly() {
        let message = ServerAndAccountView.removeConfirmationMessage(for: "alice.spaces-alpha.bsky.network")
        #expect(message.contains("@alice.spaces-alpha.bsky.network"))
        #expect(message.contains("this Mac"))
        #expect(message.contains("remote account"))
        #expect(message.contains("not affected"))
    }

    @MainActor
    @Test("AccountOverviewView, ServerAndAccountView, and PrivateAppStateView instantiate cleanly")
    func viewsInstantiateCleanly() {
        let overview = AccountOverviewView(accountDID: fixtureAliceDID) { _ in }
        #expect(overview.accountDID == fixtureAliceDID)

        let serverAndAccount = ServerAndAccountView(
            accountDID: fixtureAliceDID,
            onReconnect: { _ in },
            onRemoveAccount: { _ in }
        )
        #expect(serverAndAccount.accountDID == fixtureAliceDID)

        let privateState = PrivateAppStateView(accountDID: fixtureAliceDID)
        #expect(privateState.accountDID == fixtureAliceDID)
    }
}
