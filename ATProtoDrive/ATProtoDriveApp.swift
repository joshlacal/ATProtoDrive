//
//  ATProtoDriveApp.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel
import SwanSpaces

@MainActor
private struct BrowserSceneRoot: View {
    @Environment(AccountStore.self) private var accountStore
    @State private var session: BrowserSession
    @State private var publicRepositoryStore: PublicRepositoryStore
    private let recentRepositoryStore: RecentRepositoryStore
    private let isFixtureMode: Bool
    #if DEBUG
    @State private var fixtureReadiness: FixtureReadiness = .idle
    #endif

    init(
        publicRepositoryService: any PublicRepositoryServing,
        publicBlobService: any PublicBlobServing,
        recentRepositoryStore: RecentRepositoryStore,
        isFixtureMode: Bool = false
    ) {
        _session = State(initialValue: BrowserSession())
        _publicRepositoryStore = State(initialValue: PublicRepositoryStore(
            service: publicRepositoryService,
            blobService: publicBlobService
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
        .onChange(of: accountStore.activeAccount?.id) { _, activeID in
            guard !isFixtureMode,
                  session.selectedSource == nil,
                  ProcessInfo.processInfo.environment["ATPROTODRIVE_INITIAL_DESTINATION"] == "spaces",
                  let activeID
            else { return }
            session.selectSource(.account(did: activeID, destination: .spaces))
        }
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
    @State private var transferQueue: TransferQueue
    @State private var backupStore: BackupStore
    private let publicRepositoryService: any PublicRepositoryServing
    private let publicBlobService: any PublicBlobServing
    private let recentRepositoryStore: RecentRepositoryStore
    private let isFixtureMode: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        let isTesting = env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil

        #if DEBUG
        let fixtureMode = env["ATPROTODRIVE_FIXTURE_MODE"] == "public-browser"
        self.isFixtureMode = fixtureMode
        if fixtureMode {
            self.publicRepositoryService = FixturePublicRepositoryService()
            self.publicBlobService = FixturePublicBlobService()
            self.recentRepositoryStore = RecentRepositoryStore(
                persistence: MemoryRecentRepositoryPersistence()
            )
        } else {
            self.publicRepositoryService = PublicRepositoryService()
            self.publicBlobService = PublicBlobService()
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
        let fixtureMode = false
        self.isFixtureMode = false
        self.publicRepositoryService = PublicRepositoryService()
        self.publicBlobService = PublicBlobService()
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

        if fixtureMode || isTesting {
            _transferQueue = State(initialValue: TransferQueue.inMemory())
            let ephemeralBackupsDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ATProtoDrive-EphemeralBackups-\(UUID().uuidString)", isDirectory: true)
            _backupStore = State(initialValue: BackupStore(rootDirectory: ephemeralBackupsDir))
        } else {
            _transferQueue = State(initialValue: TransferQueue())
            _backupStore = State(initialValue: BackupStore())
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserSceneRoot(
                publicRepositoryService: publicRepositoryService,
                publicBlobService: publicBlobService,
                recentRepositoryStore: recentRepositoryStore,
                isFixtureMode: isFixtureMode
            )
            .environment(accountStore)
            .environment(transferQueue)
            .environment(backupStore)
            .task {
                let env = ProcessInfo.processInfo.environment
                let isTesting = env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
                if !isFixtureMode && !isTesting {
                    await accountStore.restore()
                    backupStore.reload()
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
