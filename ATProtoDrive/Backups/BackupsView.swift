//
//  BackupsView.swift
//  ATProtoDrive
//

import Foundation
import Petrel
import SwiftUI

public struct BackupsView: View {
    public typealias RegisterTransferHandler = @MainActor @Sendable (
        _ title: String,
        _ subtitle: String?,
        _ accountDIDs: Set<String>,
        _ work: @escaping @Sendable (@escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL?
    ) -> Void

    public enum ScopeFilter: String, CaseIterable, Identifiable, Sendable {
        case thisAccount = "This Account"
        case allLocal = "All Local"

        public var id: String { rawValue }
    }

    public let accountDID: String
    public let backupStore: BackupStore
    public let onRegisterTransfer: RegisterTransferHandler?
    public let refreshToken: Int

    @Environment(AccountStore.self) private var accountStore: AccountStore?

    @State private var scopeFilter: ScopeFilter = .allLocal
    @State private var browsingPackage: BackupPackageSummary?
    @State private var showingSpaceBackupSheet: Bool = false
    @State private var packageToTrash: BackupPackageSummary?
    @State private var actionError: String?
    @State private var localBusyMessage: String?

    public init(
        accountDID: String,
        backupStore: BackupStore,
        onRegisterTransfer: RegisterTransferHandler? = nil,
        refreshToken: Int = 0
    ) {
        self.accountDID = accountDID
        self.backupStore = backupStore
        self.onRegisterTransfer = onRegisterTransfer
        self.refreshToken = refreshToken
    }

    private var account: AccountStore.Account? {
        accountStore?.account(for: accountDID)
    }

    private var accountPackages: [BackupPackageSummary] {
        backupStore.packages(forAccountDID: accountDID)
    }

    private var otherLocalPackages: [BackupPackageSummary] {
        backupStore.otherPackages(excludingAccountDID: accountDID)
    }

    public var body: some View {
        Group {
            if let browsingPackage {
                LocalBackupBrowserView(
                    package: browsingPackage,
                    backupStore: backupStore,
                    service: backupStore.service,
                    onBack: {
                        self.browsingPackage = nil
                    }
                )
            } else {
                backupsListContent
            }
        }
        .navigationTitle("Backups")
        .task(id: "\(accountDID)-\(refreshToken)") {
            backupStore.reload()
        }
        .onChange(of: accountDID) { _, _ in
            browsingPackage = nil
        }
        .sheet(isPresented: $showingSpaceBackupSheet) {
            if let account, let accountStore {
                SpaceBackupPickerSheet(
                    account: account,
                    spaceModel: accountStore.spaceModel(for: accountDID)
                ) { space, repo in
                    startSpaceBackup(space: space, repo: repo, account: account)
                }
            }
        }
        .confirmationDialog(
            "Move Backup to Trash",
            isPresented: Binding(
                get: { packageToTrash != nil },
                set: { if !$0 { packageToTrash = nil } }
            ),
            presenting: packageToTrash
        ) { package in
            Button("Move to Trash", role: .destructive) {
                do {
                    try backupStore.trash(package: package)
                    if browsingPackage?.id == package.id {
                        browsingPackage = nil
                    }
                } catch {
                    actionError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { package in
            Text(
                "Move \"\(package.packageURL.lastPathComponent)\" to the macOS Trash? This only removes the local backup package on this Mac and does not modify your remote repository."
            )
        }
        .alert(
            "Backup Action Error",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let actionError {
                Text(actionError)
            }
        }
    }

    private var backupsListContent: some View {
        VStack(spacing: 0) {
            headerToolbar
            Divider()

            if backupStore.isCreatingBackup || localBusyMessage != nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(localBusyMessage ?? "Creating verified backup package…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }

            if let storeError = backupStore.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(storeError)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    Spacer()
                    Button("Dismiss") {
                        backupStore.clearError()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            if backupStore.isLoading && backupStore.packages.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning local backups…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visiblePackagesIsEmpty {
                emptyStateView
            } else {
                List {
                    if !accountPackages.isEmpty {
                        Section("Account Backups (\(accountPackages.count))") {
                            ForEach(accountPackages) { package in
                                backupRow(package)
                            }
                        }
                    }

                    if scopeFilter == .allLocal && !otherLocalPackages.isEmpty {
                        Section("Other Local Backups (\(otherLocalPackages.count))") {
                            ForEach(otherLocalPackages) { package in
                                backupRow(package)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visiblePackagesIsEmpty: Bool {
        switch scopeFilter {
        case .thisAccount:
            return accountPackages.isEmpty
        case .allLocal:
            return backupStore.packages.isEmpty
        }
    }

    private var headerToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Backups")
                    .font(.headline)
                Text("Verified .atprotodrivebackup packages stored locally on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Filter", selection: $scopeFilter) {
                ForEach(ScopeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            Button {
                startPublicBackup()
            } label: {
                Label("Back Up Public Repository", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(backupStore.isCreatingBackup)

            Button {
                showingSpaceBackupSheet = true
            } label: {
                Label("Back Up Space…", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(backupStore.isCreatingBackup || account == nil)

            Button {
                backupStore.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(backupStore.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Local Backups Yet", systemImage: "archivebox")
        } description: {
            Text(
                "Create a verified offline backup of your public repository or any permissioned Space. Each .atprotodrivebackup package includes the raw repository archive, SHA-256 manifest, and an offline searchable record index."
            )
        } actions: {
            HStack(spacing: 10) {
                Button("Back Up Public Repository") {
                    startPublicBackup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(backupStore.isCreatingBackup)

                Button("Back Up Space…") {
                    showingSpaceBackupSheet = true
                }
                .buttonStyle(.bordered)
                .disabled(backupStore.isCreatingBackup || account == nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func backupRow(_ package: BackupPackageSummary) -> some View {
        let report = backupStore.verificationReports[package.id]
        let isVerifying = backupStore.verifyingPackageIDs.contains(package.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: package.manifest.isSpaceBackup ? "externaldrive.fill" : "globe")
                    .font(.title3)
                    .foregroundStyle(package.manifest.isSpaceBackup ? .purple : .blue)
                    .frame(width: 26, height: 26)
                    .background(
                        (package.manifest.isSpaceBackup ? Color.purple : Color.blue).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(package.manifest.shortOriginBadge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (package.manifest.isSpaceBackup ? Color.purple : Color.blue).opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(package.manifest.isSpaceBackup ? .purple : .blue)

                        Text(package.manifest.displayTarget)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        verificationBadge(for: package, report: report, isVerifying: isVerifying)
                    }

                    if package.manifest.isSpaceBackup {
                        Text("Writer: \(package.manifest.did)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(package.manifest.did)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 10) {
                        Label(
                            package.manifest.createdAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "clock"
                        )
                        Label(
                            "\(package.manifest.recordCount) \(package.manifest.recordCount == 1 ? "record" : "records")",
                            systemImage: "doc.text"
                        )
                        Label(
                            ByteCountFormatter.string(fromByteCount: package.manifest.carByteCount, countStyle: .file),
                            systemImage: "internaldrive"
                        )
                        if let rev = package.manifest.commitRev, !rev.isEmpty {
                            Text("rev \(rev)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Button {
                        browsingPackage = package
                    } label: {
                        Label("Inspect Offline", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        Task { await verifyPackage(package) }
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
                        backupStore.revealInFinder(package: package)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        packageToTrash = package
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Move to Trash")
                }
            }

            if let report, !report.isValid, !report.issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                browsingPackage = package
            } label: {
                Label("Inspect Offline", systemImage: "doc.text.magnifyingglass")
            }

            Button {
                Task { await verifyPackage(package) }
            } label: {
                Label("Verify Integrity", systemImage: "checkmark.shield")
            }

            Button {
                backupStore.revealInFinder(package: package)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                do {
                    _ = try backupStore.exportToFolder(package: package)
                } catch {
                    actionError = error.localizedDescription
                }
            } label: {
                Label("Export Copy…", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                packageToTrash = package
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func verificationBadge(
        for package: BackupPackageSummary,
        report: BackupVerificationReport?,
        isVerifying: Bool
    ) -> some View {
        if isVerifying {
            Label("Verifying…", systemImage: "hourglass")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        } else if let report {
            if report.isValid {
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(.green)
            } else {
                Label("Integrity Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.14), in: Capsule())
                    .foregroundStyle(.red)
            }
        } else if package.manifest.verified {
            Label("Verified", systemImage: "checkmark.seal")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.10), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Label("Unverified", systemImage: "questionmark.circle")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.14), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func startPublicBackup() {
        let targetDID = accountDID
        let knownHandle = account?.handle
        let store = backupStore
        let title = "Public Repo Backup"
        let subtitle = knownHandle.map { "@\($0)" } ?? targetDID

        let work: @Sendable (@escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL? = { progress in
            let resolver = DIDDocumentPDSResolver()
            let resolved = try await resolver.resolvePDS(for: targetDID)
            let summary = try await store.createPublicBackup(
                did: resolved.did,
                handle: (knownHandle?.isEmpty == false) ? knownHandle : resolved.declaredHandle,
                pdsURL: resolved.pdsURL,
                progressHandler: progress
            )
            return summary.packageURL
        }

        if let onRegisterTransfer {
            onRegisterTransfer(title, subtitle, Set([targetDID]), work)
        } else {
            Task {
                localBusyMessage = "Backing up public repository for \(subtitle)…"
                defer { localBusyMessage = nil }
                do {
                    _ = try await work { _, _ in }
                } catch is CancellationError {
                    return
                } catch {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func startSpaceBackup(space: SpaceItem, repo: RepoEntry, account: AccountStore.Account) {
        let store = backupStore
        let title = "Space Backup: \(space.skey)"
        let subtitle = "\(space.ref.uriString()) (\(repo.did))"

        let work: @Sendable (@escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL? = { progress in
            let summary = try await store.createSpaceBackup(
                space: space,
                repo: repo,
                account: account,
                progressHandler: progress
            )
            return summary.packageURL
        }

        if let onRegisterTransfer {
            onRegisterTransfer(title, subtitle, Set([account.id]), work)
        } else {
            Task {
                localBusyMessage = "Backing up Space \"\(space.skey)\"…"
                defer { localBusyMessage = nil }
                do {
                    _ = try await work { _, _ in }
                } catch is CancellationError {
                    return
                } catch {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func verifyPackage(_ package: BackupPackageSummary) async {
        do {
            _ = try await backupStore.verify(package: package)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Space Backup Picker Sheet

private struct SpaceBackupPickerSheet: View {
    let account: AccountStore.Account
    let spaceModel: SpaceListModel
    let onStartBackup: (_ space: SpaceItem, _ repo: RepoEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedSpaceID: SpaceItem.ID?
    @State private var detailModel = SpaceDetailModel()
    @State private var selectedWriterDID: String = ""

    private var selectedSpace: SpaceItem? {
        guard let selectedSpaceID else { return nil }
        return spaceModel.spaces.first(where: { $0.id == selectedSpaceID })
    }

    private var availableWriters: [RepoEntry] {
        if !detailModel.repos.isEmpty {
            return detailModel.repos
        }
        if let space = selectedSpace {
            if let own = space.ownRepoEntry {
                return [own]
            }
            return [RepoEntry(did: account.id, rev: space.repoRev ?? "", hash: space.repoDataHash ?? "")]
        }
        return []
    }

    private var selectedRepo: RepoEntry? {
        if let match = availableWriters.first(where: { $0.did == selectedWriterDID }) {
            return match
        }
        return availableWriters.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Back Up Permissioned Space")
                    .font(.title3.bold())
                Text(
                    "Choose a Space and writer repository to fetch via Space endpoints, verify its STAR archive, and save a local .atprotodrivebackup package."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if spaceModel.isLoading && spaceModel.spaces.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Spaces for @\(account.handle)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else if spaceModel.spaces.isEmpty {
                ContentUnavailableView(
                    "No Spaces Loaded",
                    systemImage: "square.stack.3d.up",
                    description: Text("No permissioned Spaces were found for this account yet. Open or create a Space first, or refresh.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Form {
                    Picker("Space", selection: $selectedSpaceID) {
                        ForEach(spaceModel.spaces) { space in
                            Text("\(space.skey) — \(space.spaceType)")
                                .tag(Optional(space.id))
                        }
                    }

                    if let space = selectedSpace {
                        LabeledContent("Space URI") {
                            Text(space.ref.uriString())
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        if detailModel.isLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading writers…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if availableWriters.count > 1 {
                            Picker("Writer Repository", selection: $selectedWriterDID) {
                                ForEach(availableWriters) { writer in
                                    Text(writer.did == account.id ? "\(writer.did) (Your Repo)" : writer.did)
                                        .tag(writer.did)
                                }
                            }
                        } else if let onlyWriter = availableWriters.first {
                            LabeledContent("Writer Repository") {
                                Text(onlyWriter.did == account.id ? "\(onlyWriter.did) (Your Repo)" : onlyWriter.did)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }

                        if let detailError = detailModel.error {
                            Label(detailError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Button("Refresh Spaces") {
                    Task {
                        await spaceModel.load(account: account)
                        if selectedSpaceID == nil {
                            selectedSpaceID = spaceModel.spaces.first?.id
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(spaceModel.isLoading)

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create Space Backup") {
                    guard let space = selectedSpace, let repo = selectedRepo else { return }
                    dismiss()
                    onStartBackup(space, repo)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSpace == nil || selectedRepo == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 390)
        .task {
            if spaceModel.spaces.isEmpty {
                await spaceModel.load(account: account)
            }
            if selectedSpaceID == nil {
                selectedSpaceID = spaceModel.spaces.first?.id
            }
        }
        .task(id: selectedSpaceID) {
            guard let space = selectedSpace else { return }
            selectedWriterDID = account.id
            await detailModel.load(space: space, account: account)
            if !detailModel.repos.contains(where: { $0.did == selectedWriterDID }),
               let first = detailModel.repos.first {
                selectedWriterDID = first.did
            }
        }
    }
}
