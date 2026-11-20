//
//  PrivateAppStateView.swift
//  ATProtoDrive
//

import AppKit
import SwiftUI

public struct PrivateAppStateView: View {
    public let accountDID: String
    public let refreshToken: Int

    @Environment(AccountStore.self) private var accountStore
    @State private var model: PrivateAppStateModel
    @State private var showRawJSON = false
    @State private var copiedJSON = false

    public init(
        accountDID: String,
        refreshToken: Int = 0,
        service: PrivateAppStateService = PrivateAppStateService()
    ) {
        self.accountDID = accountDID
        self.refreshToken = refreshToken
        self._model = State(initialValue: PrivateAppStateModel(service: service))
    }

    public var body: some View {
        Group {
            if let account = accountStore.account(for: accountDID) {
                let result = model.result(for: account.id)
                let isLoading = model.isLoading(for: account.id)

                VStack(spacing: 0) {
                    providerHeader(account: account, result: result, isLoading: isLoading)
                    Divider()
                    contentArea(account: account, result: result, isLoading: isLoading)
                }
                .navigationTitle("Private App State")
                .task(id: "\(account.id)-\(refreshToken)") {
                    await model.load(account: account)
                }
                .onChange(of: accountDID) { _, _ in
                    copiedJSON = false
                }
            } else {
                ContentUnavailableView(
                    "Account Disconnected",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("This account is no longer connected to ATProtoDrive.")
                )
                .navigationTitle("Private App State")
            }
        }
    }

    // MARK: - Provider Header

    @ViewBuilder
    private func providerHeader(
        account: AccountStore.Account,
        result: PrivateAppStateResult?,
        isLoading: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label("Read Only · Private App State", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.14), in: Capsule())
                        .foregroundStyle(.purple)

                    if let checkedAt = model.checkedAt(for: account.id) {
                        Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(PrivateAppStateService.providerTitle)
                        .font(.headline)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Text(PrivateAppStateService.providerID)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            if case .loaded(_, let rawJSON) = result {
                Picker("View Mode", selection: $showRawJSON) {
                    Text("Structured").tag(false)
                    Text("Raw JSON").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)

                Button {
                    copyToClipboard(rawJSON)
                    copiedJSON = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedJSON = false
                    }
                } label: {
                    Label(
                        copiedJSON ? "Copied" : "Copy JSON",
                        systemImage: copiedJSON ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy pretty-printed preferences JSON")
            }

            Button {
                Task {
                    await model.load(account: account)
                }
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
            .help("Refresh private app state")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Content States

    @ViewBuilder
    private func contentArea(
        account: AccountStore.Account,
        result: PrivateAppStateResult?,
        isLoading: Bool
    ) -> some View {
        switch result {
        case nil:
            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Bluesky preferences…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Private App State", systemImage: "lock")
                } description: {
                    Text("Inspect read-only Bluesky preferences stored for this account.")
                } actions: {
                    Button("Load Preferences") {
                        Task { await model.load(account: account) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .loaded(let items, let rawJSON):
            if showRawJSON {
                rawJSONInspector(rawJSON: rawJSON, itemCount: items.count)
            } else {
                structuredPreferencesView(items: items, rawJSON: rawJSON)
            }

        case .unsupported(let reason):
            ContentUnavailableView {
                Label("Not Supported on This Server", systemImage: "lock.slash")
            } description: {
                VStack(spacing: 8) {
                    Text(reason)
                    Text("Private App State reads are strictly read-only and authenticated against your account’s server. ATProtoDrive never falls back to unauthenticated public endpoints.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 460)
            } actions: {
                Button("Check Again") {
                    Task { await model.load(account: account) }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Private App State", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(message)
                    .frame(maxWidth: 460)
            } actions: {
                Button("Retry") {
                    Task { await model.load(account: account) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Structured List & Raw JSON

    @ViewBuilder
    private func structuredPreferencesView(
        items: [PreferenceSummaryItem],
        rawJSON: String
    ) -> some View {
        if items.isEmpty {
            ContentUnavailableView(
                "No Preferences Stored",
                systemImage: "tray",
                description: Text("The server returned an empty preferences array for this account.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(items.count) preference \(items.count == 1 ? "entry" : "entries")")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Inspect Raw JSON") {
                            showRawJSON = true
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    ForEach(items) { item in
                        PreferenceCardView(item: item)
                    }
                }
                .padding(16)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func rawJSONInspector(rawJSON: String, itemCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Raw Preferences JSON (\(itemCount) \(itemCount == 1 ? "item" : "items"))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Read Only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(rawJSON)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct PreferenceCardView: View {
    let item: PreferenceSummaryItem
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.typeIdentifier)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if !item.details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
                        Text("• \(detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 34)
            }

            DisclosureGroup("Raw Item JSON", isExpanded: $isExpanded) {
                ScrollView(.horizontal) {
                    Text(item.rawItemJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}
