//
//  MemberEditor.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct MemberEditor: View {
    @Environment(\.dismiss) private var dismiss

    let space: SpaceItem
    let account: AccountStore.Account
    var onMemberAdded: (() -> Void)?

    @State private var identifier: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        space: SpaceItem,
        account: AccountStore.Account,
        onMemberAdded: (() -> Void)? = nil
    ) {
        self.space = space
        self.account = account
        self.onMemberAdded = onMemberAdded
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Member to Space")
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
                    TextField("Member DID or Handle", text: $identifier, prompt: Text("alice.bsky.social or did:plc:..."))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    Text("Handles will be resolved automatically to their DID using ATProto DID resolution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Member Identifier")
                        .font(.subheadline.bold())
                } footer: {
                    Text("Target space: \(space.skey) (\(space.authorityDID))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
            }

            Divider()
                .padding(.top, 8)

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

                Button("Add Member") {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 260, idealHeight: 290)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await SpaceDetailModel.performAddMember(
                space: space,
                identifier: identifier,
                account: account
            )
            onMemberAdded?()
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
