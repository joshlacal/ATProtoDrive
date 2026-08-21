//
//  SpaceDetailView.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct SpaceDetailView: View {
    @Environment(AccountStore.self) private var accountStore

    let space: SpaceItem
    let account: AccountStore.Account?
    @Binding var selectedRepo: RepoEntry?
    var onDelete: (() -> Void)?

    @State private var model = SpaceDetailModel()
    @State private var showingAddMemberSheet = false
    @State private var showingCreateRecordSheet = false
    @State private var memberToRemove: String?
    @State private var showingDeleteSpaceConfirmation = false
    @State private var actionError: String?

    public init(
        space: SpaceItem,
        account: AccountStore.Account?,
        selectedRepo: Binding<RepoEntry?> = .constant(nil),
        onDelete: (() -> Void)? = nil
    ) {
        self.space = space
        self.account = account
        self._selectedRepo = selectedRepo
        self.onDelete = onDelete
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if account == nil {
                    ContentUnavailableView(
                        "Account Unavailable",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("The owning account for this space is no longer available. Please sign in again.")
                    )
                    .padding(.top, 24)
                } else if model.isLoading && model.repos.isEmpty && model.errorState == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading space details…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                } else if let errorState = model.errorState {
                    errorStateView(errorState)
                } else {
                    reposSection

                    if let members = model.members {
                        Divider()
                        membersSection(members)
                    }
                }
            }
            .padding()
        }
        .id(space.id)
        .navigationTitle(space.skey)
        .task(id: "\(space.id)-\(account?.id ?? "")") {
            if let account {
                await model.load(space: space, account: account)
            }
        }
        .refreshable {
            if let account {
                await model.load(space: space, account: account)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if account != nil {
                    Button {
                        showingCreateRecordSheet = true
                    } label: {
                        Label("New Record", systemImage: "plus")
                    }
                    .help("Create Record in Space")
                }
            }
        }
        .sheet(isPresented: $showingCreateRecordSheet) {
            if let account {
                RecordEditorSheet(
                    space: space,
                    repo: RepoEntry(did: account.id, rev: "", hash: ""),
                    account: account,
                    mode: .create()
                ) {
                    Task {
                        await model.load(space: space, account: account)
                        if let myRepo = model.repos.first(where: { $0.did == account.id }) {
                            selectedRepo = myRepo
                        } else {
                            selectedRepo = RepoEntry(did: account.id, rev: "", hash: "")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddMemberSheet) {
            if let account {
                MemberEditor(
                    space: space,
                    account: account,
                    model: model
                )
            }
        }
        .confirmationDialog(
            "Remove Member",
            isPresented: Binding(
                get: { memberToRemove != nil },
                set: { if !$0 { memberToRemove = nil } }
            ),
            presenting: memberToRemove
        ) { did in
            Button("Remove \(did)", role: .destructive) {
                if let account {
                    Task {
                        do {
                            try await model.removeMember(did: did, space: space, account: account)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { did in
            Text("Are you sure you want to remove \(did) from this space?")
        }
        .confirmationDialog(
            "Delete Space",
            isPresented: $showingDeleteSpaceConfirmation
        ) {
            Button("Delete Space", role: .destructive) {
                if let account {
                    Task {
                        do {
                            let spaceListModel = accountStore.spaceModel(for: account.id)
                            try await spaceListModel.deleteSpace(space: space, account: account)
                            selectedRepo = nil
                            onDelete?()
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete space \"\(space.skey)\"? This action is irreversible.")
        }
        .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let actionError {
                Text(actionError)
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(space.skey)
                    .font(.title2.bold())
                Spacer()
                if space.isOwnAuthority {
                    Menu {
                        Button(role: .destructive) {
                            showingDeleteSpaceConfirmation = true
                        } label: {
                            Label("Delete Space…", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                }

                Text(space.isOwnAuthority ? "Owned Space" : "Shared Space")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(space.isOwnAuthority ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                    .foregroundStyle(space.isOwnAuthority ? .blue : .purple)
                    .clipShape(Capsule())
            }

            Text(space.spaceType)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Authority", value: space.authorityDID)
                LabeledContent("Type", value: space.spaceType)
                LabeledContent("Key", value: space.skey)
                LabeledContent("URI", value: space.ref.uriString())
            }
            .font(.caption)
            .padding(.top, 4)
        }
    }

    // MARK: - Error State Views

    @ViewBuilder
    private func errorStateView(_ errorState: SpaceDetailModel.ErrorState) -> some View {
        switch errorState {
        case .tombstone(let message):
            ContentUnavailableView {
                Label("Space Deleted", systemImage: "trash.slash.fill")
            } description: {
                Text("This space has been deleted by its authority.")
            } actions: {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)

        case .reconsentNeeded(let message):
            ContentUnavailableView {
                Label("Re-consent Required", systemImage: "lock.trianglebadge.exclamationmark.fill")
            } description: {
                Text("Your account requires updated authorization scopes to access this space.")
            } actions: {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)

        case .general(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)

                if let account {
                    Button("Retry") {
                        Task {
                            await model.load(space: space, account: account)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Repos Section

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Writer Repos")
                    .font(.headline)
                Spacer()
                Text("\(model.repos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.repos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No repos have written to this space yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if account != nil {
                        Button {
                            showingCreateRecordSheet = true
                        } label: {
                            Label("Create First Record", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.repos) { repo in
                        Button {
                            selectedRepo = repo
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(repo.did)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedRepo?.did == repo.did {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }

                                HStack(spacing: 12) {
                                    Label(repo.rev, systemImage: "clock.arrow.circlepath")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)

                                    Label(repo.hash, systemImage: "number")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selectedRepo?.did == repo.did ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Members Section

    private func membersSection(_ members: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Members")
                    .font(.headline)
                Spacer()
                Text("\(members.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if space.isOwnAuthority, account != nil {
                    Button {
                        showingAddMemberSheet = true
                    } label: {
                        Label("Add Member", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if members.isEmpty {
                Text("No members in this space.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(members, id: \.self) { memberDID in
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(memberDID)
                                .font(.system(.body, design: .monospaced))
                            Spacer()

                            if space.isOwnAuthority {
                                Button(role: .destructive) {
                                    memberToRemove = memberDID
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove Member")
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}
