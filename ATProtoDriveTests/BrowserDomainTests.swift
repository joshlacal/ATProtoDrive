import Foundation
import Testing
@testable import ATProtoDrive

@Suite("Browser domain")
struct BrowserDomainTests {
    @Test("public and permissioned resources cannot share an unqualified identity")
    func qualifiedResourceIdentity() {
        let did = "did:plc:4hqjfn7m6n5hno3doamuhgef"
        let publicScope = RepositoryScope.publicRepository(
            did: did,
            pdsURL: URL(string: "https://pds.example")!
        )
        let spaceScope = RepositoryScope.permissionedSpace(
            spaceURI: "at://did:plc:z72i7hdynmk6r22z27h6tvur/space/place.swan.drive/main",
            writerDID: did,
            accountDID: did
        )
        let cid = "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"
        #expect(BlobLocator(scope: publicScope, cid: cid).stableID !=
                BlobLocator(scope: spaceScope, cid: cid).stableID)
        #expect(publicScope.accessClassification == .publicRepository(did: did))
    }

    @MainActor
    @Test("browser sessions isolate windows")
    func windowIsolation() {
        let first = BrowserSession()
        let second = BrowserSession()
        let did = "did:plc:4hqjfn7m6n5hno3doamuhgef"
        let pdsURL = URL(string: "https://alice.example")!
        let scope = RepositoryScope.publicRepository(
            did: did,
            pdsURL: pdsURL
        )
        let locator = RecordLocator(
            scope: scope,
            uri: "at://\(did)/app.test.item/first",
            collection: "app.test.item",
            rkey: "first",
            cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
        )
        let source = BrowserSource.openedPublicRepository(did: did)
        first.selectSource(source)
        first.navigate(to: BrowserPath(source: source, components: [.repository(scope)]))
        first.replaceSelection(with: [.record(locator)])
        #expect(second.selectedSource == nil)
        #expect(second.selectedItemIDs.isEmpty)
        #expect(first.primarySelection == .record(locator))
    }

    @Test("failed load retains its previous snapshot")
    func staleSnapshot() {
        let state = LoadState<[String]>.failed(
            previous: ["visible"],
            failure: .offline
        )
        #expect(state.snapshot == ["visible"])
        #expect(state.isStale)
    }

    @Test("error normalization owns offline mapping and redacts source detail")
    func normalizedFailureIsSafe() {
        #expect(BrowserFailure.normalize(URLError(.notConnectedToInternet)) == .offline)
        let source = NSError(
            domain: "fixture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "https://pds.example/x?token=secret record body"]
        )
        guard case .transport(let summary) = BrowserFailure.normalize(source) else {
            Issue.record("Expected a redacted transport failure")
            return
        }
        #expect(!summary.contains("token"))
        #expect(!summary.contains("record body"))
    }

    @MainActor
    @Test("multi-element selection resolves primarySelection deterministically via lexicographically smallest ID")
    func deterministicPrimarySelection() {
        let session = BrowserSession()
        let did = "did:plc:4hqjfn7m6n5hno3doamuhgef"
        let scope = RepositoryScope.publicRepository(
            did: did,
            pdsURL: URL(string: "https://alice.example")!
        )
        let locatorA = RecordLocator(
            scope: scope,
            uri: "at://\(did)/app.test.item/a",
            collection: "app.test.item",
            rkey: "a",
            cid: "bafyreia"
        )
        let locatorB = RecordLocator(
            scope: scope,
            uri: "at://\(did)/app.test.item/b",
            collection: "app.test.item",
            rkey: "b",
            cid: "bafyreib"
        )
        let locatorZ = RecordLocator(
            scope: scope,
            uri: "at://\(did)/app.test.item/z",
            collection: "app.test.item",
            rkey: "z",
            cid: "bafyreiz"
        )

        let refA = ResourceReference.record(locatorA)
        let refB = ResourceReference.record(locatorB)
        let refZ = ResourceReference.record(locatorZ)

        session.replaceSelection(with: [refZ, refB, refA])

        let expectedID = [refA.stableID, refB.stableID, refZ.stableID].min()!
        #expect(session.primarySelectionID == expectedID)
        #expect(session.primarySelection == refA)
        #expect(session.primarySelection?.stableID == expectedID)
    }

    @MainActor
    @Test("rememberOpenedRepository deduplicates by summary ID only across different source accounts")
    func rememberOpenedRepositorySourceAccountIsolation() {
        let session = BrowserSession()
        let did = "did:plc:4hqjfn7m6n5hno3doamuhgef"
        let pdsURL = URL(string: "https://alice.example")!

        let anonymousSummary = OpenedRepositorySummary(
            did: did,
            pdsURL: pdsURL,
            sourceAccountDID: nil
        )
        let accountSummary = OpenedRepositorySummary(
            did: did,
            pdsURL: pdsURL,
            sourceAccountDID: "did:plc:viewer123"
        )

        session.rememberOpenedRepository(anonymousSummary)
        session.rememberOpenedRepository(accountSummary)

        #expect(session.openedPublicRepositories.count == 2)
        #expect(session.openedPublicRepositories[0].id == accountSummary.id)
        #expect(session.openedPublicRepositories[1].id == anonymousSummary.id)

        session.rememberOpenedRepository(anonymousSummary)
        #expect(session.openedPublicRepositories.count == 2)
        #expect(session.openedPublicRepositories[0].id == anonymousSummary.id)
        #expect(session.openedPublicRepositories[1].id == accountSummary.id)
    }
}
