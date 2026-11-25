//
//  SpaceListModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

public struct SpaceItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(accountDID):\(ref.uriString())" }
    public let ref: SpaceRef           // at:space/authority/type/skey
    public let accountDID: String
    public let authorityDID: String
    public let spaceType: String
    public let skey: String
    public let isOwnAuthority: Bool    // authority == account DID

    public init(ref: SpaceRef, accountDID: String) {
        self.ref = ref
        self.accountDID = accountDID
        self.authorityDID = ref.spaceDID
        self.spaceType = ref.spaceType
        self.skey = ref.skey
        self.isOwnAuthority = (ref.spaceDID == accountDID)
    }
    public init(uriString: String, accountDID: String) throws {
        let ref = try SpaceRef(uriString: uriString)
        self.init(ref: ref, accountDID: accountDID)
    }
}
/// Lenient reading of space URIs from the Spaces alpha, which used
/// `at://{spaceDid}/space/{spaceType}/{skey}[/...]`. `SpaceRef` accepts only the
/// current `at:space/{spaceDid}/...` form; this rewrites saved or pasted
/// alpha-form values before they are parsed, so nothing is sent in the old form.
/// Mirrors `fromLegacySpaceUri` in `@atproto/syntax`.
///
/// TODO: remove before beta.
public enum LegacySpaceURI {
    public static let spaceURIPrefix = "at:space/"

    /// `uri` in the current form when it is an alpha-form space URI
    /// (`at://X/space/...` becomes `at:space/X/...`), otherwise nil.
    public static func fromLegacySpaceUri(_ uri: String) -> String? {
        guard uri.hasPrefix("at://") else { return nil }
        let rest = uri.dropFirst("at://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let authority = rest[..<slash]
        let path = rest[rest.index(after: slash)...]
        guard !authority.isEmpty,
              !authority.contains(where: { $0 == "?" || $0 == "#" || $0.isWhitespace }),
              path.hasPrefix("space/")
        else { return nil }
        return "\(spaceURIPrefix)\(authority)/\(path.dropFirst("space/".count))"
    }

    /// `uri` converted when it is an alpha-form space URI, unchanged otherwise.
    public static func normalized(_ uri: String) -> String {
        fromLegacySpaceUri(uri) ?? uri
    }
}

public enum OpenSpaceError: LocalizedError, Equatable, Sendable {
    case emptyURI
    case invalidURI(String)
    case credentialFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyURI:
            return "Space URI cannot be empty."
        case .invalidURI(let msg):
            return "Invalid space URI: \(msg)"
        case .credentialFailed(let msg):
            return "Failed to obtain credential for space: \(msg)"
        }
    }
}


@MainActor
@Observable
public final class SpaceListModel {
    public private(set) var spaces: [SpaceItem] = []
    public private(set) var error: String?
    public private(set) var isLoading: Bool = false

    public init(spaces: [SpaceItem] = [], error: String? = nil) {
        self.spaces = spaces
        self.error = error
    }
    // MARK: - Custom Space Persistence Helpers

    nonisolated public static func customSpacesKey(for accountDID: String) -> String {
        "blue.catbird.atprotodrive.customSpaces.\(accountDID)"
    }

    /// Space URIs saved during the Spaces alpha (`at://{did}/space/...`) are
    /// rewritten to the `at:space/` form and saved back the first time they are read.
    nonisolated public static func loadCustomSpaceURIs(for accountDID: String, userDefaults: UserDefaults = .standard) -> [String] {
        let stored = userDefaults.stringArray(forKey: customSpacesKey(for: accountDID)) ?? []
        var uris: [String] = []
        for uri in stored.map(LegacySpaceURI.normalized) where !uris.contains(uri) {
            uris.append(uri)
        }
        if uris != stored {
            saveCustomSpaceURIs(uris, for: accountDID, userDefaults: userDefaults)
        }
        return uris
    }

    nonisolated public static func saveCustomSpaceURIs(_ uris: [String], for accountDID: String, userDefaults: UserDefaults = .standard) {
        userDefaults.set(uris, forKey: customSpacesKey(for: accountDID))
    }


    /// Pure pagination helper: repeatedly invokes `fetchPage` following `output.cursor` until nil,
    /// accumulating all `SpaceItem` instances across pages and protecting against duplicate-cursor loops.
    public static func fetchAllSpaces(
        accountDID: String,
        fetchPage: (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?)
    ) async throws -> [SpaceItem] {
        var accumulated: [SpaceItem] = []
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

            let pageItems = output.spaces.map { SpaceItem(ref: $0.uri, accountDID: accountDID) }
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

    public func load(account: AccountStore.Account) async {
        await load(accountDID: account.id) { cursor in
            let (responseCode, output) = try await account.client.com.atproto.space.listSpaces(
                input: ComAtprotoSpaceListSpaces.Parameters(cursor: cursor)
            )
            return (responseCode, output)
        }
    }

    public func load(
        accountDID: String,
        fetchPage: @Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?)
    ) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        let customURIs = Self.loadCustomSpaceURIs(for: accountDID)
        let persistedItems = customURIs.compactMap { uri -> SpaceItem? in
            guard let ref = try? SpaceRef(uriString: uri) else { return nil }
            return SpaceItem(ref: ref, accountDID: accountDID)
        }

        do {
            let fetchedSpaces = try await Self.fetchAllSpaces(accountDID: accountDID, fetchPage: fetchPage)
            var merged = fetchedSpaces
            var existingURIs = Set(fetchedSpaces.map { $0.ref.uriString() })
            for item in persistedItems {
                if !existingURIs.contains(item.ref.uriString()) {
                    merged.append(item)
                    existingURIs.insert(item.ref.uriString())
                }
            }
            self.spaces = merged
            self.error = nil
        } catch {
            var merged = self.spaces
            var existingURIs = Set(merged.map { $0.ref.uriString() })
            for item in persistedItems {
                if !existingURIs.contains(item.ref.uriString()) {
                    merged.append(item)
                    existingURIs.insert(item.ref.uriString())
                }
            }
            self.spaces = merged.isEmpty ? persistedItems : merged
            self.error = error.localizedDescription
        }
    }

    // MARK: - Mutation & Reload Actions

    @discardableResult
    public func createSpace(
        spaceType: String,
        skey: String?,
        policy: SpacePolicyOption,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceCreateSpace.Input) async throws -> (responseCode: Int, data: ComAtprotoSpaceCreateSpace.Output?))? = nil,
        listSpacesTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?))? = nil
    ) async throws -> SpaceRef {
        let input = try SpaceDetailModel.makeCreateSpaceInput(spaceType: spaceType, skey: skey, policy: policy)
        let execute = transport ?? { input in
            try await account.client.com.atproto.space.createSpace(input: input)
        }
        let (responseCode, output) = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "CreateSpaceFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        guard let output else {
            throw ATProtoXRPCError(error: "EmptyResponse", message: "No response body from createSpace", statusCode: responseCode)
        }

        // Persist the newly created space URI so it appears even before creating a repo in it
        var customURIs = Self.loadCustomSpaceURIs(for: account.id)
        if !customURIs.contains(output.uri.uriString()) {
            customURIs.append(output.uri.uriString())
            Self.saveCustomSpaceURIs(customURIs, for: account.id)
        }

        let listTransport = listSpacesTransport ?? { cursor in
            let (responseCode, data) = try await account.client.com.atproto.space.listSpaces(
                input: ComAtprotoSpaceListSpaces.Parameters(cursor: cursor)
            )
            return (responseCode: responseCode, output: data)
        }
        await load(accountDID: account.id, fetchPage: listTransport)
        return output.uri
    }

    public func deleteSpace(
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSpaceDeleteSpace.Input) async throws -> Int)? = nil,
        listSpacesTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?))? = nil
    ) async throws {
        let input = ComAtprotoSpaceDeleteSpace.Input(space: space.ref)
        let execute = transport ?? { input in
            try await account.client.com.atproto.space.deleteSpace(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "DeleteSpaceFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }
        var customURIs = Self.loadCustomSpaceURIs(for: account.id)
        if customURIs.contains(space.ref.uriString()) {
            customURIs.removeAll { $0 == space.ref.uriString() }
            Self.saveCustomSpaceURIs(customURIs, for: account.id)
        }


        let listTransport = listSpacesTransport ?? { cursor in
            let (responseCode, data) = try await account.client.com.atproto.space.listSpaces(
                input: ComAtprotoSpaceListSpaces.Parameters(cursor: cursor)
            )
            return (responseCode: responseCode, output: data)
        }
        await load(accountDID: account.id, fetchPage: listTransport)
    }

    // MARK: - Open Space by Reference

    @discardableResult
    public func openSpace(
        uriString: String,
        account: AccountStore.Account,
        credentialTransport: (@Sendable (SpaceRef) async throws -> Void)? = nil,
        listSpacesTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?))? = nil
    ) async throws -> SpaceItem {
        try await openSpace(
            uriString: uriString,
            accountDID: account.id,
            credentialTransport: credentialTransport ?? { ref in
                _ = try await account.credentials.credential(for: ref)
            },
            listSpacesTransport: listSpacesTransport ?? { cursor in
                let (responseCode, data) = try await account.client.com.atproto.space.listSpaces(
                    input: ComAtprotoSpaceListSpaces.Parameters(cursor: cursor)
                )
                return (responseCode: responseCode, output: data)
            }
        )
    }

    @discardableResult
    public func openSpace(
        uriString: String,
        accountDID: String,
        credentialTransport: (@Sendable (SpaceRef) async throws -> Void)? = nil,
        listSpacesTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?))? = nil
    ) async throws -> SpaceItem {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenSpaceError.emptyURI
        }

        // Step 1: Validate space URI locally before any network call. A pasted
        // alpha-form URI (`at://{did}/space/...`) is converted to `at:space/` first.
        let spaceRef: SpaceRef
        do {
            spaceRef = try SpaceRef(uriString: LegacySpaceURI.normalized(trimmed))
        } catch {
            throw OpenSpaceError.invalidURI(error.localizedDescription)
        }

        // Step 2: Validate/obtain space credential
        if let credentialTransport {
            do {
                try await credentialTransport(spaceRef)
            } catch {
                throw OpenSpaceError.credentialFailed(error.localizedDescription)
            }
        }

        // Step 3: Persist URI across launches for this account
        var customURIs = Self.loadCustomSpaceURIs(for: accountDID)
        if !customURIs.contains(spaceRef.uriString()) {
            customURIs.append(spaceRef.uriString())
            Self.saveCustomSpaceURIs(customURIs, for: accountDID)
        }

        // Step 4: Reload space list or update state
        if let listSpacesTransport {
            await load(accountDID: accountDID, fetchPage: listSpacesTransport)
        } else {
            if !spaces.contains(where: { $0.ref.uriString() == spaceRef.uriString() }) {
                let newItem = SpaceItem(ref: spaceRef, accountDID: accountDID)
                spaces.append(newItem)
            }
        }

        guard let found = spaces.first(where: { $0.ref.uriString() == spaceRef.uriString() }) else {
            let item = SpaceItem(ref: spaceRef, accountDID: accountDID)
            spaces.append(item)
            return item
        }
        return found
    }
}
