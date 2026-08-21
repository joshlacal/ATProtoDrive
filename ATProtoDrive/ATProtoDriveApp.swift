//
//  ATProtoDriveApp.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel
import SwanSpaces

@main
struct ATProtoDriveApp: App {
    @State private var accountStore = AccountStore()
    @State private var showingAddAccount = false
    @State private var selectedSpace: SpaceItem?
    @State private var selectedRepo: RepoEntry?
    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(
                    selectedSpace: $selectedSpace,
                    showingAddAccount: $showingAddAccount
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddAccount = true
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                    }
                }
            } content: {
                if let space = selectedSpace {
                    let owningAccount = AccountStore.resolveDetailAccount(for: space, in: accountStore.accounts)
                    SpaceDetailView(
                        space: space,
                        account: owningAccount,
                        selectedRepo: $selectedRepo
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
                if let space = selectedSpace, let repo = selectedRepo {
                    let owningAccount = AccountStore.resolveDetailAccount(for: space, in: accountStore.accounts)
                    RecordTableView(
                        space: space,
                        repo: repo,
                        account: owningAccount
                    )
                    .id("\(space.id)-\(repo.did)")
                } else if selectedSpace != nil {
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
            .environment(accountStore)
            .onChange(of: selectedSpace) { _, _ in
                selectedRepo = nil
            }
            .sheet(isPresented: $showingAddAccount) {
                AddAccountView()
                    .environment(accountStore)
            }
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
