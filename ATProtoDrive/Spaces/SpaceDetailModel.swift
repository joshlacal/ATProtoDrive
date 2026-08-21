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

    /// Distinguishes an unreadable member list (e.g. endpoint not supported on this space type / PDS)
    /// from a genuine XRPC error (auth/permission/server failure).
    nonisolated public static func isMemberListNotReadableError(_ error: Error) -> Bool {
        if let xrpc = error as? ATProtoXRPCError {
            if xrpc.error == "MethodNotFound" || xrpc.error == "NotFound" {
                return true
            }
            if let msg = xrpc.message?.lowercased(), msg.contains("method not found") || msg.contains("not implemented") {
                return true
            }
            if xrpc.statusCode == 404 && xrpc.error == "InvalidRequest" {
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

    // MARK: - Load Action

    public func load(space: SpaceItem, account: AccountStore.Account) async {
        isLoading = true
        error = nil
        errorState = nil
        repos = []
        members = nil
        defer { isLoading = false }

        do {
            let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: account.client))
            let endpoints = try await resolver.resolve(authorityDID: space.authorityDID)
            let spaceHost = endpoints.spaceHost

            let fetchedRepos = try await Self.fetchAllRepos { cursor in
                guard let requestURL = Self.makeListReposURL(spaceHost: spaceHost, space: space.ref, cursor: cursor) else {
                    throw SpaceHostResolutionError.invalidDID(space.authorityDID)
                }
                let (data, response) = try await account.credentials.get(url: requestURL, space: space.ref)
                return (response.statusCode, data)
            }

            self.repos = fetchedRepos

            // Fetch members if own authority (any space type)
            if space.isOwnAuthority {
                do {
                    let fetchedMembers = try await Self.fetchAllMembers { cursor in
                        let (responseCode, output) = try await account.client.com.atproto.simplespace.listMembers(
                            input: ComAtprotoSimplespaceListMembers.Parameters(space: space.ref, cursor: cursor)
                        )
                        return (responseCode, output)
                    }
                    self.members = fetchedMembers
                } catch {
                    if Self.isMemberListNotReadableError(error) {
                        self.members = nil
                    } else {
                        throw error
                    }
                }
            } else {
                self.members = nil
            }

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
}
