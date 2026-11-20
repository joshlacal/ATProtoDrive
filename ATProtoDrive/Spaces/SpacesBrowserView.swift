//
//  SpacesBrowserView.swift
//  ATProtoDrive
//

import Foundation
import Petrel
import SwiftUI

public struct SpacesBrowserView: View {
    public let accountDID: String
    @Binding public var pendingOpenSpaceURI: String?
    public let refreshToken: Int

    @Environment(AccountStore.self) private var accountStore
    @State private var selectedSpaceID: SpaceItem.ID?
    @State private var selectedRepo: RepoEntry?
    @State private var searchText: String = ""
    @State private var showingCreateSpace = false
    @State private var showingOpenSpace = false
    @State private var spaceToDelete: SpaceItem?
    @State private var actionError: String?

    public init(
        accountDID: String,
        pendingOpenSpaceURI: Binding<String?> = .constant(nil),
        refreshToken: Int = 0
    ) {
        self.accountDID = accountDID
        self._pendingOpenSpaceURI = pendingOpenSpaceURI
        self.refreshToken = refreshToken
    }

    public var body: some View {
        if let account = accountStore.account(for: accountDID) {
            let model = accountStore.spaceModel(for: accountDID)
            let filteredSpaces = Self.filterSpaces(model.spaces, query: searchText)
            let selectedSpace = selectedSpaceID.flatMap { id in
                model.spaces.first(where: { $0.id == id })
            }

            HSplitView {
                spacesListPane(account: account, model: model, filteredSpaces: filteredSpaces)
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 380, maxHeight: .infinity)

                spaceDetailPane(account: account, selectedSpace: selectedSpace)
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Spaces")
            .task(id: "\(account.id)-\(refreshToken)") {
                await model.load(account: account)
                applyPendingOrDefaultSelection(in: model.spaces)
            }
            .onChange(of: accountDID) { _, _ in
                selectedSpaceID = nil
                selectedRepo = nil
                searchText = ""
            }
            .onChange(of: selectedSpaceID) { oldValue, newValue in
                if oldValue != newValue {
                    selectedRepo = nil
                }
            }
            .onChange(of: pendingOpenSpaceURI) { _, _ in
                applyPendingOrDefaultSelection(in: model.spaces)
            }
            .sheet(isPresented: $showingCreateSpace) {
                CreateSpaceSheet(account: account) { createdRef in
                    Task {
                        await model.load(account: account)
                        if let createdItem = model.spaces.first(where: { $0.ref.uriString() == createdRef.uriString() }) {
                            selectedSpaceID = createdItem.id
                            selectedRepo = nil
                        }
                    }
                }
            }
            .sheet(isPresented: $showingOpenSpace) {
                OpenSpaceSheet(account: account) { openedItem in
                    selectedSpaceID = openedItem.id
                    selectedRepo = nil
                }
            }
            .confirmationDialog(
                "Delete Space",
                isPresented: Binding(
                    get: { spaceToDelete != nil },
                    set: { if !$0 { spaceToDelete = nil } }
                ),
                presenting: spaceToDelete
            ) { space in
                Button("Delete \"\(space.skey)\"", role: .destructive) {
                    Task {
                        do {
                            try await model.deleteSpace(space: space, account: account)
                            if selectedSpaceID == space.id {
                                selectedSpaceID = model.spaces.first?.id
                                selectedRepo = nil
                            }
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { space in
                Text("Are you sure you want to delete space \"\(space.skey)\"? This action is irreversible.")
            }
            .alert(
                "Space Action Error",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                if let actionError {
                    Text(actionError)
                }
            }
        } else {
            ContentUnavailableView(
                "Account Disconnected",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("The requested account is not available.")
            )
            .navigationTitle("Spaces")
        }
    }

    nonisolated public static func filterSpaces(_ spaces: [SpaceItem], query: String) -> [SpaceItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return spaces }
        return spaces.filter { space in
            space.skey.localizedStandardContains(trimmed) ||
                space.spaceType.localizedStandardContains(trimmed) ||
                space.authorityDID.localizedStandardContains(trimmed) ||
                space.ref.uriString().localizedStandardContains(trimmed)
        }
    }

    private func applyPendingOrDefaultSelection(in spaces: [SpaceItem]) {
        if let pendingURI = pendingOpenSpaceURI,
           let matched = spaces.first(where: { $0.ref.uriString() == pendingURI }) {
            selectedSpaceID = matched.id
            selectedRepo = nil
            pendingOpenSpaceURI = nil
            return
        }
        if let currentID = selectedSpaceID, !spaces.contains(where: { $0.id == currentID }) {
            selectedSpaceID = spaces.first?.id
            selectedRepo = nil
        } else if selectedSpaceID == nil, let first = spaces.first {
            selectedSpaceID = first.id
        }
    }

    @ViewBuilder
    private func spacesListPane(
        account: AccountStore.Account,
        model: SpaceListModel,
        filteredSpaces: [SpaceItem]
    ) -> some View {
        VStack(spacing: 0) {
            // Header toolbar
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Spaces")
                        .font(.headline)
                    Text("\(model.spaces.count) \(model.spaces.count == 1 ? "space" : "spaces")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    showingCreateSpace = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Create New Space…")

                Button {
                    showingOpenSpace = true
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Space by URI…")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Filter bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Filter spaces…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Inline error banner when spaces already exist
            if let error = model.error, !model.spaces.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") {
                        Task { await model.load(account: account) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            if model.isLoading && model.spaces.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading spaces…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.spaces.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await model.load(account: account) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.spaces.isEmpty {
                ContentUnavailableView {
                    Label("No Spaces Yet", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Create a permissioned Space or open one by its at:// URI.")
                } actions: {
                    VStack(spacing: 8) {
                        Button("New Space…") {
                            showingCreateSpace = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open Space by URI…") {
                            showingOpenSpace = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if filteredSpaces.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredSpaces, selection: $selectedSpaceID) { space in
                    SpaceListRow(space: space)
                        .tag(space.id)
                        .contextMenu {
                            ContextMenuEntriesView(
                                items: RecordMenuDescriptors.spaceRowMenu(
                                    for: space,
                                    onDelete: {
                                        spaceToDelete = space
                                    }
                                )
                            )
                            if model.isCustomSpace(space, accountDID: account.id) && !space.isOwnAuthority {
                                Divider()
                                Button(role: .destructive) {
                                    model.removeCustomSpace(space, accountDID: account.id)
                                    if selectedSpaceID == space.id {
                                        selectedSpaceID = model.spaces.first?.id
                                        selectedRepo = nil
                                    }
                                } label: {
                                    Label("Remove Saved Reference", systemImage: "bookmark.slash")
                                }
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func spaceDetailPane(
        account: AccountStore.Account,
        selectedSpace: SpaceItem?
    ) -> some View {
        if let selectedSpace {
            if let activeRepo = selectedRepo {
                RecordTableView(
                    space: selectedSpace,
                    repo: activeRepo,
                    account: account,
                    refreshToken: refreshToken,
                    onBack: {
                        selectedRepo = nil
                    }
                )
                .id("\(selectedSpace.id)-\(activeRepo.did)")
            } else {
                SpaceDetailView(
                    space: selectedSpace,
                    account: account,
                    selectedRepo: $selectedRepo,
                    refreshToken: refreshToken
                ) {
                    let model = accountStore.spaceModel(for: account.id)
                    selectedSpaceID = model.spaces.first?.id
                    selectedRepo = nil
                }
                .id(selectedSpace.id)
            }
        } else {
            ContentUnavailableView {
                Label("Select a Space", systemImage: "square.stack.3d.up")
            } description: {
                Text("Choose a Space from the list to inspect its policy, writers, members, and records.")
            } actions: {
                HStack(spacing: 8) {
                    Button("New Space…") {
                        showingCreateSpace = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Space by URI…") {
                        showingOpenSpace = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct SpaceListRow: View {
    let space: SpaceItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: space.isOwnAuthority ? "externaldrive" : "externaldrive.badge.person.crop")
                .foregroundStyle(space.isOwnAuthority ? .blue : .purple)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(space.skey)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !space.isOwnAuthority {
                        Text("Shared")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(space.spaceType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let repoRev = space.repoRev, !repoRev.isEmpty {
                    Text("rev \(repoRev)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

public struct OpenSpaceDestinationView: View {
    @Environment(AccountStore.self) private var accountStore
    public var onOpened: (_ accountDID: String, _ space: SpaceItem) -> Void
    public var onAddAccount: () -> Void

    @State private var selectedAccountDID: String = ""
    @State private var uriString: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        onOpened: @escaping (_ accountDID: String, _ space: SpaceItem) -> Void,
        onAddAccount: @escaping () -> Void
    ) {
        self.onOpened = onOpened
        self.onAddAccount = onAddAccount
    }

    private var activeAccount: AccountStore.Account? {
        if let matched = accountStore.account(for: selectedAccountDID) {
            return matched
        }
        return accountStore.activeAccount ?? accountStore.accounts.first
    }

    public var body: some View {
        Group {
            if accountStore.accounts.isEmpty {
                ContentUnavailableView {
                    Label("Sign In to Open a Space", systemImage: "person.badge.key")
                } description: {
                    Text("Opening a permissioned Space requires a connected ATProto account.")
                } actions: {
                    Button("Add Account…", action: onAddAccount)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Open Space by URI")
                            .font(.title2.bold())
                        Text("Enter a permissioned Space URI to verify access and browse its writers and records.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Form {
                        if accountStore.accounts.count > 1 {
                            Picker("Account", selection: $selectedAccountDID) {
                                ForEach(accountStore.accounts) { account in
                                    Text(account.handle.isEmpty ? account.id : account.handle)
                                        .tag(account.id)
                                }
                            }
                        } else if let onlyAccount = activeAccount {
                            LabeledContent("Account", value: onlyAccount.handle.isEmpty ? onlyAccount.id : onlyAccount.handle)
                        }

                        TextField(
                            "Space URI",
                            text: $uriString,
                            prompt: Text("at://did:plc:.../space/space.swan.drive/self")
                        )
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await submit() }
                        }
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: 540, maxHeight: 190)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }

                    HStack(spacing: 12) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Open Space") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSubmitting || activeAccount == nil || uriString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    if selectedAccountDID.isEmpty, let initial = activeAccount {
                        selectedAccountDID = initial.id
                    }
                }
            }
        }
        .navigationTitle("Open Space by URI")
    }

    private func submit() async {
        guard let account = activeAccount else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let model = accountStore.spaceModel(for: account.id)
            let opened = try await model.openSpace(uriString: uriString, account: account)
            uriString = ""
            onOpened(account.id, opened)
        } catch {
            if let openError = error as? OpenSpaceError {
                errorMessage = openError.errorDescription
            } else if let xrpc = error as? ATProtoXRPCError {
                errorMessage = xrpc.errorDescription ?? xrpc.error
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
