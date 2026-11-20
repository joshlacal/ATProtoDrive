//
//  SpaceDetailModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import OSLog
import Petrel

private let spaceDetailLogger = Logger(subsystem: "blue.catbird.atprotodrive", category: "Spaces")

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
public struct SpaceMemberEntry: Identifiable, Hashable, Sendable {
    public var id: String { did }
    public let did: String
    public let read: Bool
    public let write: Bool

    public init(did: String, read: Bool = true, write: Bool = true) {
        self.did = did
        self.read = read
        self.write = write
    }
}

public enum SpacePolicySummary: Equatable, Hashable, Sendable {
    case personal
    case memberList(
        publicRead: Bool,
        publicWrite: Bool,
        allowedApps: [String],
        publishPolicy: Bool,
        publishMembers: Bool
    )
    case managed(managingApp: String, publishPolicy: Bool)
    case other(String)

    public var title: String {
        switch self {
        case .personal:
            return "Personal Space"
        case let .memberList(publicRead, publicWrite, _, _, _):
            if publicRead && publicWrite {
                return "Member Space (Public Read & Write)"
            } else if publicRead {
                return "Member Space (Public Read)"
            } else if publicWrite {
                return "Member Space (Public Write)"
            }
            return "Member Space"
        case .managed:
            return "Managed Space"
        case let .other(name):
            return name
        }
    }

    public var allowedApps: [String] {
        switch self {
        case let .memberList(_, _, apps, _, _):
            return apps
        default:
            return []
        }
    }
}

public enum SpacePolicyOption: String, CaseIterable, Identifiable, Sendable {
    case personal = "personal"
    case memberList = "memberList"
    case `public` = "public"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .personal: return "Personal Space"
        case .memberList: return "Member List Policy"
        case .public: return "Public Policy"
        }
    }
    public var description: String {
        switch self {
        case .personal: return "Only your account can read and write records."
        case .memberList: return "Only authorized members can read and write records."
        case .public: return "Anyone can read and write records."
        }
    }
    public var appAccessSummary: String {
        switch self {
        case .personal: return "Owner account only"
        case .memberList, .public: return "All apps allowed (no allowedApps restriction)"
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

public enum EditableSpacePolicy: Equatable, Hashable, Sendable {
    case personal
    case memberList(
        publicRead: Bool,
        publicWrite: Bool,
        allowedApps: [String],
        publishPolicy: Bool,
        publishMembers: Bool
    )

    public init(from summary: SpacePolicySummary?) {
        switch summary {
        case .personal:
            self = .personal
        case let .memberList(publicRead, publicWrite, allowedApps, publishPolicy, publishMembers):
            self = .memberList(
                publicRead: publicRead,
                publicWrite: publicWrite,
                allowedApps: allowedApps,
                publishPolicy: publishPolicy,
                publishMembers: publishMembers
            )
        case .managed, .other, nil:
            self = .memberList(
                publicRead: false,
                publicWrite: false,
                allowedApps: [],
                publishPolicy: false,
                publishMembers: false
            )
        }
    }

    public var policySummary: SpacePolicySummary {
        switch self {
        case .personal:
            return .personal
        case let .memberList(publicRead, publicWrite, allowedApps, publishPolicy, publishMembers):
            return .memberList(
                publicRead: publicRead,
                publicWrite: publicWrite,
                allowedApps: allowedApps,
                publishPolicy: publishPolicy,
                publishMembers: publishMembers
            )
        }
    }

    /// Parses comma- and/or newline-separated OAuth client ID URIs, trimming whitespace,
    /// discarding blank entries, and deduplicating while preserving order.
    public static func parseAllowedApps(from rawText: String) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        let separators = CharacterSet(charactersIn: ",\n\r")
        for piece in rawText.components(separatedBy: separators) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                results.append(trimmed)
            }
        }
        return results
    }
}

public enum SpaceAdminError: LocalizedError, Equatable, Sendable {
    case notSpaceAuthority(accountDID: String, authorityDID: String)
    case invalidAllowedAppURI(String)
    case invalidMemberDID(String)

    public var errorDescription: String? {
        switch self {
        case let .notSpaceAuthority(accountDID, authorityDID):
            return "Only the space authority (\(authorityDID)) can administer this Space (signed in as \(accountDID))."
        case let .invalidAllowedAppURI(uri):
            return "Invalid allowed app URI: \"\(uri)\". Enter a valid OAuth client ID URI."
        case let .invalidMemberDID(did):
            return "Invalid member DID: \"\(did)\"."
        }
    }
}


@MainActor
@Observable
public final class SpaceDetailModel {
    public enum ErrorState: Equatable, Sendable {
        case reconsentNeeded(String)
        case tombstone(String)
        case authorizationRefused(String)
        case tokenRejected(String)
        case general(String)

        public var message: String {
            switch self {
            case let .reconsentNeeded(msg),
                 let .tombstone(msg),
                 let .authorizationRefused(msg),
                 let .tokenRejected(msg),
                 let .general(msg):
                return msg
            }
        }
    }

    public private(set) var repos: [RepoEntry] = []
    public private(set) var members: [String]? // DIDs; nil when the member list is not readable
    public private(set) var memberEntries: [SpaceMemberEntry]?
    public private(set) var policySummary: SpacePolicySummary?
    public private(set) var isLoading: Bool = false
    public private(set) var error: String?
    public private(set) var errorState: ErrorState?
    private var loadGeneration: Int = 0
    public struct StoredVerification: Sendable, Equatable {
        public let targetRev: String
        public let report: VerificationReport

        public init(targetRev: String, report: VerificationReport) {
            self.targetRev = targetRev
            self.report = report
        }
    }

    public private(set) var verificationReports: [String: StoredVerification] = [:]
    public private(set) var verifyingRepoDIDs: Set<String> = []

    /// Returns the verified report for a repository entry iff it matches the requested repo revision (not stale),
    /// and for `.verified` outcomes additionally verifies that the wire revision matches the repo revision.
    public func verificationReport(for repo: RepoEntry) -> VerificationReport? {
        guard let stored = verificationReports[repo.did], stored.targetRev == repo.rev else {
            return nil
        }
        if case .verified = stored.report.outcome {
            guard stored.report.rev == repo.rev && !repo.rev.isEmpty else {
                return nil
            }
        }
        return stored.report
    }

    public init(
        repos: [RepoEntry] = [],
        members: [String]? = nil,
        memberEntries: [SpaceMemberEntry]? = nil,
        policySummary: SpacePolicySummary? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        errorState: ErrorState? = nil,
        verificationReports: [String: StoredVerification] = [:],
        verifyingRepoDIDs: Set<String> = []
    ) {
        self.repos = repos
        self.members = members
        self.memberEntries = memberEntries
        self.policySummary = policySummary
        self.isLoading = isLoading
        self.error = error
        self.errorState = errorState
        self.verificationReports = verificationReports
        self.verifyingRepoDIDs = verifyingRepoDIDs
    }

    /// Summarizes a `com.atproto.space.getSpace` policy union for UI presentation.
    nonisolated public static func summarizePolicy(
        _ policy: ComAtprotoSpaceGetSpace.OutputPolicyUnion
    ) -> SpacePolicySummary {
        switch policy {
        case .comAtprotoPersonalspacePolicy:
            return .personal
        case let .comAtprotoMemberspacePolicy(memberPolicy):
            return .memberList(
                publicRead: memberPolicy.publicRead == true,
                publicWrite: memberPolicy.publicWrite == true,
                allowedApps: memberPolicy.allowedApps?.map(\.description) ?? [],
                publishPolicy: memberPolicy.publishPolicy == true,
                publishMembers: memberPolicy.publishMembers == true
            )
        case let .comAtprotoManagedspacePolicy(managedPolicy):
            return .managed(
                managingApp: managedPolicy.managingApp,
                publishPolicy: managedPolicy.publishPolicy == true
            )
        case let .unexpected(container):
            if case let .unknownType(type, _) = container {
                return .other(type)
            }
            if case let .object(dict) = container,
               case let .string(type) = dict["$type"] {
                return .other(type)
            }
            return .other("Custom Policy")
        }
    }

    // MARK: - Pure Static Helpers

    /// Builds the full XRPC URL for `com.atproto.space.listWriters` on the authority's space host.
    nonisolated public static func makeListWritersURL(spaceHost: URL, space: SpaceRef, cursor: String? = nil) -> URL? {
        guard var comps = URLComponents(url: spaceHost, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = comps.path
        if path.hasSuffix("/") {
            path += "xrpc/com.atproto.space.listWriters"
        } else {
            path += "/xrpc/com.atproto.space.listWriters"
        }
        comps.path = path

        var queryItems = [URLQueryItem(name: "space", value: space.uriString())]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        comps.queryItems = queryItems
        return comps.url
    }

    /// Maps current writer entries to the repositories shown by the app.
    /// Removed and unknown entries are not current writers, so they stay out of the existing repository view.
    nonisolated public static func mapWriterEntries(
        from writers: [ComAtprotoSpaceListWriters.OutputReposUnion]
    ) -> [RepoEntry] {
        writers.compactMap { writer in
            guard case let .comAtprotoSpaceDefsRepoWrite(repo) = writer else { return nil }
            return RepoEntry(
                did: repo.repo.description,
                rev: repo.repoRev.description,
                hash: repo.data.data.base64EncodedString()
            )
        }
    }

    /// Determines whether members should be fetched for a space.
    /// Members are listed whenever the space authority is owned by the current account,
    /// regardless of the specific space type NSID.
    nonisolated public static func shouldFetchMembers(space: SpaceItem) -> Bool {
        space.isOwnAuthority
    }

    /// Distinguishes an unreadable member list (e.g. a space not governed by the memberspace policy, or an
    /// endpoint/method not implemented or supported on this server)
    /// from a genuine XRPC error (auth, permission, space not found, invalid request, server error).
    nonisolated public static func isMemberListNotReadableError(_ error: Error) -> Bool {
        // A space governed by a personalspace or managedspace policy has no member list.
        if let typed = error as? ATProtoError<ComAtprotoMemberspaceListMembers.Error>,
           typed.error == .policyMismatch {
            return true
        }
        if let xrpc = error as? ATProtoXRPCError {
            if xrpc.error == "PolicyMismatch" ||
                xrpc.error == "MethodNotImplemented" ||
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

    /// Classifies an error into specific UI error states (tombstone, reconsent, authorizationRefused, tokenRejected, or general).
    nonisolated public static func classifyError(_ error: Error) -> ErrorState {
        if let credError = error as? SpaceCredentialError {
            switch credError {
            case .spaceDeleted(_, let message):
                let msg = credError.errorDescription ?? message ?? "SpaceDeleted"
                return .tombstone(msg)
            case .authorizationRefused:
                return .authorizationRefused(credError.errorDescription ?? "You no longer have access to this space.")
            case .tokenRejected:
                return .tokenRejected(credError.errorDescription ?? "Delegation token rejected by host.")
            case .missingDelegationToken:
                return .reconsentNeeded(credError.errorDescription ?? "Missing delegation token")
            case .exchangeFailed, .invalidToken, .invalidResponse, .invalidKey, .invalidSpaceRef, .insecureURL:
                break
            }
        }

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

        if errorString == "RepoTakendown" || errorString == "RepoDeactivated" ||
            lowercasedMessage.hasPrefix("repotakendown") || lowercasedMessage.hasPrefix("repodeactivated") {
            return .general("Space suspended: \(message)")
        }

        if errorString == "UpstreamFailure" || lowercasedMessage.hasPrefix("upstreamfailure") {
            return .general("Temporary upstream failure: \(message)")
        }

        if errorString == "InvalidSpaceMac" || lowercasedMessage.hasPrefix("invalidspacemac") {
            return .general("Space response verification failed: \(message)")
        }

        if let xrpc = error as? ATProtoXRPCError,
           xrpc.error == "SpaceDeleted", xrpc.statusCode == 400 {
            return .tombstone(message)
        }

        if lowercasedMessage.contains("rejected the delegation token as invalid") ||
            errorString == "InvalidDelegationToken" ||
            lowercasedError.contains("invaliddelegationtoken") ||
            lowercasedMessage.contains("invaliddelegationtoken") {
            return .tokenRejected(message)
        }

        if lowercasedMessage.contains("you no longer have access") ||
            errorString == "AccountNotAuthorized" ||
            errorString == "AppNotAuthorized" ||
            errorString == "NotAuthorized" ||
            errorString == "AccessDenied" ||
            errorString == "Forbidden" ||
            errorString == "PermissionDenied" ||
            lowercasedError.contains("accountnotauthorized") ||
            lowercasedError.contains("notauthorized") ||
            lowercasedError.contains("accessdenied") ||
            lowercasedMessage.contains("accountnotauthorized") ||
            lowercasedMessage.contains("notauthorized") ||
            lowercasedMessage.contains("access denied") ||
            lowercasedMessage.contains("refused authorization") {
            return .authorizationRefused(message)
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
    /// decoding `ComAtprotoSpaceListWriters.Output` and protecting against duplicate-cursor loops.
    nonisolated public static func fetchAllWriters(
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

            let output = try JSONDecoder().decode(ComAtprotoSpaceListWriters.Output.self, from: data)
            accumulated.append(contentsOf: mapWriterEntries(from: output.repos))

            if let nextCursor = output.cursor, !nextCursor.isEmpty, !seenCursors.contains(nextCursor) {
                seenCursors.insert(nextCursor)
                currentCursor = nextCursor
            } else {
                currentCursor = nil
            }
        } while currentCursor != nil

        return accumulated
    }

    /// Pure pagination helper for `com.atproto.memberspace.listMembers` returning full read/write member entries.
    nonisolated public static func fetchAllMemberEntries(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?)
    ) async throws -> [SpaceMemberEntry] {
        var accumulated: [SpaceMemberEntry] = []
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

            let pageItems = output.members.map {
                SpaceMemberEntry(did: $0.did.description, read: $0.read, write: $0.write)
            }
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

    /// Pure pagination helper for `com.atproto.memberspace.listMembers`.
    nonisolated public static func fetchAllMembers(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?)
    ) async throws -> [String] {
        try await fetchAllMemberEntries(fetchPage: fetchPage).map(\.did)
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
        authorityResolver: SpaceHostResolver? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil,
        getSpaceTransport: (@Sendable () async throws -> (responseCode: Int, output: ComAtprotoSpaceGetSpace.Output?))? = nil
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        errorState = nil
        repos = []
        members = nil
        memberEntries = nil
        policySummary = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        let shouldFetchPolicy = space.isOwnAuthority && (getSpaceTransport != nil || fetchRepos == nil)
        async let policyTask: SpacePolicySummary? = {
            guard shouldFetchPolicy else { return nil }
            let fetchPolicy: @Sendable () async throws -> (responseCode: Int, output: ComAtprotoSpaceGetSpace.Output?) =
                getSpaceTransport ?? {
                    let (responseCode, data) = try await account.client.com.atproto.space.getSpace(
                        input: ComAtprotoSpaceGetSpace.Parameters(space: space.ref)
                    )
                    return (responseCode: responseCode, output: data)
                }
            do {
                let (code, output) = try await fetchPolicy()
                if (200...299).contains(code), let output {
                    return Self.summarizePolicy(output.policy)
                }
                spaceDetailLogger.info("getSpace returned status=\(code, privacy: .public) hasOutput=\(output != nil, privacy: .public) for \(space.spaceType, privacy: .public)/\(space.skey, privacy: .public)")
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    return nil
                }
                spaceDetailLogger.info("getSpace failed for \(space.spaceType, privacy: .public)/\(space.skey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }()

        let reposFetchClosure: @Sendable () async throws -> [RepoEntry] = fetchRepos ?? {
            let resolver = authorityResolver ?? SpaceHostResolver(didResolver: ClientDIDResolver(client: account.client))
            let endpoints = try await resolver.resolve(authorityDID: space.authorityDID)
            let spaceHost = endpoints.spaceHost
            return try await Self.fetchAllWriters { cursor in
                guard let requestURL = Self.makeListWritersURL(spaceHost: spaceHost, space: space.ref, cursor: cursor) else {
                    throw SpaceHostResolutionError.invalidDID(space.authorityDID)
                }
                let (data, response) = try await account.credentials.get(url: requestURL, space: space.ref)
                return (responseCode: response.statusCode, data: data)
            }
        }

        let memberEntriesFetchClosure: @Sendable () async throws -> [SpaceMemberEntry] = {
            if let listMembersTransport = listMembersTransport {
                return try await Self.fetchAllMemberEntries(fetchPage: listMembersTransport)
            } else {
                return try await Self.fetchAllMemberEntries { cursor in
                    let (responseCode, output) = try await account.client.com.atproto.memberspace.listMembers(
                        input: ComAtprotoMemberspaceListMembers.Parameters(space: space.ref, cursor: cursor)
                    )
                    return (responseCode, output)
                }
            }
        }

        do {
            let fetchedRepos = try await reposFetchClosure()
            let fetchedPolicy = await policyTask
            guard !Task.isCancelled, loadGeneration == generation else { return }

            let policyAllowsMembers: Bool
            switch fetchedPolicy {
            case .personal, .managed:
                policyAllowsMembers = false
            case .memberList, .other, nil:
                policyAllowsMembers = true
            }

            let fetchedMemberEntries: [SpaceMemberEntry]?
            if Self.shouldFetchMembers(space: space) && policyAllowsMembers {
                do {
                    fetchedMemberEntries = try await memberEntriesFetchClosure()
                } catch is CancellationError {
                    return
                } catch {
                    if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                        return
                    }
                    if Self.isMemberListNotReadableError(error) {
                        fetchedMemberEntries = nil
                    } else {
                        throw error
                    }
                }
            } else {
                fetchedMemberEntries = nil
            }

            guard !Task.isCancelled, loadGeneration == generation else { return }
            self.policySummary = fetchedPolicy
            self.repos = fetchedRepos
            self.memberEntries = fetchedMemberEntries
            self.members = fetchedMemberEntries?.map(\.did)
            self.error = nil
            self.errorState = nil
            let policyLabel = self.policySummary?.title ?? "unavailable"
            let memberCount = fetchedMemberEntries?.count ?? -1
            spaceDetailLogger.info("Loaded space \(space.spaceType, privacy: .public)/\(space.skey, privacy: .public): policy=\(policyLabel, privacy: .public) writers=\(fetchedRepos.count, privacy: .public) members=\(memberCount, privacy: .public)")
        } catch is CancellationError {
            _ = await policyTask
            return
        } catch {
            let fetchedPolicy = await policyTask
            if (error as? URLError)?.code == .cancelled || Task.isCancelled || loadGeneration != generation {
                return
            }
            self.policySummary = fetchedPolicy
            let classified = Self.classifyError(error)
            self.errorState = classified
            self.error = classified.message
            self.repos = []
            self.members = nil
            self.memberEntries = nil
            let policyLabel = self.policySummary?.title ?? "unavailable"
            spaceDetailLogger.error("Failed to load space \(space.spaceType, privacy: .public)/\(space.skey, privacy: .public): policy=\(policyLabel, privacy: .public) error=\(classified.message, privacy: .public)")

            if case .tombstone = classified {
                await account.credentials.invalidate(space.ref)
            }
        }
    }

    // MARK: - Write Pipelines & Actions

    /// Pure helper to construct `ComAtprotoSpaceCreateSpace.Input`.
    nonisolated public static func makeCreateSpaceInput(
        spaceType: String,
        skey: String?,
        policy: SpacePolicyOption
    ) throws -> ComAtprotoSpaceCreateSpace.Input {
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

        let policyUnion: ComAtprotoSpaceCreateSpace.InputPolicyUnion
        switch policy {
        case .personal:
            policyUnion = .comAtprotoPersonalspacePolicy(ComAtprotoPersonalspacePolicy())
        case .memberList:
            policyUnion = .comAtprotoMemberspacePolicy(ComAtprotoMemberspacePolicy())
        case .public:
            policyUnion = .comAtprotoMemberspacePolicy(
                ComAtprotoMemberspacePolicy(publicRead: true, publicWrite: true)
            )
        }

        return ComAtprotoSpaceCreateSpace.Input(
            spaceType: nsid,
            skey: recordKey,
            policy: policyUnion
        )
    }

    /// Pure helper to construct `ComAtprotoSpaceUpdateSpace.Input` for updating an owned space's policy.
    nonisolated public static func makeUpdateSpaceInput(
        space: SpaceItem,
        policy: EditableSpacePolicy
    ) throws -> ComAtprotoSpaceUpdateSpace.Input {
        guard space.isOwnAuthority else {
            throw SpaceAdminError.notSpaceAuthority(
                accountDID: space.accountDID,
                authorityDID: space.authorityDID
            )
        }

        let policyUnion: ComAtprotoSpaceUpdateSpace.InputPolicyUnion
        switch policy {
        case .personal:
            policyUnion = .comAtprotoPersonalspacePolicy(ComAtprotoPersonalspacePolicy())
        case let .memberList(publicRead, publicWrite, allowedApps, publishPolicy, publishMembers):
            var seen = Set<String>()
            var validatedApps: [URI] = []
            for rawApp in allowedApps {
                let trimmed = rawApp.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed).inserted else { continue }
                do {
                    validatedApps.append(try URI(validating: trimmed))
                } catch {
                    throw SpaceAdminError.invalidAllowedAppURI(trimmed)
                }
            }
            policyUnion = .comAtprotoMemberspacePolicy(
                ComAtprotoMemberspacePolicy(
                    publicRead: publicRead,
                    publicWrite: publicWrite,
                    allowedApps: validatedApps.isEmpty ? nil : validatedApps,
                    publishPolicy: publishPolicy,
                    publishMembers: publishMembers
                )
            )
        }

        return ComAtprotoSpaceUpdateSpace.Input(
            space: space.ref,
            policy: policyUnion
        )
    }

    /// Pure helper to construct `ComAtprotoMemberspacePutMembers.Input` for updating a member's read/write permissions.
    nonisolated public static func makeUpdateMemberPermissionsInput(
        did: String,
        read: Bool,
        write: Bool,
        space: SpaceItem
    ) throws -> ComAtprotoMemberspacePutMembers.Input {
        guard space.isOwnAuthority else {
            throw SpaceAdminError.notSpaceAuthority(
                accountDID: space.accountDID,
                authorityDID: space.authorityDID
            )
        }
        let trimmedDID = did.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDID: DID
        do {
            memberDID = try DID(didString: trimmedDID)
        } catch {
            throw SpaceAdminError.invalidMemberDID(did)
        }
        let member = ComAtprotoMemberspaceDefs.Member(did: memberDID, read: read, write: write)
        return ComAtprotoMemberspacePutMembers.Input(space: space.ref, members: [member])
    }

    /// Updates an owned space's policy via `com.atproto.space.updateSpace` and updates local state.
    public func updateSpacePolicy(
        space: SpaceItem,
        policy: EditableSpacePolicy,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceUpdateSpace.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil,
        getSpaceTransport: (@Sendable () async throws -> (responseCode: Int, output: ComAtprotoSpaceGetSpace.Output?))? = nil
    ) async throws {
        guard space.isOwnAuthority, account.id == space.authorityDID else {
            throw SpaceAdminError.notSpaceAuthority(
                accountDID: account.id,
                authorityDID: space.authorityDID
            )
        }

        let input = try Self.makeUpdateSpaceInput(space: space, policy: policy)
        let execute = transport ?? { input in
            try await account.client.com.atproto.space.updateSpace(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(
                error: "UpdateSpaceFailed",
                message: "Failed with HTTP \(responseCode)",
                statusCode: responseCode
            )
        }

        let normalizedSummary = normalizedPolicySummary(from: policy)
        self.policySummary = normalizedSummary
        if case .personal = policy {
            self.memberEntries = nil
            self.members = nil
        }

        if transport == nil || fetchRepos != nil || listMembersTransport != nil || getSpaceTransport != nil {
            await load(
                space: space,
                account: account,
                fetchRepos: fetchRepos,
                listMembersTransport: listMembersTransport,
                getSpaceTransport: getSpaceTransport
            )
            if self.policySummary == nil {
                self.policySummary = normalizedSummary
            }
        }
    }

    /// Updates a single member's read/write permissions via `com.atproto.memberspace.putMembers`
    /// and updates `memberEntries`.
    public func updateMemberPermissions(
        did: String,
        read: Bool,
        write: Bool,
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoMemberspacePutMembers.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil,
        getSpaceTransport: (@Sendable () async throws -> (responseCode: Int, output: ComAtprotoSpaceGetSpace.Output?))? = nil
    ) async throws {
        guard space.isOwnAuthority, account.id == space.authorityDID else {
            throw SpaceAdminError.notSpaceAuthority(
                accountDID: account.id,
                authorityDID: space.authorityDID
            )
        }

        let input = try Self.makeUpdateMemberPermissionsInput(
            did: did,
            read: read,
            write: write,
            space: space
        )
        let execute = transport ?? { input in
            try await account.client.com.atproto.memberspace.putMembers(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(
                error: "UpdateMemberPermissionsFailed",
                message: "Failed with HTTP \(responseCode)",
                statusCode: responseCode
            )
        }

        let normalizedDID = did.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedEntry = SpaceMemberEntry(did: normalizedDID, read: read, write: write)
        if var entries = self.memberEntries {
            if let existingIndex = entries.firstIndex(where: { $0.did == normalizedDID }) {
                entries[existingIndex] = updatedEntry
            } else {
                entries.append(updatedEntry)
            }
            self.memberEntries = entries
            self.members = entries.map(\.did)
        } else {
            self.memberEntries = [updatedEntry]
            self.members = [normalizedDID]
        }

        if transport == nil || fetchRepos != nil || listMembersTransport != nil || getSpaceTransport != nil {
            await load(
                space: space,
                account: account,
                fetchRepos: fetchRepos,
                listMembersTransport: listMembersTransport,
                getSpaceTransport: getSpaceTransport
            )
        }
    }

    private func normalizedPolicySummary(from policy: EditableSpacePolicy) -> SpacePolicySummary {
        switch policy {
        case .personal:
            return .personal
        case let .memberList(publicRead, publicWrite, allowedApps, publishPolicy, publishMembers):
            let cleaned = EditableSpacePolicy.parseAllowedApps(from: allowedApps.joined(separator: "\n"))
            return .memberList(
                publicRead: publicRead,
                publicWrite: publicWrite,
                allowedApps: cleaned,
                publishPolicy: publishPolicy,
                publishMembers: publishMembers
            )
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

    /// Adds a member to the space and reloads members.
    public func addMember(
        identifier: String,
        space: SpaceItem,
        account: AccountStore.Account,
        resolveHandle: (@Sendable (_ handle: String) async throws -> String)? = nil,
        transport: (@Sendable (_ input: ComAtprotoMemberspacePutMembers.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil
    ) async throws {
        let resolver = resolveHandle ?? { handle in
            try await account.client.resolveHandleToDID(handle: handle)
        }
        let did = try await Self.resolveIdentifierToDID(identifier, resolveHandle: resolver)
        let member = ComAtprotoMemberspaceDefs.Member(did: did, read: true, write: true)
        let input = ComAtprotoMemberspacePutMembers.Input(space: space.ref, members: [member])
        let execute = transport ?? { input in
            try await account.client.com.atproto.memberspace.putMembers(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "AddMemberFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        await load(
            space: space,
            account: account,
            fetchRepos: fetchRepos,
            listMembersTransport: listMembersTransport
        )
    }

    /// Removes a member from the space and reloads members.
    public func removeMember(
        did: String,
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoMemberspaceRemoveMembers.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil
    ) async throws {
        let didVal = try DID(didString: did.trimmingCharacters(in: .whitespacesAndNewlines))
        let input = ComAtprotoMemberspaceRemoveMembers.Input(space: space.ref, dids: [didVal])
        let execute = transport ?? { input in
            try await account.client.com.atproto.memberspace.removeMembers(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "RemoveMemberFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        await load(
            space: space,
            account: account,
            fetchRepos: fetchRepos,
            listMembersTransport: listMembersTransport
        )
    }

    // MARK: - Verify Repo Pipeline

    /// Builds the full XRPC URL for `com.atproto.space.getRepo`.
    nonisolated public static func makeGetRepoURL(pdsHost: URL, space: SpaceRef, repoDID: String) -> URL? {
        guard var comps = URLComponents(url: pdsHost, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = comps.path
        if path.hasSuffix("/") {
            path += "xrpc/com.atproto.space.getRepo"
        } else {
            path += "/xrpc/com.atproto.space.getRepo"
        }
        comps.path = path
        comps.queryItems = [
            URLQueryItem(name: "space", value: space.uriString()),
            URLQueryItem(name: "repo", value: repoDID),
        ]
        return comps.url
    }

    /// Largest foreign `getRepo` STAR archive accepted. Petrel's credential
    /// transport stops responses at 10 MiB unless a getRepo caller raises the
    /// limit, and a member's repo can be larger. Petrel still checks the MAC and
    /// the archive, and callers verify it again, before anything is shown.
    nonisolated static let foreignRepoArchiveLimit = SpaceSTAR.defaultMaximumArchiveBytes

    /// Response limits for the owner's OAuth `getRepo` archive. The generated
    /// call otherwise stops at the client's 10 MiB default; this accepts the
    /// same STAR maximum as foreign archives, and the archive is still verified
    /// in full before anything is shown.
    nonisolated static let ownRepoArchiveResponseLimits = NetworkResponseLimits(
        maximumWireBytes: SpaceSTAR.defaultMaximumArchiveBytes,
        maximumDecodedBytes: SpaceSTAR.defaultMaximumArchiveBytes
    )

    /// Petrel's MAC-verified space-credential GET for a foreign repo's
    /// `getRepo` archive, accepting archives up to `foreignRepoArchiveLimit`.
    nonisolated static func foreignRepoArchiveGet(
        _ credentials: SpaceCredentialManager
    ) -> @Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data) {
        { url, space in
            let (data, response) = try await credentials.get(
                url: url,
                space: space,
                maximumArchiveBytes: Self.foreignRepoArchiveLimit
            )
            return (response.statusCode, data)
        }
    }

    /// Verify a STAR export from the owner's OAuth transport or Petrel's MAC-verified
    /// credential transport. Foreign responses must pass SpaceCredentialManager.get
    /// before entering this pipeline; all exports receive full archive/digest validation.
    nonisolated public static func verifyRepoPipeline(
        space: SpaceItem,
        repo: RepoEntry,
        accountDID: String,
        clientGetRepo: @Sendable (_ space: SpaceRef, _ repoDID: DID) async throws -> (responseCode: Int, data: ComAtprotoSpaceGetRepo.Output?),
        resolveDIDToPDS: @Sendable (_ did: String) async throws -> URL,
        credentialGet: @Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data)
    ) async throws -> VerificationReport {
        let isOwnRepo = (repo.did == accountDID)
        let archiveData: Data

        if isOwnRepo {
            let repoDID = try DID(didString: repo.did)
            let (responseCode, output) = try await clientGetRepo(space.ref, repoDID)
            guard (200...299).contains(responseCode), let data = output?.data else {
                throw ATProtoXRPCError(
                    error: "GetRepoFailed",
                    message: "HTTP \(responseCode)",
                    statusCode: responseCode
                )
            }
            archiveData = data
        } else {
            let pdsHost = try await resolveDIDToPDS(repo.did)
            guard let requestURL = makeGetRepoURL(pdsHost: pdsHost, space: space.ref, repoDID: repo.did) else {
                throw SpaceHostResolutionError.invalidDID(repo.did)
            }
            let (responseCode, data) = try await credentialGet(requestURL, space.ref)
            guard (200...299).contains(responseCode) else {
                if let parsed = ATProtoErrorParser.parseGeneric(data: data, statusCode: responseCode) {
                    throw parsed
                }
                throw ATProtoXRPCError(
                    error: "GetRepoFailed",
                    message: "HTTP \(responseCode)",
                    statusCode: responseCode
                )
            }
            archiveData = data
        }

        return try RepoVerifier.verifySTAR(archive: archiveData, authorDID: repo.did, space: space.ref)
    }

    /// Verifies a specific repository and stores the resulting VerificationReport.
    public func verifyRepo(
        repo: RepoEntry,
        space: SpaceItem,
        account: AccountStore.Account,
        clientGetRepo: (@Sendable (_ space: SpaceRef, _ repoDID: DID) async throws -> (responseCode: Int, data: ComAtprotoSpaceGetRepo.Output?))? = nil,
        resolveDIDToPDS: (@Sendable (_ did: String) async throws -> URL)? = nil,
        credentialGet: (@Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data))? = nil
    ) async throws -> VerificationReport {
        verifyingRepoDIDs.insert(repo.did)
        defer { verifyingRepoDIDs.remove(repo.did) }

        let client = account.client
        let credentials = account.credentials

        let clientFetch: @Sendable (_ space: SpaceRef, _ repoDID: DID) async throws -> (responseCode: Int, data: ComAtprotoSpaceGetRepo.Output?) = clientGetRepo ?? { spaceRef, repoDID in
            try await NetworkService.withResponseLimits(Self.ownRepoArchiveResponseLimits) {
                try await client.com.atproto.space.getRepo(input: .init(space: spaceRef, repo: repoDID))
            }
        }

        let resolvePDS: @Sendable (_ did: String) async throws -> URL = resolveDIDToPDS ?? { did in
            try await client.resolveDIDToPDSURL(did: did)
        }

        let foreignGet: @Sendable (_ url: URL, _ space: SpaceRef) async throws -> (responseCode: Int, data: Data) =
            credentialGet ?? Self.foreignRepoArchiveGet(credentials)

        let report = try await Self.verifyRepoPipeline(
            space: space,
            repo: repo,
            accountDID: account.id,
            clientGetRepo: clientFetch,
            resolveDIDToPDS: resolvePDS,
            credentialGet: foreignGet
        )

        verificationReports[repo.did] = StoredVerification(targetRev: repo.rev, report: report)
        return report
    }

}
