//
//  RecordEditorSheet.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel
import UniformTypeIdentifiers

public struct RecordEditorSheet: View {
    public enum Mode: Identifiable, Equatable, Sendable {
        case create(collection: String = "", rkey: String = "", initialJSON: String = "{\n  \n}")
        case edit(row: RecordRow)

        public var id: String {
            switch self {
            case .create: return "create"
            case .edit(let row): return "edit-\(row.id)"
            }
        }

        public var isEditing: Bool {
            switch self {
            case .create: return false
            case .edit: return true
            }
        }
    }
    @Environment(\.dismiss) private var dismiss

    let space: SpaceItem
    let repo: RepoEntry
    let account: AccountStore.Account
    let model: RecordListModel
    let mode: Mode
    var onSaved: (() -> Void)?

    @State private var collection: String
    @State private var rkey: String
    @State private var jsonText: String
    @State private var textSelection: TextSelection?
    @State private var isSubmitting: Bool = false
    @State private var isUploadingBlob: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var validationError: String?
    @State private var apiError: String?

    public init(
        space: SpaceItem,
        repo: RepoEntry,
        account: AccountStore.Account,
        model: RecordListModel,
        mode: Mode = .create(),
        onSaved: (() -> Void)? = nil
    ) {
        self.space = space
        self.repo = repo
        self.account = account
        self.model = model
        self.mode = mode
        self.onSaved = onSaved

        switch mode {
        case .create(let initialCollection, let initialRKey, let initialJSON):
            _collection = State(initialValue: initialCollection)
            _rkey = State(initialValue: initialRKey)
            _jsonText = State(initialValue: initialJSON)
        case .edit(let row):
            _collection = State(initialValue: row.collection)
            _rkey = State(initialValue: row.rkey)
            _jsonText = State(initialValue: row.json)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(mode.isEditing ? "Edit Record" : "New Record")
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

            // Form Fields
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Collection (NSID)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("e.g. app.bsky.feed.post", text: $collection)
                            .textFieldStyle(.roundedBorder)
                            .disabled(mode.isEditing) // Primary key cannot change in edit mode
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.isEditing ? "Record Key (rkey)" : "Record Key (Optional)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField(mode.isEditing ? "rkey" : "Auto-generated if empty", text: $rkey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(mode.isEditing)
                            .autocorrectionDisabled()
                    }
                }

                // Editor Toolbar
                HStack {
                    Text("Record JSON Value")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isUploadingBlob {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Uploading Blob…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Upload Blob…", systemImage: "arrow.up.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isUploadingBlob || isSubmitting)

                    Button {
                        formatJSON()
                    } label: {
                        Label("Format JSON", systemImage: "curlybraces")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isUploadingBlob || isSubmitting)
                }

                // JSON Text Editor
                TextEditor(text: $jsonText, selection: $textSelection)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(validationError != nil ? Color.red : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .disabled(isUploadingBlob || isSubmitting)
                    .frame(minHeight: 200)

                // Error Displays
                if let validationError = validationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(validationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let apiError = apiError {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(apiError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()

            Divider()

            // Bottom Actions
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

                Button(mode.isEditing ? "Save Changes" : "Create Record") {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 520)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await handleBlobUpload(from: url)
                }
            case .failure(let error):
                apiError = "File selection failed: \(error.localizedDescription)"
            }
        }
    }

    private func formatJSON() {
        validationError = nil
        do {
            _ = try RecordListModel.validateRecordJSON(jsonText, collection: collection)
            if let data = jsonText.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                jsonText = prettyString
            }
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func handleBlobUpload(from fileURL: URL) async {
        apiError = nil

        var replacementRange: Range<String.Index>? = nil
        if let indices = textSelection?.indices {
            switch indices {
            case .selection(let range):
                replacementRange = range
            default:
                break
            }
        }

        guard let replacementRange else {
            apiError = "Please place the cursor in the JSON editor where the blob reference should be inserted."
            return
        }

        isUploadingBlob = true
        defer { isUploadingBlob = false }

        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

            let blob = try await RecordListModel.performUploadBlob(
                data: data,
                mimeType: mimeType,
                account: account
            )

            // Ensure range bounds remain valid within jsonText
            guard replacementRange.lowerBound >= jsonText.startIndex && replacementRange.upperBound <= jsonText.endIndex else {
                apiError = "Cursor selection is no longer valid. Please place the cursor in the JSON editor."
                return
            }

            jsonText = try RecordListModel.spliceBlobRef(into: jsonText, blob: blob, replacementRange: replacementRange)
        } catch {
            if let xrpc = error as? ATProtoXRPCError {
                apiError = "Blob upload error: \(xrpc.errorDescription ?? xrpc.error)"
            } else {
                apiError = "Blob upload error: \(error.localizedDescription)"
            }
        }
    }

    private func submit() async {
        validationError = nil
        apiError = nil

        // Validate JSON with JSONSerialization BEFORE calling API
        do {
            _ = try RecordListModel.validateRecordJSON(jsonText, collection: collection)
        } catch {
            validationError = error.localizedDescription
            return // DO NOT call API if JSON is invalid
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            switch mode {
            case .create:
                _ = try await model.createRecord(
                    space: space,
                    repo: repo,
                    collection: collection,
                    rkey: rkey.isEmpty ? nil : rkey,
                    jsonText: jsonText,
                    account: account
                )
            case .edit:
                _ = try await model.putRecord(
                    space: space,
                    repo: repo,
                    collection: collection,
                    rkey: rkey,
                    jsonText: jsonText,
                    account: account
                )
            }
            onSaved?()
            dismiss()
        } catch {
            if let xrpc = error as? ATProtoXRPCError {
                apiError = xrpc.errorDescription ?? xrpc.error
            } else {
                apiError = error.localizedDescription
            }
        }
    }
}
