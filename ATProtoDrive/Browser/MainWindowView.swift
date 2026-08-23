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
        .inspector(isPresented: $bindableSession.isInspectorPresented) {
            BrowserInspectorView(
                references: Array(session.selectedReferences.values),
                primaryRecord: session.primarySelection.flatMap(publicRepositoryStore.record(for:))
            )
            .inspectorColumnWidth(min: 260, ideal: 340, max: 480)
        }
    }
}
