//
//  SpaceListModel.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

public struct SpaceItem: Identifiable, Hashable, Sendable {
    public var id: SpaceRef { ref }
    public let ref: SpaceRef           // at://authority/space/type/skey
    public let authorityDID: String
    public let spaceType: String
    public let skey: String
    public let isOwnAuthority: Bool    // authority == account DID

    public init(ref: SpaceRef, accountDID: String) {
        self.ref = ref
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

    public func load(account: AccountStore.Account) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let (responseCode, output) = try await account.client.com.atproto.space.listSpaces(
                input: ComAtprotoSpaceListSpaces.Parameters()
            )
            guard (200...299).contains(responseCode) else {
                self.error = "XRPC error (HTTP \(responseCode))"
                return
            }
            guard let output else {
                self.error = "XRPC error: empty response body (HTTP \(responseCode))"
                return
            }
            self.spaces = output.spaces.map { SpaceItem(ref: $0.uri, accountDID: account.id) }
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
