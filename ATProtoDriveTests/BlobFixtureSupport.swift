import Foundation
import Petrel
import PetrelCore
@testable import ATProtoDrive

public enum FixtureError: Error, Sendable, Equatable {
    case exhausted
    case scripted(String)
}

public enum ScriptedResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(FixtureError)
}

public actor OrderedScript<Input: Sendable, Output: Sendable> {
    private var results: [ScriptedResult<Output>]
    public private(set) var inputs: [Input] = []

    public init(_ results: [ScriptedResult<Output>]) {
        self.results = results
    }

    public func next(_ input: Input) throws -> Output {
        inputs.append(input)
        guard !results.isEmpty else { throw FixtureError.exhausted }
        switch results.removeFirst() {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

public enum FixtureRoot {
    public static func make(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

public struct ThrowingATProtocolValue: ATProtocolValue {
    public static var typeIdentifier: String { "test.failing" }

    public init() {}

    public func isEqual(to other: any ATProtocolValue) -> Bool {
        false
    }

    public init(from decoder: Decoder) throws {}

    public func encode(to encoder: Encoder) throws {
        throw FixtureError.scripted("Forced encode failure")
    }

    public func toCBORValue() throws -> Any {
        throw FixtureError.scripted("Forced cbor failure")
    }

    public func encodedDAGCBOR() throws -> Data {
        throw FixtureError.scripted("Forced cbor failure")
    }

    public static func decodedFromDAGCBOR(_ data: Data) throws -> ThrowingATProtocolValue {
        ThrowingATProtocolValue()
    }
}

extension RepositoryScope {
    public static func fixturePublic(
        did: String = "did:plc:alice",
        pdsURL: URL = URL(string: "https://alice.example")!
    ) -> RepositoryScope {
        .publicRepository(did: did, pdsURL: pdsURL)
    }

    public static func fixtureSpace(
        spaceURI: String = "at://did:plc:owner/space/app.example.drive/shared",
        writerDID: String = "did:plc:alice",
        accountDID: String = "did:plc:alice"
    ) -> RepositoryScope {
        .permissionedSpace(spaceURI: spaceURI, writerDID: writerDID, accountDID: accountDID)
    }
}

extension RecordLocator {
    public static func fixturePublic(
        did: String = "did:plc:alice",
        pdsURL: URL = URL(string: "https://alice.example")!,
        uri: String = "at://did:plc:alice/app.example.file/one",
        collection: String = "app.example.file",
        rkey: String = "one",
        cid: String = "bafyreipublic"
    ) -> RecordLocator {
        RecordLocator(
            scope: .fixturePublic(did: did, pdsURL: pdsURL),
            uri: uri,
            collection: collection,
            rkey: rkey,
            cid: cid
        )
    }

    public static func fixtureSpace(
        spaceURI: String = "at://did:plc:owner/space/app.example.drive/shared",
        writerDID: String = "did:plc:alice",
        accountDID: String = "did:plc:alice",
        rkey: String = "one",
        recordCID: String = "bafyreispace"
    ) -> RecordLocator {
        RecordLocator(
            scope: .fixtureSpace(spaceURI: spaceURI, writerDID: writerDID, accountDID: accountDID),
            uri: "\(spaceURI)/\(writerDID)/app.example.file/\(rkey)",
            collection: "app.example.file",
            rkey: rkey,
            cid: recordCID
        )
    }
}

extension BlobLocator {
    public static func fixturePublic(
        did: String = "did:plc:alice",
        pdsURL: URL = URL(string: "https://alice.example")!,
        cid: String = "bafkreigh2akiscaildcq"
    ) -> BlobLocator {
        BlobLocator(scope: .fixturePublic(did: did, pdsURL: pdsURL), cid: cid)
    }

    public static func fixtureSpace(
        spaceURI: String = "at://did:plc:owner/space/app.example.drive/shared",
        writerDID: String = "did:plc:alice",
        accountDID: String = "did:plc:alice",
        cid: String = "bafkreigh2akiscaildcq"
    ) -> BlobLocator {
        BlobLocator(scope: .fixtureSpace(spaceURI: spaceURI, writerDID: writerDID, accountDID: accountDID), cid: cid)
    }

    public static func fixtureOtherSpace(
        cid: String = "bafkreiotherspace"
    ) -> BlobLocator {
        BlobLocator(
            scope: .permissionedSpace(
                spaceURI: "at://did:plc:owner/space/app.example.drive/other",
                writerDID: "did:plc:alice",
                accountDID: "did:plc:alice"
            ),
            cid: cid
        )
    }

    public static func fixtureForeignSpace(
        cid: String = "bafkreiforeignspace"
    ) -> BlobLocator {
        BlobLocator(
            scope: .permissionedSpace(
                spaceURI: "at://did:plc:foreign/space/app.example.drive/foreign",
                writerDID: "did:plc:stranger",
                accountDID: "did:plc:foreign"
            ),
            cid: cid
        )
    }
}
