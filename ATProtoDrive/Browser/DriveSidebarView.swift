import SwiftUI

public struct SidebarAccountSummary: Hashable, Sendable {
    public let did: String
    public let handle: String

    public init(did: String, handle: String) {
        self.did = did
        self.handle = handle
    }
}

public enum DriveSidebarSection: Hashable, Sendable {
    case account(String)
    case openedAndRecent
    case utilities
}

public struct DriveSidebarRow: Identifiable, Hashable, Sendable {
    public var id: String { source.stableID }
    public let source: BrowserSource
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let section: DriveSidebarSection

    public var accountDID: String? {
        guard case .account(let did, _) = source else { return nil }
        return did
    }

    public var accountDestination: AccountDestination? {
        guard case .account(_, let destination) = source else { return nil }
        return destination
    }

    public init(
        source: BrowserSource,
        title: String,
        subtitle: String? = nil,
        symbolName: String,
        section: DriveSidebarSection
    ) {
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.section = section
    }
}

public enum DriveSidebarProjection {
    public static func rows(
        accounts: [SidebarAccountSummary],
        openedRepositories: [OpenedRepositorySummary]
    ) -> [DriveSidebarRow] {
        var result: [DriveSidebarRow] = []

        // Account sections
        for account in accounts {
            let section = DriveSidebarSection.account(account.did)
            for destination in AccountDestination.allCases {
                let row = rowForAccountDestination(destination, account: account, section: section)
                result.append(row)
            }
        }

        // Opened & Recent section
        var seenDIDs = Set<String>()
        for repo in openedRepositories {
            if seenDIDs.insert(repo.did).inserted {
                let title = (repo.handle?.isEmpty == false) ? repo.handle! : repo.did
                result.append(DriveSidebarRow(
                    source: .openedPublicRepository(did: repo.did),
                    title: title,
                    subtitle: repo.did,
                    symbolName: "externaldrive.connected.to.line.below",
                    section: .openedAndRecent
                ))
            }
        }

        // Utilities / Global section
        let utilSection = DriveSidebarSection.utilities
        result.append(DriveSidebarRow(
            source: .global(.openPublicRepository),
            title: "Open Public Repository…",
            subtitle: nil,
            symbolName: "globe",
            section: utilSection
        ))
        result.append(DriveSidebarRow(
            source: .global(.openSpace),
            title: "Open Space by URI…",
            subtitle: nil,
            symbolName: "square.and.arrow.down",
            section: utilSection
        ))
        result.append(DriveSidebarRow(
            source: .global(.addAccount),
            title: "Add Account…",
            subtitle: nil,
            symbolName: "person.badge.plus",
            section: utilSection
        ))

        return result
    }

    private static func rowForAccountDestination(
        _ destination: AccountDestination,
        account: SidebarAccountSummary,
        section: DriveSidebarSection
    ) -> DriveSidebarRow {
        let (title, symbolName): (String, String) = switch destination {
        case .overview:
            ("Overview", "house")
        case .publicRecords:
            ("Public Records", "doc.text")
        case .publicBlobs:
            ("Public Blobs", "photo")
        case .spaces:
            ("Spaces", "square.stack.3d.up")
        case .privateAppState:
            ("Private App State", "lock")
        case .backups:
            ("Backups", "arrow.clockwise.icloud")
        case .activity:
            ("Activity", "waveform.path.ecg")
        case .serverAndAccount:
            ("Server & Account", "server.rack")
        }

        return DriveSidebarRow(
            source: .account(did: account.did, destination: destination),
            title: title,
            subtitle: nil,
            symbolName: symbolName,
            section: section
        )
    }
}

public struct DriveSidebarView: View {
    @Bindable var session: BrowserSession
    let recentRepositoryStore: RecentRepositoryStore
    @Environment(AccountStore.self) private var accountStore

    public init(session: BrowserSession, recentRepositoryStore: RecentRepositoryStore) {
        self.session = session
        self.recentRepositoryStore = recentRepositoryStore
    }

    private var accountSummaries: [SidebarAccountSummary] {
        accountStore.accounts.map {
            SidebarAccountSummary(did: $0.id, handle: $0.handle)
        }
    }

    private var mergedOpenedRepositories: [OpenedRepositorySummary] {
        var result = session.openedPublicRepositories
        var seenIDs = Set(result.map(\.id))
        for entry in recentRepositoryStore.entries {
            if seenIDs.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    private var rows: [DriveSidebarRow] {
        DriveSidebarProjection.rows(
            accounts: accountSummaries,
            openedRepositories: mergedOpenedRepositories
        )
    }

    public var body: some View {
        List(selection: Binding(
            get: { session.selectedSource },
            set: { newSource in
                if let newSource {
                    session.selectSource(newSource)
                } else {
                    session.selectedSource = nil
                }
            }
        )) {
            // Group by account if any
            ForEach(accountSummaries, id: \.did) { account in
                let accountRows = rows.filter { $0.section == .account(account.did) }
                Section(header: Text(account.handle.isEmpty ? account.did : account.handle)) {
                    ForEach(accountRows) { row in
                        rowView(for: row)
                    }
                }
            }

            let recentRows = rows.filter { $0.section == .openedAndRecent }
            if !recentRows.isEmpty {
                Section(header: Text("Opened & Recent")) {
                    ForEach(recentRows) { row in
                        rowView(for: row)
                    }
                }
            }

            let utilityRows = rows.filter { $0.section == .utilities }
            if !utilityRows.isEmpty {
                Section(header: Text("Utilities")) {
                    ForEach(utilityRows) { row in
                        rowView(for: row)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func rowView(for row: DriveSidebarRow) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: row.symbolName)
        }
        .tag(row.source)
    }
}
