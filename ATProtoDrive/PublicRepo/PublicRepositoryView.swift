import SwiftUI

public struct CollectionRow: Identifiable, Hashable, Sendable {
    public var id: String { reference.stableID }
    public let nsid: String
    public let title: String
    public let reference: ResourceReference

    public init(nsid: String, title: String, reference: ResourceReference) {
        self.nsid = nsid
        self.title = title
        self.reference = reference
    }
}

public enum KnownCollectionNames {
    private static let titles = [
        "app.bsky.feed.post": "Posts",
        "app.bsky.actor.profile": "Profile"
    ]
    public static func title(for nsid: String) -> String? { titles[nsid] }
}

public enum PublicRepositoryPresentation {
    public static func collections(_ description: RepositoryDescription) -> [CollectionRow] {
        description.collections.map { nsid in
            CollectionRow(
                nsid: nsid,
                title: KnownCollectionNames.title(for: nsid) ?? nsid,
                reference: .collection(
                    scope: description.repository.scope,
                    collection: nsid
                )
            )
        }
    }
}

@MainActor
public enum PublicRepositoryOpenCoordinator {
    public static func open(
        _ target: RepositoryTarget,
        store: PublicRepositoryStore,
        session: BrowserSession,
        recents: RecentRepositoryStore,
        selectedSource: BrowserSource? = nil
    ) async {
        await store.open(target: target)
        guard !Task.isCancelled, store.target == target,
              case .loaded(let description) = store.state else { return }
        let source = selectedSource ?? .openedPublicRepository(did: description.repository.did)
        session.selectSource(source)
        session.navigate(to: BrowserPath(
            source: source,
            components: [.repository(description.repository.scope)]
        ))
        let sourceAccountDID: String?
        if case .connectedAccount(let did) = target { sourceAccountDID = did }
        else { sourceAccountDID = nil }
        let summary = OpenedRepositorySummary(
            did: description.repository.did,
            handle: description.repository.handle,
            pdsURL: description.repository.pdsURL,
            sourceAccountDID: sourceAccountDID,
            lastOpenedAt: .now
        )
        session.rememberOpenedRepository(summary)
        await recents.remember(summary)
    }

    @discardableResult
    public static func openCollection(
        _ collection: String,
        store: PublicRepositoryStore,
        session: BrowserSession
    ) async -> Bool {
        let originalPath = session.path
        guard let description = store.state.snapshot,
              description.collections.contains(collection),
              let originalSource = session.selectedSource else { return false }
        guard await store.loadCollection(collection) != nil,
              !Task.isCancelled,
              session.selectedSource == originalSource,
              session.path == originalPath,
              store.state.snapshot?.repository.scope == description.repository.scope else { return false }
        let source: BrowserSource
        if case .account(let did, .publicBlobs) = originalSource {
            source = .account(did: did, destination: .publicRecords)
        } else { source = originalSource }
        session.navigate(to: BrowserPath(
            source: source,
            components: [
                .repository(description.repository.scope),
                .collection(scope: description.repository.scope, collection: collection)
            ]
        ))
        return true
    }

    public static func restorePreviousTarget(
        _ previousTarget: RepositoryTarget?,
        store: PublicRepositoryStore,
        session: BrowserSession
    ) async {
        guard let previousTarget else { return }
        await store.open(target: previousTarget)
        if case .loaded(let description) = store.state,
           let path = session.path, path.components.count >= 2,
           case .collection(_, let collection) = path.components[1],
           description.collections.contains(collection) {
            _ = await store.loadCollection(collection)
        }
    }
}

public struct BrowserBreadcrumbView: View {
    @Bindable var session: BrowserSession
    let repository: ResolvedRepository
    let currentCollection: String?

    public init(session: BrowserSession, repository: ResolvedRepository, currentCollection: String? = nil) {
        self.session = session
        self.repository = repository
        self.currentCollection = currentCollection
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button {
                guard let source = session.selectedSource else { return }
                session.navigate(to: BrowserPath(
                    source: source,
                    components: [.repository(repository.scope)]
                ))
            } label: {
                Text(repository.handle ?? repository.did)
                    .fontWeight(.medium)
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                guard let source = session.selectedSource else { return }
                session.navigate(to: BrowserPath(
                    source: source,
                    components: [.repository(repository.scope)]
                ))
            } label: {
                Text("Public Records")
            }
            .buttonStyle(.plain)

            if let currentCollection {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    // Current collection segment
                } label: {
                    Text(KnownCollectionNames.title(for: currentCollection) ?? currentCollection)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }
}

public struct PublicRepositoryHeaderView: View {
    public let repository: ResolvedRepository

    public init(repository: ResolvedRepository) {
        self.repository = repository
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.handle ?? repository.did)
                        .font(.headline)
                    Text(repository.did)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text("PDS: \(repository.pdsURL.host() ?? repository.pdsURL.absoluteString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if repository.handleIsCorrect == false {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Handle verification mismatch: declared handle may not resolve to this DID.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(.background)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.secondary.opacity(0.15)),
            alignment: .bottom
        )
    }
}

public struct PublicRepositoryView: View {
    @Bindable var session: BrowserSession
    let store: PublicRepositoryStore

    public init(session: BrowserSession, store: PublicRepositoryStore) {
        self.session = session
        self.store = store
    }

    public var body: some View {
        BrowserTableShell(state: store.state, retry: {
            Task { await store.refresh() }
        }) { description in
            VStack(spacing: 0) {
                BrowserBreadcrumbView(session: session, repository: description.repository)

                PublicRepositoryHeaderView(repository: description.repository)

                let rows = PublicRepositoryPresentation.collections(description)
                Table(rows, selection: Binding(
                    get: { session.primarySelectionID },
                    set: { selectedID in
                        if let selectedID, let row = rows.first(where: { $0.id == selectedID }) {
                            session.replaceSelection(with: [row.reference])
                        } else {
                            session.replaceSelection(with: [])
                        }
                    }
                )) {
                    TableColumn("Collection") { row in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(row.title)
                                .fontWeight(row.title != row.nsid ? .medium : .regular)
                        }
                    }
                    TableColumn("NSID") { row in
                        Text(row.nsid)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Action") { row in
                        Button("Open") {
                            Task {
                                await PublicRepositoryOpenCoordinator.openCollection(
                                    row.nsid,
                                    store: store,
                                    session: session
                                )
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(min: 60, ideal: 70, max: 80)
                }
                .contextMenu(forSelectionType: String.self) { selection in
                    if let selectedID = selection.first,
                       let row = rows.first(where: { $0.id == selectedID }) {
                        Button("Open Collection") {
                            Task {
                                await PublicRepositoryOpenCoordinator.openCollection(
                                    row.nsid,
                                    store: store,
                                    session: session
                                )
                            }
                        }
                        Button("Copy NSID") {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.nsid, forType: .string)
                            #endif
                        }
                    }
                } primaryAction: { selection in
                    if let selectedID = selection.first,
                       let row = rows.first(where: { $0.id == selectedID }) {
                        Task {
                            await PublicRepositoryOpenCoordinator.openCollection(
                                row.nsid,
                                store: store,
                                session: session
                            )
                        }
                    }
                }
            }
        }
    }
}
