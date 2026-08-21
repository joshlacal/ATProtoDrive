//
//  TestCARFixtureHelper.swift
//  ATProtoDriveTests
//

import CryptoKit
import Foundation
import Petrel
import secp256k1
import SwanCore
import SwanSpaces

public enum TestCARFixtureHelper {
    public static let authorDID = "did:plc:alice"
    public static let spaceRefString = "at://did:plc:alice/space/app.bsky.bookmarks/shared"
    public static let revision = "3l3vbfz2zsk22"
    public static let privateKeyRaw = Data(repeating: 1, count: 32)
    public static let secp256k1PrivateRaw = Data(repeating: 2, count: 32)

    public static func makeFixture(authorDID: String = authorDID) async throws -> (carData: Data, publicKey: P256.Signing.PublicKey, privateKey: P256.Signing.PrivateKey, spaceRef: SpaceRef) {
        let space = try SpaceURI(authority: "did:plc:alice", spaceType: "app.bsky.bookmarks", skey: "shared")
        let spaceRef = try SpaceRef(uriString: spaceRefString)
        let uri1 = try SpaceRecordURI(space: space, author: authorDID, collection: "app.bsky.feed.post", rkey: "one")
        let uri2 = try SpaceRecordURI(space: space, author: authorDID, collection: "app.bsky.feed.post", rkey: "two")
        let repository = try SpaceRepository(space: space, author: authorDID)
        let authorization = AuthorizationContext.accountOAuth(
            subject: authorDID,
            scopes: [
                "space:app.bsky.bookmarks?authority=did:plc:alice&skey=shared&action=create&collection=app.bsky.feed.post",
                "space:app.bsky.bookmarks?authority=did:plc:alice&skey=shared&action=read",
            ]
        )
        // Canonical DAG-CBOR for {"text": "hello"} and {"text": "world"}
        let recordCBOR1 = Data([0xa1, 0x64, 0x74, 0x65, 0x78, 0x74, 0x65, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
        let recordCBOR2 = Data([0xa1, 0x64, 0x74, 0x65, 0x78, 0x74, 0x65, 0x77, 0x6f, 0x72, 0x6c, 0x64])
        _ = try await repository.apply(.put(uri: uri1, value: recordCBOR1), authorization: authorization)
        _ = try await repository.apply(.put(uri: uri2, value: recordCBOR2), authorization: authorization)
        let state = await repository.currentState()
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        let context = try SpaceCommitContext(space: space, author: authorDID, rev: revision, ikm: Data(repeating: 7, count: 32))
        let commit = try SpaceCommitCodec.sign(context: context, commitment: state.commitment, key: key)
        let car = try await SpaceCARCodec.encode(commit: commit, records: repository.snapshot(authorization: authorization))
        return (carData: car.data, publicKey: key.publicKey, privateKey: key, spaceRef: spaceRef)
    }

    public static func makeSecp256k1Fixture(authorDID: String = authorDID) async throws -> (carData: Data, publicKeyBytes: Data, spaceRef: SpaceRef) {
        let space = try SpaceURI(authority: "did:plc:alice", spaceType: "app.bsky.bookmarks", skey: "shared")
        let spaceRef = try SpaceRef(uriString: spaceRefString)
        let uri1 = try SpaceRecordURI(space: space, author: authorDID, collection: "app.bsky.feed.post", rkey: "one")
        let uri2 = try SpaceRecordURI(space: space, author: authorDID, collection: "app.bsky.feed.post", rkey: "two")
        let repository = try SpaceRepository(space: space, author: authorDID)
        let authorization = AuthorizationContext.accountOAuth(
            subject: authorDID,
            scopes: [
                "space:app.bsky.bookmarks?authority=did:plc:alice&skey=shared&action=create&collection=app.bsky.feed.post",
                "space:app.bsky.bookmarks?authority=did:plc:alice&skey=shared&action=read",
            ]
        )
        let recordCBOR1 = Data([0xa1, 0x64, 0x74, 0x65, 0x78, 0x74, 0x65, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
        let recordCBOR2 = Data([0xa1, 0x64, 0x74, 0x65, 0x78, 0x74, 0x65, 0x77, 0x6f, 0x72, 0x6c, 0x64])
        _ = try await repository.apply(.put(uri: uri1, value: recordCBOR1), authorization: authorization)
        _ = try await repository.apply(.put(uri: uri2, value: recordCBOR2), authorization: authorization)
        let state = await repository.currentState()

        let readerEnvelope = try SpaceCommitCodec.createReaderEnvelope(
            space: space,
            author: authorDID,
            rev: revision,
            commitment: state.commitment,
            key: P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        )

        let secpKey = try secp256k1.Signing.PrivateKey(dataRepresentation: secp256k1PrivateRaw)
        let signingInput = try SpaceCommitCodec.contextSigningBytes(readerEnvelope.context)
        let signature = try secpKey.signature(for: signingInput).compactRepresentation

        let commit = SpaceCommitEnvelope(
            ver: 1,
            context: readerEnvelope.context,
            contextSignature: signature,
            contentBinding: readerEnvelope.contentBinding,
            commitment: state.commitment
        )

        let car = try await SpaceCARCodec.encode(commit: commit, records: repository.snapshot(authorization: authorization))
        let multicodecKey = Data([0xe7, 0x01]) + secpKey.publicKey.dataRepresentation
        return (carData: car.data, publicKeyBytes: multicodecKey, spaceRef: spaceRef)
    }
}
