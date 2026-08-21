//
//  SpaceDetailModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

public struct RepoEntry: Identifiable, Hashable, Sendable {
    public var id: String { did }
    public let did: String
    public let rev: String
    public let hash: String   // hex/base64 as served

    public init(did: String, rev: String, hash: String) {
        self.did = did
        self.rev = rev
        self.hash = hash
    }
}
public enum SpacePolicyOption: String, CaseIterable, Identifiable, Sendable {
    case memberList = "memberList"
    case `public` = "public"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .memberList: return "Member List Policy"
        case .public: return "Public Policy"
        }
    }
    public var description: String {
        switch self {
        case .memberList: return "Only authorized members can write records."
        case .public: return "Anyone can write records."
        }
    }
}

public enum MemberError: LocalizedError, Equatable, Sendable {
    case emptyIdentifier
    case invalidIdentifier(String)
    case resolutionUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            return "Member identifier cannot be empty."
        case .invalidIdentifier(let msg):
            return "Invalid identifier: \(msg)"
        case .resolutionUnavailable(let msg):
            return "Handle resolution failed: \(msg)"
        }
    }
}

public enum CreateSpaceError: LocalizedError, Equatable, Sendable {
    case emptySpaceType
    case invalidSpaceType(String)
    case invalidSKey(String)

    public var errorDescription: String? {
        switch self {
        case .emptySpaceType:
            return "Space type NSID cannot be empty."
        case .invalidSpaceType(let msg):
            return "Invalid space type NSID: \(msg)"
        case .invalidSKey(let msg):
            return "Invalid space key (skey): \(msg)"
        }
    }
}


@MainActor
@Observable
public final class SpaceDetailModel {
    public enum ErrorState: Equatable, Sendable {
        case reconsentNeeded(String)
        case tombstone(String)
        case general(String)

        public var message: String {
            switch self {
            case let .reconsentNeeded(msg), let .tombstone(msg), let .general(msg):
                return msg
            }
        }
    }

    public private(set) var repos: [RepoEntry] = []
    public private(set) var members: [String]? // DIDs; nil when not simplespace-readable
    public private(set) var isLoading: Bool = false
    public private(set) var error: String?
    public private(set) var errorState: ErrorState?

    public init(
        repos: [RepoEntry] = [],
        members: [String]? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        errorState: ErrorState? = nil
    ) {
        self.repos = repos
        self.members = members
        self.isLoading = isLoading
        self.error = error
        self.errorState = errorState
    }

    // MARK: - Pure Static Helpers

    /// Builds the full XRPC URL for `com.atproto.space.listRepos` on the authority's space host.
    nonisolated public static func makeListReposURL(spaceHost: URL, space: SpaceRef, cursor: String? = nil) -> URL? {
        guard var comps = URLComponents(url: spaceHost, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = comps.path
        if path.hasSuffix("/") {
            path += "xrpc/com.atproto.space.listRepos"
        } else {
            path += "/xrpc/com.atproto.space.listRepos"
        }
        comps.path = path

        var queryItems = [URLQueryItem(name: "space", value: space.uriString())]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        comps.queryItems = queryItems
        return comps.url
    }

    /// Maps lexicon Repo structures to UI RepoEntry items.
    nonisolated public static func mapRepoEntries(from repos: [ComAtprotoSpaceListRepos.Repo]) -> [RepoEntry] {
        repos.map { repo in
            RepoEntry(
                did: repo.did.description,
                rev: repo.rev.description,
                hash: repo.hash.data.base64EncodedString()
            )
        }
    }

    /// Determines whether members should be fetched for a space.
    /// Members are listed whenever the space authority is owned by the current account,
    /// regardless of the specific space type NSID.
    nonisolated public static func shouldFetchMembers(space: SpaceItem) -> Bool {
        space.isOwnAuthority
    }

    /// Distinguishes an unreadable member list (e.g. endpoint/method not implemented or supported on this server)
    /// from a genuine XRPC error (auth, permission, space not found, invalid request, server error).
    nonisolated public static func isMemberListNotReadableError(_ error: Error) -> Bool {
        if let xrpc = error as? ATProtoXRPCError {
            if xrpc.error == "MethodNotImplemented" ||
                xrpc.error == "MethodNotFound" ||
                xrpc.error == "XRPCNotSupported" {
                return true
            }
            if let msg = xrpc.message?.lowercased(),
               msg.contains("method not implemented") ||
               msg.contains("not implemented") ||
               msg.contains("method not found") ||
               msg.contains("xrpc not supported") {
                return true
            }
        }
        return false
    }

    /// Classifies an error into specific UI error states (tombstone, reconsent, or general).
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

        if errorString == "SpaceDeleted" ||
            lowercasedError.contains("spacedeleted") ||
            lowercasedMessage.contains("spacedeleted") ||
            (lowercasedMessage.contains("space") && lowercasedMessage.contains("deleted")) {
            return .tombstone(message)
        }

        if errorString == "MissingScope" ||
            errorString == "InsufficientScope" ||
            errorString == "InvalidScope" ||
            errorString == "AuthError" ||
            lowercasedMessage.contains("missing scope") ||
            lowercasedMessage.contains("insufficient_scope") ||
            lowercasedMessage.contains("insufficient scope") ||
            lowercasedMessage.contains("re-consent") ||
            lowercasedMessage.contains("reconsent") ||
            lowercasedMessage.contains("missingdelegationtoken") ||
            lowercasedMessage.contains("failed to obtain delegation token") ||
            lowercasedMessage.contains("scope:*?authority=*") ||
            lowercasedMessage.contains("scope missing") {
            return .reconsentNeeded(message)
        }

        return .general(message)
    }

    /// Pure pagination helper: repeatedly invokes `fetchPage` following `output.cursor` until nil,
    /// decoding `ComAtprotoSpaceListRepos.Output` and protecting against duplicate-cursor loops.
    nonisolated public static func fetchAllRepos(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, data: Data)
    ) async throws -> [RepoEntry] {
        var accumulated: [RepoEntry] = []
        var currentCursor: String? = nil
        var seenCursors = Set<String>()

        repeat {
            let (responseCode, data) = try await fetchPage(currentCursor)
            guard (200...299).contains(responseCode) else {
                if let xrpcError = ATProtoErrorParser.parseGeneric(data: data, statusCode: responseCode) {
                    throw xrpcError
                }
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw ATProtoXRPCError(
                    error: "HTTP \(responseCode)",
                    message: body.isEmpty ? nil : body,
                    statusCode: responseCode
                )
            }

            let output = try JSONDecoder().decode(ComAtprotoSpaceListRepos.Output.self, from: data)
            let pageItems = mapRepoEntries(from: output.repos)
            accumulated.append(contentsOf: pageItems)

            if let nextCursor = output.cursor, !nextCursor.isEmpty, !seenCursors.contains(nextCursor) {
                seenCursors.insert(nextCursor)
                currentCursor = nextCursor
            } else {
                currentCursor = nil
            }
        } while currentCursor != nil

        return accumulated
    }

    /// Pure pagination helper for `com.atproto.simplespace.listMembers`.
    nonisolated public static func fetchAllMembers(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSimplespaceListMembers.Output?)
    ) async throws -> [String] {
        var accumulated: [String] = []
        var currentCursor: String? = nil
        var seenCursors = Set<String>()

        repeat {
            let (responseCode, output) = try await fetchPage(currentCursor)
            guard (200...299).contains(responseCode) else {
                throw ATProtoXRPCError(error: "HTTP \(responseCode)", message: nil, statusCode: responseCode)
            }
            guard let output else {
                throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body (HTTP \(responseCode))", statusCode: responseCode)
            }

            let pageItems = output.members.map { $0.did.description }
            accumulated.append(contentsOf: pageItems)

            if let nextCursor = output.cursor, !nextCursor.isEmpty, !seenCursors.contains(nextCursor) {
                seenCursors.insert(nextCursor)
                currentCursor = nextCursor
            } else {
                currentCursor = nil
            }
        } while currentCursor != nil

        return accumulated
    }

    // MARK: - Loading Pipeline

    /// Pipeline helper that executes repos and conditional members fetching with injected closures,
    /// allowing full deterministic testing of the loading flow and members gating.
    nonisolated public static func loadSpaceDetails(
        space: SpaceItem,
        fetchRepos: @Sendable () async throws -> [RepoEntry],
        fetchMembers: @Sendable () async throws -> [String]
    ) async throws -> (repos: [RepoEntry], members: [String]?) {
        let repos = try await fetchRepos()
        let members: [String]?
        if shouldFetchMembers(space: space) {
            do {
                members = try await fetchMembers()
            } catch {
                if isMemberListNotReadableError(error) {
                    members = nil
                } else {
                    throw error
                }
            }
        } else {
            members = nil
        }
        return (repos, members)
    }

    // MARK: - Load Action

    public func load(
        space: SpaceItem,
        account: AccountStore.Account,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSimplespaceListMembers.Output?))? = nil
    ) async {
        isLoading = true
        error = nil
        errorState = nil
        repos = []
        members = nil
        defer { isLoading = false }

        let reposFetchClosure: @Sendable () async throws -> [RepoEntry] = fetchRepos ?? {
            let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: account.client))
            let endpoints = try await resolver.resolve(authorityDID: space.authorityDID)
            let spaceHost = endpoints.spaceHost
            return try await Self.fetchAllRepos { cursor in
                guard let requestURL = Self.makeListReposURL(spaceHost: spaceHost, space: space.ref, cursor: cursor) else {
                    throw SpaceHostResolutionError.invalidDID(space.authorityDID)
                }
                let (data, response) = try await account.credentials.get(url: requestURL, space: space.ref)
                return (responseCode: response.statusCode, data: data)
            }
        }

        let membersFetchClosure: @Sendable () async throws -> [String] = {
            if let listMembersTransport = listMembersTransport {
                return try await Self.fetchAllMembers(fetchPage: listMembersTransport)
            } else {
                return try await Self.fetchAllMembers { cursor in
                    let (responseCode, output) = try await account.client.com.atproto.simplespace.listMembers(
                        input: ComAtprotoSimplespaceListMembers.Parameters(space: space.ref, cursor: cursor)
                    )
                    return (responseCode, output)
                }
            }
        }

        do {
            let (fetchedRepos, fetchedMembers) = try await Self.loadSpaceDetails(
                space: space,
                fetchRepos: reposFetchClosure,
                fetchMembers: membersFetchClosure
            )

            self.repos = fetchedRepos
            self.members = fetchedMembers
            self.error = nil
            self.errorState = nil
        } catch {
            let classified = Self.classifyError(error)
            self.errorState = classified
            self.error = classified.message
            self.repos = []
            self.members = nil

            if case .tombstone = classified {
                await account.credentials.invalidate(space.ref)
            }
        }
    }

    // MARK: - Write Pipelines & Actions

    /// Pure helper to construct `ComAtprotoSimplespaceCreateSpace.Input`.
    nonisolated public static func makeCreateSpaceInput(
        spaceType: String,
        skey: String?,
        policy: SpacePolicyOption
    ) throws -> ComAtprotoSimplespaceCreateSpace.Input {
        let trimmedType = spaceType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty else {
            throw CreateSpaceError.emptySpaceType
        }
        let nsid = try NSID(nsidString: trimmedType)
        let recordKey: RecordKey?
        if let skey = skey?.trimmingCharacters(in: .whitespacesAndNewlines), !skey.isEmpty {
            recordKey = try RecordKey(keyString: skey)
        } else {
            recordKey = nil
        }

        let policyUnion: ComAtprotoSimplespaceCreateSpace.InputPolicyUnion
        switch policy {
        case .memberList:
            policyUnion = .comAtprotoSimplespaceDefsMemberListPolicy(ComAtprotoSimplespaceDefs.MemberListPolicy())
        case .public:
            policyUnion = .comAtprotoSimplespaceDefsPublicPolicy(ComAtprotoSimplespaceDefs.PublicPolicy())
        }

        let appAccessUnion: ComAtprotoSimplespaceCreateSpace.InputAppAccessUnion = .comAtprotoSimplespaceDefsOpen(ComAtprotoSimplespaceDefs.Open())

        return ComAtprotoSimplespaceCreateSpace.Input(
            type: nsid,
            skey: recordKey,
            policy: policyUnion,
            appAccess: appAccessUnion
        )
    }

    /// Performs `createSpace` with an injected transport.
    nonisolated public static func performCreateSpace(
        spaceType: String,
        skey: String?,
        policy: SpacePolicyOption,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceCreateSpace.Input) async throws -> (responseCode: Int, data: ComAtprotoSimplespaceCreateSpace.Output?))? = nil
    ) async throws -> SpaceRef {
        let input = try makeCreateSpaceInput(spaceType: spaceType, skey: skey, policy: policy)
        let execute = transport ?? { input in
            try await account.client.com.atproto.simplespace.createSpace(input: input)
        }
        let (responseCode, output) = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "CreateSpaceFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        guard let output else {
            throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body from createSpace", statusCode: responseCode)
        }
        return output.uri
    }

    /// Performs `deleteSpace` with an injected transport.
    nonisolated public static func performDeleteSpace(
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceDeleteSpace.Input) async throws -> Int)? = nil
    ) async throws {
        let input = ComAtprotoSimplespaceDeleteSpace.Input(space: space.ref)
        let execute = transport ?? { input in
            try await account.client.com.atproto.simplespace.deleteSpace(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "DeleteSpaceFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
    }

    /// Resolves an identifier (either a DID or a handle) to a validated `DID`.
    nonisolated public static func resolveIdentifierToDID(
        _ identifier: String,
        resolveHandle: (@Sendable (_ handle: String) async throws -> String)? = nil
    ) async throws -> DID {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemberError.emptyIdentifier
        }
        if trimmed.hasPrefix("did:") {
            return try DID(didString: trimmed)
        }
        let handle = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard let resolver = resolveHandle else {
            throw MemberError.resolutionUnavailable("No handle resolver available")
        }
        let resolved = try await resolver(handle)
        return try DID(didString: resolved)
    }

    /// Performs `addMember` with handle resolution and injected transport.
    nonisolated public static func performAddMember(
        space: SpaceItem,
        identifier: String,
        account: AccountStore.Account,
        resolveHandle: (@Sendable (_ handle: String) async throws -> String)? = nil,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceAddMember.Input) async throws -> Int)? = nil
    ) async throws {
        let resolver = resolveHandle ?? { handle in
            try await account.client.resolveHandleToDID(handle: handle)
        }
        let did = try await resolveIdentifierToDID(identifier, resolveHandle: resolver)
        let input = ComAtprotoSimplespaceAddMember.Input(space: space.ref, did: did)
        let execute = transport ?? { input in
            try await account.client.com.atproto.simplespace.addMember(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "AddMemberFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
    }

    /// Adds a member to the space and reloads members.
    public func addMember(
        identifier: String,
        space: SpaceItem,
        account: AccountStore.Account,
        resolveHandle: (@Sendable (_ handle: String) async throws -> String)? = nil,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceAddMember.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSimplespaceListMembers.Output?))? = nil
    ) async throws {
        try await Self.performAddMember(
            space: space,
            identifier: identifier,
            account: account,
            resolveHandle: resolveHandle,
            transport: transport
        )
        await load(
            space: space,
            account: account,
            fetchRepos: fetchRepos,
            listMembersTransport: listMembersTransport
        )
    }

    /// Performs `removeMember` with injected transport.
    nonisolated public static func performRemoveMember(
        space: SpaceItem,
        did: String,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceRemoveMember.Input) async throws -> Int)? = nil
    ) async throws {
        let didVal = try DID(didString: did.trimmingCharacters(in: .whitespacesAndNewlines))
        let input = ComAtprotoSimplespaceRemoveMember.Input(space: space.ref, did: didVal)
        let execute = transport ?? { input in
            try await account.client.com.atproto.simplespace.removeMember(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "RemoveMemberFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
    }

    /// Removes a member from the space and reloads members.
    public func removeMember(
        did: String,
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceRemoveMember.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSimplespaceListMembers.Output?))? = nil
    ) async throws {
        try await Self.performRemoveMember(
            space: space,
            did: did,
            account: account,
            transport: transport
        )
        await load(
            space: space,
            account: account,
            fetchRepos: fetchRepos,
            listMembersTransport: listMembersTransport
        )
    }

    /// Deletes the space.
    public func deleteSpace(
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceDeleteSpace.Input) async throws -> Int)? = nil
    ) async throws {
        try await Self.performDeleteSpace(
            space: space,
            account: account,
            transport: transport
        )
    }
}
