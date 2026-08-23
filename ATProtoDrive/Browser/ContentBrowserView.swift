import SwiftUI
import Petrel
import SwanSpaces

public enum LegacySpaceCompatibilityCapability: Hashable, Sendable {
    case readOnly
}

public enum LegacySpaceMutationAction: Hashable, Sendable {
    case createSpace, updateSpace, deleteSpace, addMember, removeMember
    case createRecord, updateRecord, deleteRecord, uploadBlob
}

public struct LegacySpacesCompatibilityProjection: Hashable, Sendable {
    public let accountDID: String?
    public let capabilities: LegacySpaceCompatibilityCapability = .readOnly
    public let availableActions: [LegacySpaceMutationAction] = []

    public init(selectedAccountDID: String, accounts: [SidebarAccountSummary]) {
        accountDID = accounts.contains(where: { $0.did == selectedAccountDID })
            ? selectedAccountDID
            : nil
    }
}

public struct LegacySpacesCompatibilityView: View {
    public let accountDID: String
    @Environment(AccountStore.self) private var accountStore
    @State private var expandedSpaceIDs: Set<String> = []

    public init(accountDID: String) {
        self.accountDID = accountDID
    }

    public var body: some View {
        if let account = accountStore.account(for: accountDID) {
            let model = accountStore.spaceModel(for: accountDID)
            List {
                Section(header: Text("Spaces — Experimental (Read Only)")) {
                    if model.isLoading && model.spaces.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading spaces…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = model.error, model.spaces.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await model.load(account: account) }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if model.spaces.isEmpty {
                        Text("No spaces found for this account.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.spaces) { space in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedSpaceIDs.contains(space.id) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedSpaceIDs.insert(space.id)
                                        } else {
                                            expandedSpaceIDs.remove(space.id)
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 8) {
                                    LabeledContent("URI", value: space.ref.uriString())
                                    LabeledContent("Authority", value: space.authorityDID)
                                    LabeledContent("Space Type", value: space.spaceType)
                                    LabeledContent("Mode", value: "Read Only")
                                }
                                .font(.caption)
                                .padding(.vertical, 4)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(space.skey)
                                            .font(.headline)
                                        Text(space.ref.uriString())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: space.isOwnAuthority ? "externaldrive" : "externaldrive.badge.person.crop")
                                        .foregroundStyle(space.isOwnAuthority ? .blue : .purple)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Spaces — Experimental (Read Only)")
            .task(id: account.id) {
                await model.load(account: account)
            }
            .refreshable {
                await model.load(account: account)
            }
        } else {
            ContentUnavailableView(
                "Account Disconnected",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("The requested account is not available.")
            )
            .navigationTitle("Spaces — Experimental (Read Only)")
        }
    }
}

public struct ContentBrowserView: View {
    @Bindable var session: BrowserSession
    let publicRepositoryStore: PublicRepositoryStore
    let recentRepositoryStore: RecentRepositoryStore
    @Environment(AccountStore.self) private var accountStore
    @State private var showingAddAccountSheet = false

    public init(
        session: BrowserSession,
        publicRepositoryStore: PublicRepositoryStore,
        recentRepositoryStore: RecentRepositoryStore
    ) {
        self.session = session
        self.publicRepositoryStore = publicRepositoryStore
        self.recentRepositoryStore = recentRepositoryStore
    }

    public var body: some View {
        Group {
            if let selectedSource = session.selectedSource {
                switch selectedSource {
                case .account(let did, let destination):
                    switch destination {
                    case .spaces:
                        LegacySpacesCompatibilityView(accountDID: did)
                    case .publicRecords:
                        ProgressView("Loading public repository…")
                    default:
                        ContentUnavailableView(
                            destination.rawValue.capitalized,
                            systemImage: "folder",
                            description: Text("Destination \(destination.rawValue) is under development.")
                        )
                    }
                case .openedPublicRepository(let did):
                    VStack {
                        Text("Opened Public Repository")
                            .font(.headline)
                        Text(did)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .global(let globalDestination):
                    switch globalDestination {
                    case .openPublicRepository:
                        ContentUnavailableView(
                            "Open Public Repository",
                            systemImage: "globe",
                            description: Text("Enter a handle or DID to open a repository.")
                        )
                    case .openSpace:
                        ContentUnavailableView(
                            "Open Space",
                            systemImage: "square.and.arrow.down",
                            description: Text("Enter a space URI to open.")
                        )
                    case .addAccount:
                        ContentUnavailableView {
                            Label("Add Account", systemImage: "person.badge.plus")
                        } description: {
                            Text("Sign in with your ATProto account to manage Spaces and records.")
                        } actions: {
                            Button("Add Account…") {
                                showingAddAccountSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Source Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select an account, repository, or utility from the sidebar.")
                )
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAddAccountSheet) {
            AddAccountView()
                .environment(accountStore)
        }
    }
}
