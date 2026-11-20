import SwiftUI

public struct PublicRecordItem: Identifiable, Hashable, Sendable {
    public let record: RecordRow
    public let reference: ResourceReference
    public let timestampFields: [RecordTimestampField]
    public var id: String { reference.stableID }

    public init(record: RecordRow, repository: ResolvedRepository) {
        let locator = RecordLocator(
            scope: repository.scope,
            uri: record.uri,
            collection: record.collection,
            rkey: record.rkey,
            cid: record.cid
        )
        self.record = record
        self.reference = .record(locator)
        self.timestampFields = RecordTimestampProjection.fields(in: record)
    }

    public init(record: RecordRow, repository: ResolvedRepository, timestampFields: [RecordTimestampField]) {
        let locator = RecordLocator(
            scope: repository.scope,
            uri: record.uri,
            collection: record.collection,
            rkey: record.rkey,
            cid: record.cid
        )
        self.record = record
        self.reference = .record(locator)
        self.timestampFields = timestampFields
    }
}

public enum PublicRecordSurfaceState: Equatable, Sendable {
    case rows([PublicRecordItem])
    case emptyCollection
    case noMatches
    case unsupportedTokens([SearchToken])
}

public struct RecordTimestampField: Hashable, Sendable {
    public let field: String
    public let date: Date
    public let sourceValue: String

    public init(field: String, date: Date, sourceValue: String) {
        self.field = field
        self.date = date
        self.sourceValue = sourceValue
    }
}

public enum RecordTimestampProjection {
    public static func parseDate(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: string)
    }

    public static func fields(in record: RecordRow) -> [RecordTimestampField] {
        guard let data = record.json.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [RecordTimestampField] = []
        for (key, value) in jsonObject {
            guard let stringValue = value as? String,
                  let date = parseDate(from: stringValue) else {
                continue
            }
            results.append(RecordTimestampField(field: key, date: date, sourceValue: stringValue))
        }

        return results.sorted { $0.field < $1.field }
    }

    public static func columnNames(in items: [PublicRecordItem]) -> [String] {
        var set = Set<String>()
        for item in items {
            for field in item.timestampFields {
                set.insert(field.field)
            }
        }
        return set.sorted()
    }

    public static func columnNames(in records: [RecordRow]) -> [String] {
        var set = Set<String>()
        for record in records {
            for field in fields(in: record) {
                set.insert(field.field)
            }
        }
        return set.sorted()
    }
}

public enum PublicRecordPresentation {
    public static func surface(
        rows: [RecordRow],
        repository: ResolvedRepository,
        query: SearchQuery
    ) -> PublicRecordSurfaceState {
        let unsupported = query.unsupportedTokens(for: .publicRecord)
        if !unsupported.isEmpty {
            return .unsupportedTokens(unsupported)
        }
        if rows.isEmpty {
            return .emptyCollection
        }
        let matched = rows.filter { query.matches(record: $0, repository: repository) }
        if matched.isEmpty {
            return .noMatches
        }
        return .rows(matched.map { PublicRecordItem(record: $0, repository: repository) })
    }

    /// Extracts completed tokens from the terminated prefix of input text (up to the last whitespace).
    /// The trailing in-progress word is preserved and never tokenized on keystroke.
    public static func extractTerminatedTokens(from input: String) -> (newTokens: [SearchToken], remainingText: String)? {
        guard let lastSpaceIdx = input.lastIndex(where: { $0.isWhitespace }) else {
            return nil
        }
        let terminatedPrefix = String(input[...lastSpaceIdx])
        let inProgress = String(input[input.index(after: lastSpaceIdx)...])

        let parsed = SearchQueryParser.parse(terminatedPrefix)
        guard !parsed.tokens.isEmpty else {
            return nil
        }

        let remaining = inProgress.isEmpty ? parsed.text : (parsed.text.isEmpty ? inProgress : "\(parsed.text) \(inProgress)")
        return (parsed.tokens, remaining)
    }

    /// Calculates the new complete qualified selection set when visible table selection changes.
    public static func updatedSelection(
        currentSelectedReferences: [String: ResourceReference],
        visibleItems: [PublicRecordItem],
        newSelectedIDs: Set<PublicRecordItem.ID>
    ) -> Set<ResourceReference> {
        let visibleUniverse = Set(visibleItems.map(\.reference))
        let itemsByID = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.id, $0.reference) })
        let retainedOutsideVisible = Set(currentSelectedReferences.values).subtracting(visibleUniverse)
        let newlySelectedReferences = Set(newSelectedIDs.compactMap { itemsByID[$0] })
        return retainedOutsideVisible.union(newlySelectedReferences)
    }

    /// Prunes selected record references in the current collection that are no longer present in the fresh store rows.
    /// Does NOT prune references outside the current collection or repository scope.
    public static func prunedSelection(
        currentSelectedReferences: [String: ResourceReference],
        refreshedRows: [RecordRow],
        repository: ResolvedRepository,
        collection: String
    ) -> Set<ResourceReference> {
        let freshReferences = Set(refreshedRows.map {
            PublicRecordItem(record: $0, repository: repository).reference
        })
        var result: Set<ResourceReference> = []
        for ref in currentSelectedReferences.values {
            switch ref {
            case .record(let locator):
                if locator.scope == repository.scope && locator.collection == collection {
                    if freshReferences.contains(ref) {
                        result.insert(ref)
                    }
                } else {
                    result.insert(ref)
                }
            default:
                result.insert(ref)
            }
        }
        return result
    }

    /// Returns `true` only when the signed-in account owns `repository` and may mutate its public records.
    public static func isWriteEnabled(
        repository: ResolvedRepository,
        owningAccount: AccountStore.Account?
    ) -> Bool {
        PublicRecordMutationService.canMutate(repositoryDID: repository.did, with: owningAccount)
    }
}

public extension Array where Element == PublicRecordItem {
    func sorted(by sort: BrowserSort) -> [PublicRecordItem] {
        let field = sort.field
        let ascending = sort.ascending
        return sorted { a, b in
            switch field.lowercased() {
            case "type", "collection":
                let cmp = a.record.collection.localizedStandardCompare(b.record.collection)
                if cmp != .orderedSame {
                    return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
                return a.record.uri < b.record.uri
            case "record key", "rkey":
                let cmp = a.record.rkey.localizedStandardCompare(b.record.rkey)
                if cmp != .orderedSame {
                    return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
                return a.record.uri < b.record.uri
            case "uri":
                let cmp = a.record.uri.localizedStandardCompare(b.record.uri)
                if cmp != .orderedSame {
                    return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
                return a.record.uri < b.record.uri
            case "cid":
                let cmp = a.record.cid.localizedStandardCompare(b.record.cid)
                if cmp != .orderedSame {
                    return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
                return a.record.uri < b.record.uri
            default:
                let aField = a.timestampFields.first { $0.field == field }
                let bField = b.timestampFields.first { $0.field == field }
                switch (aField, bField) {
                case (.some(let aF), .some(let bF)):
                    if aF.date != bF.date {
                        return ascending ? aF.date < bF.date : aF.date > bF.date
                    }
                    return a.record.uri < b.record.uri
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    let cmp = a.record.rkey.localizedStandardCompare(b.record.rkey)
                    if cmp != .orderedSame {
                        return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                    }
                    return a.record.uri < b.record.uri
                }
            }
        }
    }
}

public struct PublicRecordTable: View {
    let store: PublicRecordStore
    @Bindable var session: BrowserSession
    let owningAccount: AccountStore.Account?
    let mutationService: PublicRecordMutationService
    @FocusState private var isSearchFocused: Bool
    @State private var searchInput: String = ""
    @State private var sortOrder: [KeyPathComparator<PublicRecordItem>] = [
        KeyPathComparator(\.record.rkey, order: .forward)
    ]
    @State private var editorMode: PublicRecordEditorSheet.Mode?
    @State private var recordPendingDelete: RecordRow?
    @State private var isDeletingRecord: Bool = false
    @State private var deleteConflictMessage: String?
    @State private var deleteErrorMessage: String?

    public init(
        store: PublicRecordStore,
        session: BrowserSession,
        owningAccount: AccountStore.Account? = nil,
        mutationService: PublicRecordMutationService = PublicRecordMutationService()
    ) {
        self.store = store
        self.session = session
        self.owningAccount = owningAccount
        self.mutationService = mutationService
    }

    private var writableAccount: AccountStore.Account? {
        guard let owningAccount,
              PublicRecordPresentation.isWriteEnabled(
                  repository: store.repository,
                  owningAccount: owningAccount
              ) else {
            return nil
        }
        return owningAccount
    }

    private var surfaceState: PublicRecordSurfaceState {
        PublicRecordPresentation.surface(
            rows: store.rows,
            repository: store.repository,
            query: session.searchQuery
        )
    }

    private var visibleItems: [PublicRecordItem] {
        guard case .rows(let items) = surfaceState else { return [] }
        return items
    }

    private var singleSelectedRecord: RecordRow? {
        let items = visibleItems
        let visibleIDs = Set(items.map(\.id))
        let selectedVisible = session.selectedItemIDs.intersection(visibleIDs)
        guard selectedVisible.count == 1, let onlyID = selectedVisible.first else {
            return nil
        }
        return items.first(where: { $0.id == onlyID })?.record
    }

    public var body: some View {
        VStack(spacing: 0) {
            if writableAccount != nil {
                ownerActionBar
                Divider()
            }
            contentView
            footerView
        }
        .searchable(
            text: $searchInput,
            tokens: $session.searchQuery.tokens,
            suggestedTokens: .constant([
                .collection(store.collection),
                .owner(store.repository.did),
                .source("public"),
                .kind("record")
            ]),
            prompt: Text("Search records by key, URI, CID, or text")
        ) { token in
            tokenView(token)
        }
        .searchFocused($isSearchFocused)
        .focusedSceneValue(\.browserFocusSearchAction, BrowserFocusSearchAction {
            isSearchFocused = true
        })
        .onChange(of: searchInput) { _, newValue in
            handleSearchInputChange(newValue)
        }
        .onSubmit(of: .search) {
            handleSearchSubmit()
        }
        .onChange(of: sortOrder) { _, newOrder in
            handleSortOrderChange(newOrder)
        }
        .onChange(of: store.rows) { _, newRows in
            handleRowsRefresh(newRows)
        }
        .sheet(item: $editorMode) { mode in
            if let account = writableAccount {
                PublicRecordEditorSheet(
                    repository: store.repository,
                    account: account,
                    mode: mode,
                    mutationService: mutationService,
                    onRefreshRequested: {
                        await store.refresh()
                    },
                    onSaved: {
                        Task { await store.refresh() }
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Public Record",
            isPresented: Binding(
                get: { recordPendingDelete != nil },
                set: { if !$0 { recordPendingDelete = nil } }
            ),
            presenting: recordPendingDelete
        ) { record in
            Button("Delete Record", role: .destructive) {
                if let account = writableAccount {
                    Task {
                        await performDelete(record: record, account: account)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Delete \(record.collection)/\(record.rkey)? This permanently removes the record from your public repository using compare-and-swap protection (CID: \(record.cid)).")
        }
        .alert(
            "Delete Conflict Detected",
            isPresented: Binding(
                get: { deleteConflictMessage != nil },
                set: { if !$0 { deleteConflictMessage = nil } }
            )
        ) {
            Button("Refresh Collection") {
                deleteConflictMessage = nil
                Task { await store.refresh() }
            }
            Button("Close", role: .cancel) {
                deleteConflictMessage = nil
            }
        } message: {
            if let deleteConflictMessage {
                Text(deleteConflictMessage)
            }
        }
        .alert(
            "Delete Failed",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            if let deleteErrorMessage {
                Text(deleteErrorMessage)
            }
        }
    }

    private var ownerActionBar: some View {
        HStack(spacing: 8) {
            Label("Owner · Public Repository", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isDeletingRecord {
                ProgressView()
                    .controlSize(.small)
            }

            if let selected = singleSelectedRecord {
                Button {
                    editorMode = .edit(record: selected)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDeletingRecord)

                Button(role: .destructive) {
                    recordPendingDelete = selected
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDeletingRecord)
            }

            Button {
                editorMode = .create(defaultCollection: store.collection)
            } label: {
                Label("New Record", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isDeletingRecord)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }

    private func performDelete(record: RecordRow, account: AccountStore.Account) async {
        isDeletingRecord = true
        defer { isDeletingRecord = false }

        do {
            _ = try await mutationService.deleteRecord(
                targetRepoDID: store.repository.did,
                collection: record.collection,
                rkey: record.rkey,
                expectedCID: record.cid,
                account: account
            )
            await store.refresh()
        } catch let mutationError as PublicRecordMutationError {
            if case .conflictDetected(let message) = mutationError {
                deleteConflictMessage = message
            } else {
                deleteErrorMessage = mutationError.localizedDescription
            }
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }

    private func handleSearchInputChange(_ text: String) {
        if let (newTokens, remaining) = PublicRecordPresentation.extractTerminatedTokens(from: text) {
            for token in newTokens {
                if !session.searchQuery.tokens.contains(token) {
                    session.searchQuery.tokens.append(token)
                }
            }
            session.searchQuery.text = remaining
            searchInput = remaining
            return
        }
        session.searchQuery.text = text
    }

    private func handleSearchSubmit() {
        let parsed = SearchQueryParser.parse(searchInput)
        for token in parsed.tokens {
            if !session.searchQuery.tokens.contains(token) {
                session.searchQuery.tokens.append(token)
            }
        }
        session.searchQuery.text = parsed.text
        searchInput = parsed.text
    }

    private func handleSortOrderChange(_ order: [KeyPathComparator<PublicRecordItem>]) {
        guard let first = order.first else { return }
        let ascending = first.order == .forward
        if first.keyPath == \PublicRecordItem.record.collection {
            session.sort = BrowserSort(field: "collection", ascending: ascending)
        } else if first.keyPath == \PublicRecordItem.record.rkey {
            session.sort = BrowserSort(field: "rkey", ascending: ascending)
        } else if first.keyPath == \PublicRecordItem.record.uri {
            session.sort = BrowserSort(field: "uri", ascending: ascending)
        } else if first.keyPath == \PublicRecordItem.record.cid {
            session.sort = BrowserSort(field: "cid", ascending: ascending)
        }
    }

    private func handleRowsRefresh(_ newRows: [RecordRow]) {
        let pruned = PublicRecordPresentation.prunedSelection(
            currentSelectedReferences: session.selectedReferences,
            refreshedRows: newRows,
            repository: store.repository,
            collection: store.collection
        )
        if pruned != Set(session.selectedReferences.values) {
            session.replaceSelection(with: pruned)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch surfaceState {
        case .emptyCollection:
            ContentUnavailableView {
                Label("No records in this collection", systemImage: "doc.text")
            } description: {
                Text("This collection does not contain any records.")
            } actions: {
                if writableAccount != nil {
                    Button {
                        editorMode = .create(defaultCollection: store.collection)
                    } label: {
                        Label("New Record", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .noMatches:
            ContentUnavailableView {
                Label("No records match this search", systemImage: "magnifyingglass")
            } description: {
                Text("Try changing your search terms or filters.")
            } actions: {
                Button("Clear Search") {
                    searchInput = ""
                    session.searchQuery = SearchQuery()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unsupportedTokens(let unsupported):
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "This filter is not available for public records",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Remove unsupported filters to see records.")
                )
                HStack(spacing: 8) {
                    ForEach(unsupported, id: \.self) { token in
                        Button {
                            session.searchQuery.tokens.removeAll { $0 == token }
                        } label: {
                            HStack(spacing: 4) {
                                Text(tokenDescription(token))
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .rows(let items):
            let sorted = items.sorted(by: session.sort)
            let timestampColumns = RecordTimestampProjection.columnNames(in: items)

            Table(sorted, selection: selectionBinding(items: items), sortOrder: $sortOrder) {
                TableColumn("Type", value: \.record.collection) { item in
                    Text(item.record.collection)
                        .onAppear {
                            if item.id == sorted.last?.id && store.canLoadMore && !store.isLoadingPage {
                                Task { await store.loadNextPage() }
                            }
                        }
                }
                TableColumn("Record Key", value: \.record.rkey) { item in
                    Text(item.record.rkey)
                        .font(.system(.body, design: .monospaced))
                }
                TableColumn("URI", value: \.record.uri) { item in
                    Text(item.record.uri)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("CID", value: \.record.cid) { item in
                    Text(item.record.cid)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumnForEach(timestampColumns, id: \.self) { fieldName in
                    TableColumn(fieldName) { item in
                        if let field = item.timestampFields.first(where: { $0.field == fieldName }) {
                            Text(field.sourceValue)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: PublicRecordItem.ID.self) { selection in
                if selection.count == 1,
                   let selectedID = selection.first,
                   let item = sorted.first(where: { $0.id == selectedID }) {
                    Button {
                        RecordCopyAction.copyRecordURI(item.record)
                    } label: {
                        Label("Copy at:// URI", systemImage: "link")
                    }
                    Button {
                        RecordCopyAction.copyRecordCID(item.record)
                    } label: {
                        Label("Copy CID", systemImage: "doc.on.doc")
                    }
                    Button {
                        RecordCopyAction.copyRecordJSON(item.record)
                    } label: {
                        Label("Copy JSON", systemImage: "curlybraces")
                    }
                    if writableAccount != nil {
                        Divider()
                        Button {
                            editorMode = .edit(record: item.record)
                        } label: {
                            Label("Edit Record…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            recordPendingDelete = item.record
                        } label: {
                            Label("Delete Record…", systemImage: "trash")
                        }
                    }
                }
            } primaryAction: { selection in
                guard writableAccount != nil,
                      selection.count == 1,
                      let selectedID = selection.first,
                      let item = sorted.first(where: { $0.id == selectedID }) else {
                    return
                }
                editorMode = .edit(record: item.record)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        if store.isLoadingPage {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading more records…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if store.canRetryPage {
            HStack(spacing: 12) {
                Text("Failed to load next page")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Retry Page") {
                    Task { await store.retryFailedPage() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
        } else if store.canLoadMore {
            Button("Load More") {
                Task { await store.loadNextPage() }
            }
            .buttonStyle(.bordered)
            .padding(.vertical, 8)
        }
    }

    private func selectionBinding(items: [PublicRecordItem]) -> Binding<Set<PublicRecordItem.ID>> {
        Binding(
            get: {
                let visibleIDs = Set(items.map(\.id))
                return session.selectedItemIDs.intersection(visibleIDs)
            },
            set: { newSelectedIDs in
                let updated = PublicRecordPresentation.updatedSelection(
                    currentSelectedReferences: session.selectedReferences,
                    visibleItems: items,
                    newSelectedIDs: newSelectedIDs
                )
                session.replaceSelection(with: updated)
            }
        )
    }

    @ViewBuilder
    private func tokenView(_ token: SearchToken) -> some View {
        HStack(spacing: 4) {
            Text(tokenDescription(token))
        }
    }

    private func tokenDescription(_ token: SearchToken) -> String {
        switch token {
        case .source(let v): "source:\(v)"
        case .account(let v): "account:\(v)"
        case .space(let v): "space:\(v)"
        case .owner(let v): "owner:\(v)"
        case .collection(let v): "collection:\(v)"
        case .kind(let v): "kind:\(v)"
        case .mimeType(let v): "mime:\(v)"
        case .transferState(let v): "state:\(v)"
        case .verification(let v): "verification:\(v)"
        }
    }
}
