import Foundation
import Testing
import SwiftUI
@testable import ATProtoDrive

@Suite("Drive sidebar")
struct DriveSidebarTests {
    @Test("public repository utility remains available with no accounts")
    func noAccountUtilities() {
        let rows = DriveSidebarProjection.rows(accounts: [], openedRepositories: [])
        #expect(rows.contains { $0.source == .global(.openPublicRepository) })
        #expect(rows.contains { $0.source == .global(.addAccount) })
    }

    @Test("each account has the eight stable product destinations")
    func accountDestinations() {
        let did = ResolvedRepository.fixture.did
        let rows = DriveSidebarProjection.rows(
            accounts: [.init(did: did, handle: "alice.test")],
            openedRepositories: []
        )
        let accountRows = rows.filter { $0.accountDID == did }
        #expect(Set(accountRows.compactMap(\.accountDestination)) == Set(AccountDestination.allCases))
        #expect(accountRows.count == 8)
    }

    @Test("opened repositories have a visible recent row")
    func openedRepositoryRow() {
        let recent = OpenedRepositorySummary(
            did: ResolvedRepository.fixture.did,
            handle: ResolvedRepository.fixture.handle,
            pdsURL: ResolvedRepository.fixture.pdsURL,
            sourceAccountDID: nil,
            lastOpenedAt: .distantPast
        )
        let rows = DriveSidebarProjection.rows(accounts: [], openedRepositories: [recent])
        let row = rows.first { $0.source == .openedPublicRepository(did: recent.did) }
        #expect(row?.section == .openedAndRecent)
        #expect(row?.title == "alice.test")
        #expect(row?.subtitle == recent.did)
    }

    @Test("legacy Space route resolves only the source account and is read only")
    func legacySpaceRouteIsAccountBound() {
        let selectedDID = ResolvedRepository.fixture.did
        let projection = LegacySpacesCompatibilityProjection(
            selectedAccountDID: selectedDID,
            accounts: [.init(did: selectedDID, handle: "alice.test")]
        )
        #expect(projection.accountDID == selectedDID)
        #expect(projection.capabilities == .readOnly)
        #expect(projection.availableActions.isEmpty)
    }

    @MainActor
    @Test("two windows share service and durable recents while isolating session and store state")
    func twoWindowSceneIsolation() async throws {
        let sharedService = ScriptedPublicRepositoryService(pages: [:])
        let sharedPersistence = MemoryRecentRepositoryPersistence()
        let sharedRecentStore = RecentRepositoryStore(persistence: sharedPersistence, maximumCount: 10)

        // Window 1 session & store
        let session1 = BrowserSession()
        let store1 = PublicRepositoryStore(service: sharedService)

        // Window 2 session & store
        let session2 = BrowserSession()
        let store2 = PublicRepositoryStore(service: sharedService)

        let did1 = "did:plc:window1"
        let pdsURL1 = URL(string: "https://window1.example")!
        let scope1 = RepositoryScope.publicRepository(did: did1, pdsURL: pdsURL1)
        let source1 = BrowserSource.openedPublicRepository(did: did1)
        let path1 = BrowserPath(source: source1, components: [.repository(scope1)])
        let locator1 = RecordLocator(
            scope: scope1,
            uri: "at://\(did1)/app.test.item/rec1",
            collection: "app.test.item",
            rkey: "rec1",
            cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        )
        let ref1 = ResourceReference.record(locator1)

        // Mutate window 1
        session1.selectSource(source1)
        session1.navigate(to: path1)
        session1.replaceSelection(with: [ref1])
        session1.searchQuery = SearchQuery(text: "query-window-1")
        session1.sort = BrowserSort(field: "createdAt", ascending: false)
        session1.isInspectorPresented = true
        session1.rememberOpenedRepository(.init(
            did: did1,
            handle: "w1.test",
            pdsURL: pdsURL1,
            sourceAccountDID: nil,
            lastOpenedAt: Date()
        ))

        // Set target on store1
        await store1.open(target: .publicIdentifier(did1))
        _ = store1.recordStore(for: "app.test.item")

        // Assert window 2 is completely unmutated / isolated
        #expect(session2.selectedSource == nil)
        #expect(session2.path == nil)
        #expect(session2.selectedItemIDs.isEmpty)
        #expect(session2.primarySelection == nil)
        #expect(session2.searchQuery.text == "")
        #expect(session2.sort == BrowserSort())
        #expect(session2.history.isEmpty)
        #expect(session2.historyIndex == nil)
        #expect(session2.openedPublicRepositories.isEmpty)
        #expect(session2.isInspectorPresented == false)
        #expect(store2.target == nil)
        #expect(store2.cachedCollectionCount == 0)

        // Persist a recent in shared store; intentionally visible in both projections
        let persistedSummary = OpenedRepositorySummary(
            did: "did:plc:shared",
            handle: "shared.test",
            pdsURL: URL(string: "https://shared.example")!,
            sourceAccountDID: nil,
            lastOpenedAt: Date()
        )
        await sharedRecentStore.remember(persistedSummary)

        let rows1 = DriveSidebarProjection.rows(accounts: [], openedRepositories: sharedRecentStore.entries)
        let rows2 = DriveSidebarProjection.rows(accounts: [], openedRepositories: sharedRecentStore.entries)
        #expect(rows1.contains { $0.source == .openedPublicRepository(did: "did:plc:shared") })
        #expect(rows2.contains { $0.source == .openedPublicRepository(did: "did:plc:shared") })
    }
}
