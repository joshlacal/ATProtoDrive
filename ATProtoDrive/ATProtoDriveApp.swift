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
    private let isFixtureMode: Bool
    #if DEBUG
    @State private var fixtureReadiness: FixtureReadiness = .idle
    #endif

    init(
        publicRepositoryService: any PublicRepositoryServing,
        recentRepositoryStore: RecentRepositoryStore,
        isFixtureMode: Bool = false
    ) {
        _session = State(initialValue: BrowserSession())
        _publicRepositoryStore = State(initialValue: PublicRepositoryStore(
            service: publicRepositoryService
        ))
        self.recentRepositoryStore = recentRepositoryStore
        self.isFixtureMode = isFixtureMode
    }

    var body: some View {
        Group {
            #if DEBUG
            if isFixtureMode {
                switch fixtureReadiness {
                case .idle, .loading:
                    ProgressView("Loading fixture...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    MainWindowView(
                        session: session,
                        publicRepositoryStore: publicRepositoryStore,
                        recentRepositoryStore: recentRepositoryStore
                    )
                    .accessibilityIdentifier("public-browser-ready")
                case .failed(let failure):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(failure.errorDescription ?? "Unknown failure")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                MainWindowView(
                    session: session,
                    publicRepositoryStore: publicRepositoryStore,
                    recentRepositoryStore: recentRepositoryStore
                )
            }
            #else
            MainWindowView(
                session: session,
                publicRepositoryStore: publicRepositoryStore,
                recentRepositoryStore: recentRepositoryStore
            )
            #endif
        }
        #if DEBUG
        .task {
            guard isFixtureMode, fixtureReadiness == .idle else { return }
            fixtureReadiness = .loading
            do {
                try await PublicBrowserFixture.bootstrap(
                    session: session,
                    repositoryStore: publicRepositoryStore,
                    recentRepositoryStore: recentRepositoryStore
                )
                fixtureReadiness = .ready
            } catch is CancellationError {
                fixtureReadiness = .idle
            } catch {
                let failure = BrowserFailure.normalize(error)
                fixtureReadiness = .failed(failure)
            }
        }
        #endif
    }
}

@main
struct ATProtoDriveApp: App {
    @State private var accountStore = AccountStore()
    private let publicRepositoryService: any PublicRepositoryServing
    private let recentRepositoryStore: RecentRepositoryStore
    private let isFixtureMode: Bool

    init() {
        #if DEBUG
        let fixtureMode = ProcessInfo.processInfo.environment["ATPROTODRIVE_FIXTURE_MODE"] == "public-browser"
        self.isFixtureMode = fixtureMode
        if fixtureMode {
            self.publicRepositoryService = FixturePublicRepositoryService()
            self.recentRepositoryStore = RecentRepositoryStore(
                persistence: MemoryRecentRepositoryPersistence()
            )
        } else {
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
        #else
        self.isFixtureMode = false
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
        #endif
    }

    var body: some Scene {
        WindowGroup {
            BrowserSceneRoot(
                publicRepositoryService: publicRepositoryService,
                recentRepositoryStore: recentRepositoryStore,
                isFixtureMode: isFixtureMode
            )
            .environment(accountStore)
            .task {
                if !isFixtureMode {
                    await accountStore.restore()
                }
                await recentRepositoryStore.restore()
            }
            .onOpenURL { url in
                Task {
                    try? await accountStore.handleCallback(url)
                }
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            BrowserCommands()
        }
    }
}
