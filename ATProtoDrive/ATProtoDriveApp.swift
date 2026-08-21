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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(space.skey)
                            .font(.title2.bold())
                        Text(space.spaceType)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Divider()
                        LabeledContent("Authority", value: space.authorityDID)
                        LabeledContent("Type", value: space.spaceType)
                        LabeledContent("Key", value: space.skey)
                        LabeledContent("URI", value: space.ref.uriString())
                        LabeledContent("Ownership", value: space.isOwnAuthority ? "Owned Space" : "Shared Space")
                        Spacer()
                    }
                    .padding()
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
