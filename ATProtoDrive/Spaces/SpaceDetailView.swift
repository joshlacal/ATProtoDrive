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
    let refreshToken: Int
    var onDelete: (() -> Void)?

    @State private var model = SpaceDetailModel()
    @State private var recordListModel = RecordListModel()
    @State private var showingAddMemberSheet = false
    @State private var showingCreateRecordSheet = false
    @State private var showingEditPolicySheet = false
    @State private var memberPendingPermissionEdit: SpaceMemberEntry?
    @State private var updatingMemberDIDs: Set<String> = []
    @State private var memberToRemove: String?
    @State private var showingDeleteSpaceConfirmation = false
    @State private var actionError: String?

    private var isManagedSpace: Bool {
        if case .managed = model.policySummary {
            return true
        }
        return false
    }

    public init(
        space: SpaceItem,
        account: AccountStore.Account?,
        selectedRepo: Binding<RepoEntry?> = .constant(nil),
        refreshToken: Int = 0,
        onDelete: (() -> Void)? = nil
    ) {
        self.space = space
        self.account = account
        self._selectedRepo = selectedRepo
        self.refreshToken = refreshToken
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
        .task(id: "\(space.id)-\(account?.id ?? "")-\(refreshToken)") {
            if let account {
                await model.load(space: space, account: account)
            }
        }
        .refreshable {
            if let account {
                await model.load(space: space, account: account)
            }
        }
        .sheet(isPresented: $showingCreateRecordSheet) {
            if let account {
                RecordEditorSheet(
                    space: space,
                    repo: RepoEntry(did: account.id, rev: "", hash: ""),
                    account: account,
                    model: recordListModel,
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
        .sheet(isPresented: $showingEditPolicySheet) {
            if let account {
                SpacePolicyEditorSheet(
                    space: space,
                    currentPolicy: model.policySummary,
                    account: account,
                    model: model
                )
            }
        }
        .sheet(item: $memberPendingPermissionEdit) { memberEntry in
            if let account {
                MemberPermissionsEditorSheet(
                    member: memberEntry,
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
            HStack(alignment: .center, spacing: 8) {
                Text(space.skey)
                    .font(.title2.bold())

                Text(space.isOwnAuthority ? "Owned Space" : "Shared Space")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(space.isOwnAuthority ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                    .foregroundStyle(space.isOwnAuthority ? .blue : .purple)
                    .clipShape(Capsule())

                if let policySummary = model.policySummary {
                    Text(policySummary.title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.14))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                Spacer()

                if let account {
                    if space.isOwnAuthority && !isManagedSpace {
                        Button {
                            showingEditPolicySheet = true
                        } label: {
                            Label("Edit Policy…", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Edit Space Access Policy")
                    }

                    Button {
                        showingCreateRecordSheet = true
                    } label: {
                        Label("New Record", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Create Record in Space")

                    Button {
                        Task {
                            await model.load(space: space, account: account)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isLoading)
                    .help("Reload Space Details")
                }

                Menu {
                    if space.isOwnAuthority && account != nil {
                        Button {
                            showingEditPolicySheet = true
                        } label: {
                            Label(
                                isManagedSpace ? "Edit Policy (Managed Space)…" : "Edit Policy…",
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        Divider()
                    }
                    ContextMenuEntriesView(
                        items: RecordMenuDescriptors.spaceRowMenu(
                            for: space,
                            onDelete: {
                                showingDeleteSpaceConfirmation = true
                            }
                        )
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
            }

            Text(space.spaceType)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Authority", value: space.authorityDID)
                    .textSelection(.enabled)
                LabeledContent("Type", value: space.spaceType)
                    .textSelection(.enabled)
                LabeledContent("Key", value: space.skey)
                    .textSelection(.enabled)
                LabeledContent("URI", value: space.ref.uriString())
                    .textSelection(.enabled)
                    .contextMenu {
                        ContextMenuEntriesView(items: RecordMenuDescriptors.spaceRowMenu(for: space))
                    }
                if let spaceRev = space.spaceRev, !spaceRev.isEmpty {
                    LabeledContent("Space Revision", value: spaceRev)
                        .textSelection(.enabled)
                }
                if let policySummary = model.policySummary {
                    policyMetadataRows(policySummary)
                }
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .contextMenu {
            ContextMenuEntriesView(items: RecordMenuDescriptors.spaceRowMenu(for: space))
        }
    }

    @ViewBuilder
    private func policyMetadataRows(_ policy: SpacePolicySummary) -> some View {
        LabeledContent("Policy", value: policy.title)
        switch policy {
        case .personal:
            EmptyView()
        case let .memberList(_, _, allowedApps, publishPolicy, publishMembers):
            if !allowedApps.isEmpty {
                LabeledContent("Allowed Apps", value: allowedApps.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            if publishPolicy || publishMembers {
                let flags = [
                    publishPolicy ? "policy" : nil,
                    publishMembers ? "members" : nil
                ].compactMap { $0 }.joined(separator: ", ")
                LabeledContent("Published", value: flags)
            }
        case let .managed(managingApp, publishPolicy):
            LabeledContent("Managing App", value: managingApp)
                .textSelection(.enabled)
            if publishPolicy {
                LabeledContent("Published", value: "policy")
            }
        case .other:
            EmptyView()
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

        case .authorizationRefused(let message):
            ContentUnavailableView {
                Label("Access Denied", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                Text("This space was not found, or you do not have access to it.")
            } actions: {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        if let account {
                            Button("Retry") {
                                Task {
                                    await model.load(space: space, account: account)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        if let ownRepo = space.ownRepoEntry {
                            Button("Browse My Records (OAuth)") {
                                selectedRepo = ownRepo
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(.vertical, 24)

        case .tokenRejected(let message):
            ContentUnavailableView {
                Label("Token Rejected", systemImage: "network.badge.shield.half.filled")
            } description: {
                Text(message)
            } actions: {
                if let account {
                    Button("Retry") {
                        Task {
                            await model.load(space: space, account: account)
                        }
                    }
                    .buttonStyle(.bordered)
                }
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

                HStack(spacing: 8) {
                    if let account {
                        Button("Retry") {
                            Task {
                                await model.load(space: space, account: account)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let ownRepo = space.ownRepoEntry {
                        Button("Browse My Records (OAuth)") {
                            selectedRepo = ownRepo
                        }
                        .buttonStyle(.borderedProminent)
                    }
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
                    HStack(spacing: 8) {
                        if let ownRepo = space.ownRepoEntry {
                            Button {
                                selectedRepo = ownRepo
                            } label: {
                                Label("Browse My Records (OAuth)", systemImage: "folder")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
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
                                    if repo.did == account?.id {
                                        Text("You")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                    Spacer()
                                    verificationBadge(for: repo)
                                    if account != nil {
                                        Button {
                                            Task {
                                                do {
                                                    _ = try await model.verifyRepo(repo: repo, space: space, account: account!)
                                                } catch {
                                                    actionError = error.localizedDescription
                                                }
                                            }
                                        } label: {
                                            Label("Verify", systemImage: "checkmark.shield")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .disabled(model.verifyingRepoDIDs.contains(repo.did))
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private func verificationBadge(for repo: RepoEntry) -> some View {
        if model.verifyingRepoDIDs.contains(repo.did) {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Verifying…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        } else if let report = model.verificationReport(for: repo) {
            switch report.outcome {
            case .verified(let count):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Verified (\(count) recs)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
                .help("Repository archive and digest verified successfully for revision \(report.rev)")
            case .signatureInvalid:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Invalid Signature")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
                .help("Author signature verification failed")
            case .hashMismatch(let expected, let computed):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Hash Mismatch")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
                .help("Expected: \(expected)\nComputed: \(computed)")
            case .malformedArchive(let errorMsg):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Malformed archive")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
                .help(errorMsg)
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
                let entriesByDID = Dictionary(
                    uniqueKeysWithValues: (model.memberEntries ?? []).map { ($0.did, $0) }
                )
                VStack(spacing: 6) {
                    ForEach(members, id: \.self) { memberDID in
                        let entry = entriesByDID[memberDID] ?? SpaceMemberEntry(did: memberDID, read: true, write: true)
                        let isUpdating = updatingMemberDIDs.contains(memberDID)
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(memberDID)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()

                            if let storedEntry = entriesByDID[memberDID] {
                                HStack(spacing: 4) {
                                    if storedEntry.read {
                                        Text("Read")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.14))
                                            .clipShape(Capsule())
                                    }
                                    if storedEntry.write {
                                        Text("Write")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.14))
                                            .foregroundStyle(.blue)
                                            .clipShape(Capsule())
                                    }
                                    if !storedEntry.read && !storedEntry.write {
                                        Text("No Access")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.14))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    }
                                }
                            }

                            if space.isOwnAuthority, let account {
                                if isUpdating {
                                    ProgressView()
                                        .controlSize(.mini)
                                }

                                Menu {
                                    Button {
                                        Task {
                                            await applyMemberPermissions(
                                                did: memberDID,
                                                read: true,
                                                write: true,
                                                account: account
                                            )
                                        }
                                    } label: {
                                        if entry.read && entry.write {
                                            Label("Read & Write", systemImage: "checkmark")
                                        } else {
                                            Text("Read & Write")
                                        }
                                    }

                                    Button {
                                        Task {
                                            await applyMemberPermissions(
                                                did: memberDID,
                                                read: true,
                                                write: false,
                                                account: account
                                            )
                                        }
                                    } label: {
                                        if entry.read && !entry.write {
                                            Label("Read Only", systemImage: "checkmark")
                                        } else {
                                            Text("Read Only")
                                        }
                                    }

                                    Button {
                                        Task {
                                            await applyMemberPermissions(
                                                did: memberDID,
                                                read: false,
                                                write: true,
                                                account: account
                                            )
                                        }
                                    } label: {
                                        if !entry.read && entry.write {
                                            Label("Write Only", systemImage: "checkmark")
                                        } else {
                                            Text("Write Only")
                                        }
                                    }

                                    Button {
                                        Task {
                                            await applyMemberPermissions(
                                                did: memberDID,
                                                read: false,
                                                write: false,
                                                account: account
                                            )
                                        }
                                    } label: {
                                        if !entry.read && !entry.write {
                                            Label("No Access", systemImage: "checkmark")
                                        } else {
                                            Text("No Access")
                                        }
                                    }

                                    Divider()

                                    Button {
                                        memberPendingPermissionEdit = entry
                                    } label: {
                                        Label("Edit Permissions…", systemImage: "slider.horizontal.3")
                                    }
                                } label: {
                                    Label("Permissions", systemImage: "slider.horizontal.3")
                                        .labelStyle(.iconOnly)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(isUpdating)
                                .help("Edit Member Read/Write Permissions")

                                Button(role: .destructive) {
                                    memberToRemove = memberDID
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(isUpdating)
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

    private func applyMemberPermissions(
        did: String,
        read: Bool,
        write: Bool,
        account: AccountStore.Account
    ) async {
        updatingMemberDIDs.insert(did)
        defer { updatingMemberDIDs.remove(did) }

        do {
            try await model.updateMemberPermissions(
                did: did,
                read: read,
                write: write,
                space: space,
                account: account
            )
        } catch {
            if let xrpc = error as? ATProtoXRPCError {
                actionError = xrpc.errorDescription ?? xrpc.error
            } else {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct MemberPermissionsEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let member: SpaceMemberEntry
    let space: SpaceItem
    let account: AccountStore.Account
    let model: SpaceDetailModel

    @State private var canRead: Bool
    @State private var canWrite: Bool
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    init(
        member: SpaceMemberEntry,
        space: SpaceItem,
        account: AccountStore.Account,
        model: SpaceDetailModel
    ) {
        self.member = member
        self.space = space
        self.account = account
        self.model = model
        _canRead = State(initialValue: member.read)
        _canWrite = State(initialValue: member.write)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Member Permissions")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                Section {
                    LabeledContent("Member DID", value: member.did)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Member")
                        .font(.subheadline.bold())
                }

                Section {
                    Toggle("Allow Read", isOn: $canRead)
                    Toggle("Allow Write", isOn: $canWrite)
                } header: {
                    Text("Permissions")
                        .font(.subheadline.bold())
                } footer: {
                    Text("Updates are applied via com.atproto.memberspace.putMembers for space \(space.skey).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                Button("Save Permissions") {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 280, idealHeight: 320)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await model.updateMemberPermissions(
                did: member.did,
                read: canRead,
                write: canWrite,
                space: space,
                account: account
            )
            dismiss()
        } catch {
            if let xrpc = error as? ATProtoXRPCError {
                errorMessage = xrpc.errorDescription ?? xrpc.error
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
