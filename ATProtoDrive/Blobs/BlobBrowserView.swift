import AppKit
import SwiftUI

public struct BlobBrowserView: View {
    @Bindable var store: BlobInventoryStore
    @Bindable var session: BrowserSession
    @FocusState private var isSearchFocused: Bool
    @State private var searchInput = ""
    @State private var sortOrder: [KeyPathComparator<BlobTableItem>] = [
        KeyPathComparator(\.suggestedFilename, order: .forward)
    ]

    public init(store: BlobInventoryStore, session: BrowserSession) {
        self.store = store
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            BrowserTableShell(state: store.loadState, retry: {
                Task { await store.reload() }
            }) { snapshot in
                browserContent(snapshot)
            }
            footer
        }
        .searchable(text: $searchInput, prompt: Text("Search files by CID, MIME type, or metadata token"))
        .searchFocused($isSearchFocused)
        .focusedSceneValue(\.browserFocusSearchAction, BrowserFocusSearchAction {
            isSearchFocused = true
        })
        .onChange(of: searchInput) { _, value in
            session.searchQuery = SearchQueryParser.parse(value)
            pruneSelectionToVisibleItems()
        }
        .onChange(of: store.snapshot.blobs) { _, blobs in
            let pruned = BlobBrowserPresentation.prunedSelection(
                currentSelectedReferences: session.selectedReferences,
                repositoryScope: store.repository.scope,
                refreshedBlobs: blobs
            )
            replaceSelectionIfChanged(pruned)
        }
        .onChange(of: sortOrder) { _, order in
            updateSessionSort(order)
        }
    }

    @ViewBuilder
    private func browserContent(_ snapshot: BlobInventorySnapshot) -> some View {
        switch BlobBrowserPresentation.surface(blobs: snapshot.blobs, query: session.searchQuery) {
        case .emptyInventory:
            ContentUnavailableView(
                "No public files",
                systemImage: "doc",
                description: Text("This repository did not enumerate any public file blobs.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noMatches:
            ContentUnavailableView {
                Label("No files match this search", systemImage: "magnifyingglass")
            } description: {
                Text("Try a different CID, MIME type, or filter.")
            } actions: {
                Button("Clear Search") {
                    searchInput = ""
                    session.searchQuery = SearchQuery()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unsupportedTokens(let tokens):
            ContentUnavailableView {
                Label("Filter unavailable for public files", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Unsupported filter: \(tokens.map(\.id).joined(separator: ", ")). Use source, owner, kind, mime, or verification.")
            } actions: {
                Button("Clear Search") {
                    searchInput = ""
                    session.searchQuery = SearchQuery()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rows(let rows):
            fileTable(rows)
        }
    }

    private func fileTable(_ rows: [BlobTableItem]) -> some View {
        let sorted = rows.sorted(by: session.sort)
        return Table(sorted, selection: selectionBinding(items: rows), sortOrder: $sortOrder) {
            TableColumn("Suggested Name", value: \.suggestedFilename) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.suggestedFilename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Suggested from CID and MIME type")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: item.blob.fileSymbolName)
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("CID", value: \.cid) { item in
                Text(item.cid)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("MIME Type", value: \.mimeType) { item in
                Text(item.mimeType)
                    .foregroundStyle(item.blob.mimeType == nil ? .secondary : .primary)
            }
            TableColumn("Declared Size", value: \.sizeSortValue) { item in
                Text(item.declaredSizeLabel)
                    .foregroundStyle(item.blob.declaredSize == nil ? .secondary : .primary)
            }
            TableColumn("References", value: \.referenceCount) { item in
                Text(item.referenceCountLabel)
                    .foregroundStyle(item.blob.referenceIndexComplete ? .primary : .secondary)
            }
            TableColumn("Verification", value: \.verification) { item in
                Text(item.verification)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: BlobTableItem.ID.self) { selection in
            if let id = selection.first, let item = rows.first(where: { $0.id == id }) {
                Button("Copy CID") { copyCID(item.cid) }
                Button("Inspect") {
                    session.replaceSelection(with: [item.reference])
                    session.isInspectorPresented = true
                }
            }
        } primaryAction: { selection in
            if let id = selection.first, let item = rows.first(where: { $0.id == id }) {
                session.replaceSelection(with: [item.reference])
                session.isInspectorPresented = true
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            if let failure = store.appendFailure {
                InlineErrorBanner(message: failure.localizedDescription, actionTitle: "Retry Page") {
                    Task { await store.retryPage() }
                }
            }
            if let failure = store.referenceFailure {
                InlineErrorBanner(message: failure.localizedDescription, actionTitle: "Retry Scan") {
                    Task { await store.scanReferences() }
                }
            }
            HStack(spacing: 12) {
                pagingControls
                Divider().frame(height: 18)
                referenceControls
                Spacer()
                completionSummary
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var pagingControls: some View {
        if store.isLoadingPage {
            ProgressView().controlSize(.small)
            Text("Loading files…").font(.subheadline).foregroundStyle(.secondary)
        } else if store.canRetryPage {
            Button("Retry Page") { Task { await store.retryPage() } }
                .buttonStyle(.bordered)
        } else if store.canLoadMore {
            Button("Load More") { Task { await store.loadMore() } }
                .buttonStyle(.bordered)
        } else {
            Text(store.snapshot.blobEnumerationComplete ? "All blob pages loaded" : "Blob enumeration pending")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var referenceControls: some View {
        if store.isScanningReferences {
            ProgressView().controlSize(.small)
            Text("\(store.referenceProgress.collectionsScanned) collections · \(store.referenceProgress.recordsScanned) records · \(store.referenceProgress.referencesFound) references")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Cancel") { store.cancelReferenceScan() }
                .buttonStyle(.bordered)
        } else {
            Button(store.referenceFailure == nil ? "Scan References" : "Retry Scan") {
                Task { await store.scanReferences() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var completionSummary: some View {
        Text(completionSummaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var completionSummaryText: String {
        if store.loadState.isStale {
            return "Showing previous file inventory · refresh failed"
        }
        if store.snapshot.isComplete {
            return "Inventory and reference scan complete"
        }
        return "Metadata only · file bytes not fetched"
    }

    private func selectionBinding(items: [BlobTableItem]) -> Binding<Set<BlobTableItem.ID>> {
        Binding(
            get: { session.selectedItemIDs.intersection(Set(items.map(\.id))) },
            set: { ids in
                let updated = BlobBrowserPresentation.updatedSelection(
                    currentSelectedReferences: session.selectedReferences,
                    repositoryScope: store.repository.scope,
                    visibleItems: items,
                    newSelectedIDs: ids
                )
                replaceSelectionIfChanged(updated)
            }
        )
    }

    private func pruneSelectionToVisibleItems() {
        let items: [BlobTableItem]
        if case .rows(let visible) = BlobBrowserPresentation.surface(
            blobs: store.snapshot.blobs, query: session.searchQuery
        ) {
            items = visible
        } else {
            items = []
        }
        let visibleIDs = Set(items.map(\.id))
        let selected = session.selectedItemIDs.intersection(visibleIDs)
        let updated = BlobBrowserPresentation.updatedSelection(
            currentSelectedReferences: session.selectedReferences,
            repositoryScope: store.repository.scope,
            visibleItems: items,
            newSelectedIDs: selected
        )
        replaceSelectionIfChanged(updated)
    }

    private func replaceSelectionIfChanged(_ references: Set<ResourceReference>) {
        guard references != Set(session.selectedReferences.values) else { return }
        session.replaceSelection(with: references)
    }

    private func updateSessionSort(_ order: [KeyPathComparator<BlobTableItem>]) {
        guard let first = order.first else { return }
        let field: String
        if first.keyPath == \BlobTableItem.cid { field = "cid" }
        else if first.keyPath == \BlobTableItem.mimeType { field = "mime" }
        else if first.keyPath == \BlobTableItem.sizeSortValue { field = "size" }
        else if first.keyPath == \BlobTableItem.referenceCount { field = "references" }
        else if first.keyPath == \BlobTableItem.verification { field = "verification" }
        else { field = "suggested name" }
        session.sort = BrowserSort(field: field, ascending: first.order == .forward)
    }

    private func copyCID(_ cid: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cid, forType: .string)
    }
}
