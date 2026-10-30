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
    public private(set) var isLoading: Bool = false
    public private(set) var error: String?
    public private(set) var errorState: ErrorState?
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
        isLoading: Bool = false,
        error: String? = nil,
        errorState: ErrorState? = nil,
        verificationReports: [String: StoredVerification] = [:],
        verifyingRepoDIDs: Set<String> = []
    ) {
        self.repos = repos
        self.members = members
        self.isLoading = isLoading
        self.error = error
        self.errorState = errorState
        self.verificationReports = verificationReports
        self.verifyingRepoDIDs = verifyingRepoDIDs
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
            errorString == "UserNotAuthorized" ||
            errorString == "AppNotAuthorized" ||
            errorString == "NotAuthorized" ||
            errorString == "AccessDenied" ||
            errorString == "Forbidden" ||
            errorString == "PermissionDenied" ||
            lowercasedError.contains("usernotauthorized") ||
            lowercasedError.contains("notauthorized") ||
            lowercasedError.contains("accessdenied") ||
            lowercasedMessage.contains("usernotauthorized") ||
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

    /// Pure pagination helper for `com.atproto.memberspace.listMembers`.
    nonisolated public static func fetchAllMembers(
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?)
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
        authorityResolver: SpaceHostResolver? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil
    ) async {
        isLoading = true
        error = nil
        errorState = nil
        repos = []
        members = nil
        defer { isLoading = false }

        let reposFetchClosure: @Sendable () async throws -> [RepoEntry] = fetchRepos ?? {
            let resolver = authorityResolver ?? SpaceHostResolver(didResolver: ClientDIDResolver(client: account.client))
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
                    let (responseCode, output) = try await account.client.com.atproto.memberspace.listMembers(
                        input: ComAtprotoMemberspaceListMembers.Parameters(space: space.ref, cursor: cursor)
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

        // Both legacy options map exactly onto the memberspace policy: a member list
        // on both sides is memberspace with no public flags, and public on both sides
        // is memberspace with public read and public write. Omitting allowedApps keeps
        // the old open app access.
        let memberspacePolicy: ComAtprotoMemberspacePolicy
        switch policy {
        case .memberList:
            memberspacePolicy = ComAtprotoMemberspacePolicy()
        case .public:
            memberspacePolicy = ComAtprotoMemberspacePolicy(publicRead: true, publicWrite: true)
        }

        return ComAtprotoSpaceCreateSpace.Input(
            spaceType: nsid,
            skey: recordKey,
            policy: .comAtprotoMemberspacePolicy(memberspacePolicy)
        )
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
        transport: (@Sendable (_ input: ComAtprotoMemberspacePutMember.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil
    ) async throws {
        let resolver = resolveHandle ?? { handle in
            try await account.client.resolveHandleToDID(handle: handle)
        }
        let did = try await Self.resolveIdentifierToDID(identifier, resolveHandle: resolver)
        let input = ComAtprotoMemberspacePutMember.Input(space: space.ref, did: did, read: true, write: true)
        let execute = transport ?? { input in
            try await account.client.com.atproto.memberspace.putMember(input: input)
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
        transport: (@Sendable (_ input: ComAtprotoMemberspaceRemoveMember.Input) async throws -> Int)? = nil,
        fetchRepos: (@Sendable () async throws -> [RepoEntry])? = nil,
        listMembersTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoMemberspaceListMembers.Output?))? = nil
    ) async throws {
        let didVal = try DID(didString: did.trimmingCharacters(in: .whitespacesAndNewlines))
        let input = ComAtprotoMemberspaceRemoveMember.Input(space: space.ref, did: didVal)
        let execute = transport ?? { input in
            try await account.client.com.atproto.memberspace.removeMember(input: input)
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
