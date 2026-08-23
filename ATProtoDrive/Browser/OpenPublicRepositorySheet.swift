import SwiftUI

public struct OpenPublicRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: BrowserSession
    let store: PublicRepositoryStore
    let recentRepositoryStore: RecentRepositoryStore

    @State private var identifier: String = ""
    @State private var errorMessage: String?
    @State private var isLoading: Bool = false

    public init(
        session: BrowserSession,
        store: PublicRepositoryStore,
        recentRepositoryStore: RecentRepositoryStore
    ) {
        self.session = session
        self.store = store
        self.recentRepositoryStore = recentRepositoryStore
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Handle or DID", text: $identifier, prompt: Text("alice.bsky.social or did:plc:..."))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(macOS)
                        .textContentType(.username)
                        #endif

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                } footer: {
                    Text("Enter a handle (e.g. alice.bsky.social) or a DID (e.g. did:plc:... or did:web:...) to open the public repository.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Open Public Repository")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        Task {
                            await openRepository()
                        }
                    }
                    .disabled(identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 220)
    }

    private func openRepository() async {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousTarget = store.target

        isLoading = true
        errorMessage = nil

        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier(trimmed),
            store: store,
            session: session,
            recents: recentRepositoryStore
        )

        isLoading = false

        switch store.state {
        case .loaded:
            dismiss()
        case .failed(_, let failure):
            errorMessage = failure.localizedDescription
            if let previousTarget, previousTarget != .publicIdentifier(trimmed) {
                await PublicRepositoryOpenCoordinator.restorePreviousTarget(
                    previousTarget,
                    store: store,
                    session: session
                )
            }
        case .idle, .loading:
            break
        }
    }
}
