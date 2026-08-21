//
//  RecordListModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

public struct RecordRow: Identifiable, Hashable, Sendable {
    public var id: String { uri }
    public let uri: String        // full space record at:// URI: at://{spaceDid}/space/{spaceType}/{skey}/{authorDid}/{collection}/{rkey}
    public let collection: String
    public let rkey: String
    public let cid: String
    public let json: String       // pretty-printed record value
    public let blobRefs: [String] // extracted blob cids or links if any

    public init(
        uri: String,
        collection: String,
        rkey: String,
        cid: String,
        json: String,
        blobRefs: [String] = []
    ) {
        self.uri = uri
        self.collection = collection
        self.rkey = rkey
        self.cid = cid
        self.json = json
        self.blobRefs = blobRefs
    }
}

@MainActor
@Observable
public final class RecordListModel {
    public enum ErrorState: Equatable, Sendable {
        case repoNotFound(String)
        case tombstone(String)
        case reconsentNeeded(String)
        case general(String)

        public var message: String {
            switch self {
            case .repoNotFound(let msg),
                 .tombstone(let msg),
                 .reconsentNeeded(let msg),
                 .general(let msg):
                return msg
            }
        }
    }

    public private(set) var rows: [RecordRow] = []
    public private(set) var commit: (rev: String, hash: String)?
    public private(set) var isLoading: Bool = false
    public private(set) var error: String?
    public private(set) var errorState: ErrorState?

    public var sortOrder: [KeyPathComparator<RecordRow>] = [
        KeyPathComparator(\.collection, order: .forward),
        KeyPathComparator(\.rkey, order: .forward)
    ] {
        didSet {
            applySorting()
        }
    }

    public init(
        rows: [RecordRow] = [],
        commit: (rev: String, hash: String)? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        errorState: ErrorState? = nil,
        sortOrder: [KeyPathComparator<RecordRow>] = [
            KeyPathComparator(\.collection, order: .forward),
            KeyPathComparator(\.rkey, order: .forward)
        ]
    ) {
        self.rows = rows
        self.commit = commit
        self.isLoading = isLoading
        self.error = error
        self.errorState = errorState
        self.sortOrder = sortOrder
        if !rows.isEmpty {
            applySorting()
        }
    }

    private func applySorting() {
        rows.sort(using: sortOrder)
    }

    // MARK: - Pure Static Helpers

    /// Formats an `ATProtocolValueContainer` into a pretty-printed JSON string.
    nonisolated public static func formatPrettyJSON(from container: ATProtocolValueContainer?) -> String {
        guard let container = container else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(container),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }

    /// Extracts blob references (CIDs / links) from a JSON string or value container where `$type` or type indicates blob.
    nonisolated public static func extractBlobRefs(from container: ATProtocolValueContainer?) -> [String] {
        guard let container = container else { return [] }
        var blobs: [String] = []

        func traverse(_ val: ATProtocolValueContainer) {
            switch val {
            case .object(let dict):
                // Check if this object is a blob descriptor
                // Standard atproto blob descriptor: { "$type": "blob", "ref": { "$link": "bafy..." }, "mimeType": "...", "size": 123 }
                if let typeVal = dict["$type"] {
                    if case .string(let typeStr) = typeVal, typeStr == "blob" {
                        if let refVal = dict["ref"] {
                            if case .link(let link) = refVal {
                                blobs.append(link.cid.description)
                            } else if case .object(let refDict) = refVal,
                                      let linkVal = refDict["$link"],
                                      case .string(let linkStr) = linkVal {
                                blobs.append(linkStr)
                            }
                        }
                    }
                }
                for child in dict.values {
                    traverse(child)
                }
            case .array(let arr):
                for item in arr {
                    traverse(item)
                }
            case .unknownType(let typeStr, let child):
                if typeStr == "blob" {
                    if case .object(let dict) = child,
                       let refVal = dict["ref"] {
                        if case .link(let link) = refVal {
                            blobs.append(link.cid.description)
                        } else if case .object(let refDict) = refVal,
                                  let linkVal = refDict["$link"],
                                  case .string(let linkStr) = linkVal {
                            blobs.append(linkStr)
                        }
                    }
                }
                traverse(child)
            case .link(let link):
                _ = link
            default:
                break
            }
        }

        traverse(container)

        // If AST traversal didn't catch specialized structures, inspect via JSONSerialization
        if blobs.isEmpty,
           let encoder = try? JSONEncoder().encode(container),
           let jsonObject = try? JSONSerialization.jsonObject(with: encoder) {
            blobs = extractBlobRefsFromJSONObject(jsonObject)
        }

        return Array(NSOrderedSet(array: blobs)).compactMap { $0 as? String }
    }

    nonisolated private static func extractBlobRefsFromJSONObject(_ object: Any) -> [String] {
        var results: [String] = []
        if let dict = object as? [String: Any] {
            if let type = dict["$type"] as? String, type == "blob" {
                if let ref = dict["ref"] as? [String: Any], let link = ref["$link"] as? String {
                    results.append(link)
                } else if let ref = dict["ref"] as? String {
                    results.append(ref)
                } else if let cid = dict["cid"] as? String {
                    results.append(cid)
                }
            }
            for value in dict.values {
                results.append(contentsOf: extractBlobRefsFromJSONObject(value))
            }
        } else if let array = object as? [Any] {
            for item in array {
                results.append(contentsOf: extractBlobRefsFromJSONObject(item))
            }
        }
        return results
    }

    /// Constructs the canonical record `at://` URI for a space record:
    /// `at://{spaceDid}/space/{spaceType}/{skey}/{authorDid}/{collection}/{rkey}`
    nonisolated public static func makeRecordURI(space: SpaceRef, repoDID: String, collection: String, rkey: String) -> String {
        if let uri = try? space.recordURI(authorDID: repoDID, collection: collection, recordKey: rkey) {
            return uri.uriString()
        }
        return "\(space.uriString())/\(repoDID)/\(collection)/\(rkey)"
    }

    /// Maps a `ComAtprotoSpaceListRecords.Record` to a UI `RecordRow`.
    nonisolated public static func mapRecordRow(
        from record: ComAtprotoSpaceListRecords.Record,
        space: SpaceRef,
        repoDID: String
    ) -> RecordRow {
        let uri = makeRecordURI(
            space: space,
            repoDID: repoDID,
            collection: record.collection.description,
            rkey: record.rkey.description
        )
        let json = formatPrettyJSON(from: record.value)
        let blobRefs = extractBlobRefs(from: record.value)

        return RecordRow(
            uri: uri,
            collection: record.collection.description,
            rkey: record.rkey.description,
            cid: record.cid.description,
            json: json,
            blobRefs: blobRefs
        )
    }

    /// Builds the full XRPC URL for `com.atproto.space.listRecords` on a member's PDS host.
    nonisolated public static func makeListRecordsURL(
        pdsHost: URL,
        space: SpaceRef,
        repoDID: String,
        collection: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> URL? {
        guard var components = URLComponents(url: pdsHost, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/xrpc/com.atproto.space.listRecords"
        components.path = path

        var queryItems = [
            URLQueryItem(name: "space", value: space.uriString()),
            URLQueryItem(name: "repo", value: repoDID)
        ]

        if let collection = collection, !collection.isEmpty {
            queryItems.append(URLQueryItem(name: "collection", value: collection))
        }
        if let cursor = cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit = limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Builds the full XRPC URL for `com.atproto.space.getLatestCommit` on a member's PDS host.
    nonisolated public static func makeGetLatestCommitURL(
        pdsHost: URL,
        space: SpaceRef,
        repoDID: String
    ) -> URL? {
        guard var components = URLComponents(url: pdsHost, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/xrpc/com.atproto.space.getLatestCommit"
        components.path = path

        components.queryItems = [
            URLQueryItem(name: "space", value: space.uriString()),
            URLQueryItem(name: "repo", value: repoDID)
        ]

        return components.url
    }

    /// Pure pagination helper: repeatedly invokes `fetchPage` following `output.cursor` until nil,
    /// decoding `ComAtprotoSpaceListRecords.Output` and protecting against duplicate-cursor loops.
    nonisolated public static func fetchAllRecords(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, data: Data)
    ) async throws -> [ComAtprotoSpaceListRecords.Record] {
        var allRecords: [ComAtprotoSpaceListRecords.Record] = []
        var nextCursor: String? = nil
        var seenCursors = Set<String>()

        while true {
            let (statusCode, data) = try await fetchPage(nextCursor)

            guard (200...299).contains(statusCode) else {
                if let genericError = ATProtoErrorParser.parseGeneric(data: data, statusCode: statusCode) {
                    throw genericError
                }
                throw ATProtoXRPCError(
                    error: "XRPCError_\(statusCode)",
                    message: "HTTP \(statusCode)",
                    statusCode: statusCode
                )
            }

            let output = try JSONDecoder().decode(ComAtprotoSpaceListRecords.Output.self, from: data)
            allRecords.append(contentsOf: output.records)

            guard let cursor = output.cursor, !cursor.isEmpty else {
                break
            }

            if seenCursors.contains(cursor) {
                break
            }
            seenCursors.insert(cursor)
            nextCursor = cursor
        }

        return allRecords
    }

    /// Pure pagination helper using generated client output type.
    nonisolated public static func fetchAllRecordsClient(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListRecords.Output?)
    ) async throws -> [ComAtprotoSpaceListRecords.Record] {
        var allRecords: [ComAtprotoSpaceListRecords.Record] = []
        var nextCursor: String? = nil
        var seenCursors = Set<String>()

        while true {
            let (statusCode, output) = try await fetchPage(nextCursor)

            guard (200...299).contains(statusCode), let output = output else {
                throw ATProtoXRPCError(
                    error: "XRPCError_\(statusCode)",
                    message: "HTTP \(statusCode)",
                    statusCode: statusCode
                )
            }

            allRecords.append(contentsOf: output.records)

            guard let cursor = output.cursor, !cursor.isEmpty else {
                break
            }

            if seenCursors.contains(cursor) {
                break
            }
            seenCursors.insert(cursor)
            nextCursor = cursor
        }

        return allRecords
    }

    /// Classifies an error into specific UI error states.
    nonisolated public static func classifyError(_ error: Error) -> ErrorState {
        let message: String
        let errorString: String

        if let xrpc = error as? ATProtoXRPCError {
            errorString = xrpc.error
            message = xrpc.errorDescription ?? xrpc.error
        } else if let localized = (error as? LocalizedError)?.errorDescription {
            errorString = ""
            message = localized
        } else {
            errorString = ""
            message = error.localizedDescription
        }

        let lowercasedMessage = message.lowercased()
        let lowercasedError = errorString.lowercased()

        if errorString == "RepoNotFound" || lowercasedError.contains("reponotfound") || lowercasedMessage.contains("reponotfound") {
            return .repoNotFound(message)
        }

        if errorString == "SpaceNotFound" ||
            errorString == "SpaceDeleted" ||
            lowercasedError.contains("spacenotfound") ||
            lowercasedError.contains("spacedeleted") ||
            lowercasedMessage.contains("spacenotfound") ||
            lowercasedMessage.contains("spacedeleted") {
            return .tombstone(message)
        }

        if errorString == "MissingScope" ||
            errorString == "InsufficientScope" ||
            errorString == "InvalidScope" ||
            errorString == "AuthError" ||
            lowercasedMessage.contains("invalid_token") ||
            lowercasedMessage.contains("missing scope") ||
            lowercasedMessage.contains("insufficient_scope") ||
            lowercasedMessage.contains("re-consent") ||
            lowercasedMessage.contains("reconsent") ||
            lowercasedMessage.contains("scope") ||
            lowercasedMessage.contains("auth") {
            return .reconsentNeeded(message)
        }

        return .general(message)
    }

    // MARK: - Pure Pipeline

    /// Pure pipeline helper that decides and executes the own-vs-foreign repo path with injected closures.
    nonisolated public static func loadRecordsPipeline(
        space: SpaceItem,
        repo: RepoEntry,
        accountDID: String,
        fetchOwnRecords: @Sendable () async throws -> [ComAtprotoSpaceListRecords.Record],
        fetchOwnCommit: @Sendable () async throws -> (rev: String, hash: String),
        resolveForeignPDS: @Sendable () async throws -> URL,
        fetchForeignRecords: @Sendable (_ pdsURL: URL) async throws -> [ComAtprotoSpaceListRecords.Record],
        fetchForeignCommit: @Sendable (_ pdsURL: URL) async throws -> (rev: String, hash: String)
    ) async throws -> (records: [ComAtprotoSpaceListRecords.Record], commit: (rev: String, hash: String)) {
        let isOwnRepo = (repo.did == accountDID)

        if isOwnRepo {
            async let recordsTask = fetchOwnRecords()
            async let commitTask = fetchOwnCommit()
            let records = try await recordsTask
            let commit = try await commitTask
            return (records, commit)
        } else {
            let pdsURL = try await resolveForeignPDS()
            async let recordsTask = fetchForeignRecords(pdsURL)
            async let commitTask = fetchForeignCommit(pdsURL)
            let records = try await recordsTask
            let commit = try await commitTask
            return (records, commit)
        }
    }

    // MARK: - Load Action

    public func load(space: SpaceItem, repo: RepoEntry, account: AccountStore.Account) async {
        isLoading = true
        error = nil
        errorState = nil
        rows = []
        commit = nil
        defer { isLoading = false }

        do {
            let (fetchedRecords, fetchedCommit) = try await Self.loadRecordsPipeline(
                space: space,
                repo: repo,
                accountDID: account.id,
                fetchOwnRecords: {
                    let repoDIDObj = try DID(didString: repo.did)
                    return try await Self.fetchAllRecordsClient { cursor in
                        let (responseCode, output) = try await account.client.com.atproto.space.listRecords(
                            input: ComAtprotoSpaceListRecords.Parameters(
                                space: space.ref,
                                repo: repoDIDObj,
                                cursor: cursor
                            )
                        )
                        return (responseCode, output)
                    }
                },
                fetchOwnCommit: {
                    let repoDIDObj = try DID(didString: repo.did)
                    let (_, commitOutput) = try await account.client.com.atproto.space.getLatestCommit(
                        input: ComAtprotoSpaceGetLatestCommit.Parameters(
                            space: space.ref,
                            repo: repoDIDObj
                        )
                    )
                    guard let commitObj = commitOutput?.commit else {
                        throw ATProtoXRPCError(
                            error: "CommitNotFound",
                            message: "Latest commit not returned by server",
                            statusCode: 404
                        )
                    }
                    let hashStr = commitObj.hash.data.base64EncodedString()
                    return (rev: commitObj.rev.description, hash: hashStr)
                },
                resolveForeignPDS: {
                    try await account.client.resolveDIDToPDSURL(did: repo.did)
                },
                fetchForeignRecords: { pdsURL in
                    try await Self.fetchAllRecords { cursor in
                        guard let requestURL = Self.makeListRecordsURL(
                            pdsHost: pdsURL,
                            space: space.ref,
                            repoDID: repo.did,
                            cursor: cursor
                        ) else {
                            throw SpaceHostResolutionError.invalidDID(repo.did)
                        }
                        let (data, response) = try await account.credentials.get(url: requestURL, space: space.ref)
                        return (responseCode: response.statusCode, data: data)
                    }
                },
                fetchForeignCommit: { pdsURL in
                    guard let commitURL = Self.makeGetLatestCommitURL(
                        pdsHost: pdsURL,
                        space: space.ref,
                        repoDID: repo.did
                    ) else {
                        throw SpaceHostResolutionError.invalidDID(repo.did)
                    }
                    let (data, response) = try await account.credentials.get(url: commitURL, space: space.ref)
                    guard (200...299).contains(response.statusCode) else {
                        if let parsed = ATProtoErrorParser.parseGeneric(data: data, statusCode: response.statusCode) {
                            throw parsed
                        }
                        throw ATProtoXRPCError(
                            error: "XRPCError_\(response.statusCode)",
                            message: "HTTP \(response.statusCode)",
                            statusCode: response.statusCode
                        )
                    }
                    let commitOutput = try JSONDecoder().decode(ComAtprotoSpaceGetLatestCommit.Output.self, from: data)
                    let hashStr = commitOutput.commit.hash.data.base64EncodedString()
                    return (rev: commitOutput.commit.rev.description, hash: hashStr)
                }
            )

            let mappedRows = fetchedRecords.map {
                Self.mapRecordRow(from: $0, space: space.ref, repoDID: repo.did)
            }

            self.rows = mappedRows
            self.commit = fetchedCommit
            self.applySorting()
            self.error = nil
            self.errorState = nil
        } catch {
            let classified = Self.classifyError(error)
            self.errorState = classified
            self.error = classified.message
            self.rows = []
            self.commit = nil

            if case .tombstone = classified {
                await account.credentials.invalidate(space.ref)
            }
        }
    }
}
