//
//  BackupService.swift
//  ATProtoDrive
//

import CryptoKit
import Foundation
import Petrel

public struct BackupService: Sendable {
    public static let defaultMaximumPublicCARBytes: Int = 512 * 1_048_576

    public struct Operations: Sendable {
        public typealias ProgressHandler = @Sendable (_ bytesCompleted: Int64, _ totalBytes: Int64?) -> Void

        /// Unauthenticated GET <pdsURL>/xrpc/com.atproto.sync.getRepo?did=<did>
        public let fetchPublicRepoCAR: @Sendable (
            _ pdsURL: URL,
            _ did: String,
            _ progress: ProgressHandler?
        ) async throws -> Data

        /// Parses and verifies a public ATProto CAR v1 export.
        public let verifyPublicCAR: @Sendable (
            _ data: Data,
            _ expectedDID: String
        ) throws -> VerifiedCARSnapshot

        /// Authenticated owner fetch for a Space repository via `com.atproto.space.getRepo`.
        public let fetchOwnSpaceRepo: @Sendable (
            _ account: AccountStore.Account,
            _ space: SpaceRef,
            _ repoDID: DID
        ) async throws -> (responseCode: Int, data: Data?)

        /// Resolves a writer DID to its PDS URL for Space repository access.
        public let resolveSpaceWriterPDS: @Sendable (
            _ account: AccountStore.Account,
            _ writerDID: String
        ) async throws -> URL

        /// MAC-verified Space credential fetch for a foreign writer's `com.atproto.space.getRepo`.
        public let fetchForeignSpaceRepo: @Sendable (
            _ account: AccountStore.Account,
            _ url: URL,
            _ space: SpaceRef
        ) async throws -> (responseCode: Int, data: Data)

        /// Verifies a Space STAR repository archive via `SpaceSTAR.verify`.
        public let verifySpaceArchive: @Sendable (
            _ data: Data,
            _ space: SpaceRef,
            _ repoDID: String
        ) throws -> VerifiedCARSnapshot

        public init(
            fetchPublicRepoCAR: @escaping @Sendable (
                _ pdsURL: URL,
                _ did: String,
                _ progress: ProgressHandler?
            ) async throws -> Data = BackupService.liveFetchPublicRepoCAR,
            verifyPublicCAR: @escaping @Sendable (
                _ data: Data,
                _ expectedDID: String
            ) throws -> VerifiedCARSnapshot = BackupService.verifyPublicCAR,
            fetchOwnSpaceRepo: @escaping @Sendable (
                _ account: AccountStore.Account,
                _ space: SpaceRef,
                _ repoDID: DID
            ) async throws -> (responseCode: Int, data: Data?) = BackupService.liveFetchOwnSpaceRepo,
            resolveSpaceWriterPDS: @escaping @Sendable (
                _ account: AccountStore.Account,
                _ writerDID: String
            ) async throws -> URL = BackupService.liveResolveSpaceWriterPDS,
            fetchForeignSpaceRepo: @escaping @Sendable (
                _ account: AccountStore.Account,
                _ url: URL,
                _ space: SpaceRef
            ) async throws -> (responseCode: Int, data: Data) = BackupService.liveFetchForeignSpaceRepo,
            verifySpaceArchive: @escaping @Sendable (
                _ data: Data,
                _ space: SpaceRef,
                _ repoDID: String
            ) throws -> VerifiedCARSnapshot = BackupService.verifySpaceSTAR
        ) {
            self.fetchPublicRepoCAR = fetchPublicRepoCAR
            self.verifyPublicCAR = verifyPublicCAR
            self.fetchOwnSpaceRepo = fetchOwnSpaceRepo
            self.resolveSpaceWriterPDS = resolveSpaceWriterPDS
            self.fetchForeignSpaceRepo = fetchForeignSpaceRepo
            self.verifySpaceArchive = verifySpaceArchive
        }

        public static let live = Operations()
    }

    public let operations: Operations

    public init(operations: Operations = .live) {
        self.operations = operations
    }

    // MARK: - Endpoint Builders

    /// Builds an unauthenticated `GET <pdsURL>/xrpc/com.atproto.sync.getRepo?did=<did>` URL.
    public static func makePublicGetRepoURL(
        pdsURL: URL,
        did: String,
        allowLocalhostDevelopment: Bool = false
    ) throws -> URL {
        let trimmedDID = did.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? DID(didString: trimmedDID)) != nil else {
            throw BackupError.invalidIdentifier(did)
        }
        let canonicalOrigin = try DIDDocumentPDSResolver.canonicalPDSOrigin(
            from: pdsURL,
            allowLocalhostDevelopment: allowLocalhostDevelopment
        )
        guard var components = URLComponents(url: canonicalOrigin, resolvingAgainstBaseURL: false) else {
            throw BackupError.invalidURL(pdsURL.absoluteString)
        }
        components.path = "/xrpc/com.atproto.sync.getRepo"
        components.queryItems = [
            URLQueryItem(name: "did", value: trimmedDID)
        ]
        guard let url = components.url else {
            throw BackupError.invalidURL(pdsURL.absoluteString)
        }
        return url
    }

    // MARK: - Live Transports

    /// Strictly unauthenticated fetch of `com.atproto.sync.getRepo` on the resolved target PDS.
    /// NEVER attaches OAuth tokens, DPoP proofs, or cookies.
    public static func liveFetchPublicRepoCAR(
        pdsURL: URL,
        did: String,
        progress: Operations.ProgressHandler?
    ) async throws -> Data {
        let url = try makePublicGetRepoURL(pdsURL: pdsURL, did: did)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 180
        request.setValue("application/vnd.ipld.car", forHTTPHeaderField: "Accept")

        let downloader = AnonymousCARDownloadSession(
            maxBytes: defaultMaximumPublicCARBytes,
            allowLocalhostDevelopment: false,
            progressHandler: progress
        )
        let (statusCode, data) = try await downloader.start(request: request)
        guard (200 ... 299).contains(statusCode) else {
            let message = ATProtoErrorParser.parseGeneric(data: data, statusCode: statusCode)?.errorDescription
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError.httpError(
                endpoint: "com.atproto.sync.getRepo",
                statusCode: statusCode,
                message: message
            )
        }
        guard !data.isEmpty else {
            throw BackupError.emptyResponse(endpoint: "com.atproto.sync.getRepo")
        }
        return data
    }

    public static func liveFetchOwnSpaceRepo(
        account: AccountStore.Account,
        space: SpaceRef,
        repoDID: DID
    ) async throws -> (responseCode: Int, data: Data?) {
        let limits = NetworkResponseLimits(
            maximumWireBytes: SpaceSTAR.defaultMaximumArchiveBytes,
            maximumDecodedBytes: SpaceSTAR.defaultMaximumArchiveBytes
        )
        let (responseCode, output) = try await NetworkService.withResponseLimits(limits) {
            try await account.client.com.atproto.space.getRepo(
                input: .init(space: space, repo: repoDID)
            )
        }
        return (responseCode, output?.data)
    }

    public static func liveResolveSpaceWriterPDS(
        account: AccountStore.Account,
        writerDID: String
    ) async throws -> URL {
        try await account.client.resolveDIDToPDSURL(did: writerDID)
    }

    public static func liveFetchForeignSpaceRepo(
        account: AccountStore.Account,
        url: URL,
        space: SpaceRef
    ) async throws -> (responseCode: Int, data: Data) {
        let (data, response) = try await account.credentials.get(
            url: url,
            space: space,
            maximumArchiveBytes: SpaceSTAR.defaultMaximumArchiveBytes
        )
        return (response.statusCode, data)
    }

    // MARK: - Archive Verification & Record Extraction

    /// Parses and verifies a public CAR v1 archive:
    /// 1. Validates CARv1 header, roots, framing, and every block's SHA-256 CID multihash via `CARReader`.
    /// 2. Validates the root commit block's `did` matches `expectedDID` and has an MST root `data` link.
    /// 3. Walks the MST via `MSTTraverser`, checking key ordering, prefix compression, cycles, and depth bounds.
    /// 4. Decodes every record block to pretty-printed JSON.
    public static func verifyPublicCAR(
        data: Data,
        expectedDID: String
    ) throws -> VerifiedCARSnapshot {
        let reader: CARReader
        do {
            reader = try CARReader(data: data)
        } catch {
            throw BackupError.verificationFailed("Invalid CAR archive: \(error.localizedDescription)")
        }

        guard let commitCID = reader.roots.first else {
            throw BackupError.verificationFailed("CAR archive header does not specify a root commit CID.")
        }

        let decodedRoot: Any?
        do {
            decodedRoot = try reader.decodeBlock(for: commitCID.bytes)
        } catch {
            throw BackupError.verificationFailed("Failed to decode commit block: \(error.localizedDescription)")
        }

        guard let commitBlock = decodedRoot as? [String: Any] else {
            throw BackupError.verificationFailed("Root commit block is not a DAG-CBOR map.")
        }

        guard let commitDID = commitBlock["did"] as? String else {
            throw BackupError.verificationFailed("Root commit block is missing its 'did' field.")
        }
        guard commitDID == expectedDID else {
            throw BackupError.verificationFailed(
                "Commit DID '\(commitDID)' does not match expected DID '\(expectedDID)'."
            )
        }

        guard commitBlock["data"] is CID else {
            throw BackupError.verificationFailed("Root commit block is missing its 'data' MST root CID.")
        }

        let commitRev = commitBlock["rev"] as? String
        let traverser = MSTTraverser(reader: reader)
        var records: [BackupRecordEntry] = []

        do {
            try traverser.walkRepository(commitCID: commitCID) { path, recordCID in
                let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw BackupError.verificationFailed("Invalid MST record path '\(path)'.")
                }
                let collection = String(parts[0])
                let rkey = String(parts[1])
                let rawBlock = try reader.rawBlockData(for: recordCID.bytes)
                let prettyJSON = try formatRecordBlockAsPrettyJSON(
                    rawCBOR: rawBlock,
                    fallbackDecode: { try reader.decodeBlock(for: recordCID.bytes) }
                )
                records.append(BackupRecordEntry(
                    collection: collection,
                    rkey: rkey,
                    cid: recordCID.string,
                    prettyJSON: prettyJSON
                ))
            }
        } catch let backupError as BackupError {
            throw backupError
        } catch {
            throw BackupError.verificationFailed("MST traversal failed: \(error.localizedDescription)")
        }

        records.sort { ($0.collection, $0.rkey) < ($1.collection, $1.rkey) }
        let blockCount = reader.rawBlockIndex.count
        let revNote = commitRev.map { ", rev \($0)" } ?? ""
        let summary = "Verified CAR v1 (commit \(commitCID.string)\(revNote), \(records.count) records, \(blockCount) CID-verified blocks)"
        return VerifiedCARSnapshot(
            commitRev: commitRev,
            commitCID: commitCID.string,
            records: records,
            verificationSummary: summary
        )
    }

    /// Verifies a Space STAR archive using `SpaceSTAR.verify(archive:space:repo:)` and extracts all records.
    public static func verifySpaceSTAR(
        data: Data,
        space: SpaceRef,
        repoDID: String
    ) throws -> VerifiedCARSnapshot {
        let verified: VerifiedSpaceRepository
        do {
            verified = try SpaceSTAR.verify(archive: data, space: space, repo: repoDID)
        } catch {
            throw BackupError.verificationFailed("Space STAR verification failed: \(error.localizedDescription)")
        }

        var records: [BackupRecordEntry] = []
        records.reserveCapacity(verified.records.count)

        for record in verified.records {
            let parts = record.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw BackupError.verificationFailed("Invalid Space record path '\(record.path)'.")
            }
            let collection = String(parts[0])
            let rkey = String(parts[1])
            let prettyJSON: String
            if let container = try? ATProtocolValueContainer.decodedFromDAGCBOR(record.bytes) {
                prettyJSON = RecordListModel.formatPrettyJSON(from: container)
            } else if let container = try? CARRepository.decodeRecordCBOR(record.bytes) {
                prettyJSON = RecordListModel.formatPrettyJSON(from: container)
            } else {
                throw BackupError.verificationFailed("Failed to decode Space record '\(record.path)' from DAG-CBOR.")
            }

            records.append(BackupRecordEntry(
                collection: collection,
                rkey: rkey,
                cid: record.cid.string,
                prettyJSON: prettyJSON
            ))
        }

        records.sort { ($0.collection, $0.rkey) < ($1.collection, $1.rkey) }
        let digestPrefix = verified.data.prefix(8).map { String(format: "%02x", $0) }.joined()
        let summary = "Verified Space STAR archive (rev \(verified.revision), \(records.count) records, set digest \(digestPrefix)…)"
        return VerifiedCARSnapshot(
            commitRev: verified.revision,
            commitCID: nil,
            records: records,
            verificationSummary: summary
        )
    }

    // MARK: - Backup Creation

    /// Creates a verified `.atprotodrivebackup` package for a public repository using anonymous `com.atproto.sync.getRepo`.
    public func createPublicBackup(
        did: String,
        handle: String? = nil,
        pdsURL: URL,
        rootDirectory: URL,
        progressHandler: Operations.ProgressHandler? = nil
    ) async throws -> BackupPackageSummary {
        let trimmedDID = did.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? DID(didString: trimmedDID)) != nil else {
            throw BackupError.invalidIdentifier(did)
        }

        progressHandler?(0, nil)
        let carData = try await operations.fetchPublicRepoCAR(pdsURL, trimmedDID, progressHandler)
        try Task.checkCancellation()

        let snapshot = try operations.verifyPublicCAR(carData, trimmedDID)
        try Task.checkCancellation()

        let normalizedHandle = handle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHandle = (normalizedHandle?.isEmpty == false) ? normalizedHandle : nil

        let summary = try writePackageAtomically(
            carData: carData,
            snapshot: snapshot,
            accessClassification: .publicRepository(did: trimmedDID),
            did: trimmedDID,
            handle: cleanHandle,
            pdsURL: pdsURL,
            spaceURI: nil,
            sanitizedBaseName: Self.sanitizeFilenameComponent(cleanHandle ?? trimmedDID),
            rootDirectory: rootDirectory
        )
        progressHandler?(Int64(carData.count), Int64(carData.count))
        return summary
    }

    /// Creates a verified `.atprotodrivebackup` package for a Space writer repository.
    /// Uses `account.client.com.atproto.space.getRepo` for the account's own repository and
    /// MAC-verified `account.credentials.get(url:space:)` for foreign writer repositories.
    /// NEVER falls back to `com.atproto.sync.getRepo`.
    public func createSpaceBackup(
        space: SpaceItem,
        repo: RepoEntry,
        account: AccountStore.Account,
        rootDirectory: URL,
        progressHandler: Operations.ProgressHandler? = nil
    ) async throws -> BackupPackageSummary {
        let ops = operations
        let fallbackPDS = await account.client.baseURL
        return try await createSpaceBackup(
            space: space,
            repo: repo,
            accountDID: account.id,
            fallbackOwnPDSURL: fallbackPDS,
            rootDirectory: rootDirectory,
            clientGetRepo: { spaceRef, repoDID in
                try await ops.fetchOwnSpaceRepo(account, spaceRef, repoDID)
            },
            resolveDIDToPDS: { writerDID in
                try await ops.resolveSpaceWriterPDS(account, writerDID)
            },
            credentialGet: { url, spaceRef in
                try await ops.fetchForeignSpaceRepo(account, url, spaceRef)
            },
            progressHandler: progressHandler
        )
    }

    /// Pure injectable pipeline for Space repository backups (100% offline unit-testable).
    /// NEVER falls back to public sync endpoints.
    public func createSpaceBackup(
        space: SpaceItem,
        repo: RepoEntry,
        accountDID: String,
        fallbackOwnPDSURL: URL? = nil,
        rootDirectory: URL,
        clientGetRepo: @escaping @Sendable (_ space: SpaceRef, _ repoDID: DID) async throws -> (responseCode: Int, data: Data?),
        resolveDIDToPDS: @escaping @Sendable (_ did: String) async throws -> URL,
        credentialGet: @escaping @Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data),
        progressHandler: Operations.ProgressHandler? = nil
    ) async throws -> BackupPackageSummary {
        let trimmedRepoDID = repo.did.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedRepoDID: DID
        do {
            parsedRepoDID = try DID(didString: trimmedRepoDID)
        } catch {
            throw BackupError.invalidIdentifier(repo.did)
        }

        progressHandler?(0, nil)
        let isOwnRepo = (trimmedRepoDID == accountDID)
        let archiveData: Data
        let writerPDSURL: URL

        if isOwnRepo {
            let (responseCode, maybeData) = try await clientGetRepo(space.ref, parsedRepoDID)
            guard (200 ... 299).contains(responseCode) else {
                let message = maybeData.flatMap { ATProtoErrorParser.parseGeneric(data: $0, statusCode: responseCode)?.errorDescription }
                throw BackupError.httpError(
                    endpoint: "com.atproto.space.getRepo",
                    statusCode: responseCode,
                    message: message
                )
            }
            guard let data = maybeData, !data.isEmpty else {
                throw BackupError.emptyResponse(endpoint: "com.atproto.space.getRepo")
            }
            archiveData = data
            if let resolved = try? await resolveDIDToPDS(trimmedRepoDID) {
                writerPDSURL = resolved
            } else if let fallbackOwnPDSURL {
                writerPDSURL = fallbackOwnPDSURL
            } else {
                writerPDSURL = ATProtoClient.defaultBaseURL
            }
        } else {
            let pdsHost = try await resolveDIDToPDS(trimmedRepoDID)
            guard let requestURL = SpaceDetailModel.makeGetRepoURL(
                pdsHost: pdsHost,
                space: space.ref,
                repoDID: trimmedRepoDID
            ) else {
                throw BackupError.invalidIdentifier(trimmedRepoDID)
            }
            let (responseCode, data) = try await credentialGet(requestURL, space.ref)
            guard (200 ... 299).contains(responseCode) else {
                let message = ATProtoErrorParser.parseGeneric(data: data, statusCode: responseCode)?.errorDescription
                    ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BackupError.httpError(
                    endpoint: "com.atproto.space.getRepo",
                    statusCode: responseCode,
                    message: message
                )
            }
            guard !data.isEmpty else {
                throw BackupError.emptyResponse(endpoint: "com.atproto.space.getRepo")
            }
            archiveData = data
            writerPDSURL = pdsHost
        }

        try Task.checkCancellation()
        progressHandler?(Int64(archiveData.count), Int64(archiveData.count))

        let snapshot = try operations.verifySpaceArchive(archiveData, space.ref, trimmedRepoDID)
        try Task.checkCancellation()

        let spaceURI = space.ref.uriString()
        let baseName = Self.sanitizeFilenameComponent("space-\(space.skey)-\(trimmedRepoDID)")

        return try writePackageAtomically(
            carData: archiveData,
            snapshot: snapshot,
            accessClassification: .permissionedSpace(spaceURI: spaceURI, writerDID: trimmedRepoDID),
            did: trimmedRepoDID,
            handle: nil,
            pdsURL: writerPDSURL,
            spaceURI: spaceURI,
            sanitizedBaseName: baseName,
            rootDirectory: rootDirectory
        )
    }

    // MARK: - Atomic Package Publishing

    private func writePackageAtomically(
        carData: Data,
        snapshot: VerifiedCARSnapshot,
        accessClassification: AccessClassification,
        did: String,
        handle: String?,
        pdsURL: URL,
        spaceURI: String?,
        sanitizedBaseName: String,
        rootDirectory: URL
    ) throws -> BackupPackageSummary {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        } catch {
            throw BackupError.stagingFailed("Unable to create backups directory: \(error.localizedDescription)")
        }

        let backupID = UUID()
        let createdAt = Date()
        let stagingURL = rootDirectory.appendingPathComponent(
            ".staging-\(backupID.uuidString)",
            isDirectory: true
        )

        do {
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        } catch {
            throw BackupError.stagingFailed("Unable to create staging directory: \(error.localizedDescription)")
        }

        do {
            let carFilename = BackupManifest.defaultCARFilename
            let carURL = stagingURL.appendingPathComponent(carFilename, isDirectory: false)
            try carData.write(to: carURL, options: .atomic)

            let carSHA256 = BackupCoding.sha256Hex(of: carData)
            let encoder = BackupCoding.makeEncoder()

            let recordsIndexData = try encoder.encode(snapshot.records)
            let recordsIndexURL = stagingURL.appendingPathComponent(
                BackupManifest.recordsIndexFilename,
                isDirectory: false
            )
            try recordsIndexData.write(to: recordsIndexURL, options: .atomic)

            let collectionCounts = Dictionary(grouping: snapshot.records, by: \.collection)
                .mapValues(\.count)

            let manifest = BackupManifest(
                schemaVersion: BackupManifest.currentSchemaVersion,
                backupID: backupID,
                createdAt: createdAt,
                accessClassification: accessClassification,
                did: did,
                handle: handle,
                pdsURL: pdsURL,
                spaceURI: spaceURI,
                commitRev: snapshot.commitRev,
                commitCID: snapshot.commitCID,
                carFilename: carFilename,
                carSHA256: carSHA256,
                carByteCount: Int64(carData.count),
                recordCount: snapshot.records.count,
                collectionCounts: collectionCounts,
                verified: true,
                verificationSummary: snapshot.verificationSummary
            )

            let manifestData = try encoder.encode(manifest)
            let manifestURL = stagingURL.appendingPathComponent(
                BackupManifest.manifestFilename,
                isDirectory: false
            )
            try manifestData.write(to: manifestURL, options: .atomic)

            let timestamp = Self.formatPackageTimestamp(createdAt)
            var candidateName = "\(sanitizedBaseName)-\(timestamp).\(BackupManifest.packageExtension)"
            var finalURL = rootDirectory.appendingPathComponent(candidateName, isDirectory: true)
            if fm.fileExists(atPath: finalURL.path) {
                let shortID = String(backupID.uuidString.prefix(8)).lowercased()
                candidateName = "\(sanitizedBaseName)-\(timestamp)-\(shortID).\(BackupManifest.packageExtension)"
                finalURL = rootDirectory.appendingPathComponent(candidateName, isDirectory: true)
            }

            do {
                try fm.moveItem(at: stagingURL, to: finalURL)
            } catch {
                throw BackupError.moveFailed(error.localizedDescription)
            }

            return BackupPackageSummary(id: manifest.backupID, packageURL: finalURL, manifest: manifest)
        } catch {
            // Remove ONLY the unpublished private staging directory on failure.
            try? fm.removeItem(at: stagingURL)
            throw error
        }
    }

    // MARK: - Package Discovery, Verification, Offline Reading, Trash & Export

    public func listPackages(in rootDirectory: URL) throws -> [BackupPackageSummary] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = BackupCoding.makeDecoder()
        var summaries: [BackupPackageSummary] = []

        for url in contents where url.pathExtension == BackupManifest.packageExtension {
            let manifestURL = url.appendingPathComponent(BackupManifest.manifestFilename, isDirectory: false)
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(BackupManifest.self, from: data)
            else {
                continue
            }
            summaries.append(BackupPackageSummary(id: manifest.backupID, packageURL: url, manifest: manifest))
        }

        summaries.sort { lhs, rhs in
            if lhs.manifest.createdAt != rhs.manifest.createdAt {
                return lhs.manifest.createdAt > rhs.manifest.createdAt
            }
            return lhs.packageURL.lastPathComponent > rhs.packageURL.lastPathComponent
        }
        return summaries
    }

    public func loadManifest(at packageURL: URL) throws -> BackupManifest {
        let manifestURL = packageURL.appendingPathComponent(BackupManifest.manifestFilename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BackupError.invalidPackageLayout("Missing \(BackupManifest.manifestFilename).")
        }
        let data = try Data(contentsOf: manifestURL)
        return try BackupCoding.makeDecoder().decode(BackupManifest.self, from: data)
    }

    /// Reads offline records from `records-index.json` without any network access.
    public func loadRecords(at packageURL: URL) throws -> [BackupRecordEntry] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackupError.packageNotFound(packageURL.path)
        }
        let indexURL = packageURL.appendingPathComponent(BackupManifest.recordsIndexFilename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw BackupError.invalidPackageLayout("Missing \(BackupManifest.recordsIndexFilename).")
        }
        let data = try Data(contentsOf: indexURL)
        return try BackupCoding.makeDecoder().decode([BackupRecordEntry].self, from: data)
    }

    /// Independently verifies a `.atprotodrivebackup` package:
    /// - Validates `manifest.json` decoding, `schemaVersion`, and safe relative archive filename.
    /// - Recomputes SHA-256 of `repo.car` and verifies exact match against `manifest.carSHA256` and `carByteCount`.
    /// - Re-verifies the archive contents (public CAR v1 or Space STAR) against the recorded origin.
    /// - Validates `records-index.json` decoding, record count, and collection counts.
    public func verifyPackage(at packageURL: URL) async throws -> BackupVerificationReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: packageURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackupError.packageNotFound(packageURL.path)
        }

        let manifest: BackupManifest
        do {
            manifest = try loadManifest(at: packageURL)
        } catch {
            return BackupVerificationReport(
                isValid: false,
                carSHA256Matches: false,
                manifestValid: false,
                recordCount: 0,
                commitRev: nil,
                issues: ["Failed to read or decode manifest.json: \(error.localizedDescription)"]
            )
        }

        var issues: [String] = []
        var manifestValid = true

        if manifest.schemaVersion != BackupManifest.currentSchemaVersion {
            manifestValid = false
            issues.append(
                "Unsupported manifest schemaVersion \(manifest.schemaVersion) (expected \(BackupManifest.currentSchemaVersion))."
            )
        }

        if manifest.carFilename.isEmpty
            || manifest.carFilename.contains("/")
            || manifest.carFilename.contains("\\")
            || manifest.carFilename.contains("..") {
            manifestValid = false
            issues.append("Invalid archive filename '\(manifest.carFilename)' in manifest.")
        }

        if manifest.carByteCount < 0 {
            manifestValid = false
            issues.append("Manifest carByteCount is negative.")
        }

        if manifest.recordCount < 0 {
            manifestValid = false
            issues.append("Manifest recordCount is negative.")
        }

        // Verify repo.car byte count, SHA-256, and cryptographic archive structure
        var carSHA256Matches = false
        var carData: Data?
        if !manifest.carFilename.isEmpty
            && !manifest.carFilename.contains("/")
            && !manifest.carFilename.contains("\\")
            && !manifest.carFilename.contains("..") {
            let carURL = packageURL.appendingPathComponent(manifest.carFilename, isDirectory: false)
            if !fm.fileExists(atPath: carURL.path) {
                issues.append("Missing archive file '\(manifest.carFilename)'.")
            } else {
                do {
                    let loaded = try Data(contentsOf: carURL)
                    carData = loaded
                    if Int64(loaded.count) != manifest.carByteCount {
                        issues.append(
                            "Archive byte count mismatch: expected \(manifest.carByteCount), found \(loaded.count)."
                        )
                    }
                    let computedSHA256 = BackupCoding.sha256Hex(of: loaded)
                    if computedSHA256.lowercased() == manifest.carSHA256.lowercased() {
                        carSHA256Matches = true
                    } else {
                        issues.append(
                            "SHA-256 digest mismatch for \(manifest.carFilename): expected \(manifest.carSHA256), computed \(computedSHA256)."
                        )
                    }
                } catch {
                    issues.append("Failed to read archive '\(manifest.carFilename)': \(error.localizedDescription)")
                }
            }
        }

        // Re-verify archive cryptographic/structural contents
        if let carData {
            switch manifest.accessClassification.unwrappedOriginal {
            case .publicRepository(let expectedDID):
                do {
                    let snapshot = try operations.verifyPublicCAR(carData, expectedDID)
                    if snapshot.records.count != manifest.recordCount {
                        issues.append(
                            "CAR record count (\(snapshot.records.count)) does not match manifest recordCount (\(manifest.recordCount))."
                        )
                    }
                    if let expectedCommitCID = manifest.commitCID, snapshot.commitCID != expectedCommitCID {
                        issues.append(
                            "CAR commit CID mismatch: expected \(expectedCommitCID), found \(snapshot.commitCID ?? "none")."
                        )
                    }
                } catch {
                    issues.append("Public CAR verification failed: \(error.localizedDescription)")
                }

            case .permissionedSpace(let spaceURI, let writerDID):
                do {
                    let spaceRef = try SpaceRef(uriString: spaceURI)
                    let snapshot = try operations.verifySpaceArchive(carData, spaceRef, writerDID)
                    if snapshot.records.count != manifest.recordCount {
                        issues.append(
                            "Space archive record count (\(snapshot.records.count)) does not match manifest recordCount (\(manifest.recordCount))."
                        )
                    }
                    if let expectedRev = manifest.commitRev, snapshot.commitRev != expectedRev {
                        issues.append(
                            "Space archive revision mismatch: expected \(expectedRev), found \(snapshot.commitRev ?? "none")."
                        )
                    }
                } catch {
                    issues.append("Space STAR verification failed: \(error.localizedDescription)")
                }

            case .privateAppState, .localBackup:
                break
            }
        }

        // Validate records-index.json
        var verifiedRecordCount = manifest.recordCount
        do {
            let records = try loadRecords(at: packageURL)
            verifiedRecordCount = records.count
            if records.count != manifest.recordCount {
                issues.append(
                    "records-index.json contains \(records.count) records, expected \(manifest.recordCount)."
                )
            }
            let actualCollectionCounts = Dictionary(grouping: records, by: \.collection)
                .mapValues(\.count)
            if actualCollectionCounts != manifest.collectionCounts {
                issues.append("Collection counts in records-index.json do not match manifest.collectionCounts.")
            }
        } catch {
            issues.append("Failed to validate records-index.json: \(error.localizedDescription)")
        }

        let isValid = manifestValid && carSHA256Matches && issues.isEmpty
        return BackupVerificationReport(
            isValid: isValid,
            carSHA256Matches: carSHA256Matches,
            manifestValid: manifestValid,
            recordCount: verifiedRecordCount,
            commitRev: manifest.commitRev,
            issues: issues
        )
    }

    /// Moves a backup package to the user's Trash via `FileManager.default.trashItem`.
    /// Never silently deletes packages with `removeItem`.
    public func moveToTrash(packageURL: URL) throws {
        _ = try moveToTrashReturningURL(packageURL: packageURL)
    }

    @discardableResult
    public func moveToTrashReturningURL(packageURL: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageURL.path) else {
            throw BackupError.packageNotFound(packageURL.path)
        }
        do {
            var resultingURL: NSURL?
            try fm.trashItem(at: packageURL, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        } catch {
            throw BackupError.trashFailed(error.localizedDescription)
        }
    }

    /// Copies a `.atprotodrivebackup` package cleanly to a user-chosen destination URL.
    @discardableResult
    public func copyPackage(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw BackupError.packageNotFound(sourceURL.path)
        }

        let didAccessDest = destinationURL.startAccessingSecurityScopedResource()
        let parentURL = destinationURL.deletingLastPathComponent()
        let didAccessParent = parentURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessDest { destinationURL.stopAccessingSecurityScopedResource() }
            if didAccessParent { parentURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                var trashedExisting: NSURL?
                try fm.trashItem(at: destinationURL, resultingItemURL: &trashedExisting)
            }
            try fm.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw BackupError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - Formatting & Filename Helpers

    public static func sanitizeFilenameComponent(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var result = ""
        result.reserveCapacity(min(raw.count, 64))
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        let collapsed = result
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        let bounded = String(collapsed.prefix(64))
        return bounded.isEmpty ? "backup" : bounded
    }

    private static func formatPackageTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func formatRecordBlockAsPrettyJSON(
        rawCBOR: Data,
        fallbackDecode: () throws -> Any?
    ) throws -> String {
        if let container = try? CARRepository.decodeRecordCBOR(rawCBOR) {
            return RecordListModel.formatPrettyJSON(from: container)
        }
        guard let decoded = try fallbackDecode() else {
            return "{}"
        }
        let jsonCompatible = makeJSONCompatible(decoded)
        guard JSONSerialization.isValidJSONObject(jsonCompatible) else {
            throw BackupError.verificationFailed("Record block is not a valid JSON object.")
        }
        let jsonData = try JSONSerialization.data(
            withJSONObject: jsonCompatible,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    private static func makeJSONCompatible(_ value: Any) -> Any {
        switch value {
        case is NSNull:
            return NSNull()
        case let cid as CID:
            return ["$link": cid.string]
        case let data as Data:
            return ["$bytes": data.base64EncodedString()]
        case let dict as [String: Any]:
            return dict.mapValues(makeJSONCompatible)
        case let array as [Any]:
            return array.map(makeJSONCompatible)
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return NSNumber(value: int)
        case let int64 as Int64:
            return NSNumber(value: int64)
        case let uint64 as UInt64:
            return uint64 > UInt64(Int.max) ? String(uint64) : NSNumber(value: uint64)
        case let number as NSNumber:
            return number
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Anonymous Public CAR Download Delegate

private final class AnonymousCARDownloadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let allowLocalhostDevelopment: Bool
    private let progressHandler: BackupService.Operations.ProgressHandler?

    private var buffer = Data()
    private var expectedLength: Int64?
    private var statusCode: Int?
    private var redirectError: Error?
    private var continuation: CheckedContinuation<(statusCode: Int, data: Data), Error>?
    private var activeTask: URLSessionDataTask?
    private var didFinish = false

    init(
        maxBytes: Int,
        allowLocalhostDevelopment: Bool,
        progressHandler: BackupService.Operations.ProgressHandler?
    ) {
        self.maxBytes = maxBytes
        self.allowLocalhostDevelopment = allowLocalhostDevelopment
        self.progressHandler = progressHandler
    }

    func start(request: URLRequest) async throws -> (statusCode: Int, data: Data) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let cancelledAlready: Bool = lock.withLock {
                    if didFinish {
                        return true
                    }
                    self.continuation = cont
                    let task = session.dataTask(with: request)
                    self.activeTask = task
                    task.resume()
                    return false
                }
                if cancelledAlready {
                    cont.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let (taskToCancel, contToResume): (URLSessionDataTask?, CheckedContinuation<(statusCode: Int, data: Data), Error>?) =
                self.lock.withLock {
                    guard !self.didFinish else { return (nil, nil) }
                    self.didFinish = true
                    let task = self.activeTask
                    self.activeTask = nil
                    let cont = self.continuation
                    self.continuation = nil
                    return (task, cont)
                }
            taskToCancel?.cancel()
            contToResume?.resume(throwing: CancellationError())
        }
    }

    private func finish(with result: Result<(statusCode: Int, data: Data), Error>) {
        let cont: CheckedContinuation<(statusCode: Int, data: Data), Error>? = lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true
            activeTask = nil
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = newRequest.url,
              DIDDocumentPDSResolver.validateFetchURL(
                  targetURL,
                  allowLocalhostDevelopment: allowLocalhostDevelopment
              )
        else {
            lock.withLock {
                redirectError = BackupError.invalidURL(newRequest.url?.absoluteString ?? "redirect")
            }
            completionHandler(nil)
            return
        }
        var sanitized = newRequest
        sanitized.httpShouldHandleCookies = false
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "DPoP")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitized)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(BackupError.emptyResponse(endpoint: "com.atproto.sync.getRepo")))
            return
        }

        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let expected, expected > Int64(maxBytes) {
            completionHandler(.cancel)
            finish(with: .failure(BackupError.archiveTooLarge(maxBytes: maxBytes)))
            return
        }

        lock.withLock {
            self.statusCode = httpResponse.statusCode
            self.expectedLength = expected
        }
        progressHandler?(0, expected)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let state: (exceeded: Bool, count: Int64, expected: Int64?) = lock.withLock {
            guard !didFinish else { return (false, 0, nil) }
            if buffer.count + data.count > maxBytes {
                return (true, Int64(buffer.count + data.count), expectedLength)
            }
            buffer.append(data)
            return (false, Int64(buffer.count), expectedLength)
        }

        if state.exceeded {
            dataTask.cancel()
            finish(with: .failure(BackupError.archiveTooLarge(maxBytes: maxBytes)))
            return
        }

        progressHandler?(state.count, state.expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot: (redirectError: Error?, statusCode: Int?, data: Data) = lock.withLock {
            (redirectError, statusCode, buffer)
        }

        if let redirectError = snapshot.redirectError {
            finish(with: .failure(redirectError))
            return
        }
        if let error {
            finish(with: .failure(error))
            return
        }
        guard let code = snapshot.statusCode else {
            finish(with: .failure(BackupError.emptyResponse(endpoint: "com.atproto.sync.getRepo")))
            return
        }
        finish(with: .success((code, snapshot.data)))
    }
}
