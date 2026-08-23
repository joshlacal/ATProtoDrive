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
    @State private var showingOpenRepoSheet = false

    public init(
        session: BrowserSession,
        publicRepositoryStore: PublicRepositoryStore,
        recentRepositoryStore: RecentRepositoryStore
    ) {
        self.session = session
        self.publicRepositoryStore = publicRepositoryStore
        self.recentRepositoryStore = recentRepositoryStore
    }

    private var currentRefreshAction: BrowserRefreshAction? {
        if let path = session.path, path.components.count >= 2,
           case .collection(_, let collection) = path.components[1],
           let recordStore = publicRepositoryStore.recordStore(for: collection) {
            return BrowserRefreshAction {
                await recordStore.refresh()
            }
        } else if session.path != nil {
            return BrowserRefreshAction {
                await publicRepositoryStore.refresh()
            }
        }
        return nil
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
                        repositoryContentView(
                            for: .connectedAccount(did: did),
                            selectedSource: .account(did: did, destination: .publicRecords)
                        )
                    default:
                        ContentUnavailableView(
                            destination.rawValue.capitalized,
                            systemImage: "folder",
                            description: Text("Destination \(destination.rawValue) is under development.")
                        )
                    }
                case .openedPublicRepository(let did):
                    repositoryContentView(
                        for: .publicIdentifier(did),
                        selectedSource: .openedPublicRepository(did: did)
                    )
                case .global(let globalDestination):
                    switch globalDestination {
                    case .openPublicRepository:
                        ContentUnavailableView {
                            Label("Open Public Repository", systemImage: "globe")
                        } description: {
                            Text("Enter a handle or DID to browse any public ATProto repository.")
                        } actions: {
                            Button("Open Repository…") {
                                showingOpenRepoSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
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
        .focusedSceneValue(\.browserSession, session)
        .focusedSceneValue(\.browserRefreshAction, currentRefreshAction)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    session.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!session.canGoBack)

                Button {
                    session.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!session.canGoForward)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await currentRefreshAction?.perform()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(currentRefreshAction == nil)
            }
        }
        .sheet(isPresented: $showingAddAccountSheet) {
            AddAccountView()
                .environment(accountStore)
        }
        .sheet(isPresented: $showingOpenRepoSheet) {
            OpenPublicRepositorySheet(
                session: session,
                store: publicRepositoryStore,
                recentRepositoryStore: recentRepositoryStore
            )
        }
    }

    @ViewBuilder
    private func repositoryContentView(
        for target: RepositoryTarget,
        selectedSource: BrowserSource
    ) -> some View {
        Group {
            if let path = session.path, path.components.count >= 2,
               case .collection(_, let collection) = path.components[1] {
                if let recordStore = publicRepositoryStore.recordStore(for: collection) {
                    BrowserTableShell(state: recordStore.state, retry: {
                        Task { await recordStore.refresh() }
                    }) { records in
                        VStack(spacing: 0) {
                            BrowserBreadcrumbView(
                                session: session,
                                repository: recordStore.repository,
                                currentCollection: collection
                            )
                            if records.isEmpty {
                                ContentUnavailableView(
                                    "No Records",
                                    systemImage: "doc.text",
                                    description: Text("No records found in \(collection).")
                                )
                            } else {
                                List(records, id: \.uri) { record in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.rkey)
                                            .font(.headline)
                                        Text(record.uri)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .task(id: "\(collection)|\(recordStore.repository.did)") {
                        if case .idle = recordStore.state {
                            _ = await publicRepositoryStore.loadCollection(collection)
                        }
                    }
                } else if case .failed(_, let failure) = publicRepositoryStore.state {
                    UnavailableStateView(failure: failure, retry: {
                        Task { await publicRepositoryStore.refresh() }
                    })
                } else {
                    ProgressView("Loading collection…")
                }
            } else {
                PublicRepositoryView(session: session, store: publicRepositoryStore)
            }
        }
        .task(id: target) {
            if publicRepositoryStore.state.snapshot == nil || session.path?.source != selectedSource {
                await PublicRepositoryOpenCoordinator.open(
                    target,
                    store: publicRepositoryStore,
                    session: session,
                    recents: recentRepositoryStore,
                    selectedSource: selectedSource
                )
            }
        }
    }
}
