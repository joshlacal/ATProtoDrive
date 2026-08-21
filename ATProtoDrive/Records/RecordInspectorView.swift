//
//  RecordInspectorView.swift
//  ATProtoDrive
//

import AppKit
import Foundation
import QuickLook
import SwiftUI
import Petrel
import UniformTypeIdentifiers

public struct RecordInspectorView: View {
    let record: RecordRow?
    let commit: (rev: String, hash: String)?
    let space: SpaceItem?
    let repo: RepoEntry?
    let account: AccountStore.Account?
    let model: RecordListModel?

    @State private var quickLookURL: URL?
    @State private var isLoadingBlob = false
    @State private var activeBlobCID: String?
    @State private var blobError: String?

    public init(
        record: RecordRow?,
        commit: (rev: String, hash: String)? = nil,
        space: SpaceItem? = nil,
        repo: RepoEntry? = nil,
        account: AccountStore.Account? = nil,
        model: RecordListModel? = nil
    ) {
        self.record = record
        self.commit = commit
        self.space = space
        self.repo = repo
        self.account = account
        self.model = model
    }

    public var body: some View {
        if let record = record {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(record.collection)
                            .font(.headline)
                        Text("/ \(record.rkey)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("CID:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(record.cid)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contextMenu {
                        ContextMenuEntriesView(items: RecordMenuDescriptors.recordInspectorCIDMenu(for: record))
                    }

                    HStack(spacing: 8) {
                        Text("URI:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(record.uri)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contextMenu {
                        ContextMenuEntriesView(items: RecordMenuDescriptors.recordInspectorURIMenu(for: record))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Blob refs section if present
                if !record.blobEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Blob References (\(record.blobEntries.count))")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isLoadingBlob {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        ForEach(record.blobEntries) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.zipper")
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.cid)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if let mime = entry.mimeType {
                                        Text(mime)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Button {
                                    quickLookBlob(entry)
                                } label: {
                                    Image(systemName: "eye")
                                }
                                .buttonStyle(.borderless)
                                .help("Quick Look")
                                .disabled(isLoadingBlob || account == nil)

                                Button {
                                    downloadBlob(entry)
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Download…")
                                .disabled(isLoadingBlob || account == nil)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(activeBlobCID == entry.cid ? Color.accentColor.opacity(0.1) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contextMenu {
                                ContextMenuEntriesView(
                                    items: RecordMenuDescriptors.blobRefMenu(
                                        for: entry,
                                        hasAccount: account != nil,
                                        onDownload: {
                                            downloadBlob(entry)
                                        },
                                        onQuickLook: {
                                            quickLookBlob(entry)
                                        }
                                    )
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))

                    Divider()
                }

                // JSON Content View
                ScrollView {
                    Text(record.json)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu {
                    ContextMenuEntriesView(items: RecordMenuDescriptors.recordInspectorJSONMenu(for: record))
                }

                Divider()

                // Commit Footer
                if let commit = commit {
                    HStack(spacing: 12) {
                        Label(commit.rev, systemImage: "clock.arrow.circlepath")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Label(commit.hash, systemImage: "number")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
            .frame(minWidth: 260)
            .quickLookPreview($quickLookURL)
            .alert("Blob Action Error", isPresented: Binding(
                get: { blobError != nil },
                set: { if !$0 { blobError = nil } }
            )) {
                Button("OK", role: .cancel) { blobError = nil }
            } message: {
                if let blobError {
                    Text(blobError)
                }
            }
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "doc.text",
                description: Text("Select a record to inspect its value and metadata.")
            )
            .frame(minWidth: 260)
        }
    }

    private func downloadBlob(_ entry: BlobRefEntry) {
        guard let space = space, let repo = repo, let account = account else { return }
        let savePanel = NSSavePanel()
        savePanel.title = "Save Blob"
        savePanel.nameFieldStringValue = BlobFileHelper.suggestedFilename(cid: entry.cid, mimeType: entry.mimeType)
        if let ext = BlobFileHelper.fileExtension(forMimeType: entry.mimeType),
           let utType = UTType(filenameExtension: ext) {
            savePanel.allowedContentTypes = [utType]
        }
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            let modelToUse = model ?? RecordListModel()
            activeBlobCID = entry.cid
            isLoadingBlob = true
            Task {
                defer {
                    isLoadingBlob = false
                    activeBlobCID = nil
                }
                do {
                    let data = try await modelToUse.getBlob(
                        space: space,
                        repo: repo,
                        cid: entry.cid,
                        account: account
                    )
                    try BlobFileHelper.saveBlobData(data, to: targetURL)
                } catch {
                    blobError = error.localizedDescription
                }
            }
        }
    }

    private func quickLookBlob(_ entry: BlobRefEntry) {
        guard let space = space, let repo = repo, let account = account else { return }
        let modelToUse = model ?? RecordListModel()
        activeBlobCID = entry.cid
        isLoadingBlob = true
        Task {
            defer {
                isLoadingBlob = false
                activeBlobCID = nil
            }
            do {
                let data = try await modelToUse.getBlob(
                    space: space,
                    repo: repo,
                    cid: entry.cid,
                    account: account
                )
                let tempURL = try BlobFileHelper.writeTempFile(
                    cid: entry.cid,
                    mimeType: entry.mimeType,
                    data: data
                )
                await MainActor.run {
                    quickLookURL = tempURL
                }
            } catch {
                blobError = error.localizedDescription
            }
        }
    }
}
