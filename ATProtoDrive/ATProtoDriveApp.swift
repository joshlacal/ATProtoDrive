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
                        account: owningAccount
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
                Text("Records")
            }
            .environment(accountStore)
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
