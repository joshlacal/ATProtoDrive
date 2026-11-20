//
//  ServerAndAccountView.swift
//  ATProtoDrive
//

import AppKit
import SwiftUI

public struct ServerAndAccountView: View {
    public let accountDID: String
    public let refreshToken: Int
    public let onReconnect: @MainActor (String) async throws -> Void
    public let onRemoveAccount: @MainActor (String) async throws -> Void

    @Environment(AccountStore.self) private var accountStore
    @State private var statusModel: AccountStatusModel
    @State private var isReconnecting = false
    @State private var isRemoving = false
    @State private var showingRemoveConfirmation = false
    @State private var actionFeedbackMessage: String?
    @State private var actionErrorMessage: String?
    @State private var copiedDID = false

    /// Strictly closed list of actions exposed by this surface (verified by tests).
    nonisolated public static var exposedControlActions: [AccountControlAction] {
        AccountControlCatalog.actions.map(\.action)
    }

    nonisolated public static func removeConfirmationMessage(for handleOrDID: String) -> String {
        let formatted = (handleOrDID.hasPrefix("did:") || handleOrDID.hasPrefix("@") || handleOrDID.isEmpty)
            ? (handleOrDID.isEmpty ? "this account" : handleOrDID)
            : "@\(handleOrDID)"
        return "This removes local credentials, cached data, Space credentials, and saved sources for \(formatted) from this Mac. Your remote account, server records, blobs, Spaces, memberships, and local backups are not affected. Your provider may retain other sessions."
    }

    public init(
        accountDID: String,
        refreshToken: Int = 0,
        statusModel: AccountStatusModel? = nil,
        onReconnect: @escaping @MainActor (String) async throws -> Void,
        onRemoveAccount: @escaping @MainActor (String) async throws -> Void
    ) {
        self.accountDID = accountDID
        self.refreshToken = refreshToken
        self._statusModel = State(initialValue: statusModel ?? AccountStatusModel())
        self.onReconnect = onReconnect
        self.onRemoveAccount = onRemoveAccount
    }

    public var body: some View {
        Group {
            if let account = accountStore.account(for: accountDID) {
                let snapshot = statusModel.snapshot(for: account.id)
                let isLoading = statusModel.isLoading(for: account.id)

                Form {
                    identitySection(account: account, snapshot: snapshot, isLoading: isLoading)
                    didDocumentSection(snapshot: snapshot, isLoading: isLoading)
                    oauthAndScopesSection(account: account, snapshot: snapshot)
                    accountControlsSection(account: account)
                }
                .formStyle(.grouped)
                .navigationTitle("Server & Account")
                .task(id: "\(account.id)-\(refreshToken)") {
                    await statusModel.load(account: account)
                }
                .confirmationDialog(
                    "Remove from ATProtoDrive",
                    isPresented: $showingRemoveConfirmation
                ) {
                    Button("Remove from ATProtoDrive", role: .destructive) {
                        performRemove(account: account)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(Self.removeConfirmationMessage(
                        for: account.handle.isEmpty ? account.id : account.handle
                    ))
                }
            } else {
                ContentUnavailableView(
                    "Account Disconnected",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("This account is no longer connected to ATProtoDrive.")
                )
                .navigationTitle("Server & Account")
            }
        }
    }

    // MARK: - Identity & Connection Verification

    @ViewBuilder
    private func identitySection(
        account: AccountStore.Account,
        snapshot: AccountDiagnosticsSnapshot?,
        isLoading: Bool
    ) -> some View {
        let status: AccountConnectionStatus = isReconnecting
            ? .reconnecting
            : (snapshot?.status ?? .connected)

        Section {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(formattedHandle(account.handle.isEmpty ? account.id : account.handle))
                            .font(.headline)
                        connectionStatusBadge(status)
                    }

                    if let checkedAt = snapshot?.checkedAt {
                        Text("Last verified \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isLoading {
                        Text("Checking DID document and session…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    Task {
                        actionErrorMessage = nil
                        actionFeedbackMessage = nil
                        await statusModel.load(account: account)
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading || isReconnecting || isRemoving)
            }

            LabeledContent("Exact Account DID") {
                HStack(spacing: 6) {
                    Text(account.id)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        copyToClipboard(account.id)
                        copiedDID = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedDID = false
                        }
                    } label: {
                        Image(systemName: copiedDID ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy DID")
                }
            }

            LabeledContent("Session Handle", value: account.handle.isEmpty ? "Unavailable" : account.handle)
                .textSelection(.enabled)

            if let snapshot {
                LabeledContent("DID Document Handle", value: snapshot.declaredHandle ?? "Not declared in alsoKnownAs")
                    .textSelection(.enabled)

                LabeledContent("Identity Verification") {
                    if snapshot.status == .connected && snapshot.did == account.id {
                        Label("Exact DID verified", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else if snapshot.status == .reconnecting {
                        Label("Reconnecting", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.blue)
                    } else {
                        Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if let note = snapshot.diagnosticNote, !note.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: snapshot.status == .needsAttention ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(snapshot.status == .needsAttention ? Color.orange : Color.secondary)
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Identity & Exact-DID Verification")
        }
    }

    // MARK: - PDS & DID Document Service / Key Checks

    @ViewBuilder
    private func didDocumentSection(
        snapshot: AccountDiagnosticsSnapshot?,
        isLoading: Bool
    ) -> some View {
        Section {
            LabeledContent("PDS Endpoint") {
                if let pdsURL = snapshot?.resolvedPDSURL {
                    Text(pdsURL.absoluteString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else if isLoading {
                    Text("Resolving…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.orange)
                }
            }

            LabeledContent("Space Protocol Profile") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(AccountDiagnosticsSnapshot.currentSpaceProtocolDisplayName)
                    Text(snapshot?.spaceProtocolProfile ?? AccountDiagnosticsSnapshot.currentSpaceProtocolProfile)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            diagnosticCheckRow(
                identifier: "#atproto_pds",
                label: "Personal Data Server Service",
                isPresent: snapshot?.hasValidPDSService ?? false,
                isLoading: isLoading && snapshot == nil,
                presentDetail: snapshot?.resolvedPDSURL?.absoluteString ?? "Verified",
                absentDetail: "Missing or invalid #atproto_pds endpoint",
                isRequired: true
            )

            diagnosticCheckRow(
                identifier: "#atproto_kem",
                label: "Spaces Author P-256 KEM Key",
                isPresent: snapshot?.hasSpaceKEMKey ?? false,
                isLoading: isLoading && snapshot == nil,
                presentDetail: "Published and controlled by this DID",
                absentDetail: "Not published in DID document",
                isRequired: false
            )

            diagnosticCheckRow(
                identifier: "#atproto_space_host",
                label: "Dedicated Space Host Service",
                isPresent: snapshot?.hasSpaceHostService ?? false,
                isLoading: isLoading && snapshot == nil,
                presentDetail: snapshot?.spaceHostURL?.absoluteString ?? "Published",
                absentDetail: "Not published (November 12, 2026 alpha uses #atproto_pds)",
                isRequired: false
            )
        } header: {
            Text("PDS & DID Document Checks")
        } footer: {
            Text("Permissioned Spaces are access-controlled repositories evaluated against your DID document and OAuth session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - OAuth Session & Scopes

    @ViewBuilder
    private func oauthAndScopesSection(
        account: AccountStore.Account,
        snapshot: AccountDiagnosticsSnapshot?
    ) -> some View {
        let requestedScopes = snapshot?.requestedScopes ?? AccountStatusModel.parseScopes(from: AccountStore.scope)
        let grantedScopes = snapshot?.grantedScopes ?? []

        Section {
            LabeledContent("OAuth Mode") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(account.authMode == .cab ? "CAB Confidential" : "Public OAuth")
                        .font(.body.weight(.medium))
                    Text(
                        account.authMode == .cab
                            ? "Client Assertion Backend (confidential OAuth client)"
                            : "Native public OAuth client (PAR + PKCE + DPoP)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Granted Scopes")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(grantedScopes.isEmpty ? "Not reported" : "\(grantedScopes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if grantedScopes.isEmpty {
                    Text("Not reported by this OAuth mode. Requested scopes below reflect what ATProtoDrive asked for, not guaranteed server grants.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(grantedScopes, id: \.self) { scope in
                        scopeRow(AccountStatusModel.summarizeScope(scope))
                    }
                }
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Requested Scopes")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(requestedScopes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(requestedScopes, id: \.self) { scope in
                    scopeRow(AccountStatusModel.summarizeScope(scope))
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("OAuth Session & Scopes")
        }
    }

    // MARK: - Strictly Two-Action Account Controls

    @ViewBuilder
    private func accountControlsSection(account: AccountStore.Account) -> some View {
        Section {
            ForEach(AccountControlCatalog.actions) { descriptor in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.title)
                            .font(.body.weight(.medium))
                        Text(descriptor.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    switch descriptor.action {
                    case .reconnect:
                        Button {
                            performReconnect(account: account)
                        } label: {
                            if isReconnecting {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Reconnecting…")
                                }
                            } else {
                                Label(descriptor.title, systemImage: descriptor.systemImage)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isReconnecting || isRemoving)

                    case .removeFromApp:
                        Button(role: .destructive) {
                            showingRemoveConfirmation = true
                        } label: {
                            if isRemoving {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Removing…")
                                }
                            } else {
                                Label(descriptor.title, systemImage: descriptor.systemImage)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isReconnecting || isRemoving)
                    }
                }
                .padding(.vertical, 4)
            }

            if let actionFeedbackMessage {
                Label(actionFeedbackMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let actionErrorMessage {
                Label(actionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Account Controls")
        } footer: {
            Text("ATProtoDrive only manages local sessions on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func performReconnect(account: AccountStore.Account) {
        isReconnecting = true
        actionErrorMessage = nil
        actionFeedbackMessage = nil
        statusModel.markReconnecting(for: account)

        Task {
            defer { isReconnecting = false }
            do {
                try await onReconnect(account.id)
                actionFeedbackMessage = "Re-authentication started for \(formattedHandle(account.handle.isEmpty ? account.id : account.handle)). Complete sign-in in your browser."
                await statusModel.load(account: account)
            } catch {
                actionErrorMessage = "Reconnect failed: \(error.localizedDescription)"
                await statusModel.load(account: account)
            }
        }
    }

    private func performRemove(account: AccountStore.Account) {
        isRemoving = true
        actionErrorMessage = nil
        actionFeedbackMessage = nil

        Task {
            defer { isRemoving = false }
            do {
                try await onRemoveAccount(account.id)
                statusModel.markDisconnected(
                    did: account.id,
                    handle: account.handle,
                    authMode: account.authMode
                )
            } catch {
                actionErrorMessage = "Couldn’t remove account locally: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Subview Helpers

    @ViewBuilder
    private func diagnosticCheckRow(
        identifier: String,
        label: String,
        isPresent: Bool,
        isLoading: Bool,
        presentDetail: String,
        absentDetail: String,
        isRequired: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: isPresent ? "checkmark.circle.fill" : (isRequired ? "exclamationmark.triangle.fill" : "minus.circle"))
                    .foregroundStyle(isPresent ? Color.green : (isRequired ? Color.orange : Color.secondary))
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identifier)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(isLoading ? "Checking DID document…" : (isPresent ? presentDetail : absentDetail))
                    .font(.caption)
                    .foregroundStyle((!isPresent && isRequired) ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func scopeRow(_ item: ScopeSummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.category)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.rawScope)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private func connectionStatusBadge(_ status: AccountConnectionStatus) -> some View {
        let tint: Color = switch status {
        case .connected: .green
        case .reconnecting: .blue
        case .needsAttention: .orange
        case .disconnected: .secondary
        }
        Label(status.displayTitle, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func formattedHandle(_ raw: String) -> String {
        if raw.hasPrefix("did:") || raw.hasPrefix("@") {
            return raw
        }
        return "@\(raw)"
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
