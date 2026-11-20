import AppKit
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
    @Environment(TransferQueue.self) private var environmentTransferQueue: TransferQueue?
    @Environment(BackupStore.self) private var environmentBackupStore: BackupStore?
    @State private var fallbackTransferQueue = TransferQueue.inMemory()
    @State private var fallbackBackupStore = BackupStore(
        rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ATProtoDrive-PreviewBackups", isDirectory: true)
    )
    @State private var showingAddAccountSheet = false
    @State private var showingOpenRepoSheet = false
    @State private var pendingOpenSpaceURI: String?
    @State private var spacesRefreshToken: Int = 0
    @State private var overviewRefreshToken: Int = 0
    @State private var privateStateRefreshToken: Int = 0
    @State private var backupsRefreshToken: Int = 0
    @State private var serverAccountRefreshToken: Int = 0

    private var activeTransferQueue: TransferQueue {
        environmentTransferQueue ?? fallbackTransferQueue
    }

    private var activeBackupStore: BackupStore {
        environmentBackupStore ?? fallbackBackupStore
    }

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
        if case .account(let did, let destination) = session.selectedSource {
            switch destination {
            case .overview:
                if accountStore.account(for: did) != nil {
                    return BrowserRefreshAction { overviewRefreshToken += 1 }
                }
                return nil
            case .spaces:
                if accountStore.account(for: did) != nil {
                    return BrowserRefreshAction { spacesRefreshToken += 1 }
                }
                return nil
            case .privateAppState:
                if accountStore.account(for: did) != nil {
                    return BrowserRefreshAction { privateStateRefreshToken += 1 }
                }
                return nil
            case .backups:
                return BrowserRefreshAction { backupsRefreshToken += 1 }
            case .serverAndAccount:
                if accountStore.account(for: did) != nil {
                    return BrowserRefreshAction { serverAccountRefreshToken += 1 }
                }
                return nil
            case .activity:
                return nil
            case .publicRecords, .publicBlobs:
                break
            }
        }
        if session.path?.repositoryDestination == .files, let store = publicRepositoryStore.blobStore() {
            return BrowserRefreshAction { await store.reload() }
        }
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
                    case .overview:
                        AccountOverviewView(
                            accountDID: did,
                            refreshToken: overviewRefreshToken,
                            onNavigate: { dest in
                                session.selectSource(.account(did: did, destination: dest))
                            }
                        )
                    case .spaces:
                        SpacesBrowserView(
                            accountDID: did,
                            pendingOpenSpaceURI: $pendingOpenSpaceURI,
                            refreshToken: spacesRefreshToken
                        )
                    case .publicRecords, .publicBlobs:
                        repositoryContentView(
                            for: .connectedAccount(did: did),
                            selectedSource: .account(did: did, destination: destination),
                            owningAccount: accountStore.account(for: did)
                        )
                    case .privateAppState:
                        PrivateAppStateView(
                            accountDID: did,
                            refreshToken: privateStateRefreshToken
                        )
                    case .backups:
                        BackupsView(
                            accountDID: did,
                            backupStore: activeBackupStore,
                            onRegisterTransfer: { title, subtitle, accountDIDs, work in
                                let queue = activeTransferQueue
                                queue.enqueueAndRun(
                                    kind: .backupExport,
                                    title: title,
                                    subtitle: subtitle,
                                    requiredAccountDIDs: accountDIDs
                                ) { report in
                                    report(.running, 0, nil)
                                    return try await work { completed, total in
                                        report(.running, completed, total)
                                    }
                                }
                            },
                            refreshToken: backupsRefreshToken
                        )
                    case .activity:
                        ActivityView(transferQueue: activeTransferQueue)
                    case .serverAndAccount:
                        ServerAndAccountView(
                            accountDID: did,
                            refreshToken: serverAccountRefreshToken,
                            onReconnect: { targetDID in
                                let authURL = try await accountStore.reconnectAccount(did: targetDID)
                                #if os(macOS)
                                NSWorkspace.shared.open(authURL)
                                #endif
                            },
                            onRemoveAccount: { targetDID in
                                let queue = activeTransferQueue
                                await accountStore.removeAccountSafely(did: targetDID) { accountDIDs in
                                    _ = await queue.markAccountsUnavailable(accountDIDs)
                                }
                                if case .account(let selectedDID, _) = session.selectedSource,
                                   selectedDID == targetDID {
                                    session.selectSource(nil)
                                }
                            }
                        )
                    }
                case .openedPublicRepository(let did):
                    repositoryContentView(
                        for: .publicIdentifier(did),
                        selectedSource: .openedPublicRepository(did: did),
                        owningAccount: nil
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
                        OpenSpaceDestinationView(
                            onOpened: { accountDID, openedSpace in
                                pendingOpenSpaceURI = openedSpace.ref.uriString()
                                session.selectSource(.account(did: accountDID, destination: .spaces))
                            },
                            onAddAccount: {
                                showingAddAccountSheet = true
                            }
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.isInspectorPresented.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Inspector (⌥⌘I)")
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
        selectedSource: BrowserSource,
        owningAccount: AccountStore.Account?
    ) -> some View {
        VStack(spacing: 0) {
            if let repository = publicRepositoryStore.state.snapshot?.repository {
                repositoryDestinationPicker(repository: repository)
            }
            repositoryDetail(owningAccount: owningAccount)
        }
        .task(id: selectedSource) {
            if publicRepositoryStore.state.snapshot == nil || session.path?.source != selectedSource {
                await PublicRepositoryOpenCoordinator.open(
                    target,
                    store: publicRepositoryStore,
                    session: session,
                    recents: recentRepositoryStore,
                    selectedSource: selectedSource
                )
                if case .account(_, .publicBlobs) = selectedSource,
                   let repository = publicRepositoryStore.state.snapshot?.repository,
                   session.selectedSource == selectedSource {
                    session.navigate(to: BrowserPath(
                        source: selectedSource,
                        components: [.repository(repository.scope)],
                        repositoryDestination: .files
                    ))
                }
            }
        }
    }

    @ViewBuilder
    private func repositoryDetail(owningAccount: AccountStore.Account?) -> some View {
        Group {
            if session.path?.repositoryDestination == .files,
               let store = publicRepositoryStore.blobStore() {
                BlobBrowserView(store: store, session: session)
                    .id(store.repository.scope)
                    .task(id: store.repository.scope) {
                        if case .idle = store.loadState { await store.reload() }
                    }
                    .onDisappear { store.cancelReferenceScan() }
            } else if let path = session.path, path.components.count >= 2,
               case .collection(_, let collection) = path.components[1] {
                if let recordStore = publicRepositoryStore.recordStore(for: collection) {
                    BrowserTableShell(state: recordStore.state, retry: {
                        Task { await recordStore.refresh() }
                    }) { _ in
                        VStack(spacing: 0) {
                            BrowserBreadcrumbView(
                                session: session,
                                repository: recordStore.repository,
                                currentCollection: collection
                            )
                            PublicRecordTable(
                                store: recordStore,
                                session: session,
                                owningAccount: owningAccount
                            )
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
                PublicRepositoryView(
                    session: session,
                    store: publicRepositoryStore,
                    owningAccount: owningAccount
                )
            }
        }
    }

    private func repositoryDestinationPicker(repository: ResolvedRepository) -> some View {
        HStack {
            Label(repository.handle ?? repository.did, systemImage: "externaldrive.connected.to.line.below")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Picker("Repository content", selection: Binding(
                get: { session.path?.repositoryDestination ?? .records },
                set: { destination in
                    guard let currentSource = session.selectedSource else { return }
                    let source: BrowserSource
                    if case .account(let did, _) = currentSource {
                        source = .account(did: did, destination: destination == .files ? .publicBlobs : .publicRecords)
                    } else { source = currentSource }
                    session.navigate(to: BrowserPath(
                        source: source,
                        components: [.repository(repository.scope)],
                        repositoryDestination: destination
                    ))
                }
            )) {
                Text("Records").tag(RepositoryBrowserDestination.records)
                Text("Public Files").tag(RepositoryBrowserDestination.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
