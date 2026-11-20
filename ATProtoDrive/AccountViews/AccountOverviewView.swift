//
//  AccountOverviewView.swift
//  ATProtoDrive
//

import AppKit
import SwiftUI

public struct AccountOverviewView: View {
    public let accountDID: String
    public let refreshToken: Int
    public let onNavigate: @MainActor (AccountDestination) -> Void

    @Environment(AccountStore.self) private var accountStore
    @State private var statusModel: AccountStatusModel
    @State private var copiedDID = false

    public init(
        accountDID: String,
        refreshToken: Int = 0,
        statusModel: AccountStatusModel? = nil,
        onNavigate: @escaping @MainActor (AccountDestination) -> Void
    ) {
        self.accountDID = accountDID
        self.refreshToken = refreshToken
        self._statusModel = State(initialValue: statusModel ?? AccountStatusModel())
        self.onNavigate = onNavigate
    }

    public var body: some View {
        Group {
            if let account = accountStore.account(for: accountDID) {
                let spaceModel = accountStore.spaceModel(for: account.id)
                let snapshot = statusModel.snapshot(for: account.id)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        accountHeaderCard(account: account, snapshot: snapshot, spaceModel: spaceModel)
                        quickNavigationSection(spaceModel: spaceModel)
                    }
                    .padding(20)
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .navigationTitle(displayHandle(for: account, snapshot: snapshot))
                .task(id: "\(account.id)-\(refreshToken)") {
                    await statusModel.load(account: account)
                    if refreshToken > 0 || (spaceModel.spaces.isEmpty && !spaceModel.isLoading && spaceModel.error == nil) {
                        await spaceModel.load(account: account)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Account Disconnected",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("This account is no longer connected to ATProtoDrive.")
                )
                .navigationTitle("Overview")
            }
        }
    }

    // MARK: - Account Header Card

    @ViewBuilder
    private func accountHeaderCard(
        account: AccountStore.Account,
        snapshot: AccountDiagnosticsSnapshot?,
        spaceModel: SpaceListModel
    ) -> some View {
        let isRefreshing = statusModel.isLoading(for: account.id)
        let status = snapshot?.status ?? .connected

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(displayHandle(for: account, snapshot: snapshot))
                            .font(.title2.bold())
                            .lineLimit(1)

                        statusPill(status)
                    }

                    HStack(spacing: 6) {
                        Text(account.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
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
                            Label(
                                copiedDID ? "Copied" : "Copy DID",
                                systemImage: copiedDID ? "checkmark" : "doc.on.doc"
                            )
                            .labelStyle(.iconOnly)
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Account DID")
                    }
                }

                Spacer()

                Button {
                    Task {
                        await statusModel.load(account: account)
                        await spaceModel.load(account: account)
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("Refresh account diagnostics and spaces")
            }

            Divider()

            FlowBadgesRow {
                metadataPill(
                    title: authModeTitle(for: account.authMode),
                    systemImage: account.authMode == .cab ? "lock.shield" : "key",
                    tint: .blue
                )

                if let pdsHost = snapshot?.resolvedPDSURL?.host ?? snapshot?.resolvedPDSURL?.absoluteString {
                    metadataPill(
                        title: pdsHost,
                        systemImage: "server.rack",
                        tint: .secondary
                    )
                } else if isRefreshing {
                    metadataPill(
                        title: "Resolving PDS…",
                        systemImage: "server.rack",
                        tint: .secondary
                    )
                } else {
                    metadataPill(
                        title: "PDS Unavailable",
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

                if let snapshot {
                    metadataPill(
                        title: snapshot.hasSpaceKEMKey ? "Space KEM Ready" : "No Space KEM Key",
                        systemImage: snapshot.hasSpaceKEMKey ? "checkmark.seal.fill" : "key.slash",
                        tint: snapshot.hasSpaceKEMKey ? .green : .orange
                    )
                } else if isRefreshing {
                    metadataPill(
                        title: "Checking Space KEM…",
                        systemImage: "key",
                        tint: .secondary
                    )
                }
            }

            if let note = snapshot?.diagnosticNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: status == .needsAttention ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(status == .needsAttention ? Color.orange : Color.secondary)
                        .font(.caption)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (status == .needsAttention ? Color.orange : Color.secondary).opacity(0.08),
                    in: .rect(cornerRadius: 8)
                )
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Quick Navigation Cards

    private var navigationCards: [(destination: AccountDestination, title: String, subtitle: String, symbol: String, tint: Color)] {
        [
            (
                .publicRecords,
                "Public Records",
                "Browse world-readable collections and records stored on your PDS.",
                "doc.text",
                .blue
            ),
            (
                .publicBlobs,
                "Public Files",
                "Inspect, preview, and download CID-verified public blobs.",
                "doc.on.doc",
                .teal
            ),
            (
                .spaces,
                "Spaces",
                "Browse permissioned access-controlled Spaces and writer repositories.",
                "square.stack.3d.up",
                .indigo
            ),
            (
                .privateAppState,
                "Private App State",
                "Read-only Bluesky preferences when supported by your server.",
                "lock",
                .purple
            ),
            (
                .backups,
                "Backups",
                "Create, verify, and browse offline .atprotodrivebackup packages.",
                "arrow.clockwise.icloud",
                .green
            ),
            (
                .activity,
                "Activity",
                "Track active downloads, backup exports, and transfer history.",
                "waveform.path.ecg",
                .orange
            ),
            (
                .serverAndAccount,
                "Server & Account",
                "Inspect exact-DID diagnostics, OAuth scopes, reconnect, or remove locally.",
                "server.rack",
                .secondary
            )
        ]
    }

    @ViewBuilder
    private func quickNavigationSection(spaceModel: SpaceListModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destinations")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 12)],
                spacing: 12
            ) {
                ForEach(navigationCards, id: \.destination) { card in
                    destinationCardButton(
                        destination: card.destination,
                        title: card.title,
                        subtitle: card.subtitle,
                        symbolName: card.symbol,
                        tint: card.tint,
                        badge: badgeText(for: card.destination, spaceModel: spaceModel)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func destinationCardButton(
        destination: AccountDestination,
        title: String,
        subtitle: String,
        symbolName: String,
        tint: Color,
        badge: String?
    ) -> some View {
        Button {
            onNavigate(destination)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: symbolName)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(tint)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(Color(NSColor.controlBackgroundColor), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func badgeText(for destination: AccountDestination, spaceModel: SpaceListModel) -> String? {
        guard destination == .spaces else { return nil }
        if spaceModel.isLoading && spaceModel.spaces.isEmpty {
            return "Loading…"
        }
        let count = spaceModel.spaces.count
        return "\(count) \(count == 1 ? "space" : "spaces")"
    }

    private func displayHandle(
        for account: AccountStore.Account,
        snapshot: AccountDiagnosticsSnapshot?
    ) -> String {
        let raw = !account.handle.isEmpty
            ? account.handle
            : (snapshot?.declaredHandle ?? account.id)
        if raw.hasPrefix("did:") || raw.hasPrefix("@") {
            return raw
        }
        return "@\(raw)"
    }

    private func authModeTitle(for authMode: AccountStore.AuthModeType) -> String {
        switch authMode {
        case .cab:
            return "CAB Confidential"
        case .publicOAuth:
            return "Public OAuth"
        }
    }

    @ViewBuilder
    private func statusPill(_ status: AccountConnectionStatus) -> some View {
        let tint: Color = switch status {
        case .connected: .green
        case .reconnecting: .blue
        case .needsAttention: .orange
        case .disconnected: .secondary
        }
        Label(status.displayTitle, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private func metadataPill(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .lineLimit(1)
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct FlowBadgesRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                content
            }
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}
