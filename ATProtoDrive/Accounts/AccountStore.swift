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
        let requestedHandle: String
        let authMode: AuthModeType
        let stateToken: String
        let namespace: String
    }

    nonisolated public static let cabClientId = "https://cab.swan.place/oauth-client-metadata.json"
    nonisolated public static let publicClientId = "https://cab.swan.place/public-client-metadata.json"
    nonisolated public static let cabBackendURL = URL(string: "https://cab.swan.place")!
    nonisolated public static let redirectUri = "place.swan.cab:/callback"
    nonisolated public static let scope = "atproto space:*?authority=*"

    private static let userDefaultsKey = "blue.catbird.atprotodrive.accounts"

    public private(set) var accounts: [Account] = []
    public var activeAccountID: String?

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

    private static func resolveDID(for handle: String) async -> String? {
        if handle.starts(with: "did:") {
            return handle
        }
        do {
            let tempClient = try await ATProtoClient(
                oauthConfig: OAuthConfig(
                    clientId: publicClientId,
                    redirectUri: redirectUri,
                    scope: scope
                ),
                namespace: "atprotodrive.resolver",
                authMode: .publicOAuth
            )
            return try await tempClient.resolveHandleToDID(handle: handle)
        } catch {
            return nil
        }
    }

    /// Begin OAuth for a handle; returns the authorization URL to open.
    public func beginLogin(handle: String) async throws -> URL {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDID = await Self.resolveDID(for: trimmedHandle)
        let ns = resolvedDID.map { Self.namespace(for: $0) } ?? "atprotodrive.login.\(UUID().uuidString)"

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

            let authURL = try await cabClient.startOAuthFlow(identifier: trimmedHandle)
            if let state = extractState(from: authURL) {
                pendingLogins[state] = PendingLogin(
                    client: cabClient,
                    requestedHandle: trimmedHandle,
                    authMode: .cab,
                    stateToken: state,
                    namespace: ns
                )
            }
            return authURL
        } catch {
            // Attempt 2: Public OAuth fallback (for Bluesky-lineage PDSes rejecting private_key_jwt)
            let publicClient = try await ATProtoClient(
                oauthConfig: OAuthConfig(
                    clientId: Self.publicClientId,
                    redirectUri: Self.redirectUri,
                    scope: Self.scope
                ),
                namespace: ns,
                authMode: .publicOAuth
            )

            let authURL = try await publicClient.startOAuthFlow(identifier: trimmedHandle)
            if let state = extractState(from: authURL) {
                pendingLogins[state] = PendingLogin(
                    client: publicClient,
                    requestedHandle: trimmedHandle,
                    authMode: .publicOAuth,
                    stateToken: state,
                    namespace: ns
                )
            }
            return authURL
        }
    }

    /// Complete OAuth from the onOpenURL callback.
    public func handleCallback(_ url: URL) async throws {
        guard let state = extractState(from: url),
              let pending = pendingLogins.removeValue(forKey: state) else {
            // If state wasn't keyed, try any single pending login as fallback
            if pendingLogins.count == 1, let (firstState, pending) = pendingLogins.first {
                pendingLogins.removeValue(forKey: firstState)
                try await completeLogin(pending: pending, url: url)
                return
            }
            throw AuthError.invalidCallbackURL
        }

        try await completeLogin(pending: pending, url: url)
    }

    private func completeLogin(pending: PendingLogin, url: URL) async throws {
        try await pending.client.handleOAuthCallback(url: url)
        let (storedDID, storedHandle, _) = await pending.client.getActiveAccountInfo()
        guard let did = storedDID else {
            throw AuthError.noActiveAccount
        }

        let resolvedHandle = storedHandle ?? pending.requestedHandle
        let correctNamespace = Self.namespace(for: did)

        let finalClient: ATProtoClient
        if pending.namespace == correctNamespace {
            finalClient = pending.client
        } else {
            // Re-instantiate client with DID-isolated namespace if temporary login namespace was used
            let authMode: AuthMode = (pending.authMode == .cab)
                ? .cab(backendURL: Self.cabBackendURL)
                : .publicOAuth
            let clientId = (pending.authMode == .cab) ? Self.cabClientId : Self.publicClientId

            finalClient = try await ATProtoClient(
                oauthConfig: OAuthConfig(
                    clientId: clientId,
                    redirectUri: Self.redirectUri,
                    scope: Self.scope
                ),
                namespace: correctNamespace,
                authMode: authMode
            )
        }

        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: finalClient))
        let credentials = SpaceCredentialManager(client: finalClient, resolver: resolver)

        let account = Account(
            id: did,
            handle: resolvedHandle,
            client: finalClient,
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
                guard storedDID != nil else { continue }

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
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
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
}
