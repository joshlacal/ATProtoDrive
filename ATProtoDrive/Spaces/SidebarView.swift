//
//  SidebarView.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct SidebarView: View {
    @Environment(AccountStore.self) private var accountStore
    @Binding public var selectedSpace: SpaceItem?
    @Binding public var showingAddAccount: Bool

    public init(selectedSpace: Binding<SpaceItem?>, showingAddAccount: Binding<Bool>) {
        self._selectedSpace = selectedSpace
        self._showingAddAccount = showingAddAccount
    }

    public var body: some View {
        if accountStore.accounts.isEmpty {
            ContentUnavailableView {
                Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an ATProto account to browse Spaces.")
            } actions: {
                Button("Add Account") {
                    showingAddAccount = true
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Spaces")
        } else {
            List(selection: $selectedSpace) {
                ForEach(accountStore.accounts) { account in
                    AccountSpacesSection(
                        account: account,
                        selectedSpace: $selectedSpace
                    )
                }
            }
            .navigationTitle("Spaces")
        }
    }
}

// MARK: - AccountSpacesSection

struct AccountSpacesSection: View {
    @Environment(AccountStore.self) private var accountStore
    let account: AccountStore.Account
    @Binding var selectedSpace: SpaceItem?
    private var model: SpaceListModel {
        accountStore.spaceModel(for: account.id)
    }
    @State private var showingCreateSpace = false
    @State private var showingOpenSpace = false


    var body: some View {
        Section {
            if model.isLoading && model.spaces.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading spaces…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.error, model.spaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button("Retry") {
                        Task { await model.load(account: account) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            } else if model.spaces.isEmpty {
                Text("No spaces")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.spaces) { space in
                    SpaceRowView(space: space)
                        .tag(space)
                        .contextMenu {
                            ContextMenuEntriesView(items: RecordMenuDescriptors.spaceRowMenu(for: space))
                        }
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        } header: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.handle)
                        .font(.headline)
                    Text(account.id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        showingCreateSpace = true
                    } label: {
                        Label("New Space…", systemImage: "plus")
                    }
                    Button {
                        showingOpenSpace = true
                    } label: {
                        Label("Open Space by Reference…", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .help("Add or Open Space")
                if model.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .contextMenu {
                Button {
                    showingCreateSpace = true
                } label: {
                    Label("New Space…", systemImage: "plus")
                }
                Button {
                    showingOpenSpace = true
                } label: {
                    Label("Open Space by Reference…", systemImage: "link")
                }
                Divider()
                Button(role: .destructive) {
                    Task {
                        await accountStore.remove(account.id)
                    }
                } label: {
                    Label("Remove Account", systemImage: "trash")
                }
            }
        }
        .task(id: account.id) {
            await model.load(account: account)
        }
        .refreshable {
            await model.load(account: account)
        }
        .sheet(isPresented: $showingCreateSpace) {
            CreateSpaceSheet(account: account) { createdRef in
                Task {
                    await model.load(account: account)
                    if let createdItem = model.spaces.first(where: { $0.ref.uriString() == createdRef.uriString() }) {
                        selectedSpace = createdItem
                    } else {
                        selectedSpace = SpaceItem(ref: createdRef, accountDID: account.id)
                    }
                }
            }
        }
        .sheet(isPresented: $showingOpenSpace) {
            OpenSpaceSheet(account: account) { openedItem in
                selectedSpace = openedItem
            }
        }
    }
}

// MARK: - SpaceRowView

struct SpaceRowView: View {
    let space: SpaceItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: space.isOwnAuthority ? "externaldrive" : "externaldrive.badge.person.crop")
                .foregroundStyle(space.isOwnAuthority ? .blue : .purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(space.skey)
                    .font(.body)
                Text(space.spaceType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !space.isOwnAuthority {
                Text("Shared")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            ContextMenuEntriesView(items: RecordMenuDescriptors.spaceRowMenu(for: space))
        }
    }
}
