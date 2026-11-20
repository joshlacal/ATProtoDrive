//
//  BackupStore.swift
//  ATProtoDrive
//

import AppKit
import Foundation
import Observation
import OSLog
import Petrel

private let backupStoreLogger = Logger(subsystem: "blue.catbird.atprotodrive", category: "Backups")

@MainActor
@Observable
public final class BackupStore {
    public let rootDirectory: URL
    public let service: BackupService

    public private(set) var packages: [BackupPackageSummary] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isCreatingBackup: Bool = false
    public private(set) var error: String?
    public private(set) var verificationReports: [UUID: BackupVerificationReport] = [:]
    public private(set) var verifyingPackageIDs: Set<UUID> = []

    public static func defaultRootDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ATProtoDrive", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    public init(
        rootDirectory: URL = BackupStore.defaultRootDirectory(),
        service: BackupService = BackupService()
    ) {
        self.rootDirectory = rootDirectory
        self.service = service
    }

    // MARK: - Reload & Filtering

    public func reload() {
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try service.listPackages(in: rootDirectory)
            packages = loaded
            error = nil

            let validIDs = Set(loaded.map(\.id))
            verificationReports = verificationReports.filter { validIDs.contains($0.key) }
        } catch {
            self.error = error.localizedDescription
            backupStoreLogger.error("Failed to reload backups: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func packages(forAccountDID did: String) -> [BackupPackageSummary] {
        packages.filter { Self.package($0, matchesAccountDID: did) }
    }

    public func otherPackages(excludingAccountDID did: String) -> [BackupPackageSummary] {
        packages.filter { !Self.package($0, matchesAccountDID: did) }
    }

    nonisolated public static func package(_ package: BackupPackageSummary, matchesAccountDID did: String) -> Bool {
        if package.manifest.did == did {
            return true
        }
        switch package.manifest.accessClassification.unwrappedOriginal {
        case .publicRepository(let repoDID):
            return repoDID == did
        case .permissionedSpace(let spaceURI, let writerDID):
            return writerDID == did || spaceURI.hasPrefix("at://\(did)/")
        case .privateAppState(_, let accountDID):
            return accountDID == did
        case .localBackup:
            return false
        }
    }

    // MARK: - Backup Creation

    @discardableResult
    public func createPublicBackup(
        did: String,
        handle: String? = nil,
        pdsURL: URL,
        progressHandler: BackupService.Operations.ProgressHandler? = nil
    ) async throws -> BackupPackageSummary {
        isCreatingBackup = true
        error = nil
        defer { isCreatingBackup = false }

        do {
            let summary = try await service.createPublicBackup(
                did: did,
                handle: handle,
                pdsURL: pdsURL,
                rootDirectory: rootDirectory,
                progressHandler: progressHandler
            )
            reload()
            verificationReports[summary.id] = BackupVerificationReport(
                isValid: true,
                carSHA256Matches: true,
                manifestValid: true,
                recordCount: summary.manifest.recordCount,
                commitRev: summary.manifest.commitRev,
                issues: []
            )
            backupStoreLogger.info(
                "Created public backup \(summary.packageURL.lastPathComponent, privacy: .public) (\(summary.manifest.recordCount, privacy: .public) records)"
            )
            return summary
        } catch {
            self.error = error.localizedDescription
            backupStoreLogger.error("Public backup failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    @discardableResult
    public func createSpaceBackup(
        space: SpaceItem,
        repo: RepoEntry,
        account: AccountStore.Account,
        progressHandler: BackupService.Operations.ProgressHandler? = nil
    ) async throws -> BackupPackageSummary {
        isCreatingBackup = true
        error = nil
        defer { isCreatingBackup = false }

        do {
            let summary = try await service.createSpaceBackup(
                space: space,
                repo: repo,
                account: account,
                rootDirectory: rootDirectory,
                progressHandler: progressHandler
            )
            reload()
            verificationReports[summary.id] = BackupVerificationReport(
                isValid: true,
                carSHA256Matches: true,
                manifestValid: true,
                recordCount: summary.manifest.recordCount,
                commitRev: summary.manifest.commitRev,
                issues: []
            )
            backupStoreLogger.info(
                "Created space backup \(summary.packageURL.lastPathComponent, privacy: .public) (\(summary.manifest.recordCount, privacy: .public) records)"
            )
            return summary
        } catch {
            self.error = error.localizedDescription
            backupStoreLogger.error("Space backup failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Injectable Space backup entry point for offline unit tests.
    @discardableResult
    public func createSpaceBackup(
        space: SpaceItem,
        repo: RepoEntry,
        accountDID: String,
        fallbackOwnPDSURL: URL? = nil,
        clientGetRepo: @escaping @Sendable (_ space: SpaceRef, _ repoDID: DID) async throws -> (responseCode: Int, data: Data?),
        resolveDIDToPDS: @escaping @Sendable (_ did: String) async throws -> URL,
        credentialGet: @escaping @Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data),
        progressHandler: BackupService.Operations.ProgressHandler? = nil
    ) async throws -> BackupPackageSummary {
        isCreatingBackup = true
        error = nil
        defer { isCreatingBackup = false }

        do {
            let summary = try await service.createSpaceBackup(
                space: space,
                repo: repo,
                accountDID: accountDID,
                fallbackOwnPDSURL: fallbackOwnPDSURL,
                rootDirectory: rootDirectory,
                clientGetRepo: clientGetRepo,
                resolveDIDToPDS: resolveDIDToPDS,
                credentialGet: credentialGet,
                progressHandler: progressHandler
            )
            reload()
            verificationReports[summary.id] = BackupVerificationReport(
                isValid: true,
                carSHA256Matches: true,
                manifestValid: true,
                recordCount: summary.manifest.recordCount,
                commitRev: summary.manifest.commitRev,
                issues: []
            )
            return summary
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    // MARK: - Verification, Offline Reading, Trash, Reveal & Export

    @discardableResult
    public func verify(package: BackupPackageSummary) async throws -> BackupVerificationReport {
        verifyingPackageIDs.insert(package.id)
        defer { verifyingPackageIDs.remove(package.id) }

        do {
            let report = try await service.verifyPackage(at: package.packageURL)
            verificationReports[package.id] = report
            return report
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    public func loadRecords(for package: BackupPackageSummary) throws -> [BackupRecordEntry] {
        try service.loadRecords(at: package.packageURL)
    }

    public func trash(package: BackupPackageSummary) throws {
        do {
            try service.moveToTrash(packageURL: package.packageURL)
            packages.removeAll { $0.id == package.id }
            verificationReports.removeValue(forKey: package.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    public func revealInFinder(package: BackupPackageSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([package.packageURL])
    }

    @discardableResult
    public func export(package: BackupPackageSummary, to destinationURL: URL) throws -> URL {
        try service.copyPackage(from: package.packageURL, to: destinationURL)
    }

    @discardableResult
    public func exportToFolder(package: BackupPackageSummary) throws -> URL? {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Backup Package"
        savePanel.message = "Choose a destination to copy this verified .atprotodrivebackup package."
        savePanel.nameFieldStringValue = package.packageURL.lastPathComponent
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        guard savePanel.runModal() == .OK, let targetURL = savePanel.url else {
            return nil
        }
        return try export(package: package, to: targetURL)
    }

    public func clearError() {
        error = nil
    }
}
