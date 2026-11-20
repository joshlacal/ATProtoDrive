//
//  CreateSpaceSheet.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct CreateSpaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accountStore

    let account: AccountStore.Account
    var onCreated: ((SpaceRef) -> Void)?

    @State private var spaceType: String = "space.swan.drive"
    @State private var skey: String = "self"
    @State private var policy: SpacePolicyOption = .memberList
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        account: AccountStore.Account,
        onCreated: ((SpaceRef) -> Void)? = nil
    ) {
        self.account = account
        self.onCreated = onCreated
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create New Space")
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
                    TextField("Space Type (NSID)", text: $spaceType, prompt: Text("e.g. space.swan.drive"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    TextField("Space Key (skey)", text: $skey, prompt: Text("self (leave empty for auto TID)"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                } header: {
                    Text("Space Identity")
                        .font(.subheadline.bold())
                } footer: {
                    Text("The space authority will be your account DID: \(account.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Policy", selection: $policy) {
                        ForEach(SpacePolicyOption.allCases) { opt in
                            Text(opt.displayName).tag(opt)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(policy.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("App Access", value: policy.appAccessSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Access Control")
                        .font(.subheadline.bold())
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

                Button("Create Space") {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || spaceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420, idealHeight: 460)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let spaceListModel = accountStore.spaceModel(for: account.id)
            let ref = try await spaceListModel.createSpace(
                spaceType: spaceType,
                skey: skey.isEmpty ? nil : skey,
                policy: policy,
                account: account
            )
            onCreated?(ref)
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
