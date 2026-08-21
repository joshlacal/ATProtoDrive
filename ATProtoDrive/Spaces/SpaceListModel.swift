//
//  SpaceListModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

public struct SpaceItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(accountDID):\(ref.uriString())" }
    public let ref: SpaceRef           // at://authority/space/type/skey
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

        do {
            let fetchedSpaces = try await Self.fetchAllSpaces(accountDID: accountDID, fetchPage: fetchPage)
            self.spaces = fetchedSpaces
            self.error = nil
        } catch {
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
        transport: (@Sendable (_ input: ComAtprotoSimplespaceCreateSpace.Input) async throws -> (responseCode: Int, data: ComAtprotoSimplespaceCreateSpace.Output?))? = nil,
        listSpacesTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?))? = nil
    ) async throws -> SpaceRef {
        let input = try SpaceDetailModel.makeCreateSpaceInput(spaceType: spaceType, skey: skey, policy: policy)
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

        let listTransport = listSpacesTransport ?? { cursor in
            try await account.client.com.atproto.space.listSpaces(
                input: ComAtprotoSpaceListSpaces.Parameters(cursor: cursor)
            )
        }
        await load(accountDID: account.id, fetchPage: listTransport)
        return output.uri
    }

    public func deleteSpace(
        space: SpaceItem,
        account: AccountStore.Account,
        transport: (@Sendable (_ input: ComAtprotoSimplespaceDeleteSpace.Input) async throws -> Int)? = nil,
        listSpacesTransport: (@Sendable (_ cursor: String?) async throws -> (responseCode: Int, output: ComAtprotoSpaceListSpaces.Output?))? = nil
    ) async throws {
        let input = ComAtprotoSimplespaceDeleteSpace.Input(space: space.ref)
        let execute = transport ?? { input in
            try await account.client.com.atproto.simplespace.deleteSpace(input: input)
        }
        let responseCode = try await execute(input)
        guard (200...299).contains(responseCode) else {
            throw ATProtoXRPCError(error: "DeleteSpaceFailed", message: "Failed with HTTP \(responseCode)", statusCode: responseCode)
        }

        let listTransport = listSpacesTransport ?? { cursor in
            try await account.client.com.atproto.space.listSpaces(
                input: ComAtprotoSpaceListSpaces.Parameters(cursor: cursor)
            )
        }
        await load(accountDID: account.id, fetchPage: listTransport)
    }
}
