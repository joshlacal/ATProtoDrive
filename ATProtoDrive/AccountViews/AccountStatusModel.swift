//
//  AccountStatusModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

// MARK: - Connection Status

public enum AccountConnectionStatus: String, Hashable, Sendable {
    case connected
    case reconnecting
    case needsAttention
    case disconnected

    public var displayTitle: String {
        switch self {
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting…"
        case .needsAttention:
            return "Needs Attention"
        case .disconnected:
            return "Disconnected"
        }
    }

    public var symbolName: String {
        switch self {
        case .connected:
            return "checkmark.circle.fill"
        case .reconnecting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "xmark.circle.fill"
        }
    }
}

// MARK: - Closed Two-Action Account Control Catalog

public enum AccountControlAction: String, CaseIterable, Hashable, Sendable {
    case reconnect
    case removeFromApp
}

public enum AccountControlRole: String, Hashable, Sendable {
    case standard
    case destructive
}

public struct AccountControlDescriptor: Identifiable, Hashable, Sendable {
    public let action: AccountControlAction
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let role: AccountControlRole

    public var id: AccountControlAction { action }

    public init(
        action: AccountControlAction,
        title: String,
        subtitle: String,
        systemImage: String,
        role: AccountControlRole
    ) {
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.role = role
    }
}

/// Strictly closed catalog of the ONLY two account controls exposed in ATProtoDrive.
public enum AccountControlCatalog {
    public static let actions: [AccountControlDescriptor] = [
        AccountControlDescriptor(
            action: .reconnect,
            title: "Reconnect Account",
            subtitle: "Re-authenticate this exact account via OAuth without affecting other connected accounts.",
            systemImage: "arrow.triangle.2.circlepath",
            role: .standard
        ),
        AccountControlDescriptor(
            action: .removeFromApp,
            title: "Remove from ATProtoDrive",
            subtitle: "Remove local credentials and caches from this Mac. Your remote server account and data remain untouched.",
            systemImage: "minus.circle",
            role: .destructive
        )
    ]
}

// MARK: - Scope Summary

public struct ScopeSummaryItem: Identifiable, Hashable, Sendable {
    public var id: String { rawScope }
    public let rawScope: String
    public let category: String
    public let detail: String

    public init(rawScope: String, category: String, detail: String) {
        self.rawScope = rawScope
        self.category = category
        self.detail = detail
    }
}

// MARK: - Diagnostics Snapshot

public struct AccountDiagnosticsSnapshot: Hashable, Sendable {
    public static let currentSpaceProtocolProfile = "2026-11-12 alpha"
    public static let currentSpaceProtocolDisplayName = "November 12, 2026"

    public let did: String
    public let handle: String
    public let authMode: AccountStore.AuthModeType
    public let resolvedPDSURL: URL?
    public let declaredHandle: String?
    public let hasSpaceKEMKey: Bool
    public let hasSpaceHostService: Bool
    public let spaceHostURL: URL?
    public let requestedScopes: [String]
    public let grantedScopes: [String]
    public let spaceProtocolProfile: String
    public let status: AccountConnectionStatus
    public let checkedAt: Date
    public let diagnosticNote: String?

    public init(
        did: String,
        handle: String,
        authMode: AccountStore.AuthModeType,
        resolvedPDSURL: URL?,
        declaredHandle: String?,
        hasSpaceKEMKey: Bool,
        hasSpaceHostService: Bool,
        spaceHostURL: URL?,
        requestedScopes: [String],
        grantedScopes: [String] = [],
        spaceProtocolProfile: String = AccountDiagnosticsSnapshot.currentSpaceProtocolProfile,
        status: AccountConnectionStatus,
        checkedAt: Date = Date(),
        diagnosticNote: String? = nil
    ) {
        self.did = did
        self.handle = handle
        self.authMode = authMode
        self.resolvedPDSURL = resolvedPDSURL
        self.declaredHandle = declaredHandle
        self.hasSpaceKEMKey = hasSpaceKEMKey
        self.hasSpaceHostService = hasSpaceHostService
        self.spaceHostURL = spaceHostURL
        self.requestedScopes = requestedScopes
        self.grantedScopes = grantedScopes
        self.spaceProtocolProfile = spaceProtocolProfile
        self.status = status
        self.checkedAt = checkedAt
        self.diagnosticNote = diagnosticNote
    }

    public var hasValidPDSService: Bool {
        resolvedPDSURL != nil
    }

    public var authModeDisplayTitle: String {
        switch authMode {
        case .cab:
            return "CAB Confidential"
        case .publicOAuth:
            return "Public OAuth"
        }
    }

    public var authModeDescription: String {
        switch authMode {
        case .cab:
            return "Client Assertion Backend (DPoP-bound confidential OAuth client)"
        case .publicOAuth:
            return "Native public OAuth client (PAR, PKCE, and DPoP)"
        }
    }
}

// MARK: - Session Inspector Seam

public struct AccountSessionDiagnosticInfo: Hashable, Sendable {
    public let activeDID: String?
    public let activeHandle: String?
    public let activePDSURL: URL?
    public let grantedScopes: Set<String>

    public init(
        activeDID: String? = nil,
        activeHandle: String? = nil,
        activePDSURL: URL? = nil,
        grantedScopes: Set<String> = []
    ) {
        self.activeDID = activeDID
        self.activeHandle = activeHandle
        self.activePDSURL = activePDSURL
        self.grantedScopes = grantedScopes
    }
}

public typealias AccountSessionInspector = @Sendable (AccountStore.Account) async -> AccountSessionDiagnosticInfo

// MARK: - AccountStatusModel

@MainActor
@Observable
public final class AccountStatusModel {
    public private(set) var snapshotsByDID: [String: AccountDiagnosticsSnapshot] = [:]
    public private(set) var currentAccountDID: String?
    public private(set) var loadingDIDs: Set<String> = []
    public private(set) var errorByDID: [String: String] = [:]

    private let fetchDocument: DIDDocumentFetch
    private let sessionInspector: AccountSessionInspector
    private let allowLocalhostDevelopment: Bool
    private let now: @Sendable () -> Date
    private var generationByDID: [String: Int] = [:]

    public var snapshot: AccountDiagnosticsSnapshot? {
        guard let currentAccountDID else { return nil }
        return snapshotsByDID[currentAccountDID]
    }

    public var isLoading: Bool {
        if let currentAccountDID {
            return loadingDIDs.contains(currentAccountDID)
        }
        return !loadingDIDs.isEmpty
    }

    public var errorMessage: String? {
        guard let currentAccountDID else { return nil }
        return errorByDID[currentAccountDID]
    }

    public func snapshot(for did: String) -> AccountDiagnosticsSnapshot? {
        snapshotsByDID[did]
    }

    public func isLoading(for did: String) -> Bool {
        loadingDIDs.contains(did)
    }

    public func errorMessage(for did: String) -> String? {
        errorByDID[did]
    }

    public init(
        fetchDocument: DIDDocumentFetch? = nil,
        sessionInspector: AccountSessionInspector? = nil,
        allowLocalhostDevelopment: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.allowLocalhostDevelopment = allowLocalhostDevelopment
        self.fetchDocument = fetchDocument ?? DIDDocumentPDSResolver.makeLiveFetch(
            allowLocalhostDevelopment: allowLocalhostDevelopment
        )
        self.sessionInspector = sessionInspector ?? Self.liveSessionInspector
        self.now = now
    }

    nonisolated public static let liveSessionInspector: AccountSessionInspector = { account in
        let info = await account.client.getActiveAccountInfo()
        let grantedScopes = await account.client.getGrantedScopes(for: account.id)
        return AccountSessionDiagnosticInfo(
            activeDID: info.did,
            activeHandle: info.handle,
            activePDSURL: info.pdsURL,
            grantedScopes: grantedScopes
        )
    }

    // MARK: - Loading Exact-DID Diagnostics

    public func load(account: AccountStore.Account) async {
        let did = account.id
        currentAccountDID = did

        let nextGeneration = (generationByDID[did] ?? 0) &+ 1
        generationByDID[did] = nextGeneration
        loadingDIDs.insert(did)
        errorByDID.removeValue(forKey: did)

        defer {
            if generationByDID[did] == nextGeneration {
                loadingDIDs.remove(did)
            }
        }

        let requestedScopes = Self.parseScopes(from: AccountStore.scope)
        let sessionInfo = await sessionInspector(account)
        guard !Task.isCancelled, generationByDID[did] == nextGeneration else { return }

        let grantedScopes = sessionInfo.grantedScopes.sorted()
        let effectiveHandle = !account.handle.isEmpty
            ? account.handle
            : (sessionInfo.activeHandle ?? "")

        let sessionMismatchNote: String?
        if let activeDID = sessionInfo.activeDID, activeDID != did {
            sessionMismatchNote = "Active client session DID (\(activeDID)) does not match expected account DID (\(did)). Reconnect this account."
        } else {
            sessionMismatchNote = nil
        }

        do {
            let documentURL = try DIDDocumentPDSResolver.documentURL(
                for: did,
                allowLocalhostDevelopment: allowLocalhostDevelopment
            )
            let (statusCode, data) = try await fetchDocument(documentURL)
            guard !Task.isCancelled, generationByDID[did] == nextGeneration else { return }

            guard (200 ... 299).contains(statusCode) else {
                throw BrowserFailure.http(endpoint: documentURL.absoluteString, statusCode: statusCode)
            }
            guard let data, !data.isEmpty else {
                throw BrowserFailure.decodeFailure(endpoint: documentURL.absoluteString, statusCode: statusCode)
            }

            let document: DIDDocument
            do {
                document = try JSONDecoder().decode(DIDDocument.self, from: data)
            } catch {
                throw BrowserFailure.decodeFailure(endpoint: documentURL.absoluteString, statusCode: statusCode)
            }

            let evaluated = Self.evaluateDocument(
                document,
                expectedDID: did,
                handle: effectiveHandle,
                authMode: account.authMode,
                requestedScopes: requestedScopes,
                grantedScopes: grantedScopes,
                sessionMismatchNote: sessionMismatchNote,
                allowLocalhostDevelopment: allowLocalhostDevelopment,
                checkedAt: now()
            )

            snapshotsByDID[did] = evaluated
            if evaluated.status == .needsAttention {
                errorByDID[did] = evaluated.diagnosticNote
            } else {
                errorByDID.removeValue(forKey: did)
            }
        } catch is CancellationError {
            return
        } catch {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled || generationByDID[did] != nextGeneration {
                return
            }

            let failure = BrowserFailure.normalize(error)
            let note = [sessionMismatchNote, failure.errorDescription ?? error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: " ")

            let fallbackPDS = sessionInfo.activePDSURL.flatMap {
                try? DIDDocumentPDSResolver.canonicalPDSOrigin(
                    from: $0,
                    allowLocalhostDevelopment: allowLocalhostDevelopment
                )
            }

            snapshotsByDID[did] = AccountDiagnosticsSnapshot(
                did: did,
                handle: effectiveHandle,
                authMode: account.authMode,
                resolvedPDSURL: fallbackPDS,
                declaredHandle: nil,
                hasSpaceKEMKey: false,
                hasSpaceHostService: false,
                spaceHostURL: nil,
                requestedScopes: requestedScopes,
                grantedScopes: grantedScopes,
                spaceProtocolProfile: AccountDiagnosticsSnapshot.currentSpaceProtocolProfile,
                status: .needsAttention,
                checkedAt: now(),
                diagnosticNote: note
            )
            errorByDID[did] = note
        }
    }

    public func markReconnecting(for account: AccountStore.Account) {
        let did = account.id
        currentAccountDID = did
        let existing = snapshotsByDID[did]
        snapshotsByDID[did] = AccountDiagnosticsSnapshot(
            did: did,
            handle: existing?.handle ?? account.handle,
            authMode: existing?.authMode ?? account.authMode,
            resolvedPDSURL: existing?.resolvedPDSURL,
            declaredHandle: existing?.declaredHandle,
            hasSpaceKEMKey: existing?.hasSpaceKEMKey ?? false,
            hasSpaceHostService: existing?.hasSpaceHostService ?? false,
            spaceHostURL: existing?.spaceHostURL,
            requestedScopes: existing?.requestedScopes ?? Self.parseScopes(from: AccountStore.scope),
            grantedScopes: existing?.grantedScopes ?? [],
            spaceProtocolProfile: existing?.spaceProtocolProfile ?? AccountDiagnosticsSnapshot.currentSpaceProtocolProfile,
            status: .reconnecting,
            checkedAt: now(),
            diagnosticNote: "Waiting for OAuth re-authentication in your browser…"
        )
    }

    public func markDisconnected(
        did: String,
        handle: String = "",
        authMode: AccountStore.AuthModeType = .publicOAuth
    ) {
        currentAccountDID = did
        let existing = snapshotsByDID[did]
        snapshotsByDID[did] = AccountDiagnosticsSnapshot(
            did: did,
            handle: existing?.handle ?? handle,
            authMode: existing?.authMode ?? authMode,
            resolvedPDSURL: existing?.resolvedPDSURL,
            declaredHandle: existing?.declaredHandle,
            hasSpaceKEMKey: existing?.hasSpaceKEMKey ?? false,
            hasSpaceHostService: existing?.hasSpaceHostService ?? false,
            spaceHostURL: existing?.spaceHostURL,
            requestedScopes: existing?.requestedScopes ?? Self.parseScopes(from: AccountStore.scope),
            grantedScopes: [],
            spaceProtocolProfile: existing?.spaceProtocolProfile ?? AccountDiagnosticsSnapshot.currentSpaceProtocolProfile,
            status: .disconnected,
            checkedAt: now(),
            diagnosticNote: "This account is not currently connected in ATProtoDrive."
        )
    }

    // MARK: - Pure Document & Scope Evaluation

    nonisolated public static func parseScopes(from scopeString: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in scopeString.split(whereSeparator: \.isWhitespace) {
            let scope = String(token)
            if !scope.isEmpty, seen.insert(scope).inserted {
                result.append(scope)
            }
        }
        return result
    }

    nonisolated public static func summarizeScope(_ rawScope: String) -> ScopeSummaryItem {
        if rawScope == "atproto" {
            return ScopeSummaryItem(
                rawScope: rawScope,
                category: "Core",
                detail: "Base AT Protocol OAuth identity scope"
            )
        }
        if rawScope.hasPrefix("space:") {
            var details: [String] = []
            if rawScope.contains("manage=") {
                details.append("Space management")
            }
            if rawScope.contains("action=") || rawScope.contains("collection=") {
                details.append("Space record access")
            }
            let detailText = details.isEmpty
                ? "Permissioned Space access scope"
                : details.joined(separator: " & ")
            return ScopeSummaryItem(
                rawScope: rawScope,
                category: "Spaces",
                detail: detailText
            )
        }
        if rawScope.hasPrefix("repo:") {
            return ScopeSummaryItem(
                rawScope: rawScope,
                category: "Repository",
                detail: "Public repository write permission"
            )
        }
        if rawScope.hasPrefix("blob:") {
            return ScopeSummaryItem(
                rawScope: rawScope,
                category: "Blobs",
                detail: "Blob upload permission"
            )
        }
        if rawScope.hasPrefix("rpc:") {
            return ScopeSummaryItem(
                rawScope: rawScope,
                category: "RPC",
                detail: "Audience-qualified service RPC permission"
            )
        }
        if rawScope.hasPrefix("transition:") {
            return ScopeSummaryItem(
                rawScope: rawScope,
                category: "Transition",
                detail: "Legacy transition scope"
            )
        }
        return ScopeSummaryItem(
            rawScope: rawScope,
            category: "Custom",
            detail: "OAuth scope token"
        )
    }

    nonisolated public static func evaluateDocument(
        _ document: DIDDocument,
        expectedDID: String,
        handle: String,
        authMode: AccountStore.AuthModeType,
        requestedScopes: [String],
        grantedScopes: [String] = [],
        sessionMismatchNote: String? = nil,
        allowLocalhostDevelopment: Bool = false,
        checkedAt: Date = Date()
    ) -> AccountDiagnosticsSnapshot {
        // Strict exact-DID identity check before reading any service or key.
        guard document.id == expectedDID else {
            let note = [
                sessionMismatchNote,
                "DID document identity mismatch: expected \(expectedDID), got \(document.id)."
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            return AccountDiagnosticsSnapshot(
                did: expectedDID,
                handle: handle,
                authMode: authMode,
                resolvedPDSURL: nil,
                declaredHandle: nil,
                hasSpaceKEMKey: false,
                hasSpaceHostService: false,
                spaceHostURL: nil,
                requestedScopes: requestedScopes,
                grantedScopes: grantedScopes,
                spaceProtocolProfile: AccountDiagnosticsSnapshot.currentSpaceProtocolProfile,
                status: .needsAttention,
                checkedAt: checkedAt,
                diagnosticNote: note
            )
        }

        var notes: [String] = []
        if let sessionMismatchNote {
            notes.append(sessionMismatchNote)
        }

        // 1. Verify #atproto_pds and extract declaredHandle via DIDDocumentPDSResolver.
        var resolvedPDSURL: URL?
        var declaredHandle: String?
        var pdsFailure = false

        do {
            let identity = try DIDDocumentPDSResolver.validatedIdentity(
                from: document,
                expectedDID: expectedDID,
                allowLocalhostDevelopment: allowLocalhostDevelopment
            )
            resolvedPDSURL = identity.pdsURL
            declaredHandle = identity.declaredHandle
        } catch {
            pdsFailure = true
            let failure = BrowserFailure.normalize(error)
            notes.append(failure.errorDescription ?? error.localizedDescription)
            declaredHandle = extractDeclaredHandle(from: document)
        }

        // 2. Verify #atproto_kem (single self-controlled P-256 KEM key for Spaces).
        let hasSpaceKEMKey: Bool
        do {
            _ = try SpaceHostResolver.authorKEMKey(from: document, expectedDID: expectedDID)
            hasSpaceKEMKey = true
        } catch {
            hasSpaceKEMKey = false
            notes.append("No valid #atproto_kem key published in DID document; Spaces requiring author KEM keys may be unavailable.")
        }

        // 3. Check #atproto_space_host strictly (never fall back to #atproto_pds).
        let expectedSpaceHostID = "\(expectedDID)#atproto_space_host"
        let spaceHostMatches = document.service.filter { service in
            (service.id == "#atproto_space_host" || service.id == expectedSpaceHostID)
                && service.type == "AtprotoSpaceHost"
        }

        var hasSpaceHostService = false
        var spaceHostURL: URL?

        if spaceHostMatches.count == 1, let candidate = spaceHostMatches.first {
            if let canonicalURL = try? DIDDocumentPDSResolver.canonicalPDSOrigin(
                from: candidate.serviceEndpoint,
                allowLocalhostDevelopment: allowLocalhostDevelopment
            ) {
                hasSpaceHostService = true
                spaceHostURL = canonicalURL
            } else {
                notes.append("#atproto_space_host endpoint is malformed and was ignored.")
            }
        } else if spaceHostMatches.count > 1 {
            notes.append("Multiple #atproto_space_host entries found; strict policy ignores ambiguous service entries.")
        }

        let status: AccountConnectionStatus = (pdsFailure || sessionMismatchNote != nil)
            ? .needsAttention
            : .connected

        let diagnosticNote = notes.isEmpty ? nil : notes.joined(separator: " ")

        return AccountDiagnosticsSnapshot(
            did: expectedDID,
            handle: handle,
            authMode: authMode,
            resolvedPDSURL: resolvedPDSURL,
            declaredHandle: declaredHandle,
            hasSpaceKEMKey: hasSpaceKEMKey,
            hasSpaceHostService: hasSpaceHostService,
            spaceHostURL: spaceHostURL,
            requestedScopes: requestedScopes,
            grantedScopes: grantedScopes,
            spaceProtocolProfile: AccountDiagnosticsSnapshot.currentSpaceProtocolProfile,
            status: status,
            checkedAt: checkedAt,
            diagnosticNote: diagnosticNote
        )
    }

    nonisolated private static func extractDeclaredHandle(from document: DIDDocument) -> String? {
        for entry in document.alsoKnownAs where entry.hasPrefix("at://") {
            let candidate = String(entry.dropFirst("at://".count))
            if (try? Handle(handleString: candidate)) != nil {
                return candidate
            }
        }
        return nil
    }
}
