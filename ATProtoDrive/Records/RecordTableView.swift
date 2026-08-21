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
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

            // Right Inspector Panel
            RecordInspectorView(
                record: selectedRecord,
                commit: model.commit
            )
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 500, maxHeight: .infinity)
        }
        .navigationTitle("\(space.skey) / \(repo.did)")
        .task(id: "\(space.id)-\(repo.did)-\(account?.id ?? "")") {
            if let account = account {
                await model.load(space: space, repo: repo, account: account)
            }
        }
        .refreshable {
            if let account = account {
                await model.load(space: space, repo: repo, account: account)
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
