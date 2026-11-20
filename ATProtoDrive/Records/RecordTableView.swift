//
//  RecordTableView.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct RecordTableView: View {
    let space: SpaceItem
    let repo: RepoEntry
    let account: AccountStore.Account?
    let refreshToken: Int
    var onBack: (() -> Void)?

    @State private var model = RecordListModel()
    @State private var selectedRecordID: RecordRow.ID?
    @State private var editorMode: RecordEditorSheet.Mode?
    @State private var recordToDelete: RecordRow?
    @State private var actionError: String?
    public init(
        space: SpaceItem,
        repo: RepoEntry,
        account: AccountStore.Account?,
        refreshToken: Int = 0,
        onBack: (() -> Void)? = nil
    ) {
        self.space = space
        self.repo = repo
        self.account = account
        self.refreshToken = refreshToken
        self.onBack = onBack
    }

    private var selectedRecord: RecordRow? {
        guard let selectedRecordID = selectedRecordID else { return nil }
        return model.rows.first(where: { $0.id == selectedRecordID })
    }

    private var isOwnRepo: Bool {
        repo.did == account?.id
    }
    public var body: some View {
        VStack(spacing: 0) {
            recordHeaderBar
            Divider()
            HSplitView {
                // Main Records Table
                VStack(spacing: 0) {
                    if model.isLoading && model.rows.isEmpty {
                        ProgressView("Loading records…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorState = model.errorState {
                        errorView(errorState)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.rows.isEmpty {
                        ContentUnavailableView {
                            Label("No Records", systemImage: "tablecells")
                        } description: {
                            Text("No records found in this repository.")
                        } actions: {
                            if account != nil && isOwnRepo {
                                Button {
                                    editorMode = .create()
                                } label: {
                                    Label("New Record", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(model.rows, selection: $selectedRecordID, sortOrder: $model.sortOrder) {
                            TableColumn("Collection", value: \.collection) { row in
                                Text(row.collection)
                                    .font(.system(.body, design: .monospaced))
                            }
                            .width(min: 150, ideal: 220)

                            TableColumn("Record Key", value: \.rkey) { row in
                                Text(row.rkey)
                                    .font(.system(.body, design: .monospaced))
                            }
                            .width(min: 120, ideal: 160)

                            TableColumn("CID", value: \.cid) { row in
                                Text(row.cid)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .width(min: 180, ideal: 260)
                        }
                        .contextMenu(forSelectionType: RecordRow.ID.self) { selectedIDs in
                            recordContextMenu(for: selectedIDs)
                        } primaryAction: { selectedIDs in
                            if let targetID = selectedIDs.first {
                                selectedRecordID = targetID
                            }
                        }
                    }
                }
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)

                // Right Inspector Panel
                RecordInspectorView(
                    record: selectedRecord,
                    commit: model.commit,
                    space: space,
                    repo: repo,
                    account: account,
                    model: model
                )
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 500, maxHeight: .infinity)
            }
        }
        .navigationTitle("\(space.skey) / \(repo.did)")
        .task(id: "\(space.id)-\(repo.did)-\(repo.rev)-\(repo.hash)-\(account?.id ?? "")-\(refreshToken)") {
            if let account = account {
                await model.load(space: space, repo: repo, account: account)
            }
        }
        .refreshable {
            if let account = account {
                await model.load(space: space, repo: repo, account: account)
            }
        }
        .sheet(item: $editorMode) { mode in
            if let account {
                RecordEditorSheet(
                    space: space,
                    repo: repo,
                    account: account,
                    model: model,
                    mode: mode
                )
            }
        }
        .confirmationDialog(
            "Delete Record",
            isPresented: Binding(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            ),
            presenting: recordToDelete
        ) { record in
            Button("Delete \(record.rkey)", role: .destructive) {
                if let account {
                    Task {
                        do {
                            try await model.deleteRecord(
                                space: space,
                                repo: repo,
                                collection: record.collection,
                                rkey: record.rkey,
                                account: account
                            )
                            if selectedRecordID == record.id {
                                selectedRecordID = nil
                            }
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Are you sure you want to delete record \"\(record.rkey)\" from collection \"\(record.collection)\"?")
        }
        .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let actionError {
                Text(actionError)
            }
        }
    }

    private var recordHeaderBar: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Label(space.skey, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Back to Space Overview")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(repo.did)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isOwnRepo ? "Your Repository (Read & Write)" : "Foreign Writer (Verified Read Only)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isOwnRepo {
                Button {
                    editorMode = .create()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(account == nil)
                .help("Create record in your repository")

                Button {
                    if let selectedRecord {
                        editorMode = .edit(row: selectedRecord)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedRecord == nil || account == nil)
                .help("Edit selected record")

                Button(role: .destructive) {
                    if let selectedRecord {
                        recordToDelete = selectedRecord
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedRecord == nil || account == nil)
                .help("Delete selected record")
            }

            if let account {
                Button {
                    Task {
                        await model.load(space: space, repo: repo, account: account)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isLoading)
                .help("Reload Records")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func errorView(_ errorState: RecordListModel.ErrorState) -> some View {
        switch errorState {
        case .repoNotFound(let message):
            ContentUnavailableView {
                Label("Repository Not Found", systemImage: "folder.badge.minus")
            } description: {
                Text(message)
            } actions: {
                if account != nil && isOwnRepo {
                    Button {
                        editorMode = .create()
                    } label: {
                        Label("Create First Record", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .tombstone(let message):
            ContentUnavailableView {
                Label("Space Deleted", systemImage: "trash")
            } description: {
                Text(message)
            }
        case .authorizationRefused(let message):
            ContentUnavailableView {
                Label("Access Denied", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                Text(message)
            } actions: {
                retryRecordsButton
            }
        case .tokenRejected(let message):
            ContentUnavailableView {
                Label("Token Rejected", systemImage: "network.badge.shield.half.filled")
            } description: {
                Text(message)
            } actions: {
                retryRecordsButton
            }
        case .reconsentNeeded(let message):
            ContentUnavailableView {
                Label("Authorization Required", systemImage: "lock.shield")
            } description: {
                Text(message)
            } actions: {
                retryRecordsButton
            }
        case .general(let message):
            ContentUnavailableView {
                Label("Error Loading Records", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                retryRecordsButton
            }
        }
    }

    @ViewBuilder
    private var retryRecordsButton: some View {
        if let account {
            Button("Retry") {
                Task {
                    await model.load(space: space, repo: repo, account: account)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func recordContextMenu(for selectedIDs: Set<RecordRow.ID>) -> some View {
        if let targetID = selectedIDs.first, let row = model.rows.first(where: { $0.id == targetID }) {
            ContextMenuEntriesView(
                items: RecordMenuDescriptors.recordRowMenu(
                    for: row,
                    isOwnRepo: isOwnRepo,
                    hasAccount: account != nil,
                    onDelete: {
                        recordToDelete = row
                    }
                )
            )
        }
    }
}
