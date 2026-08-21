//
//  AccountStore.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel
import SwanSpaces

// MARK: - ClientDIDResolver

final class ClientDIDResolver: DIDResolving, @unchecked Sendable {
    private let client: ATProtoClient

    init(client: ATProtoClient) {
        self.client = client
    }

    func resolveHandleToDID(handle: String) async throws -> String {
        try await client.resolveHandleToDID(handle: handle)
    }

    func resolveDIDToPDSURL(did: String) async throws -> URL {
        try await client.resolveDIDToPDSURL(did: did)
    }

    func resolveDIDToHandleAndPDSURL(did: String) async throws -> (String, URL) {
        let pdsURL = try await client.resolveDIDToPDSURL(did: did)
        return (did, pdsURL)
    }
}

// MARK: - AccountStore

@MainActor
@Observable
public final class AccountStore {
    public enum AuthModeType: String, Codable, Sendable {
        case cab
        case publicOAuth
    }

    public struct Account: Identifiable, Sendable {
        public let id: String          // DID
        public let handle: String
        public let client: ATProtoClient
        public let credentials: SpaceCredentialManager
        public let authMode: AuthModeType

        public init(
            id: String,
            handle: String,
            client: ATProtoClient,
            credentials: SpaceCredentialManager,
            authMode: AuthModeType
        ) {
            self.id = id
            self.handle = handle
            self.client = client
            self.credentials = credentials
            self.authMode = authMode
        }
    }

    struct PersistedAccount: Codable {
        let id: String
        let handle: String
        let authMode: AuthModeType
    }

    private struct PendingLogin: Sendable {
        let client: ATProtoClient
        let did: String
        let requestedHandle: String
        let authMode: AuthModeType
        let stateToken: String
    }

    nonisolated public static let cabClientId = "https://cab.swan.place/oauth-client-metadata.json"
    nonisolated public static let publicClientId = "https://cab.swan.place/public-client-metadata.json"
    nonisolated public static let cabBackendURL = URL(string: "https://cab.swan.place")!
    nonisolated public static let redirectUri = "blue.catbird.atprotodrive:/callback"
    nonisolated public static let scope = "atproto space:*?authority=*&collection=*&manage=create&manage=update&manage=delete"

    private static let userDefaultsKey = "blue.catbird.atprotodrive.accounts"

    public private(set) var accounts: [Account] = []
    public private(set) var spaceModels: [String: SpaceListModel] = [:]

    public func spaceModel(for accountID: String) -> SpaceListModel {
        if let existing = spaceModels[accountID] {
            return existing
        }
        let model = SpaceListModel()
        spaceModels[accountID] = model
        return model
    }

    public var activeAccountID: String?

    public func account(for did: String) -> Account? {
        accounts.first(where: { $0.id == did })
    }
    /// Resolves the specific owning account for a given space item.
    /// If the owning account is not present in `accounts`, returns `nil` (never falls back to another account).
    nonisolated public static func resolveDetailAccount(for space: SpaceItem, in accounts: [Account]) -> Account? {
        accounts.first(where: { $0.id == space.accountDID })
    }


    public var activeAccount: Account? {
        if let activeAccountID, let account = accounts.first(where: { $0.id == activeAccountID }) {
            return account
        }
        return accounts.first
    }
    private var pendingLogins: [String: PendingLogin] = [:]


    public init() {}

    nonisolated public static func namespace(for did: String) -> String {
        "atprotodrive.\(did)"
    }

    private static func resolveDID(for handle: String) async throws -> String {
        if handle.starts(with: "did:") {
            return handle
        }
        let resolverClient = try await ATProtoClient(
            oauthConfig: OAuthConfig(
                clientId: publicClientId,
                redirectUri: redirectUri,
                scope: scope
            ),
            namespace: "atprotodrive.resolver",
            authMode: .publicOAuth
        )
        return try await resolverClient.resolveHandleToDID(handle: handle)
    }


    /// Begin OAuth for a handle; returns the authorization URL to open.
    public func beginLogin(handle: String) async throws -> URL {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let did = try await Self.resolveDID(for: trimmedHandle)
        let ns = Self.namespace(for: did)

        // Attempt 1: CAB OAuth flow
        do {
            let cabClient = try await ATProtoClient(
                oauthConfig: OAuthConfig(
                    clientId: Self.cabClientId,
                    redirectUri: Self.redirectUri,
                    scope: Self.scope
                ),
                namespace: ns,
                authMode: .cab(backendURL: Self.cabBackendURL)
            )

            let (authURL, state) = try await cabClient.startOAuthFlowWithState(identifier: trimmedHandle)
            pendingLogins[state] = PendingLogin(
                client: cabClient,
                did: did,
                requestedHandle: trimmedHandle,
                authMode: .cab,
                stateToken: state
            )
            return authURL
        } catch AuthError.nativeClientNoneAuthRequired {
            // Attempt 2: Public OAuth fallback (triggered ONLY on native/none client-metadata rejection)
            let publicClient = try await ATProtoClient(
                oauthConfig: OAuthConfig(
                    clientId: Self.publicClientId,
                    redirectUri: Self.redirectUri,
                    scope: Self.scope
                ),
                namespace: ns,
                authMode: .publicOAuth
            )

            let (authURL, state) = try await publicClient.startOAuthFlowWithState(identifier: trimmedHandle)
            pendingLogins[state] = PendingLogin(
                client: publicClient,
                did: did,
                requestedHandle: trimmedHandle,
                authMode: .publicOAuth,
                stateToken: state
            )
            return authURL
        }
    }


    /// Complete OAuth from the onOpenURL callback.
    public func handleCallback(_ url: URL) async throws {
        guard let state = extractState(from: url),
              let pending = pendingLogins.removeValue(forKey: state) else {
            throw AuthError.invalidCallbackURL
        }

        try await completeLogin(pending: pending, url: url)
    }

    private func completeLogin(pending: PendingLogin, url: URL) async throws {
        try await pending.client.handleOAuthCallback(url: url)
        let (storedDID, storedHandle, _) = await pending.client.getActiveAccountInfo()
        guard let did = storedDID ?? (pending.did.isEmpty ? nil : pending.did) else {
            throw AuthError.noActiveAccount
        }

        // If authorization server returned a different DID than pre-resolved and keychained, clean up and fail fast
        if !pending.did.isEmpty && did != pending.did {
            try? await pending.client.logout()
            throw AuthError.authorizationFailed
        }

        let resolvedHandle = storedHandle ?? pending.requestedHandle
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: pending.client))
        let credentials = SpaceCredentialManager(client: pending.client, resolver: resolver)

        let account = Account(
            id: did,
            handle: resolvedHandle,
            client: pending.client,
            credentials: credentials,
            authMode: pending.authMode
        )

        accounts.removeAll { $0.id == did }
        accounts.append(account)
        if activeAccountID == nil {
            activeAccountID = did
        }

        savePersistedAccounts()
    }

    /// Restore persisted sessions on launch (namespace per DID: "atprotodrive.<did>").
    public func restore() async {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              let persistedList = try? JSONDecoder().decode([PersistedAccount].self, from: data) else {
            return
        }

        var restored: [Account] = []
        for item in persistedList {
            let ns = Self.namespace(for: item.id)
            let authMode: AuthMode = (item.authMode == .cab)
                ? .cab(backendURL: Self.cabBackendURL)
                : .publicOAuth
            let clientId = (item.authMode == .cab) ? Self.cabClientId : Self.publicClientId

            do {
                let client = try await ATProtoClient(
                    oauthConfig: OAuthConfig(
                        clientId: clientId,
                        redirectUri: Self.redirectUri,
                        scope: Self.scope
                    ),
                    namespace: ns,
                    authMode: authMode
                )
                let (storedDID, storedHandle, _) = await client.getActiveAccountInfo()
                guard let activeDID = storedDID, activeDID == item.id else { continue }

                let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client))
                let credentials = SpaceCredentialManager(client: client, resolver: resolver)

                let account = Account(
                    id: item.id,
                    handle: storedHandle ?? item.handle,
                    client: client,
                    credentials: credentials,
                    authMode: item.authMode
                )
                restored.append(account)
            } catch {
                continue
            }
        }

        accounts = restored
        if activeAccountID == nil || !accounts.contains(where: { $0.id == activeAccountID }) {
            activeAccountID = accounts.first?.id
        }
    }

    public func remove(_ id: String) async {
        if let account = accounts.first(where: { $0.id == id }) {
            try? await account.client.logout()
        }
        accounts.removeAll { $0.id == id }
        spaceModels.removeValue(forKey: id)
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
        UserDefaults.standard.removeObject(forKey: SpaceListModel.customSpacesKey(for: id))
        savePersistedAccounts()
    }

    private func savePersistedAccounts() {
        let list = accounts.map { PersistedAccount(id: $0.id, handle: $0.handle, authMode: $0.authMode) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    private func extractState(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value
    }

#if DEBUG
    var pendingLoginCount: Int {
        pendingLogins.count
    }

    var firstPendingStateToken: String? {
        pendingLogins.keys.first
    }

    func hasPendingLogin(for state: String) -> Bool {
        pendingLogins[state] != nil
    }

    func registerPendingLoginForTesting(
        state: String,
        client: ATProtoClient,
        did: String,
        handle: String,
        authMode: AuthModeType
    ) {
        pendingLogins[state] = PendingLogin(
            client: client,
            did: did,
            requestedHandle: handle,
            authMode: authMode,
            stateToken: state
        )
    }

    func addAccountForTesting(_ account: Account) {
        accounts.append(account)
    }

    func setAccountsForTesting(_ list: [Account]) {
        accounts = list
    }
#endif
}
