import SwiftUI
public struct MainWindowView: View {
    @Bindable var session: BrowserSession
    let publicRepositoryStore: PublicRepositoryStore
    let recentRepositoryStore: RecentRepositoryStore

    public init(
        session: BrowserSession,
        publicRepositoryStore: PublicRepositoryStore,
        recentRepositoryStore: RecentRepositoryStore
    ) {
        self.session = session
        self.publicRepositoryStore = publicRepositoryStore
        self.recentRepositoryStore = recentRepositoryStore
    }

    public var body: some View {
        @Bindable var bindableSession = session
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $bindableSession.columnVisibility) {
                DriveSidebarView(session: bindableSession, recentRepositoryStore: recentRepositoryStore)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
            } detail: {
                ContentBrowserView(
                    session: bindableSession,
                    publicRepositoryStore: publicRepositoryStore,
                    recentRepositoryStore: recentRepositoryStore
                )
            }
            if session.isInspectorPresented {
                Divider()
                inspectorContent
                    .frame(width: 350)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var inspectorContent: some View {
        Group {
            if session.selectedReferences.count == 1,
               case .blob(let locator) = session.primarySelection,
               let store = publicRepositoryStore.blobStore(for: locator.scope),
               let blob = store.blob(for: locator) {
                BlobInspectorView(blob: blob, references: store.references(to: locator)) { record in
                    Task {
                        guard session.currentRepositoryScope == record.scope else { return }
                        let opened = await PublicRepositoryOpenCoordinator.openCollection(
                            record.collection, store: publicRepositoryStore, session: session
                        )
                        if opened, publicRepositoryStore.record(for: .record(record)) != nil {
                            session.replaceSelection(with: [.record(record)])
                        }
                    }
                }
                .id(blob.locator)
            } else {
                BrowserInspectorView(
                    references: Array(session.selectedReferences.values),
                    primaryRecord: session.primarySelection.flatMap(publicRepositoryStore.record(for:)),
                    referenceScanComplete: session.currentRepositoryScope.flatMap {
                        publicRepositoryStore.blobStore(for: $0)
                    }?.snapshot.referenceScanComplete ?? false
                )
            }
        }
    }
}
