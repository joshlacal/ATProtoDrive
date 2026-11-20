//
//  PublicRecordEditorSheet.swift
//  ATProtoDrive
//

import Foundation
import Petrel
import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct PublicRecordEditorSheet: View {
    public enum Mode: Identifiable, Hashable, Sendable {
        case create(defaultCollection: String? = nil)
        case edit(record: RecordRow)

        public var id: String {
            switch self {
            case .create(let defaultCollection):
                return "create-\(defaultCollection ?? "")"
            case .edit(let record):
                return "edit-\(record.uri)-\(record.cid)"
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

    public let repository: ResolvedRepository
    public let account: AccountStore.Account
    public let mode: Mode
    public let mutationService: PublicRecordMutationService
    public var onRefreshRequested: (@MainActor () async -> Void)?
    public var onSaved: (() -> Void)?

    @State private var collection: String
    @State private var rkey: String
    @State private var jsonText: String
    @State private var isSubmitting: Bool = false
    @State private var isRefreshingAfterConflict: Bool = false
    @State private var liveValidationError: String?
    @State private var conflictMessage: String?
    @State private var apiError: String?

    public init(
        repository: ResolvedRepository,
        account: AccountStore.Account,
        mode: Mode,
        mutationService: PublicRecordMutationService = PublicRecordMutationService(),
        onRefreshRequested: (@MainActor () async -> Void)? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.repository = repository
        self.account = account
        self.mode = mode
        self.mutationService = mutationService
        self.onRefreshRequested = onRefreshRequested
        self.onSaved = onSaved

        switch mode {
        case .create(let defaultCollection):
            let trimmed = defaultCollection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _collection = State(initialValue: trimmed)
            _rkey = State(initialValue: "")
            if trimmed.isEmpty {
                _jsonText = State(initialValue: "{\n  \n}")
            } else {
                _jsonText = State(initialValue: "{\n  \"$type\": \"\(trimmed)\"\n}")
            }
        case .edit(let record):
            _collection = State(initialValue: record.collection)
            _rkey = State(initialValue: record.rkey)
            _jsonText = State(initialValue: record.json)
        }
    }

    private var isOwner: Bool {
        PublicRecordMutationService.canMutate(repositoryDID: repository.did, with: account)
    }

    private var expectedCID: String? {
        guard case .edit(let record) = mode else { return nil }
        return record.cid
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !isRefreshingAfterConflict
            && isOwner
            && !collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && liveValidationError == nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    publicRepositoryNotice

                    if !isOwner {
                        notOwnerBanner
                    }

                    if let expectedCID {
                        casBadge(cid: expectedCID)
                    }

                    if let conflictMessage {
                        conflictBanner(message: conflictMessage)
                    }

                    identityFields

                    jsonEditorSection

                    if let liveValidationError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(liveValidationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }

                    if let apiError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text(apiError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding()
            }

            Divider()
            footerActions
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 580)
        .onAppear {
            revalidateJSON()
        }
        .onChange(of: jsonText) { _, _ in
            revalidateJSON()
        }
        .onChange(of: collection) { _, _ in
            revalidateJSON()
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.isEditing ? "Edit Public Record" : "New Public Record")
                    .font(.headline)
                Text("\(repository.handle ?? repository.did) · \(repository.did)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
    }

    private var publicRepositoryNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Public Repository (World-Readable)")
                    .font(.subheadline.weight(.semibold))
                Text("Records saved here are publicly visible on the AT Protocol network and indexed by relays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var notOwnerBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.red)
            Text("Read-only: signed-in account \(account.id) does not own repository \(repository.did).")
                .font(.caption)
                .foregroundStyle(.red)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func casBadge(cid: String) -> some View {
        HStack(spacing: 8) {
            Label("CAS swapRecord", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
            Text(cid)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("Atomic compare-and-swap protection: saving fails safely if the remote record's CID no longer matches.")
    }

    private func conflictBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Conflict Detected — Record Changed Remotely")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }

            if let onRefreshRequested {
                HStack {
                    Spacer()
                    if isRefreshingAfterConflict {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Refresh & Close") {
                        Task {
                            isRefreshingAfterConflict = true
                            await onRefreshRequested()
                            isRefreshingAfterConflict = false
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRefreshingAfterConflict)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var identityFields: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Collection (NSID)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                TextField("e.g. app.bsky.feed.post", text: $collection)
                    .textFieldStyle(.roundedBorder)
                    .disabled(mode.isEditing || isSubmitting)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(mode.isEditing ? "Record Key (rkey)" : "Record Key (Optional)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                TextField(mode.isEditing ? "rkey" : "Auto-generated TID if empty", text: $rkey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(mode.isEditing || isSubmitting)
                    .autocorrectionDisabled()
            }
        }
    }

    private var jsonEditorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Record JSON Value")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                validationStatusPill

                Spacer()

                Button {
                    formatJSON()
                } label: {
                    Label("Format JSON", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSubmitting)
            }

            TextEditor(text: $jsonText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(editorBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            liveValidationError != nil ? Color.red.opacity(0.75) : Color.secondary.opacity(0.25),
                            lineWidth: 1
                        )
                )
                .disabled(isSubmitting)
                .frame(minHeight: 210)
        }
    }

    @ViewBuilder
    private var validationStatusPill: some View {
        if collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Enter collection NSID")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        } else if liveValidationError == nil {
            Label("Valid JSON", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
        } else {
            Label("Invalid", systemImage: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private var editorBackgroundColor: Color {
        #if os(macOS)
        Color(NSColor.textBackgroundColor)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }

    private var footerActions: some View {
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
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func revalidateJSON() {
        let trimmedCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollection.isEmpty else {
            liveValidationError = nil
            return
        }
        do {
            _ = try PublicRecordMutationService.validateJSON(jsonText, collection: trimmedCollection)
            liveValidationError = nil
        } catch {
            liveValidationError = error.localizedDescription
        }
    }

    private func formatJSON() {
        let trimmedCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmedCollection.isEmpty {
                _ = try PublicRecordMutationService.validateJSON(jsonText, collection: trimmedCollection)
            }
            guard let data = jsonText.data(using: .utf8) else { return }
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            let prettyData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            if let prettyString = String(data: prettyData, encoding: .utf8) {
                jsonText = prettyString
            }
            revalidateJSON()
        } catch {
            liveValidationError = error.localizedDescription
        }
    }

    private func submit() async {
        conflictMessage = nil
        apiError = nil
        revalidateJSON()
        guard liveValidationError == nil else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            switch mode {
            case .create:
                _ = try await mutationService.createRecord(
                    targetRepoDID: repository.did,
                    collection: collection,
                    rkey: rkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rkey,
                    json: jsonText,
                    account: account
                )
            case .edit(let record):
                _ = try await mutationService.updateRecord(
                    targetRepoDID: repository.did,
                    collection: record.collection,
                    rkey: record.rkey,
                    expectedCID: record.cid,
                    json: jsonText,
                    account: account
                )
            }
            onSaved?()
            dismiss()
        } catch let mutationError as PublicRecordMutationError {
            if case .conflictDetected(let message) = mutationError {
                conflictMessage = message
            } else {
                apiError = mutationError.localizedDescription
            }
        } catch {
            if let xrpc = error as? ATProtoXRPCError {
                apiError = xrpc.errorDescription ?? xrpc.error
            } else {
                apiError = error.localizedDescription
            }
        }
    }
}
