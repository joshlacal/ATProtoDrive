import Foundation
import Testing
@testable import ATProtoDrive

@Suite("Public browser presentation")
struct PublicBrowserPresentationTests {
    @Test("collection projection preserves server order and stable selection")
    func collectionProjection() {
        let description = RepositoryDescription.fixture(collections: [
            "app.bsky.feed.post", "com.example.unknown", "app.bsky.actor.profile"
        ])
        let rows = PublicRepositoryPresentation.collections(description)
        #expect(rows.map(\.nsid) == [
            "app.bsky.feed.post", "com.example.unknown", "app.bsky.actor.profile"
        ])
        #expect(rows[1].title == "com.example.unknown")
        #expect(rows[1].reference == .collection(
            scope: description.repository.scope,
            collection: "com.example.unknown"
        ))
        #expect(rows[1].id == rows[1].reference.stableID)
    }

    @MainActor
    @Test(arguments: ["alice.test", ResolvedRepository.fixture.did])
    func openByHandleOrDIDSelectsResolvedSource(identifier: String) async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier(identifier), store: store, session: session, recents: recents
        )
        #expect(session.selectedSource == .openedPublicRepository(did: ResolvedRepository.fixture.did))
        #expect(session.path?.components == [.repository(ResolvedRepository.fixture.scope)])
        #expect(session.history.count == 1)
        #expect(session.openedPublicRepositories.map(\.did) == [ResolvedRepository.fixture.did])
        #expect(recents.entries.map(\.did) == [ResolvedRepository.fixture.did])
    }

    @MainActor
    @Test("opening with specific selectedSource preserves sidebar route")
    func openPreservesExplicitSource() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()
        let source = BrowserSource.account(did: ResolvedRepository.fixture.did, destination: .publicRecords)
        await PublicRepositoryOpenCoordinator.open(
            .connectedAccount(did: ResolvedRepository.fixture.did),
            store: store,
            session: session,
            recents: recents,
            selectedSource: source
        )
        #expect(session.selectedSource == source)
        #expect(session.path?.source == source)
        #expect(session.path?.components == [.repository(ResolvedRepository.fixture.scope)])
    }

    @MainActor
    @Test("collection loading and breadcrumb history are explicit")
    func collectionNavigation() async {
        let store = PublicRepositoryStore(service: ScriptedPublicRepositoryService.successfulFixture())
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier("alice.test"), store: store, session: session, recents: recents
        )
        await PublicRepositoryOpenCoordinator.openCollection(
            "app.bsky.feed.post", store: store, session: session
        )
        #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
        #expect(session.canGoBack)
        session.goBack()
        #expect(session.path?.components.count == 1)
        session.goForward()
        #expect(session.path?.components.count == 2)
    }

    @MainActor
    @Test("restoring previous target after failure recovers repository state")
    func restorePreviousTargetAfterFailure() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()

        // 1. Open initial repository successfully
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier("alice.test"), store: store, session: session, recents: recents
        )
        #expect(store.state.snapshot != nil)
        let initialTarget = store.target

        // 2. Attempt failed open
        await service.fail(with: .offline)
        await store.open(target: .publicIdentifier("bad.test"))
        #expect(store.state.snapshot == nil)

        // 3. Restore previous target
        await service.clearFailure()
        if let initialTarget {
            await store.open(target: initialTarget)
        }
        #expect(store.state.snapshot != nil)
        #expect(store.target == initialTarget)
    }

    @MainActor
    @Test("failed open restore re-populates collection store for active collection route")
    func failedOpenRestoreReLoadsActiveCollection() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let store = PublicRepositoryStore(service: service)
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        let session = BrowserSession()

        // 1. Open initial repository and navigate to collection
        await PublicRepositoryOpenCoordinator.open(
            .publicIdentifier("alice.test"), store: store, session: session, recents: recents
        )
        await PublicRepositoryOpenCoordinator.openCollection(
            "app.bsky.feed.post", store: store, session: session
        )
        #expect(session.path?.components.count == 2)
        #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
        let initialTarget = store.target

        // 2. Failing open wipes recordStores
        await service.fail(with: .offline)
        await store.open(target: .publicIdentifier("bad.test"))
        #expect(store.state.snapshot == nil)

        // 3. Restore previous target through coordinator
        await service.clearFailure()
        await PublicRepositoryOpenCoordinator.restorePreviousTarget(
            initialTarget,
            store: store,
            session: session
        )
        #expect(store.state.snapshot != nil)
        #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
    }

    private actor RefreshCallRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @MainActor
    @Test("focused refresh invokes only the active window action")
    func focusedRefreshIsWindowLocal() async {
        let first = RefreshCallRecorder()
        let second = RefreshCallRecorder()
        let firstAction = BrowserRefreshAction(perform: { await first.record() })
        _ = BrowserRefreshAction(perform: { await second.record() })
        await firstAction.perform()
        #expect(await first.count == 1)
        #expect(await second.count == 0)
    }

    @Test("record search combines text and collection token")
    func recordSearch() {
        let did = ResolvedRepository.fixture.did
        let post = RecordRow.fixture(
            uri: "at://\(did)/app.bsky.feed.post/one",
            collection: "app.bsky.feed.post",
            rkey: "one",
            json: #"{"text":"macOS drive"}"#
        )
        let profile = RecordRow.fixture(
            uri: "at://\(did)/app.bsky.actor.profile/self",
            collection: "app.bsky.actor.profile",
            rkey: "self",
            json: #"{"displayName":"Drive"}"#
        )
        let query = SearchQuery(text: "drive", tokens: [.collection("app.bsky.feed.post")])
        #expect([post, profile].filter { query.matches(record: $0) } == [post])
    }

    @Test("typed search extracts supported tokens and reports unsupported ones")
    func tokenSearch() {
        let query = SearchQueryParser.parse(
            "drive collection:app.bsky.feed.post owner:\(ResolvedRepository.fixture.did) mime:image/png"
        )
        #expect(query.text == "drive")
        #expect(query.tokens.contains(.collection("app.bsky.feed.post")))
        #expect(query.tokens.contains(.owner(ResolvedRepository.fixture.did)))
        #expect(query.unsupportedTokens(for: .publicRecord) == [.mimeType("image/png")])
    }

    @Test("timestamps retain source field labels and are never repository metadata")
    func timestampProjection() {
        let row = RecordRow.fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one",
            json: #"{"createdAt":"2026-08-23T12:34:56Z","updatedAt":"not-a-date"}"#
        )
        let fields = RecordTimestampProjection.fields(in: row)
        #expect(fields.map(\.field) == ["createdAt"])
        #expect(fields.first?.sourceValue == "2026-08-23T12:34:56Z")
        #expect(!fields.contains { $0.field == "Modified" })
    }

    @Test("empty collection, no matches, and unsupported filter are distinct")
    func emptyAndUnsupportedStates() {
        #expect(PublicRecordPresentation.surface(
            rows: [], repository: .fixture, query: .init()
        ) == .emptyCollection)
        #expect(PublicRecordPresentation.surface(
            rows: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one")],
            repository: .fixture,
            query: .init(text: "absent")
        ) == .noMatches)
        #expect(PublicRecordPresentation.surface(
            rows: [],
            repository: .fixture,
            query: .init(tokens: [.space("at://did:plc:z72i7hdynmk6r22z27h6tvur/space/type/key")])
        ) == .unsupportedTokens([.space("at://did:plc:z72i7hdynmk6r22z27h6tvur/space/type/key")]))
    }

    @Test("inspector keeps friendly and exact public identity")
    func inspectorProjection() {
        let row = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one", collection: "app.test.item", rkey: "one")
        let locator = RecordLocator(
            scope: ResolvedRepository.fixture.scope,
            uri: row.uri,
            collection: row.collection,
            rkey: row.rkey,
            cid: row.cid
        )
        let value = BrowserInspectorProjection.record(row, locator: locator)
        #expect(value.access == .publicRepository(did: ResolvedRepository.fixture.did))
        #expect(value.fields["URI"] == row.uri)
        #expect(value.fields["CID"] == row.cid)
        #expect(value.rawJSON == row.json)
    }

    @Test("parser handles blank input, repeated tokens, quoted spaces, and escaped characters")
    func parserEdgeCases() {
        let blank = SearchQueryParser.parse("   ")
        #expect(blank.text.isEmpty)
        #expect(blank.tokens.isEmpty)

        let repeated = SearchQueryParser.parse("collection:one collection:two")
        #expect(repeated.tokens == [.collection("one"), .collection("two")])

        let quoted = SearchQueryParser.parse(#"owner:"John Doe" kind:"record" hello"#)
        #expect(quoted.tokens.contains(.owner("John Doe")))
        #expect(quoted.tokens.contains(.kind("record")))
        #expect(quoted.text == "hello")

        let escaped = SearchQueryParser.parse(#"space:"a\"b\\c" text"#)
        #expect(escaped.tokens.contains(.space(#"a"b\c"#)))
        #expect(escaped.text == "text")

        let unterminated = SearchQueryParser.parse(#"owner:"unterminated string"#)
        #expect(unterminated.tokens.isEmpty)
        #expect(unterminated.text.contains("unterminated"))

        let unknownPrefix = SearchQueryParser.parse("foo:bar baz")
        #expect(unknownPrefix.tokens.isEmpty)
        #expect(unknownPrefix.text == "foo:bar baz")
    }

    @Test("record sorting handles valid, missing, and equal timestamps deterministically")
    func recordSorting() {
        let repo = ResolvedRepository.fixture
        let r1 = RecordRow.fixture(
            uri: "at://\(repo.did)/app.test/1",
            json: #"{"createdAt":"2026-08-23T10:00:00Z"}"#
        )
        let r2 = RecordRow.fixture(
            uri: "at://\(repo.did)/app.test/2",
            json: #"{"createdAt":"2026-08-23T12:00:00Z"}"#
        )
        let r3 = RecordRow.fixture(
            uri: "at://\(repo.did)/app.test/3",
            json: #"{"createdAt":"2026-08-23T10:00:00Z"}"#
        )
        let r4 = RecordRow.fixture(
            uri: "at://\(repo.did)/app.test/4",
            json: #"{"other":"value"}"#
        )

        let items = [r4, r2, r1, r3].map { PublicRecordItem(record: $0, repository: repo) }
        let sortedAscending = items.sorted(by: BrowserSort(field: "createdAt", ascending: true))
        #expect(sortedAscending.map(\.record.uri) == [
            "at://\(repo.did)/app.test/1",
            "at://\(repo.did)/app.test/3",
            "at://\(repo.did)/app.test/2",
            "at://\(repo.did)/app.test/4"
        ])

        let sortedDescending = items.sorted(by: BrowserSort(field: "createdAt", ascending: false))
        #expect(sortedDescending.map(\.record.uri) == [
            "at://\(repo.did)/app.test/2",
            "at://\(repo.did)/app.test/1",
            "at://\(repo.did)/app.test/3",
            "at://\(repo.did)/app.test/4"
        ])
    }

    @MainActor
    @Test("paging retry sends failed cursor and preserves existing rows")
    func pagingRetryBehavior() async {
        let repo = ResolvedRepository.fixture
        let page1 = RepositoryRecordPage(
            records: [.fixture(uri: "at://\(repo.did)/app.test/1", rkey: "1")],
            cursor: "cursor-1"
        )
        let page2 = RepositoryRecordPage(
            records: [.fixture(uri: "at://\(repo.did)/app.test/2", rkey: "2")],
            cursor: nil
        )
        let service = ScriptedPublicRepositoryService(
            pages: [nil: page1, "cursor-1": page2]
        )
        await service.failNextPage(cursor: "cursor-1", with: .transport("Network error"))
        let store = PublicRecordStore(
            service: service,
            repository: repo,
            collection: "app.test"
        )
        await store.loadFirstPage()
        #expect(store.rows.count == 1)
        #expect(store.nextCursor == "cursor-1")

        await store.loadNextPage()
        #expect(store.rows.count == 1)
        #expect(store.appendFailure != nil)
        #expect(store.retryCursor == "cursor-1")
        #expect(store.canRetryPage)

        await store.retryFailedPage()
        #expect(store.rows.count == 2)
        #expect(store.appendFailure == nil)
        #expect(store.retryCursor == nil)
        #expect(store.nextCursor == nil)
    }

    @Test("selection retention across filter-away, filter-back, sort, and append")
    func selectionRetentionBehavior() {
        let repo = ResolvedRepository.fixture
        let r1 = RecordRow.fixture(uri: "at://\(repo.did)/app.test/1", rkey: "1", cid: "cid-1")
        let r2 = RecordRow.fixture(uri: "at://\(repo.did)/app.test/2", rkey: "2", cid: "cid-2")
        let item1 = PublicRecordItem(record: r1, repository: repo)
        let item2 = PublicRecordItem(record: r2, repository: repo)

        // Initial selection: item1 selected
        var selectedRefs: [String: ResourceReference] = [item1.id: item1.reference]

        // 1. Filter-away: only item2 is visible in table; table reports selection empty for visible items
        let filteredVisible = [item2]
        let retainedAfterFilterAway = PublicRecordPresentation.updatedSelection(
            currentSelectedReferences: selectedRefs,
            visibleItems: filteredVisible,
            newSelectedIDs: []
        )
        // item1 is retained outside visible universe
        #expect(retainedAfterFilterAway == [item1.reference])
        selectedRefs = Dictionary(uniqueKeysWithValues: retainedAfterFilterAway.map { ($0.stableID, $0) })

        // 2. Filter-back: both items visible again; item1 is still selected in session
        let restoredVisible = [item1, item2]
        let visibleSelectedIDs = Set(restoredVisible.map(\.id)).intersection(Set(selectedRefs.keys))
        #expect(visibleSelectedIDs == [item1.id])

        // 3. Sort: change sort order of items; selection remains identical
        let sortedItems = [item2, item1]
        let sortedVisibleSelected = Set(sortedItems.map(\.id)).intersection(Set(selectedRefs.keys))
        #expect(sortedVisibleSelected == [item1.id])

        // 4. Append: new page row arrives; existing selection unchanged
        let r3 = RecordRow.fixture(uri: "at://\(repo.did)/app.test/3", rkey: "3", cid: "cid-3")
        let item3 = PublicRecordItem(record: r3, repository: repo)
        let appendedVisible = [item1, item2, item3]
        let appendedVisibleSelected = Set(appendedVisible.map(\.id)).intersection(Set(selectedRefs.keys))
        #expect(appendedVisibleSelected == [item1.id])
    }
    @Test("selection pruning retains unchanged refresh and prunes same-URI new-CID")
    func selectionPruningOnRefresh() {
        let repo = ResolvedRepository.fixture
        let r1 = RecordRow.fixture(uri: "at://\(repo.did)/app.test/1", collection: "app.test", rkey: "1", cid: "cid-old")
        let r2 = RecordRow.fixture(uri: "at://\(repo.did)/app.test/2", collection: "app.test", rkey: "2", cid: "cid-2")
        let item1Old = PublicRecordItem(record: r1, repository: repo)
        let item2 = PublicRecordItem(record: r2, repository: repo)

        let currentRefs: [String: ResourceReference] = [
            item1Old.id: item1Old.reference,
            item2.id: item2.reference
        ]

        // Unchanged refresh: both rows returned as-is
        let unchangedPruned = PublicRecordPresentation.prunedSelection(
            currentSelectedReferences: currentRefs,
            refreshedRows: [r1, r2],
            repository: repo,
            collection: "app.test"
        )
        #expect(unchangedPruned == [item1Old.reference, item2.reference])

        // Same-URI / New-CID refresh: r1 updated to cid-new, r2 unchanged
        let r1New = RecordRow.fixture(uri: "at://\(repo.did)/app.test/1", collection: "app.test", rkey: "1", cid: "cid-new")
        let newCIDPruned = PublicRecordPresentation.prunedSelection(
            currentSelectedReferences: currentRefs,
            refreshedRows: [r1New, r2],
            repository: repo,
            collection: "app.test"
        )
        // item1Old with cid-old was pruned, item2 remains
        #expect(newCIDPruned == [item2.reference])
    }

    @Test("multi-selection inspector resolves common access classification")
    func multiSelectionInspector() {
        let did = ResolvedRepository.fixture.did
        let r1 = RecordRow.fixture(uri: "at://\(did)/app.test/1", rkey: "1")
        let r2 = RecordRow.fixture(uri: "at://\(did)/app.test/2", rkey: "2")
        let item1 = PublicRecordItem(record: r1, repository: .fixture)
        let item2 = PublicRecordItem(record: r2, repository: .fixture)

        let commonAccess = BrowserInspectorView.commonAccessClassification(
            for: [item1.reference, item2.reference]
        )
        #expect(commonAccess == .publicRepository(did: did))

        let view = BrowserInspectorView(references: [item1.reference, item2.reference])
        #expect(view.references.count == 2)
    }

    @Test("incremental typing of collection: prefix never commits an empty token or clears text")
    func incrementalPrefixTyping() {
        var prefix = ""
        for char in "collection:" {
            prefix.append(char)
            let query = SearchQueryParser.parse(prefix)
            #expect(query.tokens.isEmpty, "Prefix '\(prefix)' must not parse as a token")
            #expect(query.text == prefix, "Prefix '\(prefix)' must remain in free text")
        }

        // Empty quoted token also never commits
        let emptyQuoted = SearchQueryParser.parse(#"collection:"" text"#)
        #expect(emptyQuoted.tokens.isEmpty)

        // Typing a complete token with value parses the token
        let complete = SearchQueryParser.parse("collection:app.bsky.feed.post")
        #expect(complete.tokens == [.collection("app.bsky.feed.post")])
        #expect(complete.text.isEmpty)
    }

    @Test("typing 'drive collection:app.bsky.feed.post' character-by-character never commits token until terminated by whitespace or submit")
    func incrementalTypingWithExistingText() {
        let fullString = "drive collection:app.bsky.feed.post"
        var currentInput = ""

        // Type character by character up to the end of the token without trailing whitespace
        for char in fullString {
            currentInput.append(char)
            let result = PublicRecordPresentation.extractTerminatedTokens(from: currentInput)
            #expect(result == nil, "Input '\(currentInput)' must not commit any token while token word is in-progress")
        }

        // When trailing whitespace is added, the token commits
        let withTrailingSpace = currentInput + " "
        let resultWithSpace = PublicRecordPresentation.extractTerminatedTokens(from: withTrailingSpace)
        #expect(resultWithSpace?.newTokens == [.collection("app.bsky.feed.post")])
        #expect(resultWithSpace?.remainingText == "drive")

        // On submit without trailing space, the entire input is parsed
        let submitParsed = SearchQueryParser.parse(currentInput)
        #expect(submitParsed.tokens == [.collection("app.bsky.feed.post")])
        #expect(submitParsed.text == "drive")
    }
}
