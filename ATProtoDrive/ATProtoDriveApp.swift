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

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                List(selection: $accountStore.activeAccountID) {
                    Section("Accounts") {
                        ForEach(accountStore.accounts) { account in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.handle)
                                    .font(.headline)
                                Text(account.id)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(account.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task {
                                        await accountStore.remove(account.id)
                                    }
                                } label: {
                                    Label("Remove Account", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Accounts")
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
                if let active = accountStore.activeAccount {
                    VStack(alignment: .leading) {
                        Text("Active: \(active.handle)")
                            .font(.headline)
                        Text("Spaces")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    ContentUnavailableView("No Account Selected", systemImage: "person.crop.circle.badge.plus", description: Text("Add an ATProto account to browse Spaces."))
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
