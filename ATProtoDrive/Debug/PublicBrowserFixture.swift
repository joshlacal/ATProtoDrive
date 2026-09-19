#if DEBUG
import Foundation
import Petrel

public enum FixtureReadiness: Equatable, Sendable {
    case idle, loading, ready
    case failed(BrowserFailure)

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

public enum PublicBrowserFixture {
    public static let did = "did:plc:4hqjfn7m6n5hno3doamuhgef"
    public static let blobCIDs = [
        "bafkreia5it24rzqq7qa26p3asvp23gvbk5rfvckl65hnj4gj62aa3lomvy",
        "bafkreibm6jg3ux5qumhcn2n3a5e7xi66rcogxyqa4nnai4odzqgxap6nii",
        "bafkreidj7vpdsxgxpjtpptvjvyueqwwcsic6pikpnmq3pr3pkbrp3fex5m"
    ]
    public static let accounts: [SidebarAccountSummary] = []

    @MainActor
    public static func bootstrap(
        session: BrowserSession,
        repositoryStore: PublicRepositoryStore,
        recentRepositoryStore: RecentRepositoryStore,
        timeout: Duration = .seconds(2)
    ) async throws {
        let workTask = Task { @MainActor in
            await PublicRepositoryOpenCoordinator.open(
                .publicIdentifier("fixture.test"),
                store: repositoryStore,
                session: session,
                recents: recentRepositoryStore
            )
            try Task.checkCancellation()
            await PublicRepositoryOpenCoordinator.openCollection(
                "app.bsky.feed.post",
                store: repositoryStore,
                session: session
            )
            try Task.checkCancellation()
            guard let store = repositoryStore.recordStore(for: "app.bsky.feed.post"),
                  let first = store.rows.first,
                  let repository = repositoryStore.state.snapshot?.repository else {
                throw BrowserFailure.decodeFailure(endpoint: "fixture.bootstrap", statusCode: 200)
            }
            let item = PublicRecordItem(record: first, repository: repository)
            session.replaceSelection(with: [item.reference])
        }

        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            workTask.cancel()
            throw BrowserFailure.transport("Fixture readiness timed out")
        }

        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await timeoutTask.value
                    }
                    group.addTask {
                        try await workTask.value
                    }
                    _ = try await group.next()
                    group.cancelAll()
                    timeoutTask.cancel()
                    workTask.cancel()
                }
            } onCancel: {
                timeoutTask.cancel()
                workTask.cancel()
            }
        } catch is CancellationError {
            timeoutTask.cancel()
            workTask.cancel()
            throw CancellationError()
        } catch {
            timeoutTask.cancel()
            workTask.cancel()
            throw error
        }
    }
}

public actor FixturePublicRepositoryService: PublicRepositoryServing {
    public init() {}

    public func resolve(target: RepositoryTarget) async throws -> ResolvedRepository {
        .init(
            did: PublicBrowserFixture.did,
            handle: "fixture.test",
            pdsURL: URL(string: "https://fixture.invalid")!,
            connectedAccountDID: nil,
            handleIsCorrect: true
        )
    }

    public func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        .init(repository: repository, collections: ["app.bsky.feed.post", "com.example.drive.file"])
    }

    public func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        guard collection == "app.bsky.feed.post" else {
            return .init(records: [
                .fixtureValue(repository: repository, collection: collection, rkey: "unknown", type: "com.example.drive.file")
            ], cursor: nil)
        }
        switch cursor {
        case nil:
            return .init(records: [
                .fixtureValue(repository: repository, collection: collection, rkey: "first", type: collection),
                .fixtureValue(repository: repository, collection: collection, rkey: "second", type: collection)
            ], cursor: "fixture-page-2+/=")
        case "fixture-page-2+/=":
            return .init(records: [
                .fixtureValue(repository: repository, collection: collection, rkey: "third", type: collection)
            ], cursor: "fixture-terminal-empty")
        case "fixture-terminal-empty":
            return .init(records: [], cursor: nil)
        default:
            throw BrowserFailure.invalidIdentifier(cursor ?? "nil")
        }
    }

    public func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow {
        .fixtureValue(repository: repository, collection: collection, rkey: rkey, type: collection)
    }
}

private extension RecordRow {
    static func fixtureValue(
        repository: ResolvedRepository,
        collection: String,
        rkey: String,
        type: String
    ) -> Self {
        let cidByKey = [
            "first": "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a",
            "second": "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm",
            "third": "bafyreid7qjxf7f4pszgnjj6x7v7dcxpehbxvqfxvlazmnhp26g5qbgzxqe",
            "unknown": "bafyreiblkecirw3zwuqmm7hru77pgxzn2wexvi2kkqbpicrqrqhri7ne2u"
        ]
        let blobIndex = ["first": 0, "second": 1, "third": 0, "unknown": 2][rkey] ?? 0
        let mime = ["image/jpeg", "video/mp4", "application/pdf"][blobIndex]
        let size = [245760, 5242880, 98304][blobIndex]
        let blobCID = PublicBrowserFixture.blobCIDs[blobIndex]
        let blobJSON = "{\"$type\":\"blob\",\"ref\":{\"$link\":\"\(blobCID)\"},\"mimeType\":\"\(mime)\",\"size\":\(size)}"
        return .init(
            uri: "at://\(repository.did)/\(collection)/\(rkey)",
            collection: collection,
            rkey: rkey,
            cid: cidByKey[rkey] ?? "bafyreifxe4xz3d6bcj47ctgoq7tnifjzrcqsnfcqghzcte7pfssbhzuoee",
            json: "{\n  \"$type\": \"\(type)\",\n  \"name\": \"\(rkey.capitalized)\",\n  \"attachment\": \(blobJSON)\n}",
            blobEntries: [.init(cid: blobCID, mimeType: mime, size: size)],
            origin: .publicRepository(did: repository.did)
        )
    }
}

public actor FixturePublicBlobService: PublicBlobServing {
    public init() {}

    public func listBlobs(in repository: ResolvedRepository, cursor: String?, limit: Int) async throws -> BlobCIDPage {
        guard repository.did == PublicBrowserFixture.did,
              repository.pdsURL == URL(string: "https://fixture.invalid") else {
            throw BrowserFailure.unsupported("Only the fixture repository is available in demo mode.")
        }
        switch cursor {
        case nil:
            return .init(cids: Array(PublicBrowserFixture.blobCIDs.prefix(2)), cursor: "files-page-2+/=")
        case "files-page-2+/=":
            return .init(cids: Array(PublicBrowserFixture.blobCIDs.suffix(2)))
        default:
            throw BrowserFailure.invalidIdentifier(cursor ?? "")
        }
    }
}
#endif
