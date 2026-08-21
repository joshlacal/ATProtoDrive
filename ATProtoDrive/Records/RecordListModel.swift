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
    // MARK: - Validation & Write Pipelines

    public enum RecordValidationError: LocalizedError, Equatable, Sendable {
        case empty
        case notJSONObject
        case serializationFailed(String)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "JSON content cannot be empty."
            case .notJSONObject:
                return "Invalid JSON: Root must be a JSON object ({ ... })."
            case .serializationFailed(let msg):
                return "Invalid JSON syntax: \(msg)"
            case .decodingFailed(let msg):
                return "Failed to parse ATProtocol value: \(msg)"
            }
        }
    }

    /// Validates raw JSON string using JSONSerialization and decodes into ATProtocolValueContainer.
    nonisolated public static func validateRecordJSON(_ text: String) throws -> ATProtocolValueContainer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecordValidationError.empty
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw RecordValidationError.serializationFailed("Could not encode string as UTF-8")
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RecordValidationError.serializationFailed(error.localizedDescription)
        }

        guard jsonObject is [String: Any] else {
            throw RecordValidationError.notJSONObject
        }

        do {
            let container = try JSONDecoder().decode(ATProtocolValueContainer.self, from: data)
            return container
        } catch {
            throw RecordValidationError.decodingFailed(error.localizedDescription)
        }
    }

    /// Pure helper to construct `ComAtprotoSpaceCreateRecord.Input` after validating JSON.
    nonisolated public static func makeCreateRecordInput(
        space: SpaceRef,
        repoDID: String,
        collection: String,
        rkey: String?,
        jsonText: String
    ) throws -> ComAtprotoSpaceCreateRecord.Input {
        let container = try validateRecordJSON(jsonText)
        let repo = try DID(didString: repoDID.trimmingCharacters(in: .whitespacesAndNewlines))
        let colNSID = try NSID(nsidString: collection.trimmingCharacters(in: .whitespacesAndNewlines))
        let recordKey: RecordKey?
        if let rkey = rkey?.trimmingCharacters(in: .whitespacesAndNewlines), !rkey.isEmpty {
            recordKey = try RecordKey(keyString: rkey)
        } else {
            recordKey = nil
        }
        return ComAtprotoSpaceCreateRecord.Input(
            space: space,
            repo: repo,
            collection: colNSID,
            rkey: recordKey,
            validate: true,
            record: container
        )
    }

    /// Performs `createRecord` with an injected transport. Validates JSON BEFORE invoking the transport.
    nonisolated public static func performCreateRecord(
        space: SpaceRef,
        repoDID: String,
        collection: String,
        rkey: String?,
        jsonText: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceCreateRecord.Input) async throws -> (responseCode: Int, data: ComAtprotoSpaceCreateRecord.Output?))? = nil
    ) async throws -> ComAtprotoSpaceCreateRecord.Output {
        let input = try makeCreateRecordInput(
            space: space,
            repoDID: repoDID,
            collection: collection,
            rkey: rkey,
            jsonText: jsonText
        )
        let execute = transport ?? { input in
            try await account.client.com.atproto.space.createRecord(input: input)
        }
        let (responseCode, output) = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "CreateRecordFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        guard let output else {
            throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body", statusCode: responseCode)
        }
        return output
    }

    /// Pure helper to construct `ComAtprotoSpacePutRecord.Input` after validating JSON.
    nonisolated public static func makePutRecordInput(
        space: SpaceRef,
        repoDID: String,
        collection: String,
        rkey: String,
        jsonText: String
    ) throws -> ComAtprotoSpacePutRecord.Input {
        let container = try validateRecordJSON(jsonText)
        let repo = try DID(didString: repoDID.trimmingCharacters(in: .whitespacesAndNewlines))
        let colNSID = try NSID(nsidString: collection.trimmingCharacters(in: .whitespacesAndNewlines))
        let recordKey = try RecordKey(keyString: rkey.trimmingCharacters(in: .whitespacesAndNewlines))
        return ComAtprotoSpacePutRecord.Input(
            space: space,
            repo: repo,
            collection: colNSID,
            rkey: recordKey,
            validate: true,
            record: container
        )
    }

    /// Performs `putRecord` with an injected transport. Validates JSON BEFORE invoking the transport.
    nonisolated public static func performPutRecord(
        space: SpaceRef,
        repoDID: String,
        collection: String,
        rkey: String,
        jsonText: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpacePutRecord.Input) async throws -> (responseCode: Int, data: ComAtprotoSpacePutRecord.Output?))? = nil
    ) async throws -> ComAtprotoSpacePutRecord.Output {
        let input = try makePutRecordInput(
            space: space,
            repoDID: repoDID,
            collection: collection,
            rkey: rkey,
            jsonText: jsonText
        )
        let execute = transport ?? { input in
            try await account.client.com.atproto.space.putRecord(input: input)
        }
        let (responseCode, output) = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "PutRecordFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        guard let output else {
            throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body", statusCode: responseCode)
        }
        return output
    }

    /// Pure helper to construct `ComAtprotoSpaceDeleteRecord.Input`.
    nonisolated public static func makeDeleteRecordInput(
        space: SpaceRef,
        repoDID: String,
        collection: String,
        rkey: String
    ) throws -> ComAtprotoSpaceDeleteRecord.Input {
        let repo = try DID(didString: repoDID.trimmingCharacters(in: .whitespacesAndNewlines))
        let colNSID = try NSID(nsidString: collection.trimmingCharacters(in: .whitespacesAndNewlines))
        let recordKey = try RecordKey(keyString: rkey.trimmingCharacters(in: .whitespacesAndNewlines))
        return ComAtprotoSpaceDeleteRecord.Input(
            space: space,
            repo: repo,
            collection: colNSID,
            rkey: recordKey
        )
    }

    /// Performs `deleteRecord` with an injected transport.
    nonisolated public static func performDeleteRecord(
        space: SpaceRef,
        repoDID: String,
        collection: String,
        rkey: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceDeleteRecord.Input) async throws -> (responseCode: Int, data: ComAtprotoSpaceDeleteRecord.Output?))? = nil
    ) async throws -> ComAtprotoSpaceDeleteRecord.Output {
        let input = try makeDeleteRecordInput(
            space: space,
            repoDID: repoDID,
            collection: collection,
            rkey: rkey
        )
        let execute = transport ?? { input in
            try await account.client.com.atproto.space.deleteRecord(input: input)
        }
        let (responseCode, output) = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "DeleteRecordFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        guard let output else {
            throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body", statusCode: responseCode)
        }
        return output
    }

    /// Uploads a blob via `com.atproto.repo.uploadBlob` on the user's PDS.
    nonisolated public static func performUploadBlob(
        data: Data,
        mimeType: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ data: Data, _ mimeType: String) async throws -> (responseCode: Int, data: ComAtprotoRepoUploadBlob.Output?))? = nil
    ) async throws -> Blob {
        let execute = transport ?? { data, mimeType in
            try await account.client.com.atproto.repo.uploadBlob(data: data, mimeType: mimeType)
        }
        let (responseCode, output) = try await execute(data, mimeType)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "UploadBlobFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        guard let output else {
            throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body from uploadBlob", statusCode: responseCode)
        }
        return output.blob
    }

    /// Formats a `Blob` into standard pretty-printed ATProto JSON.
    nonisolated public static func formatBlobRefJSON(blob: Blob) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(blob), let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let link = blob.ref?.cid.description {
            return """
            {
              "$type": "blob",
              "mimeType": "\(blob.mimeType)",
              "ref": {
                "$link": "\(link)"
              },
              "size": \(blob.size)
            }
            """
        }
        return """
        {
          "$type": "blob",
          "mimeType": "\(blob.mimeType)",
          "size": \(blob.size)
        }
        """
    }

    public enum SpliceBlobError: LocalizedError, Equatable, Sendable {
        case noSelection

        public var errorDescription: String? {
            switch self {
            case .noSelection:
                return "Place cursor in the JSON editor where the blob reference should be inserted."
            }
        }
    }

    /// Splices a formatted blob descriptor JSON into the JSON text at the given range (cursor / selection)
    /// without reparsing or modifying the rest of the document structure.
    /// Throws if no replacement range is provided.
    nonisolated public static func spliceBlobRef(
        into jsonText: String,
        blob: Blob,
        replacementRange: Range<String.Index>?
    ) throws -> String {
        guard let range = replacementRange else {
            throw SpliceBlobError.noSelection
        }
        let blobJSON = formatBlobRefJSON(blob: blob)
        var text = jsonText
        text.replaceSubrange(range, with: blobJSON)
        return text
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

    /// Pure pipeline helper that decides and executes the own-vs-foreign repo path with injected transports:
    /// - Own repo: uses `clientListRecords` + `clientGetLatestCommit`
    /// - Foreign repo: uses `resolveDIDToPDS` + `credentialGet`
    nonisolated public static func loadRecordsPipeline(
        space: SpaceItem,
        repo: RepoEntry,
        accountDID: String,
        clientListRecords: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListRecords.Output?),
        clientGetLatestCommit: @Sendable () async throws -> (responseCode: Int, output: ComAtprotoSpaceGetLatestCommit.Output?),
        resolveDIDToPDS: @Sendable (_ did: String) async throws -> URL,
        credentialGet: @Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data)
    ) async throws -> (records: [ComAtprotoSpaceListRecords.Record], commit: (rev: String, hash: String)) {
        let isOwnRepo = (repo.did == accountDID)

        if isOwnRepo {
            async let recordsTask = fetchAllRecordsClient { cursor in
                try await clientListRecords(cursor)
            }
            async let commitTask: (rev: String, hash: String) = {
                let (responseCode, commitOutput) = try await clientGetLatestCommit()
                guard (200...299).contains(responseCode), let commitObj = commitOutput?.commit else {
                    throw ATProtoXRPCError(
                        error: "XRPCError_\(responseCode)",
                        message: "HTTP \(responseCode)",
                        statusCode: responseCode
                    )
                }
                let hashStr = commitObj.hash.data.base64EncodedString()
                return (rev: commitObj.rev.description, hash: hashStr)
            }()

            let records = try await recordsTask
            let commit = try await commitTask
            return (records, commit)
        } else {
            let pdsURL = try await resolveDIDToPDS(repo.did)

            async let recordsTask = fetchAllRecords { cursor in
                guard let requestURL = makeListRecordsURL(
                    pdsHost: pdsURL,
                    space: space.ref,
                    repoDID: repo.did,
                    cursor: cursor
                ) else {
                    throw SpaceHostResolutionError.invalidDID(repo.did)
                }
                return try await credentialGet(requestURL, space.ref)
            }

            async let commitTask: (rev: String, hash: String) = {
                guard let commitURL = makeGetLatestCommitURL(
                    pdsHost: pdsURL,
                    space: space.ref,
                    repoDID: repo.did
                ) else {
                    throw SpaceHostResolutionError.invalidDID(repo.did)
                }
                let (responseCode, data) = try await credentialGet(commitURL, space.ref)
                guard (200...299).contains(responseCode) else {
                    if let parsed = ATProtoErrorParser.parseGeneric(data: data, statusCode: responseCode) {
                        throw parsed
                    }
                    throw ATProtoXRPCError(
                        error: "XRPCError_\(responseCode)",
                        message: "HTTP \(responseCode)",
                        statusCode: responseCode
                    )
                }
                let commitOutput = try JSONDecoder().decode(ComAtprotoSpaceGetLatestCommit.Output.self, from: data)
                let hashStr = commitOutput.commit.hash.data.base64EncodedString()
                return (rev: commitOutput.commit.rev.description, hash: hashStr)
            }()

            let records = try await recordsTask
            let commit = try await commitTask
            return (records, commit)
        }
    }

    // MARK: - Load Action

    /// Internal injected load entry point for testing model state transitions and error handling.
    func load(
        space: SpaceItem,
        repo: RepoEntry,
        accountDID: String,
        clientListRecords: @Sendable @escaping (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListRecords.Output?),
        clientGetLatestCommit: @Sendable @escaping () async throws -> (responseCode: Int, output: ComAtprotoSpaceGetLatestCommit.Output?),
        resolveDIDToPDS: @Sendable @escaping (_ did: String) async throws -> URL,
        credentialGet: @Sendable @escaping (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data),
        onInvalidateSpace: (@Sendable (SpaceRef) async -> Void)? = nil
    ) async {
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
                accountDID: accountDID,
                clientListRecords: clientListRecords,
                clientGetLatestCommit: clientGetLatestCommit,
                resolveDIDToPDS: resolveDIDToPDS,
                credentialGet: credentialGet
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
                if let onInvalidateSpace = onInvalidateSpace {
                    await onInvalidateSpace(space.ref)
                }
            }
        }
    }

    public func load(space: SpaceItem, repo: RepoEntry, account: AccountStore.Account) async {
        await load(
            space: space,
            repo: repo,
            accountDID: account.id,
            clientListRecords: { cursor in
                let repoDIDObj = try DID(didString: repo.did)
                let (responseCode, output) = try await account.client.com.atproto.space.listRecords(
                    input: ComAtprotoSpaceListRecords.Parameters(
                        space: space.ref,
                        repo: repoDIDObj,
                        cursor: cursor
                    )
                )
                return (responseCode, output)
            },
            clientGetLatestCommit: {
                let repoDIDObj = try DID(didString: repo.did)
                let (responseCode, output) = try await account.client.com.atproto.space.getLatestCommit(
                    input: ComAtprotoSpaceGetLatestCommit.Parameters(
                        space: space.ref,
                        repo: repoDIDObj
                    )
                )
                return (responseCode, output)
            },
            resolveDIDToPDS: { did in
                try await account.client.resolveDIDToPDSURL(did: did)
            },
            credentialGet: { url, spaceRef in
                let (data, response) = try await account.credentials.get(url: url, space: spaceRef)
                return (responseCode: response.statusCode, data: data)
            },
            onInvalidateSpace: { spaceRef in
                await account.credentials.invalidate(spaceRef)
            }
        )
    }

    // MARK: - Mutation Actions

    @discardableResult
    public func createRecord(
        space: SpaceItem,
        repo: RepoEntry,
        collection: String,
        rkey: String?,
        jsonText: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceCreateRecord.Input) async throws -> (responseCode: Int, data: ComAtprotoSpaceCreateRecord.Output?))? = nil,
        reload: (@Sendable () async -> Void)? = nil
    ) async throws -> ComAtprotoSpaceCreateRecord.Output {
        let output = try await Self.performCreateRecord(
            space: space.ref,
            repoDID: account.id,
            collection: collection,
            rkey: rkey,
            jsonText: jsonText,
            account: account,
            transport: transport
        )
        if let reload = reload {
            await reload()
        } else {
            await load(space: space, repo: repo, account: account)
        }
        return output
    }

    @discardableResult
    public func putRecord(
        space: SpaceItem,
        repo: RepoEntry,
        collection: String,
        rkey: String,
        jsonText: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpacePutRecord.Input) async throws -> (responseCode: Int, data: ComAtprotoSpacePutRecord.Output?))? = nil,
        reload: (@Sendable () async -> Void)? = nil
    ) async throws -> ComAtprotoSpacePutRecord.Output {
        let output = try await Self.performPutRecord(
            space: space.ref,
            repoDID: account.id,
            collection: collection,
            rkey: rkey,
            jsonText: jsonText,
            account: account,
            transport: transport
        )
        if let reload = reload {
            await reload()
        } else {
            await load(space: space, repo: repo, account: account)
        }
        return output
    }

    @discardableResult
    public func deleteRecord(
        space: SpaceItem,
        repo: RepoEntry,
        collection: String,
        rkey: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceDeleteRecord.Input) async throws -> (responseCode: Int, data: ComAtprotoSpaceDeleteRecord.Output?))? = nil,
        reload: (@Sendable () async -> Void)? = nil
    ) async throws -> ComAtprotoSpaceDeleteRecord.Output {
        let output = try await Self.performDeleteRecord(
            space: space.ref,
            repoDID: repo.did,
            collection: collection,
            rkey: rkey,
            account: account,
            transport: transport
        )
        if let reload = reload {
            await reload()
        } else {
            await load(space: space, repo: repo, account: account)
        }
        return output
    }

    public func uploadBlob(
        data: Data,
        mimeType: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ data: Data, _ mimeType: String) async throws -> (responseCode: Int, data: ComAtprotoRepoUploadBlob.Output?))? = nil
    ) async throws -> Blob {
        return try await Self.performUploadBlob(
            data: data,
            mimeType: mimeType,
            account: account,
            transport: transport
        )
    }

#if DEBUG
    public func setRowsForTesting(_ rows: [RecordRow]) {
        self.rows = rows
    }
#endif
}
