//
//  ATProtoDriveApp.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel
import SwanSpaces

@MainActor
@Observable
public final class WindowSelectionModel {
    public var selectedSpace: SpaceItem? {
        didSet {
            if selectedSpace?.id != oldValue?.id {
                selectedRepo = nil
            }
        }
    }
    public var selectedRepo: RepoEntry?
    public var showingAddAccount: Bool = false

    public init(
        selectedSpace: SpaceItem? = nil,
        selectedRepo: RepoEntry? = nil,
        showingAddAccount: Bool = false
    ) {
        self.selectedSpace = selectedSpace
        self.selectedRepo = selectedRepo
        self.showingAddAccount = showingAddAccount
    }

    public func selectSpace(_ space: SpaceItem?) {
        self.selectedSpace = space
    }

    public func selectRepo(_ repo: RepoEntry?) {
        self.selectedRepo = repo
    }

    public func clearSelection() {
        self.selectedSpace = nil
        self.selectedRepo = nil
    }
}

public struct MainWindowView: View {
    @Environment(AccountStore.self) private var accountStore
    @State private var selection: WindowSelectionModel

    public init(selection: WindowSelectionModel = WindowSelectionModel()) {
        self._selection = State(initialValue: selection)
    }

    public var body: some View {
        @Bindable var bindableSelection = selection
        NavigationSplitView {
            SidebarView(
                selectedSpace: $bindableSelection.selectedSpace,
                showingAddAccount: $bindableSelection.showingAddAccount
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        bindableSelection.showingAddAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                }
            }
        } content: {
            if let space = bindableSelection.selectedSpace {
                let owningAccount = AccountStore.resolveDetailAccount(for: space, in: accountStore.accounts)
                SpaceDetailView(
                    space: space,
                    account: owningAccount,
                    selectedRepo: $bindableSelection.selectedRepo,
                    onDelete: {
                        bindableSelection.clearSelection()
                    }
                )
                .id(space.id)
            } else {
                ContentUnavailableView(
                    "No Space Selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Select a space from the sidebar to view details.")
                )
            }
        } detail: {
            if let space = bindableSelection.selectedSpace, let repo = bindableSelection.selectedRepo {
                let owningAccount = AccountStore.resolveDetailAccount(for: space, in: accountStore.accounts)
                RecordTableView(
                    space: space,
                    repo: repo,
                    account: owningAccount
                )
                .id("\(space.id)-\(repo.did)-\(repo.rev)-\(repo.hash)")
            } else if bindableSelection.selectedSpace != nil {
                ContentUnavailableView(
                    "No Repository Selected",
                    systemImage: "tablecells",
                    description: Text("Select a writer repo from the space details to browse its records.")
                )
            } else {
                ContentUnavailableView(
                    "No Space Selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Select a space from the sidebar.")
                )
            }
        }
        .sheet(isPresented: $bindableSelection.showingAddAccount) {
            AddAccountView()
                .environment(accountStore)
        }
    }
}

@main
struct ATProtoDriveApp: App {
    @State private var accountStore = AccountStore()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(accountStore)
                .task {
                    await accountStore.restore()
                }
                .onOpenURL { url in
                    Task {
                        try? await accountStore.handleCallback(url)
                    }
                }
        }
    }
}
