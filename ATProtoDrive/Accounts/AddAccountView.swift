//
//  AddAccountView.swift
//  ATProtoDrive
//

import SwiftUI

struct AddAccountView: View {
    @Environment(AccountStore.self) private var accountStore
    @Environment(\.dismiss) private var dismiss

    @State private var handle: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var authURLOpened: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Add ATProto Account")
                .font(.headline)

            Text("Enter your Bluesky or ATProto handle (e.g. alice.bsky.social, bob.example.com):")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Handle", text: $handle)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .disabled(isLoading)
                .onSubmit {
                    startLogin()
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if authURLOpened {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for authentication in browser...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Log In") {
                    startLogin()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: accountStore.accounts.count) { _, _ in
            // When an account is successfully added, dismiss the sheet
            dismiss()
        }
    }

    private func startLogin() {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let url = try await accountStore.beginLogin(handle: trimmed)
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                authURLOpened = true
                isLoading = false
            } catch {
                errorMessage = "Failed to start login: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
