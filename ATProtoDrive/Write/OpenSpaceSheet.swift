//
//  OpenSpaceSheet.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct OpenSpaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accountStore

    let account: AccountStore.Account
    var onOpened: ((SpaceItem) -> Void)?

    @State private var uriString: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        account: AccountStore.Account,
        onOpened: ((SpaceItem) -> Void)? = nil
    ) {
        self.account = account
        self.onOpened = onOpened
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Open Space by Reference")
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
                    TextField(
                        "Space URI",
                        text: $uriString,
                        prompt: Text("at:space/did:plc:.../space.swan.drive/self")
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                } header: {
                    Text("Space Reference")
                        .font(.subheadline.bold())
                } footer: {
                    Text("Enter the full ATProto space URI (e.g. at:space/{authorityDID}/{spaceType}/{skey}). Older at://{authorityDID}/space/… URIs are converted.")
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

                Button("Open Space") {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || uriString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 280, idealHeight: 320)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let spaceListModel = accountStore.spaceModel(for: account.id)
            let item = try await spaceListModel.openSpace(
                uriString: uriString,
                account: account
            )
            onOpened?(item)
            dismiss()
        } catch {
            if let openError = error as? OpenSpaceError {
                errorMessage = openError.errorDescription
            } else if let xrpc = error as? ATProtoXRPCError {
                errorMessage = xrpc.errorDescription ?? xrpc.error
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
