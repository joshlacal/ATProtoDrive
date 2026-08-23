//
//  ATProtoDriveApp.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel
import SwanSpaces

@MainActor
private struct BrowserSceneRoot: View {
    @State private var session: BrowserSession
    @State private var publicRepositoryStore: PublicRepositoryStore
    private let recentRepositoryStore: RecentRepositoryStore

    init(
        publicRepositoryService: any PublicRepositoryServing,
        recentRepositoryStore: RecentRepositoryStore
    ) {
        _session = State(initialValue: BrowserSession())
        _publicRepositoryStore = State(initialValue: PublicRepositoryStore(
            service: publicRepositoryService
        ))
        self.recentRepositoryStore = recentRepositoryStore
    }

    var body: some View {
        MainWindowView(
            session: session,
            publicRepositoryStore: publicRepositoryStore,
            recentRepositoryStore: recentRepositoryStore
        )
    }
}

@main
struct ATProtoDriveApp: App {
    @State private var accountStore = AccountStore()
    private let publicRepositoryService: any PublicRepositoryServing
    private let recentRepositoryStore: RecentRepositoryStore

    init() {
        self.publicRepositoryService = PublicRepositoryService()
        do {
            self.recentRepositoryStore = RecentRepositoryStore(
                persistence: try FileRecentRepositoryPersistence.live()
            )
        } catch {
            self.recentRepositoryStore = RecentRepositoryStore(
                persistence: MemoryRecentRepositoryPersistence()
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserSceneRoot(
                publicRepositoryService: publicRepositoryService,
                recentRepositoryStore: recentRepositoryStore
            )
            .environment(accountStore)
            .task {
                await accountStore.restore()
                await recentRepositoryStore.restore()
            }
            .onOpenURL { url in
                Task {
                    try? await accountStore.handleCallback(url)
                }
            }
        }
        .commands {
            BrowserCommands()
        }
    }
}
