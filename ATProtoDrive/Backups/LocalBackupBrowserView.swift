//
//  LocalBackupBrowserView.swift
//  ATProtoDrive
//

import AppKit
import Foundation
import SwiftUI

public struct LocalBackupBrowserView: View {
    public let package: BackupPackageSummary
    public let backupStore: BackupStore?
    public let service: BackupService
    public let onBack: (() -> Void)?

    private enum CollectionSelection: Hashable {
        case all
        case collection(String)

        var collectionNSID: String? {
            switch self {
            case .all:
                return nil
            case .collection(let nsid):
                return nsid
            }
        }
    }

    @State private var records: [BackupRecordEntry] = []
    @State private var loadError: String?
    @State private var selectedCollectionFilter: CollectionSelection = .all
    @State private var selectedRecordID: BackupRecordEntry.ID?
    @State private var searchText: String = ""
    @State private var sortOrder: [KeyPathComparator<BackupRecordEntry>] = [
        KeyPathComparator(\.collection, order: .forward),
        KeyPathComparator(\.rkey, order: .forward),
    ]
    @State private var verificationReport: BackupVerificationReport?
    @State private var isVerifying: Bool = false
    @State private var verificationError: String?
    @State private var copiedBadgeText: String?

    public init(
        package: BackupPackageSummary,
        backupStore: BackupStore? = nil,
        service: BackupService = BackupService(),
        onBack: (() -> Void)? = nil
    ) {
        self.package = package
        self.backupStore = backupStore
        self.service = service
        self.onBack = onBack
    }

    nonisolated public static func filterRecords(
        _ records: [BackupRecordEntry],
        collection: String?,
        query: String
    ) -> [BackupRecordEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { entry in
            if let collection, !collection.isEmpty, entry.collection != collection {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            return entry.collection.localizedStandardContains(trimmed)
                || entry.rkey.localizedStandardContains(trimmed)
                || entry.cid.localizedStandardContains(trimmed)
                || entry.prettyJSON.localizedStandardContains(trimmed)
        }
    }

    private var collectionEntries: [(nsid: String, count: Int)] {
        Dictionary(grouping: records, by: \.collection)
            .map { (nsid: $0.key, count: $0.value.count) }
            .sorted { $0.nsid < $1.nsid }
    }

    private var filteredRecords: [BackupRecordEntry] {
        Self.filterRecords(records, collection: selectedCollectionFilter.collectionNSID, query: searchText)
            .sorted(using: sortOrder)
    }

    private var selectedRecord: BackupRecordEntry? {
        guard let selectedRecordID else { return nil }
        return filteredRecords.first(where: { $0.id == selectedRecordID })
            ?? records.first(where: { $0.id == selectedRecordID })
    }

    private var activeVerificationReport: BackupVerificationReport? {
        verificationReport ?? backupStore?.verificationReports[package.id]
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let report = activeVerificationReport {
                verificationBanner(report: report)
                Divider()
            } else if let verificationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(verificationError)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { self.verificationError = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            if let loadError {
                ContentUnavailableView {
                    Label("Unable to Read Local Backup", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") { loadOfflineRecords() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchBar
                Divider()

                HSplitView {
                    collectionsSidebar
                        .frame(minWidth: 190, idealWidth: 230, maxWidth: 320, maxHeight: .infinity)

                    recordsTablePane
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                    recordInspectorPane
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: 540, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadOfflineRecords()
        }
        .onChange(of: package.id) { _, _ in
            selectedCollectionFilter = .all
            selectedRecordID = nil
            searchText = ""
            verificationReport = nil
            verificationError = nil
            loadOfflineRecords()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Backups", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Label("Local Backup (Offline)", systemImage: "internaldrive")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.teal.opacity(0.16), in: Capsule())
                        .foregroundStyle(.teal)

                    Text(package.manifest.shortOriginBadge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (package.manifest.isSpaceBackup ? Color.purple : Color.blue).opacity(0.14),
                            in: Capsule()
                        )
                        .foregroundStyle(package.manifest.isSpaceBackup ? .purple : .blue)

                    Text(package.manifest.displayTarget)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 10) {
                    Text(package.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("•")
                    Text("\(package.manifest.recordCount) \(package.manifest.recordCount == 1 ? "record" : "records")")
                    Text("•")
                    Text(ByteCountFormatter.string(fromByteCount: package.manifest.carByteCount, countStyle: .file))
                    if let rev = package.manifest.commitRev, !rev.isEmpty {
                        Text("•")
                        Text("rev \(rev)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let copiedBadgeText {
                Text(copiedBadgeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button {
                Task { await runVerification() }
            } label: {
                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Verify Integrity", systemImage: "checkmark.shield")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isVerifying)

            Button {
                if let backupStore {
                    backupStore.revealInFinder(package: package)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([package.packageURL])
                }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func verificationBanner(report: BackupVerificationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: report.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.isValid ? .green : .red)
                if report.isValid {
                    Text("Integrity verified: SHA-256 matches, manifest valid, \(report.recordCount) records intact.")
                        .font(.caption.weight(.medium))
                } else {
                    Text("Integrity check failed (\(report.issues.count) \(report.issues.count == 1 ? "issue" : "issues"))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("SHA-256: \(package.manifest.carSHA256.prefix(16))…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !report.issues.isEmpty {
                ForEach(report.issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((report.isValid ? Color.green : Color.red).opacity(0.08))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search collections, record keys, CIDs, or JSON content offline…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Showing \(filteredRecords.count) of \(records.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var collectionsSidebar: some View {
        List(selection: $selectedCollectionFilter) {
            HStack {
                Label("All Collections", systemImage: "tray.full")
                    .fontWeight(selectedCollectionFilter == .all ? .semibold : .regular)
                Spacer()
                Text("\(records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(CollectionSelection.all)

            if !collectionEntries.isEmpty {
                Section("Collections") {
                    ForEach(collectionEntries, id: \.nsid) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                if let friendly = KnownCollectionNames.title(for: item.nsid) {
                                    Text(friendly)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(item.nsid)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(item.nsid)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(item.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(CollectionSelection.collection(item.nsid))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var recordsTablePane: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Records in Backup",
                    systemImage: "doc.text",
                    description: Text("This verified backup snapshot contains zero records.")
                )
            } else if filteredRecords.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(filteredRecords, selection: $selectedRecordID, sortOrder: $sortOrder) {
                    TableColumn("Collection", value: \.collection) { entry in
                        Text(entry.collection)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 140, ideal: 210)

                    TableColumn("Record Key", value: \.rkey) { entry in
                        Text(entry.rkey)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 140)

                    TableColumn("CID", value: \.cid) { entry in
                        Text(entry.cid)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 120, ideal: 200)
                }
                .contextMenu(forSelectionType: BackupRecordEntry.ID.self) { selection in
                    if let id = selection.first,
                       let entry = filteredRecords.first(where: { $0.id == id }) {
                        Button("Copy Record Path") {
                            copyToPasteboard(entry.id, label: "Copied path")
                        }
                        Button("Copy CID") {
                            copyToPasteboard(entry.cid, label: "Copied CID")
                        }
                        Button("Copy JSON") {
                            copyToPasteboard(entry.prettyJSON, label: "Copied JSON")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordInspectorPane: some View {
        if let record = selectedRecord {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(record.collection)
                            .font(.headline)
                            .lineLimit(1)
                        Text("/ \(record.rkey)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            copyToPasteboard(record.prettyJSON, label: "Copied JSON")
                        } label: {
                            Label("Copy JSON", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack(spacing: 6) {
                        Text("CID:")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(record.cid)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                ScrollView {
                    Text(record.prettyJSON)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Package Manifest", systemImage: "doc.badge.gearshape")
                            .font(.headline)
                        Text("Select any record from the table to inspect its offline JSON payload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("Snapshot Metadata") {
                        VStack(alignment: .leading, spacing: 6) {
                            manifestRow("Origin", value: package.manifest.originLabel)
                            manifestRow("DID", value: package.manifest.did, monospaced: true)
                            if let handle = package.manifest.handle, !handle.isEmpty {
                                manifestRow("Handle", value: "@\(handle)")
                            }
                            if let spaceURI = package.manifest.spaceURI, !spaceURI.isEmpty {
                                manifestRow("Space URI", value: spaceURI, monospaced: true)
                            }
                            manifestRow("PDS URL", value: package.manifest.pdsURL.absoluteString, monospaced: true)
                            if let rev = package.manifest.commitRev, !rev.isEmpty {
                                manifestRow("Commit Rev", value: rev, monospaced: true)
                            }
                            if let cid = package.manifest.commitCID, !cid.isEmpty {
                                manifestRow("Commit CID", value: cid, monospaced: true)
                            }
                            manifestRow("Schema Version", value: "v\(package.manifest.schemaVersion)")
                            manifestRow("Archive File", value: package.manifest.carFilename, monospaced: true)
                            manifestRow("Archive Size", value: ByteCountFormatter.string(fromByteCount: package.manifest.carByteCount, countStyle: .file))
                            manifestRow("SHA-256", value: package.manifest.carSHA256, monospaced: true)
                            manifestRow("Verification", value: package.manifest.verificationSummary)
                        }
                        .padding(6)
                    }

                    Button {
                        copyToPasteboard(package.manifest.carSHA256, label: "Copied SHA-256")
                    } label: {
                        Label("Copy Archive SHA-256", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func manifestRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
        }
    }

    private func loadOfflineRecords() {
        do {
            if let backupStore {
                records = try backupStore.loadRecords(for: package)
            } else {
                records = try service.loadRecords(at: package.packageURL)
            }
            loadError = nil
            if selectedRecordID == nil {
                selectedRecordID = filteredRecords.first?.id
            }
        } catch {
            records = []
            loadError = error.localizedDescription
        }
    }

    private func runVerification() async {
        isVerifying = true
        verificationError = nil
        defer { isVerifying = false }

        do {
            if let backupStore {
                verificationReport = try await backupStore.verify(package: package)
            } else {
                verificationReport = try await service.verifyPackage(at: package.packageURL)
            }
        } catch {
            verificationError = error.localizedDescription
        }
    }

    private func copyToPasteboard(_ string: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copiedBadgeText = label
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if copiedBadgeText == label {
                copiedBadgeText = nil
            }
        }
    }
}
