import Foundation
import Testing
@testable import ATProtoDrive

@Suite("Public Files navigation")
@MainActor
struct PublicFilesNavigationTests {
    @Test("live public file enumeration", .enabled(if: ProcessInfo.processInfo.environment["ATPROTODRIVE_LIVE_PUBLIC_SMOKE"] == "1"))
    func livePublicFiles() async throws {
        let service = PublicRepositoryService()
        let resolved = try await service.resolve(target: .publicIdentifier("bsky.app"))
        let description = try await service.describe(resolved)
        let page = try await PublicBlobService().listBlobs(in: description.repository, cursor: nil, limit: 5)
        #expect(!page.cids.isEmpty)
        #expect(page.cids.count <= 5)
        print("LIVE_PUBLIC_FILES did=\(resolved.did) pds=\(resolved.pdsURL) count=\(page.cids.count)")
    }

    @Test("files and records retain their destination in history and clear incompatible selection")
    func typedHistory() throws {
        let session = BrowserSession()
        let scope = RepositoryScope.publicRepository(did: PublicBrowserFixture.did, pdsURL: URL(string: "https://fixture.invalid")!)
        let records = BrowserPath(source: .account(did: PublicBrowserFixture.did, destination: .publicRecords), components: [.repository(scope)])
        let files = BrowserPath(source: .account(did: PublicBrowserFixture.did, destination: .publicBlobs), components: [.repository(scope)], repositoryDestination: .files)
        session.navigate(to: records)
        session.navigate(to: files)
        session.replaceSelection(with: [.blob(.init(scope: scope, cid: PublicBrowserFixture.blobCIDs[0]))])
        session.searchQuery = .init(text: "image")
        session.goBack()
        #expect(session.path == records)
        #expect(session.selectedSource == records.source)
        #expect(session.selectedReferences.isEmpty)
        #expect(session.searchQuery.text.isEmpty)
        session.goForward()
        #expect(session.path == files)
        #expect(session.selectedSource == files.source)
        #expect(try JSONDecoder().decode(BrowserPath.self, from: JSONEncoder().encode(files)) == files)
    }

    @Test("anonymous files paginate, scan references and return to records without account state")
    func fixtureFiles() async throws {
        let repositoryStore = PublicRepositoryStore(service: FixturePublicRepositoryService(), blobService: FixturePublicBlobService())
        let session = BrowserSession()
        let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
        await PublicRepositoryOpenCoordinator.open(.publicIdentifier("fixture.test"), store: repositoryStore, session: session, recents: recents)
        let repository = try #require(repositoryStore.state.snapshot?.repository)
        let source = try #require(session.selectedSource)
        session.navigate(to: .init(source: source, components: [.repository(repository.scope)], repositoryDestination: .files))
        let files = try #require(repositoryStore.blobStore())
        await files.reload()
        #expect(files.snapshot.blobs.count == 2)
        #expect(!files.snapshot.referenceScanComplete)
        await files.loadMore()
        #expect(files.snapshot.blobs.count == 3)
        await files.scanReferences()
        #expect(files.snapshot.isComplete)
        let jpeg = try #require(files.snapshot.blobs.first { $0.locator.cid == PublicBrowserFixture.blobCIDs[0] })
        #expect(jpeg.mimeType == "image/jpeg")
        #expect(jpeg.referenceCount == 2)
        #expect(jpeg.availability == .unknown)
        #expect(jpeg.verification == .notVerified)
        let reference = try #require(files.references(to: jpeg.locator).first)
        #expect(reference.jsonPointer == "/attachment")
        await PublicRepositoryOpenCoordinator.openCollection(reference.record.collection, store: repositoryStore, session: session)
        #expect(session.path?.repositoryDestination == .records)
        #expect(session.path?.components.last == .collection(scope: repository.scope, collection: reference.record.collection))
        session.goBack()
        #expect(session.path?.repositoryDestination == .files)
        #expect(repositoryStore.blobStore() === files)
    }
}
