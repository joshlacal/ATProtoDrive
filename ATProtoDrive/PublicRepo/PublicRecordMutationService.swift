//
//  PublicRecordMutationService.swift
//  ATProtoDrive
//

import Foundation
import Petrel

public enum PublicRecordMutationError: LocalizedError, Equatable, Sendable {
    case notRepositoryOwner(accountDID: String, targetRepoDID: String)
    case invalidCollection(String)
    case invalidRecordKey(String)
    case invalidCID(String)
    case invalidJSON(String)
    case conflictDetected(message: String)
    case httpFailure(endpoint: String, statusCode: Int, message: String?)
    case emptyResponse(endpoint: String, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case let .notRepositoryOwner(accountDID, targetRepoDID):
            return "Only the owner of \(targetRepoDID) can modify its public records (signed in as \(accountDID))."
        case let .invalidCollection(collection):
            return "Invalid collection NSID: \"\(collection)\"."
        case let .invalidRecordKey(rkey):
            return "Invalid record key: \"\(rkey)\"."
        case let .invalidCID(cid):
            return "Invalid record CID for compare-and-swap: \"\(cid)\"."
        case let .invalidJSON(reason):
            return reason
        case let .conflictDetected(message):
            return message
        case let .httpFailure(endpoint, statusCode, message):
            if let message, !message.isEmpty {
                return "\(endpoint) failed (HTTP \(statusCode)): \(message)"
            }
            return "\(endpoint) failed with HTTP \(statusCode)."
        case let .emptyResponse(endpoint, statusCode):
            return "\(endpoint) returned an empty response body (HTTP \(statusCode))."
        }
    }
}

public struct PublicRecordMutationResult: Equatable, Hashable, Sendable {
    public let uri: String
    public let cid: String
    public let commitCID: String?
    public let commitRev: String?
    public let validationStatus: String?

    public init(
        uri: String,
        cid: String,
        commitCID: String? = nil,
        commitRev: String? = nil,
        validationStatus: String? = nil
    ) {
        self.uri = uri
        self.cid = cid
        self.commitCID = commitCID
        self.commitRev = commitRev
        self.validationStatus = validationStatus
    }
}

public struct PublicRecordDeleteResult: Equatable, Hashable, Sendable {
    public let commitCID: String?
    public let commitRev: String?

    public init(commitCID: String? = nil, commitRev: String? = nil) {
        self.commitCID = commitCID
        self.commitRev = commitRev
    }
}

public struct PublicRecordMutationService: Sendable {
    public struct Operations: Sendable {
        public let createRecord: @Sendable (
            _ account: AccountStore.Account,
            _ input: ComAtprotoRepoCreateRecord.Input
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoCreateRecord.Output?)

        public let putRecord: @Sendable (
            _ account: AccountStore.Account,
            _ input: ComAtprotoRepoPutRecord.Input
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoPutRecord.Output?)

        public let deleteRecord: @Sendable (
            _ account: AccountStore.Account,
            _ input: ComAtprotoRepoDeleteRecord.Input
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoDeleteRecord.Output?)

        public init(
            createRecord: (@Sendable (
                _ account: AccountStore.Account,
                _ input: ComAtprotoRepoCreateRecord.Input
            ) async throws -> (responseCode: Int, data: ComAtprotoRepoCreateRecord.Output?))? = nil,
            putRecord: (@Sendable (
                _ account: AccountStore.Account,
                _ input: ComAtprotoRepoPutRecord.Input
            ) async throws -> (responseCode: Int, data: ComAtprotoRepoPutRecord.Output?))? = nil,
            deleteRecord: (@Sendable (
                _ account: AccountStore.Account,
                _ input: ComAtprotoRepoDeleteRecord.Input
            ) async throws -> (responseCode: Int, data: ComAtprotoRepoDeleteRecord.Output?))? = nil
        ) {
            self.createRecord = createRecord ?? Self.liveCreateRecord
            self.putRecord = putRecord ?? Self.livePutRecord
            self.deleteRecord = deleteRecord ?? Self.liveDeleteRecord
        }

        public static let live = Operations()

        private static func liveCreateRecord(
            account: AccountStore.Account,
            input: ComAtprotoRepoCreateRecord.Input
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoCreateRecord.Output?) {
            try await account.client.com.atproto.repo.createRecord(input: input)
        }

        private static func livePutRecord(
            account: AccountStore.Account,
            input: ComAtprotoRepoPutRecord.Input
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoPutRecord.Output?) {
            try await account.client.com.atproto.repo.putRecord(input: input)
        }

        private static func liveDeleteRecord(
            account: AccountStore.Account,
            input: ComAtprotoRepoDeleteRecord.Input
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoDeleteRecord.Output?) {
            try await account.client.com.atproto.repo.deleteRecord(input: input)
        }
    }

    private let operations: Operations

    public init(operations: Operations = .live) {
        self.operations = operations
    }

    // MARK: - Ownership & Validation Helpers

    /// Returns `true` only when `account` is present and its DID exactly matches `repositoryDID`.
    public static func canMutate(repositoryDID: String, with account: AccountStore.Account?) -> Bool {
        guard let account else { return false }
        let normalizedAccount = account.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRepo = repositoryDID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedAccount.isEmpty && normalizedAccount == normalizedRepo
    }

    /// Enforces the owner-only guard before any public repository mutation is prepared or sent.
    public static func verifyOwnership(accountDID: String, targetRepoDID: String) throws -> DID {
        let normalizedAccount = accountDID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = targetRepoDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccount.isEmpty, normalizedAccount == normalizedTarget else {
            throw PublicRecordMutationError.notRepositoryOwner(
                accountDID: normalizedAccount,
                targetRepoDID: normalizedTarget
            )
        }
        do {
            return try DID(didString: normalizedTarget)
        } catch {
            throw PublicRecordMutationError.notRepositoryOwner(
                accountDID: normalizedAccount,
                targetRepoDID: normalizedTarget
            )
        }
    }

    /// Validates that `json` is a JSON object whose `$type` matches `collection` (injecting `$type` if absent)
    /// and decodes it into `ATProtocolValueContainer`.
    public static func validateJSON(_ json: String, collection: String) throws -> ATProtocolValueContainer {
        let trimmedCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollection.isEmpty, (try? NSID(nsidString: trimmedCollection)) != nil else {
            throw PublicRecordMutationError.invalidCollection(collection)
        }

        let trimmedJSON = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJSON.isEmpty else {
            throw PublicRecordMutationError.invalidJSON(
                RecordListModel.RecordValidationError.empty.localizedDescription
            )
        }

        if let data = trimmedJSON.data(using: .utf8),
           let rawObject = try? JSONSerialization.jsonObject(with: data),
           let dict = rawObject as? [String: Any],
           let rawType = dict["$type"],
           !(rawType is String) {
            throw PublicRecordMutationError.invalidJSON(
                "Record $type must be a string matching '\(trimmedCollection)'."
            )
        }

        do {
            return try RecordListModel.validateRecordJSON(trimmedJSON, collection: trimmedCollection)
        } catch {
            throw PublicRecordMutationError.invalidJSON(error.localizedDescription)
        }
    }

    // MARK: - Pure Input Builders

    public static func makeCreateRecordInput(
        targetRepoDID: String,
        collection: String,
        rkey: String? = nil,
        json: String,
        validate: Bool? = nil,
        swapCommit: String? = nil,
        accountDID: String
    ) throws -> ComAtprotoRepoCreateRecord.Input {
        let repoDID = try verifyOwnership(accountDID: accountDID, targetRepoDID: targetRepoDID)
        let collectionNSID = try parseCollection(collection)
        let recordKey = try parseOptionalRecordKey(rkey)
        let recordValue = try validateJSON(json, collection: collectionNSID.description)
        let swapCommitCID = try parseOptionalCID(swapCommit)

        return ComAtprotoRepoCreateRecord.Input(
            repo: .did(repoDID),
            collection: collectionNSID,
            rkey: recordKey,
            validate: validate,
            record: recordValue,
            swapCommit: swapCommitCID
        )
    }

    public static func makePutRecordInput(
        targetRepoDID: String,
        collection: String,
        rkey: String,
        expectedCID: String,
        json: String,
        validate: Bool? = nil,
        swapCommit: String? = nil,
        accountDID: String
    ) throws -> ComAtprotoRepoPutRecord.Input {
        let repoDID = try verifyOwnership(accountDID: accountDID, targetRepoDID: targetRepoDID)
        let collectionNSID = try parseCollection(collection)
        let recordKey = try parseRequiredRecordKey(rkey)
        let swapRecordCID = try parseRequiredCID(expectedCID)
        let recordValue = try validateJSON(json, collection: collectionNSID.description)
        let swapCommitCID = try parseOptionalCID(swapCommit)

        return ComAtprotoRepoPutRecord.Input(
            repo: .did(repoDID),
            collection: collectionNSID,
            rkey: recordKey,
            validate: validate,
            record: recordValue,
            swapRecord: .value(swapRecordCID),
            swapCommit: swapCommitCID
        )
    }

    public static func makeDeleteRecordInput(
        targetRepoDID: String,
        collection: String,
        rkey: String,
        expectedCID: String,
        swapCommit: String? = nil,
        accountDID: String
    ) throws -> ComAtprotoRepoDeleteRecord.Input {
        let repoDID = try verifyOwnership(accountDID: accountDID, targetRepoDID: targetRepoDID)
        let collectionNSID = try parseCollection(collection)
        let recordKey = try parseRequiredRecordKey(rkey)
        let swapRecordCID = try parseRequiredCID(expectedCID)
        let swapCommitCID = try parseOptionalCID(swapCommit)

        return ComAtprotoRepoDeleteRecord.Input(
            repo: .did(repoDID),
            collection: collectionNSID,
            rkey: recordKey,
            swapRecord: swapRecordCID,
            swapCommit: swapCommitCID
        )
    }

    // MARK: - Mutations

    @discardableResult
    public func createRecord(
        targetRepoDID: String,
        collection: String,
        rkey: String? = nil,
        json: String,
        validate: Bool? = nil,
        swapCommit: String? = nil,
        account: AccountStore.Account
    ) async throws -> PublicRecordMutationResult {
        let input = try Self.makeCreateRecordInput(
            targetRepoDID: targetRepoDID,
            collection: collection,
            rkey: rkey,
            json: json,
            validate: validate,
            swapCommit: swapCommit,
            accountDID: account.id
        )

        let endpoint = ComAtprotoRepoCreateRecord.typeIdentifier
        do {
            let (responseCode, output) = try await operations.createRecord(account, input)
            guard (200 ... 299).contains(responseCode) else {
                throw PublicRecordMutationError.httpFailure(
                    endpoint: endpoint,
                    statusCode: responseCode,
                    message: nil
                )
            }
            guard let output else {
                throw PublicRecordMutationError.emptyResponse(
                    endpoint: endpoint,
                    statusCode: responseCode
                )
            }
            return PublicRecordMutationResult(
                uri: output.uri.description,
                cid: output.cid.string,
                commitCID: output.commit?.cid.string,
                commitRev: output.commit?.rev.description,
                validationStatus: output.validationStatus
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let mapped = Self.mapKnownError(error, endpoint: endpoint) {
                throw mapped
            }
            throw error
        }
    }

    @discardableResult
    public func updateRecord(
        targetRepoDID: String,
        collection: String,
        rkey: String,
        expectedCID: String,
        json: String,
        validate: Bool? = nil,
        swapCommit: String? = nil,
        account: AccountStore.Account
    ) async throws -> PublicRecordMutationResult {
        let input = try Self.makePutRecordInput(
            targetRepoDID: targetRepoDID,
            collection: collection,
            rkey: rkey,
            expectedCID: expectedCID,
            json: json,
            validate: validate,
            swapCommit: swapCommit,
            accountDID: account.id
        )

        let endpoint = ComAtprotoRepoPutRecord.typeIdentifier
        do {
            let (responseCode, output) = try await operations.putRecord(account, input)
            guard (200 ... 299).contains(responseCode) else {
                throw PublicRecordMutationError.httpFailure(
                    endpoint: endpoint,
                    statusCode: responseCode,
                    message: nil
                )
            }
            guard let output else {
                throw PublicRecordMutationError.emptyResponse(
                    endpoint: endpoint,
                    statusCode: responseCode
                )
            }
            return PublicRecordMutationResult(
                uri: output.uri.description,
                cid: output.cid.string,
                commitCID: output.commit?.cid.string,
                commitRev: output.commit?.rev.description,
                validationStatus: output.validationStatus
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let mapped = Self.mapKnownError(error, endpoint: endpoint) {
                throw mapped
            }
            throw error
        }
    }

    @discardableResult
    public func deleteRecord(
        targetRepoDID: String,
        collection: String,
        rkey: String,
        expectedCID: String,
        swapCommit: String? = nil,
        account: AccountStore.Account
    ) async throws -> PublicRecordDeleteResult {
        let input = try Self.makeDeleteRecordInput(
            targetRepoDID: targetRepoDID,
            collection: collection,
            rkey: rkey,
            expectedCID: expectedCID,
            swapCommit: swapCommit,
            accountDID: account.id
        )

        let endpoint = ComAtprotoRepoDeleteRecord.typeIdentifier
        do {
            let (responseCode, output) = try await operations.deleteRecord(account, input)
            guard (200 ... 299).contains(responseCode) else {
                throw PublicRecordMutationError.httpFailure(
                    endpoint: endpoint,
                    statusCode: responseCode,
                    message: nil
                )
            }
            guard let output else {
                throw PublicRecordMutationError.emptyResponse(
                    endpoint: endpoint,
                    statusCode: responseCode
                )
            }
            return PublicRecordDeleteResult(
                commitCID: output.commit?.cid.string,
                commitRev: output.commit?.rev.description
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let mapped = Self.mapKnownError(error, endpoint: endpoint) {
                throw mapped
            }
            throw error
        }
    }

    // MARK: - Error Mapping

    public static func mapKnownError(_ error: Error, endpoint: String) -> PublicRecordMutationError? {
        if let mutationError = error as? PublicRecordMutationError {
            return mutationError
        }
        if let putError = error as? ATProtoError<ComAtprotoRepoPutRecord.Error>,
           putError.error == .invalidSwap {
            return .conflictDetected(message: conflictMessage(serverMessage: putError.message))
        }
        if let deleteError = error as? ATProtoError<ComAtprotoRepoDeleteRecord.Error>,
           deleteError.error == .invalidSwap {
            return .conflictDetected(message: conflictMessage(serverMessage: deleteError.message))
        }
        if let createError = error as? ATProtoError<ComAtprotoRepoCreateRecord.Error>,
           createError.error == .invalidSwap {
            return .conflictDetected(message: conflictMessage(serverMessage: createError.message))
        }
        if let xrpc = error as? ATProtoXRPCError {
            if xrpc.error.caseInsensitiveCompare("InvalidSwap") == .orderedSame {
                return .conflictDetected(message: conflictMessage(serverMessage: xrpc.message))
            }
            return .httpFailure(
                endpoint: endpoint,
                statusCode: xrpc.statusCode,
                message: xrpc.errorDescription ?? xrpc.message ?? xrpc.error
            )
        }
        return nil
    }

    private static func conflictMessage(serverMessage: String?) -> String {
        let base = "This record changed remotely since it was loaded (compare-and-swap CID mismatch). Refresh the collection to inspect the latest version before retrying."
        if let serverMessage {
            let trimmed = serverMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(base) (\(trimmed))"
            }
        }
        return base
    }

    // MARK: - Parsing Helpers

    private static func parseCollection(_ raw: String) throws -> NSID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PublicRecordMutationError.invalidCollection(raw)
        }
        do {
            return try NSID(nsidString: trimmed)
        } catch {
            throw PublicRecordMutationError.invalidCollection(raw)
        }
    }

    private static func parseRequiredRecordKey(_ raw: String) throws -> RecordKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PublicRecordMutationError.invalidRecordKey(raw)
        }
        do {
            return try RecordKey(keyString: trimmed)
        } catch {
            throw PublicRecordMutationError.invalidRecordKey(raw)
        }
    }

    private static func parseOptionalRecordKey(_ raw: String?) throws -> RecordKey? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try RecordKey(keyString: trimmed)
        } catch {
            throw PublicRecordMutationError.invalidRecordKey(raw)
        }
    }

    private static func parseRequiredCID(_ raw: String) throws -> CIDString {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PublicRecordMutationError.invalidCID(raw)
        }
        do {
            return try CIDString(cidString: trimmed)
        } catch {
            throw PublicRecordMutationError.invalidCID(raw)
        }
    }

    private static func parseOptionalCID(_ raw: String?) throws -> CIDString? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try CIDString(cidString: trimmed)
        } catch {
            throw PublicRecordMutationError.invalidCID(raw)
        }
    }
}
