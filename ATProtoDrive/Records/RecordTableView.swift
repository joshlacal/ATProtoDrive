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

    @State private var model = RecordListModel()
    @State private var selectedRecordID: RecordRow.ID?
    @State private var editorMode: RecordEditorSheet.Mode?
    @State private var recordToDelete: RecordRow?
    @State private var actionError: String?
    public init(
        space: SpaceItem,
        repo: RepoEntry,
        account: AccountStore.Account?
    ) {
        self.space = space
        self.repo = repo
        self.account = account
    }

    private var selectedRecord: RecordRow? {
        guard let selectedRecordID = selectedRecordID else { return nil }
        return model.rows.first(where: { $0.id == selectedRecordID })
    }

    private var isOwnRepo: Bool {
        repo.did == account?.id
    }
    public var body: some View {
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
                    ContentUnavailableView(
                        "No Records",
                        systemImage: "tablecells",
                        description: Text("No records found in this repository.")
                    )
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
                        if let targetID = selectedIDs.first, let row = model.rows.first(where: { $0.id == targetID }) {
                            Button {
                                PasteboardHelper.copyString(row.uri)
                            } label: {
                                Label("Copy at:// URI", systemImage: "link")
                            }

                            Button {
                                PasteboardHelper.copyString(row.cid)
                            } label: {
                                Label("Copy CID", systemImage: "doc.on.doc")
                            }

                            Button {
                                PasteboardHelper.copyString(row.json)
                            } label: {
                                Label("Copy JSON", systemImage: "curlybraces")
                            }

                            Divider()

                            Button(role: .destructive) {
                                recordToDelete = row
                            } label: {
                                Label("Delete Record", systemImage: "trash")
                            }
                            .disabled(!isOwnRepo || account == nil)
                        }
                    } primaryAction: { selectedIDs in
                        if let targetID = selectedIDs.first {
                            selectedRecordID = targetID
                        }
                    }
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

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
        .navigationTitle("\(space.skey) / \(repo.did)")
        .task(id: "\(space.id)-\(repo.did)-\(repo.rev)-\(repo.hash)-\(account?.id ?? "")") {
            if let account = account {
                await model.load(space: space, repo: repo, account: account)
            }
        }
        .refreshable {
            if let account = account {
                await model.load(space: space, repo: repo, account: account)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editorMode = .create()
                } label: {
                    Label("New Record", systemImage: "plus")
                }
                .disabled(account == nil)

                Button {
                    if let selectedRecord {
                        editorMode = .edit(row: selectedRecord)
                    }
                } label: {
                    Label("Edit Record", systemImage: "pencil")
                }
                .disabled(selectedRecord == nil || account == nil || !isOwnRepo)
                .help(isOwnRepo ? "Edit selected record" : "Cannot edit records authored by other accounts")

                Button(role: .destructive) {
                    if let selectedRecord {
                        recordToDelete = selectedRecord
                    }
                } label: {
                    Label("Delete Record", systemImage: "trash")
                }
                .disabled(selectedRecord == nil || account == nil || !isOwnRepo)
                .help(isOwnRepo ? "Delete selected record" : "Cannot delete records authored by other accounts")
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

    @ViewBuilder
    private func errorView(_ errorState: RecordListModel.ErrorState) -> some View {
        switch errorState {
        case .repoNotFound(let message):
            ContentUnavailableView {
                Label("Repository Not Found", systemImage: "folder.badge.minus")
            } description: {
                Text(message)
            }
        case .tombstone(let message):
            ContentUnavailableView {
                Label("Space Deleted", systemImage: "trash")
            } description: {
                Text(message)
            }
        case .reconsentNeeded(let message):
            ContentUnavailableView {
                Label("Authorization Required", systemImage: "lock.shield")
            } description: {
                Text(message)
            }
        case .general(let message):
            ContentUnavailableView {
                Label("Error Loading Records", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}
