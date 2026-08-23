# ATProtoDrive v1 Public Browser Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Space-first window with a native, Finder-like browser that can resolve and browse every collection in any public ATProto repository without an account.

**Architecture:** Public repository discovery and reads go through a narrow `PublicRepositoryServing` boundary whose live implementation creates only unauthenticated Petrel clients pointed at the resolved target PDS. Window-local `BrowserSession` state drives a two-column `NavigationSplitView`, while feature stores preserve typed snapshots across loading and failure states. This plan keeps the existing Space implementation reachable through a compatibility route; the linked Spaces plan replaces that route without changing the public data plane.

**Tech Stack:** Swift 6, SwiftUI and Observation on macOS 15, Swift Testing, Petrel's generated `com.atproto.identity.resolveHandle` and `com.atproto.repo.*` clients, standards-compliant DID document resolution, Xcode 16 project files, and jj.

**Spec:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`

## Global Constraints

- Public reads always use a newly constructed unauthenticated `ATProtoClient(baseURL:)` aimed at the resolved target PDS. Never pass an `AccountStore.Account.client`, OAuth client, token, DPoP proof, or Space credential into `PublicRepositoryService`.
- Treat a generated Petrel call as successful only when its status is `200 ... 299` **and** its decoded output is non-nil. A 2xx response with nil output is a typed decode failure, never an empty repository.
- `BrowserSession` is created inside each `WindowGroup`; it stores stable identifiers and navigation state, not clients, credentials, or remote model objects.
- The root layout is exactly a two-column `NavigationSplitView` plus an optional trailing `.inspector`; do not reintroduce the current third navigation column or nested `HSplitView`.
- Every repository-qualified key includes `RepositoryScope.publicRepository(did:pdsURL:)` or `RepositoryScope.permissionedSpace(spaceURI:writerDID:accountDID:)`; never key by DID, CID, or an `isPrivate` Boolean alone.
- Unknown collections and record fields remain browseable. A value-supplied timestamp is labeled by its JSON field name and is not described as repository modification time.
- Failed refreshes retain the last successful snapshot and display an inline stale/error banner. Empty, loading, stale, failed, and unsupported are distinct states.
- Pagination uses opaque cursors unchanged, keeps request parameters stable, accepts empty pages with a next cursor, terminates repeated cursor cycles, and deduplicates records by `(URI, CID)`.
- DID resolution is independent of account handles: `did:plc` and hostname-level `did:web` identifiers resolve through `DIDDocumentPDSResolving`; path-form `did:web` is invalid in AT Protocol. The document ID must match exactly and `#atproto_pds` must be an origin-only HTTPS endpoint. Exact `localhost` HTTP/encoded-port exceptions are disabled by default and may be enabled only by explicit test/development injection. This resolver never selects `#atproto_space_host`.
- The Xcode project uses manual PBX groups. Task 1's named integration owner is the sole editor of `ATProtoDrive.xcodeproj/project.pbxproj`, `ATProtoDrive/ATProtoDriveApp.swift`, and the root `ATProtoDrive/Browser/ContentBrowserView.swift`; feature workers hand exact changes for those files to that owner.
- Use TDD: add a focused failing test, observe the specified failure, make the minimum implementation pass, then run the task's broader regression command.
- Use jj as the only VCS writer. Every task ends with the concrete `jj status`, `jj diff --summary`, task-specific `jj describe -m` command printed in that task, and then immediately `jj new` before any status report.
- This plan does not add public mutation, Space redesign, blob inventory, backups, transfers, private-state providers, or account controls. It only defines their typed navigation and resource seams.

## File Map and Ownership

Task 1's integration owner creates the groups, file references, target membership, and initially compilable imports for every new file below. The same owner alone resolves any later PBX membership mistake and integrates changes to the app entry point and root content router.

| File | Responsibility |
|---|---|
| `ATProtoDrive/Domain/AccessClassification.swift` | Typed public, permissioned, private-state, and backup access classifications. |
| `ATProtoDrive/Domain/ResourceReference.swift` | Plan 1 owner of canonical qualified repository, record, and blob locators; Plan 2 may add Space cases only through the handoff contract below. |
| `ATProtoDrive/Browser/BrowserModels.swift` | Stable sources, destinations, paths, presentation items, and sort descriptors. |
| `ATProtoDrive/Browser/BrowserSession.swift` | Plan 1 owner of window-local navigation, selection, search, history, and inspector state; Plan 2 becomes the follow-on editor only after this plan seals. |
| `ATProtoDrive/Browser/RecentRepositoryStore.swift` | App-scoped, versioned, atomically persisted public-repository recents with an in-memory fixture mode. |
| `ATProtoDrive/Browser/SearchQuery.swift` | Text/token search representation and deterministic record matching. |
| `ATProtoDrive/Browser/MainWindowView.swift` | Two-column root split view, inspector, toolbar, and sheets. |
| `ATProtoDrive/Browser/DriveSidebarView.swift` | Native source list and pure sidebar projection. |
| `ATProtoDrive/Browser/ContentBrowserView.swift` | Typed routing from selected source/path into feature content. |
| `ATProtoDrive/Browser/BrowserCommands.swift` | Focused-window Back, Forward, Refresh, inspector, and search commands. |
| `ATProtoDrive/Browser/BrowserTableShell.swift` | Breadcrumb, load-state, stale-banner, retry, and load-more chrome. |
| `ATProtoDrive/Browser/BrowserInspectorView.swift` | Friendly record summary followed by exact protocol details and raw JSON. |
| `ATProtoDrive/Browser/OpenPublicRepositorySheet.swift` | Handle/DID entry, validation, progress, and visible errors. |
| `ATProtoDrive/Support/LoadState.swift` | Snapshot-preserving generic remote state. |
| `ATProtoDrive/Support/BrowserFailure.swift` | Typed, user-presentable browser failures and normalization. |
| `ATProtoDrive/Resolution/DIDDocumentPDSResolver.swift` | Generic, injectable `did:plc`/hostname-level `did:web` document resolution for the exact `#atproto_pds` service. |
| `ATProtoDrive/PublicRepo/PublicRepositoryTypes.swift` | `RepositoryTarget`, resolved description, record page, and service protocol. |
| `ATProtoDrive/PublicRepo/PublicRepositoryService.swift` | Anonymous DID/PDS resolution and public XRPC mapping. |
| `ATProtoDrive/PublicRepo/PublicRepositoryStore.swift` | Open/refresh lifecycle for one resolved repository. |
| `ATProtoDrive/PublicRepo/PublicRecordStore.swift` | Collection paging, dedupe, cursor-cycle protection, and stale snapshots. |
| `ATProtoDrive/PublicRepo/PublicRepositoryView.swift` | Collection table and repository header. |
| `ATProtoDrive/PublicRepo/PublicRecordTable.swift` | Sortable/searchable public record table and accessible pagination. |
| `ATProtoDrive/Debug/PublicBrowserFixture.swift` | Deterministic no-account public-browser launch data under `#if DEBUG`. |
| `ATProtoDrive/ATProtoDriveApp.swift` | App-scoped accounts, per-window session construction, callback preservation, and debug fixture selection. |
| `ATProtoDrive/Records/RecordListModel.swift` | Adds canonical `RecordOrigin` to the existing `RecordRow` without changing Space reads. |
| `ATProtoDriveTests/BrowserDomainTests.swift` | Access, qualification, load-state, and session isolation tests. |
| `ATProtoDriveTests/DIDDocumentPDSResolverTests.swift` | ATProto DID URL restrictions, document identity, optional handle, origin-only PDS, and localhost-policy tests. |
| `ATProtoDriveTests/PublicRepositoryServiceTests.swift` | Resolution, target-PDS, anonymous-client, status, decode, and mapping tests. |
| `ATProtoDriveTests/PublicRepositoryServiceTestDouble.swift` | Shared concrete public service, repository, page, and record fixtures. |
| `ATProtoDriveTests/PublicRecordStoreTests.swift` | First-page, append, empty page, dedupe, cycle, and stale refresh tests. |
| `ATProtoDriveTests/DriveSidebarTests.swift` | No-account utilities, account destinations, and stable row identity. |
| `ATProtoDriveTests/RecentRepositoryStoreTests.swift` | Atomic versioned recents, dedupe, account qualification, cap, and in-memory isolation. |
| `ATProtoDriveTests/PublicBrowserPresentationTests.swift` | Search, sorting, breadcrumbs, inspector projection, and selection retention. |
| `ATProtoDriveTests/PublicBrowserFixtureTests.swift` | Deterministic fixture routing and complete collection traversal. |

## Shared Interfaces Produced by This Plan

Later plans may consume these exact names and signatures; they must extend cases without renaming them.

```swift
public indirect enum AccessClassification: Hashable, Codable, Sendable {
    case publicRepository(did: String)
    case permissionedSpace(spaceURI: String, writerDID: String)
    case privateAppState(provider: String, accountDID: String)
    case localBackup(backupID: UUID, original: AccessClassification)
}

public enum RepositoryScope: Hashable, Codable, Sendable {
    case publicRepository(did: String, pdsURL: URL)
    case permissionedSpace(
        spaceURI: String,
        writerDID: String,
        accountDID: String
    )
}

public struct RecordLocator: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let uri: String
    public let collection: String
    public let rkey: String
    public let cid: String
}

public struct BlobLocator: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let cid: String
}

public enum ResourceReference: Hashable, Sendable, Codable, Identifiable {
    case repository(RepositoryScope)
    case collection(scope: RepositoryScope, collection: String)
    case record(RecordLocator)
    case blob(BlobLocator)

    public var id: String { stableID }
    public var stableID: String {
        switch self {
        case .repository(let scope): "\(scope.stableID)|repository"
        case .collection(let scope, let collection): "\(scope.stableID)|collection|\(collection)"
        case .record(let locator): "\(locator.scope.stableID)|record|\(locator.uri)|\(locator.cid)"
        case .blob(let locator): locator.stableID
        }
    }
}

public enum AccountDestination: String, CaseIterable, Hashable, Sendable, Codable {
    case overview, publicRecords, publicBlobs, spaces
    case privateAppState, backups, activity, serverAndAccount
}

public enum GlobalDestination: String, Hashable, Sendable, Codable {
    case openPublicRepository, openSpace, addAccount
}

public enum BrowserSource: Hashable, Sendable, Codable {
    case account(did: String, destination: AccountDestination)
    case openedPublicRepository(did: String)
    case global(GlobalDestination)
}

public struct OpenedRepositorySummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String {
        "\(did)|source|\(sourceAccountDID ?? "anonymous")"
    }
    public let did: String
    public let handle: String?
    public let pdsURL: URL
    public let sourceAccountDID: String?
    public let lastOpenedAt: Date
}

public struct BrowserPath: Hashable, Sendable, Codable {
    public let source: BrowserSource
    public var components: [ResourceReference]
}

public struct BrowserItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case repository, collection, record, blob, utility }
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let kind: Kind
    public let reference: ResourceReference?
    public let accessClassification: AccessClassification?
}

public struct BrowserSort: Hashable, Sendable, Codable {
    public var field: String
    public var ascending: Bool
    public init(field: String = "title", ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}

public enum SearchToken: Hashable, Sendable {
    case source(String), account(String), space(String), owner(String)
    case collection(String), kind(String), mimeType(String), transferState(String)
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var tokens: [SearchToken]
    public init(text: String = "", tokens: [SearchToken] = []) {
        self.text = text
        self.tokens = tokens
    }
}

public enum RepositoryTarget: Hashable, Sendable {
    case connectedAccount(did: String)
    case publicIdentifier(String)
}

public protocol PublicRepositoryServing: Sendable {
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription
    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage
    func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow
}
```

The DID-to-PDS seam is generic because Plan 2 also consumes it for writer PDS routing. It resolves only the `#atproto_pds` service; Space authority-host routing remains a separate Plan 2 concern.

```swift
public struct ResolvedPDSIdentity: Hashable, Sendable {
    public let did: String
    public let pdsURL: URL
    public let declaredHandle: String?
}

public typealias DIDDocumentFetch = @Sendable (URL) async throws -> (
    statusCode: Int,
    data: Data?
)

public protocol DIDDocumentPDSResolving: Sendable {
    func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity
    func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity
}

public actor DIDDocumentPDSResolver: DIDDocumentPDSResolving {
    public static let liveFetch: DIDDocumentFetch
    public init(
        fetchDocument: @escaping DIDDocumentFetch = DIDDocumentPDSResolver.liveFetch,
        allowLocalhostDevelopment: Bool = false
    )
    public func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity
    public func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity
}
```

Test targets share these concrete fixtures from `ATProtoDriveTests/PublicRepositoryServiceTestDouble.swift`:

```swift
extension ResolvedRepository {
    static let fixture = ResolvedRepository(
        did: "did:plc:4hqjfn7m6n5hno3doamuhgef",
        handle: "alice.test",
        pdsURL: URL(string: "https://alice.example")!,
        connectedAccountDID: nil,
        handleIsCorrect: true
    )

    static let secondFixture = ResolvedRepository(
        did: "did:web:second.example",
        handle: nil,
        pdsURL: URL(string: "https://second.example")!,
        connectedAccountDID: nil,
        handleIsCorrect: nil
    )
}

extension RepositoryDescription {
    static func fixture(collections: [String]) -> Self {
        .init(repository: .fixture, collections: collections)
    }
}

extension RecordRow {
    static func fixture(
        uri: String,
        collection: String = "app.test.item",
        rkey: String = "one",
        cid: String = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a",
        json: String = #"{"$type":"app.test.item","name":"Fixture"}"#
    ) -> Self {
        .init(
            uri: uri,
            collection: collection,
            rkey: rkey,
            cid: cid,
            json: json,
            origin: .publicRepository(did: ResolvedRepository.fixture.did)
        )
    }
}

actor ScriptedPublicRepositoryService: PublicRepositoryServing {
    private var pages: [String: RepositoryRecordPage]
    private var firstPage: RepositoryRecordPage?
    private var failure: BrowserFailure?
    private var failuresByCursor: [String: BrowserFailure] = [:]
    private(set) var requestedCursors: [String?] = []

    init(pages: [String?: RepositoryRecordPage]) {
        firstPage = pages[nil]
        self.pages = Dictionary(uniqueKeysWithValues: pages.compactMap { entry in
            entry.key.map { ($0, entry.value) }
        })
    }

    static func successfulFixture() -> ScriptedPublicRepositoryService {
        .init(pages: [nil: .init(records: [], cursor: nil)])
    }

    func fail(with failure: BrowserFailure) { self.failure = failure }
    func failNextPage(cursor: String, with failure: BrowserFailure) {
        failuresByCursor[cursor] = failure
    }
    func resolve(target: RepositoryTarget) async throws -> ResolvedRepository { .fixture }
    func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        .fixture(collections: ["app.bsky.feed.post", "com.example.unknown"])
    }
    func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        if let failure { throw failure }
        requestedCursors.append(cursor)
        if let cursor, let failure = failuresByCursor.removeValue(forKey: cursor) {
            throw failure
        }
        if let cursor { return pages[cursor] ?? .init(records: [], cursor: nil) }
        return firstPage ?? .init(records: [], cursor: nil)
    }
    func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow { throw BrowserFailure.notFound(resource: rkey) }
}
```

`SpaceRepositoryService`, `SpaceAdministrationService`, `MutationCoordinator`, `LoginIntent`, `AccessContext`, `AccountConnectionStatus`, `AuthenticationIssue`, `TransferQueue`, and `TransferStore` are reserved for later plans and are not declared here.

## Verification Command Convention

Every test command below is complete and runs from the repository root in a fresh shell. Do not change its project, scheme, destination, or signing flags.

### Task 1: Establish qualified domain state and the single PBX integration gate

**Files:**
- Create: `ATProtoDrive/Domain/AccessClassification.swift`
- Create: `ATProtoDrive/Domain/ResourceReference.swift`
- Create: `ATProtoDrive/Browser/BrowserModels.swift`
- Create: `ATProtoDrive/Browser/BrowserSession.swift`
- Create: `ATProtoDrive/Browser/SearchQuery.swift`
- Create: `ATProtoDrive/Support/LoadState.swift`
- Create: `ATProtoDrive/Support/BrowserFailure.swift`
- Create: `ATProtoDriveTests/PublicRepositoryServiceTestDouble.swift`
- Create initially compilable imports for every remaining new source and test file in the File Map
- Modify: `ATProtoDrive/Records/RecordListModel.swift`
- Modify, sole owner for this entire plan: `ATProtoDrive.xcodeproj/project.pbxproj`
- Test: `ATProtoDriveTests/BrowserDomainTests.swift`

**Interfaces:**
- Consumes: existing `SpaceRef`, `RecordRow`, and macOS 15 Observation support.
- Produces: `AccessClassification`, `RepositoryScope`, `RecordLocator`, `BlobLocator`, `ResourceReference`, `BrowserSource`, `OpenedRepositorySummary`, `BrowserPath`, `BrowserItem`, `BrowserSort`, `BrowserSession`, `SearchQuery`, `LoadState<Value>`, `BrowserFailure`, and `RecordOrigin`.

- [ ] **Step 1: Add the failing qualification and window-isolation tests**

```swift
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
}
```

- [ ] **Step 2: Have the PBX integration owner create every group/reference/membership once, then run the focused test and observe failure**

Add `Domain`, `Browser`, `Support`, `Resolution`, `PublicRepo`, and `Debug` PBX groups beneath `ATProtoDrive`; add every source file in the File Map to the app Sources phase and every test file to the existing `ATProtoDriveTests` Sources phase. Do not add a second test target. Before editing, inventory the existing `PBXFileReference`, `PBXBuildFile`, group, and Sources-phase entries; add only the missing entries and do not perform unrelated PBX cleanup.

Run:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-browser.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/BrowserDomainTests
```

Expected: FAIL because `RepositoryScope`, `BrowserSession`, and `LoadState` are not defined. If Xcode instead reports a missing or duplicate file membership, compare each new file's reference, build-file, group, and Sources-phase entry and correct only that new-file wiring; keep this worker as the sole PBX owner.

- [ ] **Step 3: Implement the qualified types and snapshot-preserving state**

Use the shared signatures above and these exact behavioral cores:

```swift
public extension RepositoryScope {
    var accessClassification: AccessClassification {
        switch self {
        case .publicRepository(let did, _):
            return .publicRepository(did: did)
        case .permissionedSpace(let spaceURI, let writerDID, _):
            return .permissionedSpace(spaceURI: spaceURI, writerDID: writerDID)
        }
    }

    var stableID: String {
        switch self {
        case .publicRepository(let did, let pdsURL):
            return "public|\(did)|\(pdsURL.absoluteString)"
        case .permissionedSpace(let spaceURI, let writerDID, let accountDID):
            return "space|\(accountDID)|\(spaceURI)|\(writerDID)"
        }
    }
}

public extension BlobLocator {
    var stableID: String { "\(scope.stableID)|blob|\(cid)" }
}

public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(previous: Value?, failure: BrowserFailure)

    public var snapshot: Value? {
        switch self {
        case .idle: nil
        case .loading(let previous), .failed(let previous, _): previous
        case .loaded(let value): value
        }
    }

    public var isStale: Bool {
        if case .failed(previous: .some, failure: _) = self { return true }
        return false
    }
}
```

Define `BrowserFailure: Error, LocalizedError, Equatable, Sendable` in `ATProtoDrive/Support/BrowserFailure.swift` with cases `offline`, `rateLimited(retryAfter: Date?)`, `authorizationRefused`, `notFound(resource: String)`, `http(endpoint: String, statusCode: Int)`, `decodeFailure(endpoint: String, statusCode: Int)`, `invalidIdentifier(String)`, `identityMismatch(expected: String, actual: String)`, `invalidDIDDocument(String)`, `unsupported(String)`, and `transport(String)`, each with a concrete, redacted `errorDescription`. This file is the sole owner of error normalization for all four plans:

```swift
public extension BrowserFailure {
    static func normalize(_ error: any Error) -> BrowserFailure {
        if let failure = error as? BrowserFailure { return failure }
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost].contains(urlError.code) {
            return .offline
        }
        return .transport(String(describing: type(of: error)))
    }
}
```

Callers must detect `CancellationError` before normalization and leave the currently active request's state untouched. Unit tests assert that normalization never embeds a URL containing query parameters, an OAuth value, a record body, or the original error's unredacted description.

Define `BrowserSource` as `.account(did: String, destination: AccountDestination)`, `.openedPublicRepository(did: String)`, and `.global(GlobalDestination)`. `AccountDestination` has exactly `overview`, `publicRecords`, `publicBlobs`, `spaces`, `privateAppState`, `backups`, `activity`, and `serverAndAccount`; `GlobalDestination` has exactly `openPublicRepository`, `openSpace`, and `addAccount`.

Implement `BrowserSession` as `@MainActor @Observable` with `selectedSource: BrowserSource?`, `path: BrowserPath?`, `selectedItemIDs: Set<String>`, private(set) `selectedReferences: [String: ResourceReference]`, `history: [BrowserPath]`, private(set) `historyIndex: Int?`, `openedPublicRepositories: [OpenedRepositorySummary]`, `isInspectorPresented`, `columnVisibility: NavigationSplitViewVisibility`, `sort`, and `searchQuery`. Raw row IDs are never accepted as selection input. Declare `@discardableResult public func replaceSelection(with references: Set<ResourceReference>) -> Bool`; it derives every ID from `ResourceReference.stableID` and replaces the ID-to-reference map atomically. If any reference is outside the current path's complete `RepositoryScope`, it returns `false` and leaves both prior collections unchanged. `primarySelectionID` is the lexicographically first selected ID and `primarySelection` looks that ID up in `selectedReferences`, so the inspector is deterministic and fully qualified.

`navigate(to:)` appends a new path after truncating any forward entries; `goBack()` and `goForward()` change `path` through `historyIndex` without appending duplicate history. `canGoBack` and `canGoForward` are derived from the index. `selectSource` clears path, history, item IDs, and references only when the source changes; it never mutates another session. `rememberOpenedRepository(_ summary: OpenedRepositorySummary)` deduplicates by summary ID, moves it to the front, and caps the window-local opened list at 10 entries. Durable recents belong to Task 4's separate app-scoped `RecentRepositoryStore`, never to `BrowserSession`.

Add the exact source-qualified origin below, then add `public let origin: RecordOrigin` and `origin: RecordOrigin = .unknown` to `RecordRow.init` so every existing Space call site remains source-compatible:

```swift
public enum RecordOrigin: Hashable, Sendable {
    case unknown
    case publicRepository(did: String)
    case space(space: SpaceRef, repoDID: String)
}
```

- [ ] **Step 4: Run domain tests and the safe pre-existing record-model tests**

Run the focused suite:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-browser-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/BrowserDomainTests
```

Then run only the existing record-model suite, which does not write account or Space production preferences:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-browser-regression.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/RecordListModelTests
```

Expected: PASS; existing `RecordRow` construction continues to compile because origin defaults to `.unknown`. Do not run `AccountStoreTests`, `SpaceListModelTests`, `SpaceDetailModelTests`, or `WritePipelineTests` in this plan: their baseline implementations touch production `UserDefaults.standard` keys. Plan 2 Task 1 isolates Space persistence and Plan 2 Task 4 isolates account preferences/live OAuth; only after both tasks seal may later plans restore those suites to an aggregate gate.

- [ ] **Step 5: Seal the task with jj**

```bash
jj status
jj diff --summary
jj describe -m "feat: add qualified browser domain state"
jj new
```

### Task 2: Implement robust DID-to-PDS resolution and anonymous public XRPC reads

**Files:**
- Modify: `ATProtoDrive/Resolution/DIDDocumentPDSResolver.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRepositoryTypes.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRepositoryService.swift`
- Modify: `ATProtoDriveTests/DIDDocumentPDSResolverTests.swift`
- Modify: `ATProtoDriveTests/PublicRepositoryServiceTests.swift`
- Modify: `ATProtoDriveTests/PublicRepositoryServiceTestDouble.swift`
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `RepositoryScope`, `RecordOrigin`, `RecordRow`, `BrowserFailure`, Petrel `ATProtoClient`, `ATIdentifier`, `NSID`, `RecordKey`, `DID`, `DIDDocument`, and `CID`.
- Produces: generic `DIDDocumentPDSResolving`, concrete `DIDDocumentPDSResolver`, canonical `RepositoryTarget`, `ResolvedRepository`, `RepositoryDescription`, `RepositoryRecordPage`, `PublicRepositoryServing`, and `PublicRepositoryService`.

Protocol source of truth for this task: [AT Protocol DID specification](https://atproto.com/specs/did). Its ATProto-specific restrictions take precedence over the broader W3C `did:web` method grammar.

- [ ] **Step 1: Write failing DID-document and public-service contract tests**

```swift
private let fixtureDID = "did:plc:4hqjfn7m6n5hno3doamuhgef"

@Suite("DID document PDS resolver")
struct DIDDocumentPDSResolverTests {
    @Test(arguments: [
        ("did:plc:4hqjfn7m6n5hno3doamuhgef", "https://plc.directory/did:plc:4hqjfn7m6n5hno3doamuhgef"),
        ("did:web:identity.example", "https://identity.example/.well-known/did.json")
    ])
    func constructsATProtoResolutionURLs(did: String, expectedURL: String) throws {
        #expect(try DIDDocumentPDSResolver.documentURL(for: did).absoluteString == expectedURL)
    }

    @Test(arguments: [
        "did:web:identity.example:users:alice",
        "did:web:identity.example%3A8443",
        "did:web:localhost%3A2582"
    ])
    func rejectsPathsNonLocalPortsAndProductionLocalhost(did: String) {
        #expect(throws: BrowserFailure.self) {
            _ = try DIDDocumentPDSResolver.documentURL(for: did)
        }
    }

    @Test("localhost encoded ports require explicit development policy")
    func localhostDevelopmentResolution() throws {
        let url = try DIDDocumentPDSResolver.documentURL(
            for: "did:web:localhost%3A2582",
            allowLocalhostDevelopment: true
        )
        #expect(url.absoluteString == "http://localhost:2582/.well-known/did.json")
    }

    @Test("a document needs no handle to resolve its secure PDS")
    func noHandleRequired() async throws {
        let resolver = DIDDocumentPDSResolver(fetchDocument: { url in
            #expect(url.absoluteString.contains("plc.directory"))
            return (200, Data(##"{"id":"did:plc:4hqjfn7m6n5hno3doamuhgef","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://alice.example"}]}"##.utf8))
        })
        let result = try await resolver.resolvePDS(for: fixtureDID)
        #expect(result.did == fixtureDID)
        #expect(result.pdsURL == URL(string: "https://alice.example")!)
        #expect(result.declaredHandle == nil)
    }

    @Test("identity mismatch and wrong service are rejected")
    func rejectsUntrustedDocuments() async throws {
        func encoded(_ document: DIDDocument) throws -> Data {
            try JSONEncoder().encode(document)
        }

        let wrongID = try encoded(.init(
            id: "did:plc:z72i7hdynmk6r22z27h6tvur",
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://alice.example"
            )]
        ))
        let wrongIDResolver = DIDDocumentPDSResolver(fetchDocument: { _ in (200, wrongID) })
        await #expect(throws: BrowserFailure.identityMismatch(
            expected: fixtureDID,
            actual: "did:plc:z72i7hdynmk6r22z27h6tvur"
        )) {
            _ = try await wrongIDResolver.resolvePDS(for: fixtureDID)
        }

        let spaceHostOnly = try encoded(.init(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_space_host",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://space.example"
            )]
        ))
        let spaceHostResolver = DIDDocumentPDSResolver(fetchDocument: { _ in (200, spaceHostOnly) })
        await #expect(throws: BrowserFailure.invalidDIDDocument("Missing #atproto_pds service")) {
            _ = try await spaceHostResolver.resolvePDS(for: fixtureDID)
        }
    }

    @Test(arguments: [
        "http://alice.example",
        "https://alice.example/xrpc",
        "https://alice.example?token=secret",
        "https://alice.example#fragment",
        "https://user:password@alice.example",
        "http://localhost:2583"
    ])
    func rejectsNonOriginOrProductionHTTPPDSEndpoints(endpoint: String) throws {
        let document = DIDDocument(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: endpoint
            )]
        )
        #expect(throws: BrowserFailure.invalidDIDDocument(
            "PDS endpoint must be an allowed origin"
        )) {
            _ = try DIDDocumentPDSResolver.validatedIdentity(
                from: document,
                expectedDID: fixtureDID
            )
        }
    }

    @Test("localhost HTTP PDS origin requires explicit development policy")
    func localhostDevelopmentPDS() throws {
        let document = DIDDocument(
            id: fixtureDID,
            service: [.init(
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "http://localhost:2583"
            )]
        )
        let identity = try DIDDocumentPDSResolver.validatedIdentity(
            from: document,
            expectedDID: fixtureDID,
            allowLocalhostDevelopment: true
        )
        #expect(identity.pdsURL.absoluteString == "http://localhost:2583")
    }
}

@Suite("Public repository service")
struct PublicRepositoryServiceTests {
    @Test("handle and direct DID both route describe to the resolved PDS")
    func targetPDSRouting() async throws {
        let calls = PublicCallRecorder()
        let resolver = StubPDSResolver(result: .init(
            did: fixtureDID,
            pdsURL: URL(string: "https://alice.example")!,
            declaredHandle: nil
        ))
        let service = PublicRepositoryService(
            operations: try .fixture(calls: calls, did: fixtureDID),
            pdsResolver: resolver
        )

        for target in [RepositoryTarget.publicIdentifier("alice.test"), .publicIdentifier(fixtureDID)] {
            let resolved = try await service.resolve(target: target)
            _ = try await service.describe(resolved)
        }

        #expect(await calls.describeURLs == [
            URL(string: "https://alice.example")!,
            URL(string: "https://alice.example")!
        ])
        #expect(await calls.resolvedHandles == ["alice.test"])
    }

    @Test("2xx nil output is a decode failure")
    func nilSuccessFails() async throws {
        let service = PublicRepositoryService(
            operations: try .nilDescribeFixture(did: fixtureDID),
            pdsResolver: StubPDSResolver.fixture
        )
        await #expect(throws: BrowserFailure.decodeFailure(
            endpoint: "com.atproto.repo.describeRepo",
            statusCode: 200
        )) {
            _ = try await service.describe(.fixture)
        }
    }

    @Test("Petrel public clients have no auth mode")
    func anonymousPetrelClient() async {
        let client = await ATProtoClient(baseURL: URL(string: "https://pds.example")!)
        #expect(await client.authMode == .none)
    }
}
```

Use these concrete test helpers rather than an oversized inline closure list. They make closure capture and actor isolation explicit and compileable:

```swift
actor PublicCallRecorder {
    private(set) var describeURLs: [URL] = []
    private(set) var resolvedHandles: [String] = []
    func recordDescribe(_ url: URL) { describeURLs.append(url) }
    func recordHandle(_ handle: String) { resolvedHandles.append(handle) }
}

struct StubPDSResolver: DIDDocumentPDSResolving {
    let result: ResolvedPDSIdentity
    static let fixture = Self(result: .init(
        did: ResolvedRepository.fixture.did,
        pdsURL: ResolvedRepository.fixture.pdsURL,
        declaredHandle: nil
    ))
    func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity {
        guard did == result.did else {
            throw BrowserFailure.identityMismatch(expected: result.did, actual: did)
        }
        return result
    }
    func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity {
        try DIDDocumentPDSResolver.validatedIdentity(
            from: document,
            expectedDID: expectedDID
        )
    }
}

extension PublicRepositoryService.Operations {
    static func fixture(calls: PublicCallRecorder, did: String) throws -> Self {
        let didValue = try DID(didString: did)
        let output = ComAtprotoRepoDescribeRepo.Output(
            handle: try Handle(handleString: "alice.test"),
            did: didValue,
            didDoc: DIDDocument(
                id: did,
                service: [.init(
                    id: "#atproto_pds",
                    type: "AtprotoPersonalDataServer",
                    serviceEndpoint: "https://alice.example"
                )]
            ),
            collections: [try NSID(nsidString: "app.test.item")],
            handleIsCorrect: true
        )
        return .init(
            resolveHandle: { handle in
                await calls.recordHandle(handle)
                return (200, .init(did: didValue))
            },
            describe: { url, _ in
                await calls.recordDescribe(url)
                return (200, output)
            },
            listRecords: { _, _ in (200, .init(cursor: nil, records: [])) },
            getRecord: { _, _ in (404, nil) }
        )
    }

    static func nilDescribeFixture(did: String) throws -> Self {
        let didValue = try DID(didString: did)
        return .init(
            resolveHandle: { _ in (200, .init(did: didValue)) },
            describe: { _, _ in (200, nil) },
            listRecords: { _, _ in (500, nil) },
            getRecord: { _, _ in (500, nil) }
        )
    }
}
```

- [ ] **Step 2: Run both focused suites and observe failure**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-resolution-fail.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/DIDDocumentPDSResolverTests -only-testing:ATProtoDriveTests/PublicRepositoryServiceTests
```

Expected: FAIL because `DIDDocumentPDSResolver`, `ResolvedRepository`, `PublicRepositoryService`, and their injectable seams do not exist.

- [ ] **Step 3: Implement the generic, strict DID document resolver**

Use these public contracts:

```swift
public typealias DIDDocumentFetch = @Sendable (URL) async throws -> (
    statusCode: Int,
    data: Data?
)

public struct ResolvedPDSIdentity: Hashable, Sendable {
    public let did: String
    public let pdsURL: URL
    public let declaredHandle: String?
}

public protocol DIDDocumentPDSResolving: Sendable {
    func resolvePDS(for did: String) async throws -> ResolvedPDSIdentity
    func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity
}

public actor DIDDocumentPDSResolver: DIDDocumentPDSResolving {
    public static let liveFetch: DIDDocumentFetch
    private let fetchDocument: DIDDocumentFetch
    private let allowLocalhostDevelopment: Bool

    public init(
        fetchDocument: @escaping DIDDocumentFetch = Self.liveFetch,
        allowLocalhostDevelopment: Bool = false
    ) {
        self.fetchDocument = fetchDocument
        self.allowLocalhostDevelopment = allowLocalhostDevelopment
    }

    public static func documentURL(
        for did: String,
        allowLocalhostDevelopment: Bool = false
    ) throws -> URL
    public static func validatedIdentity(
        from document: DIDDocument,
        expectedDID: String,
        allowLocalhostDevelopment: Bool = false
    ) throws -> ResolvedPDSIdentity
    public func validatePDSIdentity(
        from document: DIDDocument,
        expectedDID: String
    ) async throws -> ResolvedPDSIdentity
}
```

`documentURL(for:)` supports exactly these current methods:

- A valid 24-character PLC identifier, such as `did:plc:4hqjfn7m6n5hno3doamuhgef`, becomes `https://plc.directory/did:plc:4hqjfn7m6n5hno3doamuhgef`.
- `did:web:host` percent-decodes the method-specific host and becomes `https://host/.well-known/did.json`.
- AT Protocol rejects every path-form `did:web`; do not implement the broader W3C path mapping. A percent-decoded port is rejected for normal hosts. Exact `did:web:localhost` and `did:web:localhost%3A<port>` resolve through HTTP at `/.well-known/did.json` only when `allowLocalhostDevelopment` is explicitly true; the production default rejects localhost and every encoded port.

Reject empty identifiers, path segments, user information, queries, fragments, unsupported DID methods, invalid percent encoding, disallowed top-level domains, non-local ports, and production localhost before fetching. `resolvePDS` passes its stored development policy to both static validators, requires a 2xx status plus a non-nil decodable `DIDDocument`, then `validatedIdentity` requires:

1. `document.id == expectedDID` exactly;
2. the first service whose resolved ID is exactly the expected DID plus `#atproto_pds` and whose type is exactly `AtprotoPersonalDataServer`; accept relative `#atproto_pds` and fully qualified IDs, ignore later matching entries, and never substitute `#atproto_space_host`;
3. an origin-only absolute `https://` endpoint with a hostname and optional port, no user/password, no non-root path, no query, and no fragment;
4. only under explicit development policy, an origin-only `http://localhost` endpoint with an optional port; production rejects localhost and all non-HTTPS endpoints;
5. no handle requirement. Expose the first syntactically valid `at://<handle>` entry in `alsoKnownAs`; ignore invalid or non-handle entries.

Canonicalize a validated PDS endpoint to its origin by lowercasing scheme/host, removing explicit default ports, and removing the optional root slash. Reject every path prefix instead of preserving it. Use this same function for `RepositoryScope` and describe-response comparison. Do not inspect or return `#atproto_space_host`. The live fetch uses an ephemeral `URLSession`, accepts no cookies or credentials, revalidates every redirect target under the same production/development policy, caps the body at 1 MiB, and maps status/decode/transport failures through `BrowserFailure` without logging the document body.

- [ ] **Step 4: Define the public values and anonymous operations**

```swift
public struct ResolvedRepository: Identifiable, Hashable, Sendable {
    public var id: String { scope.stableID }
    public let did: String
    public let handle: String?
    public let pdsURL: URL
    public let connectedAccountDID: String?
    public let handleIsCorrect: Bool?

    public var scope: RepositoryScope {
        .publicRepository(did: did, pdsURL: pdsURL)
    }
}

public struct RepositoryDescription: Hashable, Sendable {
    public let repository: ResolvedRepository
    public let collections: [String]
}

public struct RepositoryRecordPage: Sendable {
    public let records: [RecordRow]
    public let cursor: String?
}

public extension PublicRepositoryService {
    struct Operations: Sendable {
        public let resolveHandle: @Sendable (String) async throws -> (
            responseCode: Int,
            data: ComAtprotoIdentityResolveHandle.Output?
        )
        public let describe: @Sendable (
            URL, ComAtprotoRepoDescribeRepo.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoDescribeRepo.Output?)
        public let listRecords: @Sendable (
            URL, ComAtprotoRepoListRecords.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoListRecords.Output?)
        public let getRecord: @Sendable (
            URL, ComAtprotoRepoGetRecord.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoGetRecord.Output?)
    }
}

public actor PublicRepositoryService: PublicRepositoryServing {
    private let operations: Operations
    private let pdsResolver: any DIDDocumentPDSResolving

    public init(
        operations: Operations = .live,
        pdsResolver: any DIDDocumentPDSResolving = DIDDocumentPDSResolver()
    ) {
        self.operations = operations
        self.pdsResolver = pdsResolver
    }
}
```

`Operations.live.resolveHandle` constructs an unauthenticated client at `ATProtoClient.defaultBaseURL` and calls generated `com.atproto.identity.resolveHandle`. Each repo operation constructs a new `await ATProtoClient(baseURL: pdsURL)` inside its closure. There is no operation, initializer, stored property, or protocol method for an authenticated client, blob fetch, token, credential manager, or account object.

`resolve(target:)` trims input; validates a direct DID without resolving a handle; strictly gates generated handle output; calls `pdsResolver.resolvePDS(for:)`; and uses the requested handle or optional document handle. `.connectedAccount(did:)` records `connectedAccountDID` but still takes no account client. Both target forms therefore use the same anonymous DID-document and target-PDS path.

- [ ] **Step 5: Implement strict response identity, CID, and record mapping checks**

The sole output gate is:

```swift
private func requireOutput<Value>(
    endpoint: String,
    responseCode: Int,
    output: Value?
) throws -> Value {
    guard (200 ... 299).contains(responseCode) else {
        throw BrowserFailure.http(endpoint: endpoint, statusCode: responseCode)
    }
    guard let output else {
        throw BrowserFailure.decodeFailure(endpoint: endpoint, statusCode: responseCode)
    }
    return output
}
```

`describe` first constructs `let repo = try ATIdentifier(string: repository.did)`, passes that value through `ComAtprotoRepoDescribeRepo.Parameters(repo: repo)`, then rejects the response unless both `output.did.didString()` and `output.didDoc.id` equal the requested DID. Call `try await pdsResolver.validatePDSIdentity(from: output.didDoc, expectedDID: repository.did)` so the injected resolver applies the same production/development policy used during initial resolution, and require its normalized PDS URL to equal the resolved target PDS. Only then replace the optional handle/handle-correctness fields and stable-deduplicate collections in server order.

`listRecords` and `getRecord` likewise use `try ATIdentifier(string: repository.did)`—never a nonexistent unlabeled initializer—then pass the exact DID, collection, opaque cursor, limit, reverse, record key, and optional CID values through their generated parameter initializers. For every listed row, parse the returned AT URI and require its authority, collection, and rkey to match the requested repository/collection and a nonempty record key. Preserve the exact generated CID string, unknown JSON keys, and full value; set `RecordOrigin.publicRepository(did:)`.

`getRecord` validates the optional input CID before making a call and passes it unchanged. Require the output URI to match the requested DID/collection/rkey. If a CID was requested, require any returned CID to match and use that requested CID when the optional response field is absent; if no CID was requested, require the response to contain one. A returned different CID is an `identityMismatch`, never silently relabeled. Blob reads remain entirely absent from this plan and are introduced by Plan 3's qualified blob service.

- [ ] **Step 6: Complete the matrix, pass both suites, and seal**

Add tests for 199, 300, 401, 404, 429, and 503; 200 and 299 with nil output; invalid handle, DID, NSID, record key, and CID before any operation; hostname-level `did:web`; rejected path-form `did:web`; rejected non-local encoded ports; production-rejected localhost plus the explicit localhost development exception; documents without handles; wrong document IDs; wrong service IDs/types; non-origin PDS endpoints; a describe DID/doc/PDS mismatch; exact CID input/output/missing/mismatch behavior; unchanged cursors containing `+`, `/`, and `=`; URI authority/collection mismatches; and unknown JSON keys. Assert that `Operations` cannot accept an authenticated client.

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-resolution-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/DIDDocumentPDSResolverTests -only-testing:ATProtoDriveTests/PublicRepositoryServiceTests
```

Expected: PASS.

```bash
jj status
jj diff --summary
jj describe -m "feat: add anonymous public repository service"
jj new
```

### Task 3: Add repository and per-collection stores with safe pagination

**Files:**
- Modify: `ATProtoDrive/PublicRepo/PublicRepositoryStore.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRecordStore.swift`
- Modify: `ATProtoDriveTests/PublicRecordStoreTests.swift`
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `PublicRepositoryServing`, `ResolvedRepository`, `RepositoryDescription`, `RepositoryRecordPage`, `LoadState`, and `BrowserFailure`.
- Produces: `PublicRepositoryStore.init(service:)`, `open(target:)`, `refresh()`, `recordStore(for:)`, `loadCollection(_:)`, `record(for:)`, `PublicRecordStore.loadFirstPage()`, `loadNextPage()`, `retryFailedPage()`, `refresh()`, `rows`, `nextCursor`, `appendFailure`, `retryCursor`, `canLoadMore`, and `canRetryPage`.

- [ ] **Step 1: Write failing pagination and stale-snapshot tests**

```swift
@MainActor
@Test("empty pages advance and a repeated cursor terminates")
func emptyPageAndCycle() async {
    let service = ScriptedPublicRepositoryService(pages: [
        nil: .init(records: [], cursor: "opaque+/="),
        "opaque+/=": .init(records: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")], cursor: "opaque+/=")
    ])
    let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
    await store.loadFirstPage()
    #expect(store.rows.isEmpty)
    #expect(store.canLoadMore)
    await store.loadNextPage()
    #expect(store.rows.map(\.uri) == ["at://\(ResolvedRepository.fixture.did)/app.test.item/1"])
    #expect(!store.canLoadMore)
    #expect(await service.requestedCursors == [nil, "opaque+/="])
}

@MainActor
@Test("failed refresh keeps visible rows")
func failedRefreshIsStale() async {
    let service = ScriptedPublicRepositoryService(pages: [
        nil: .init(records: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/1", cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a")], cursor: nil)
    ])
    let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
    await store.loadFirstPage()
    await service.fail(with: .offline)
    await store.refresh()
    #expect(store.rows.count == 1)
    #expect(store.state.isStale)
}

@MainActor
@Test("append failure retains its exact cursor and retries only that page")
func appendFailureRetry() async {
    let service = ScriptedPublicRepositoryService(pages: [
        nil: .init(records: [], cursor: "retry+/="),
        "retry+/=": .init(records: [.fixture(
            uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/recovered",
            rkey: "recovered",
            cid: "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"
        )], cursor: nil)
    ])
    let store = PublicRecordStore(service: service, repository: .fixture, collection: "app.test.item")
    await store.loadFirstPage()
    await service.failNextPage(cursor: "retry+/=", with: .offline)
    await store.loadNextPage()
    #expect(store.rows.isEmpty)
    #expect(store.appendFailure == .offline)
    #expect(store.retryCursor == "retry+/=")
    #expect(store.canRetryPage)
    await store.retryFailedPage()
    #expect(store.rows.map(\.rkey) == ["recovered"])
    #expect(store.appendFailure == nil)
    #expect(await service.requestedCursors == [nil, "retry+/=", "retry+/="])
}

@MainActor
@Test("a newer target clears old rows and wins a non-cooperative race")
func targetGenerationWins() async {
    let service = DeferredPublicRepositoryService()
    let store = PublicRepositoryStore(service: service)
    let first = RepositoryTarget.publicIdentifier("first.test")
    let second = RepositoryTarget.publicIdentifier("second.test")
    let firstOpen = Task { @MainActor in await store.open(target: first) }
    await service.waitUntilResolveStarted(for: first)
    let secondOpen = Task { @MainActor in await store.open(target: second) }
    await service.waitUntilResolveStarted(for: second)
    await service.complete(target: second, with: .secondFixture)
    await service.completeIgnoringCancellation(target: first, with: .fixture)
    _ = await (firstOpen.value, secondOpen.value)
    #expect(store.target == second)
    #expect(store.state.snapshot?.repository.did == ResolvedRepository.secondFixture.did)
    #expect(store.cachedCollectionCount == 0)
}
```

`DeferredPublicRepositoryService` is a test-only actor with checked continuations keyed by `RepositoryTarget`. Its first request deliberately ignores task cancellation so the generation assertion proves stale completion cannot overwrite the second target. Add a companion test creating two `PublicRepositoryStore` instances over the same service and proving target, collections, and cached `PublicRecordStore` instances remain window-local.

- [ ] **Step 2: Run the store suite and observe failure**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-store.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicRecordStoreTests
```

Expected: FAIL because both observable stores are empty compilation units.

- [ ] **Step 3: Implement repository open/refresh without clearing good data**

```swift
@MainActor @Observable
public final class PublicRepositoryStore {
    private enum LoadOutcome: Sendable {
        case success(RepositoryDescription)
        case failure(BrowserFailure)
        case cancelled
    }

    public private(set) var state: LoadState<RepositoryDescription> = .idle
    public private(set) var target: RepositoryTarget?
    public var cachedCollectionCount: Int { recordStores.count }

    private let service: any PublicRepositoryServing
    private var recordStores: [String: PublicRecordStore] = [:]
    private var generation: UInt64 = 0
    private var activeLoad: Task<LoadOutcome, Never>?

    public init(service: any PublicRepositoryServing) {
        self.service = service
    }

    public func open(target newTarget: RepositoryTarget) async {
        let changed = target != newTarget
        if changed {
            target = newTarget
            recordStores.removeAll()
            state = .idle
        }
        await load(target: newTarget, preserveSnapshot: !changed)
    }

    public func refresh() async {
        guard let target else { return }
        await load(target: target, preserveSnapshot: true)
    }

    private func load(target requestedTarget: RepositoryTarget, preserveSnapshot: Bool) async {
        generation &+= 1
        let requestGeneration = generation
        activeLoad?.cancel()
        let previous = preserveSnapshot ? state.snapshot : nil
        state = .loading(previous: previous)
        let service = self.service
        let task = Task<LoadOutcome, Never> {
            do {
                let resolved = try await service.resolve(target: requestedTarget)
                return .success(try await service.describe(resolved))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(BrowserFailure.normalize(error))
            }
        }
        activeLoad = task
        let outcome = await task.value
        guard generation == requestGeneration, target == requestedTarget else { return }
        switch outcome {
        case .success(let description): state = .loaded(description)
        case .failure(let failure): state = .failed(previous: previous, failure: failure)
        case .cancelled: break
        }
    }

    public func recordStore(for collection: String) -> PublicRecordStore? {
        guard let repository = state.snapshot?.repository else { return nil }
        let key = "\(repository.scope.stableID)|collection|\(collection)"
        if let existing = recordStores[key] { return existing }
        let store = PublicRecordStore(
            service: service,
            repository: repository,
            collection: collection
        )
        recordStores[key] = store
        return store
    }

    public func loadCollection(_ collection: String) async -> PublicRecordStore? {
        guard let store = recordStore(for: collection) else { return nil }
        if case .idle = store.state { await store.loadFirstPage() }
        guard case .loaded = store.state else { return nil }
        return store
    }

    public func record(for reference: ResourceReference) -> RecordRow? {
        guard case .record(let locator) = reference else { return nil }
        let key = "\(locator.scope.stableID)|collection|\(locator.collection)"
        return recordStores[key]?.rows.first {
            $0.uri == locator.uri && $0.cid == locator.cid
        }
    }
}
```

The scene container, not `ATProtoDriveApp`, constructs this store. Switching targets synchronously drops the previous description and all collection stores before awaiting. Reopening or refreshing the same target retains its snapshot. Cancellation is an optimization; the generation and target guards are the correctness boundary when a dependency ignores cancellation.

- [ ] **Step 4: Implement first-page loading, dedupe, and cycle termination**

`PublicRecordStore` keeps `state: LoadState<[RecordRow]>`, the fixed repository/collection/limit/reverse request tuple, `nextCursor`, `completedCursors: Set<String>`, `appendFailure`, `retryCursor`, `isLoadingPage`, and an insertion-ordered `(URI, CID)` key list. Its computed `rows` is `state.snapshot ?? []`; `canLoadMore` is `nextCursor != nil && appendFailure == nil && !isLoadingPage`; `canRetryPage` is `retryCursor != nil && appendFailure != nil && !isLoadingPage`.

`loadFirstPage` resets paging and keeps old rows visible only while a replacement page is loading. `loadNextPage` captures the exact `nextCursor`; on success it adds that cursor to `completedCursors` and merges. On failure it leaves rows and `nextCursor` untouched, sets `appendFailure` and `retryCursor` to the captured cursor, and does not mark it complete. `retryFailedPage()` requests that exact cursor again, clears the failure only after success, and cannot advance to a different page. An empty successful page with a new cursor remains loadable. A returned cursor equal to the request cursor or already completed sets `nextCursor = nil`.

```swift
public init(
    service: any PublicRepositoryServing,
    repository: ResolvedRepository,
    collection: String,
    pageLimit: Int = 100,
    reverse: Bool = false
) {
    precondition((1 ... 100).contains(pageLimit))
    self.service = service
    self.repository = repository
    self.collection = collection
    self.pageLimit = pageLimit
    self.reverse = reverse
}
```

```swift
private func merge(
    _ page: RepositoryRecordPage,
    requestedCursor: String?,
    replacingSnapshot: Bool
) {
    if let requestedCursor { completedCursors.insert(requestedCursor) }
    var merged = replacingSnapshot ? [] : (state.snapshot ?? [])
    var identities = Set(merged.map { "\($0.uri)\u{1F}\($0.cid)" })
    for row in page.records {
        let identity = "\(row.uri)\u{1F}\(row.cid)"
        guard identities.insert(identity).inserted else { continue }
        if let existing = merged.firstIndex(where: { $0.uri == row.uri }) {
            identities.remove("\(merged[existing].uri)\u{1F}\(merged[existing].cid)")
            merged[existing] = row
        } else {
            merged.append(row)
        }
    }
    state = .loaded(merged)
    if let cursor = page.cursor,
       cursor != requestedCursor,
       !completedCursors.contains(cursor) {
        nextCursor = cursor
    } else {
        nextCursor = nil
    }
}
```

Normalize thrown errors with Task 1's `BrowserFailure.normalize`; check cancellation first and never translate a failure into `.loaded([])`. First-page and refresh failures use `LoadState.failed(previous:failure:)`; append failures use the explicit footer state above, so a recoverable page error is never mistaken for a terminal empty collection.

- [ ] **Step 5: Complete the matrix and pass store plus service tests**

Add cases for first page only, two appended pages, exact parameter stability, duplicate `(URI,CID)` removal, same URI with a new CID replacing the older row in place, first-page refresh removing records no longer returned, empty terminal page, concurrent double-load suppression, selection-independent sorting input, and retry after an idempotent page failure.

Run the store suite:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-store-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicRecordStoreTests
```

Run the service/resolver regressions in a separate fresh shell:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-service-regression.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/DIDDocumentPDSResolverTests -only-testing:ATProtoDriveTests/PublicRepositoryServiceTests
```

Expected: PASS.

- [ ] **Step 6: Seal the task with jj**

```bash
jj status
jj diff --summary
jj describe -m "feat: add paginated public repository stores"
jj new
```

### Task 4: Replace the root window with a two-column source browser

**Files:**
- Modify: `ATProtoDrive/Browser/MainWindowView.swift`
- Modify: `ATProtoDrive/Browser/DriveSidebarView.swift`
- Modify: `ATProtoDrive/Browser/RecentRepositoryStore.swift`
- Modify by the integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify by the integration owner: `ATProtoDrive/ATProtoDriveApp.swift`
- Modify: `ATProtoDriveTests/DriveSidebarTests.swift`
- Modify: `ATProtoDriveTests/RecentRepositoryStoreTests.swift`
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AccountStore`, `BrowserSession`, `BrowserSource`, `PublicRepositoryStore`, and existing Space read models.
- Produces: `RecentRepositoryStore`, `DriveSidebarProjection.rows(accounts:openedRepositories:)`, the new `MainWindowView`, a per-scene `BrowserSession`/`PublicRepositoryStore` container, and an account-filtered read-only compatibility route for existing Spaces.

- [ ] **Step 1: Write failing source-list projection tests**

```swift
@Suite("Drive sidebar")
struct DriveSidebarTests {
    @Test("public repository utility remains available with no accounts")
    func noAccountUtilities() {
        let rows = DriveSidebarProjection.rows(accounts: [], openedRepositories: [])
        #expect(rows.contains { $0.source == .global(.openPublicRepository) })
        #expect(rows.contains { $0.source == .global(.addAccount) })
    }

    @Test("each account has the eight stable product destinations")
    func accountDestinations() {
        let did = ResolvedRepository.fixture.did
        let rows = DriveSidebarProjection.rows(
            accounts: [.init(did: did, handle: "alice.test")],
            openedRepositories: []
        )
        let accountRows = rows.filter { $0.accountDID == did }
        #expect(Set(accountRows.compactMap(\.accountDestination)) == Set(AccountDestination.allCases))
        #expect(accountRows.count == 8)
    }

    @Test("opened repositories have a visible recent row")
    func openedRepositoryRow() {
        let recent = OpenedRepositorySummary(
            did: ResolvedRepository.fixture.did,
            handle: ResolvedRepository.fixture.handle,
            pdsURL: ResolvedRepository.fixture.pdsURL,
            sourceAccountDID: nil,
            lastOpenedAt: .distantPast
        )
        let rows = DriveSidebarProjection.rows(accounts: [], openedRepositories: [recent])
        let row = rows.first { $0.source == .openedPublicRepository(did: recent.did) }
        #expect(row?.section == .openedAndRecent)
        #expect(row?.title == "alice.test")
        #expect(row?.subtitle == recent.did)
    }

    @Test("legacy Space route resolves only the source account and is read only")
    func legacySpaceRouteIsAccountBound() {
        let selectedDID = ResolvedRepository.fixture.did
        let projection = LegacySpacesCompatibilityProjection(
            selectedAccountDID: selectedDID,
            accounts: [.init(did: selectedDID, handle: "alice.test")]
        )
        #expect(projection.accountDID == selectedDID)
        #expect(projection.capabilities == .readOnly)
        #expect(projection.availableActions.isEmpty)
    }
}

@MainActor
@Test("recents use a versioned envelope, dedupe, and restore without production preferences")
func recentRepositoryPersistence() async throws {
    let persistence = MemoryRecentRepositoryPersistence()
    let first = RecentRepositoryStore(persistence: persistence, maximumCount: 2)
    let summary = OpenedRepositorySummary(
        did: ResolvedRepository.fixture.did,
        handle: "alice.test",
        pdsURL: ResolvedRepository.fixture.pdsURL,
        sourceAccountDID: ResolvedRepository.fixture.did,
        lastOpenedAt: .distantPast
    )
    await first.remember(summary)
    let newestDate = Date(timeIntervalSince1970: 1_787_488_496)
    await first.remember(.init(
        did: summary.did,
        handle: summary.handle,
        pdsURL: summary.pdsURL,
        sourceAccountDID: summary.sourceAccountDID,
        lastOpenedAt: newestDate
    ))
    let encoded = try #require(await persistence.data)
    #expect(try JSONDecoder().decode(RecentRepositoryEnvelope.self, from: encoded).version == 1)

    let restored = RecentRepositoryStore(persistence: persistence, maximumCount: 2)
    await restored.restore()
    #expect(restored.entries.count == 1)
    #expect(restored.entries[0].lastOpenedAt == newestDate)
}

@MainActor
@Test("recents cap by newest and account cleanup preserves anonymous history")
func recentRepositoryQualificationAndCap() async {
    let store = RecentRepositoryStore(
        persistence: MemoryRecentRepositoryPersistence(),
        maximumCount: 2
    )
    let did = ResolvedRepository.fixture.did
    let anonymous = OpenedRepositorySummary(
        did: did,
        handle: "alice.test",
        pdsURL: ResolvedRepository.fixture.pdsURL,
        sourceAccountDID: nil,
        lastOpenedAt: Date(timeIntervalSince1970: 30)
    )
    let accountQualified = OpenedRepositorySummary(
        did: did,
        handle: "alice.test",
        pdsURL: ResolvedRepository.fixture.pdsURL,
        sourceAccountDID: did,
        lastOpenedAt: Date(timeIntervalSince1970: 20)
    )
    await store.remember(.init(
        did: ResolvedRepository.secondFixture.did,
        handle: nil,
        pdsURL: ResolvedRepository.secondFixture.pdsURL,
        sourceAccountDID: nil,
        lastOpenedAt: Date(timeIntervalSince1970: 10)
    ))
    await store.remember(accountQualified)
    await store.remember(anonymous)
    #expect(store.entries.map(\.id) == [anonymous.id, accountQualified.id])
    await store.removeEntries(sourceAccountDID: did)
    #expect(store.entries.map(\.id) == [anonymous.id])
}
```

- [ ] **Step 2: Run the sidebar suite and observe failure**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-sidebar.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/DriveSidebarTests -only-testing:ATProtoDriveTests/RecentRepositoryStoreTests
```

Expected: FAIL because `DriveSidebarProjection` and `RecentRepositoryStore` are undefined.

- [ ] **Step 3: Implement the native source list and stable row model**

Implement app-scoped recents before wiring the sidebar:

```swift
public struct RecentRepositoryEnvelope: Codable, Sendable {
    public let version: Int
    public let entries: [OpenedRepositorySummary]
}

public protocol RecentRepositoryPersisting: Sendable {
    func load() async throws -> Data?
    func saveAtomically(_ data: Data) async throws
}

public actor MemoryRecentRepositoryPersistence: RecentRepositoryPersisting {
    public private(set) var data: Data?
    public init(data: Data? = nil) { self.data = data }
    public func load() async throws -> Data? { data }
    public func saveAtomically(_ data: Data) async throws { self.data = data }
}

public typealias AtomicDataWrite = @Sendable (Data, URL) throws -> Void

public actor FileRecentRepositoryPersistence: RecentRepositoryPersisting {
    public let fileURL: URL
    private let writeAtomically: AtomicDataWrite

    public init(
        fileURL: URL,
        writeAtomically: @escaping AtomicDataWrite = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.writeAtomically = writeAtomically
    }

    public static func live() throws -> FileRecentRepositoryPersistence {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return .init(fileURL: applicationSupport
            .appendingPathComponent("ATProtoDrive", isDirectory: true)
            .appendingPathComponent("RecentRepositories-v1.json", isDirectory: false))
    }

    public func load() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func saveAtomically(_ data: Data) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomically(data, fileURL)
    }
}

@MainActor @Observable
public final class RecentRepositoryStore {
    public private(set) var entries: [OpenedRepositorySummary] = []
    public private(set) var failure: BrowserFailure?
    private let persistence: any RecentRepositoryPersisting
    private let maximumCount: Int

    public init(
        persistence: any RecentRepositoryPersisting,
        maximumCount: Int = 20
    ) {
        precondition(maximumCount > 0)
        self.persistence = persistence
        self.maximumCount = maximumCount
    }

    public func restore() async {
        do {
            guard let data = try await persistence.load() else { return }
            let envelope = try JSONDecoder().decode(RecentRepositoryEnvelope.self, from: data)
            guard envelope.version == 1 else {
                throw BrowserFailure.unsupported("Recent repository format \(envelope.version)")
            }
            entries = normalized(envelope.entries)
            failure = nil
        } catch {
            failure = BrowserFailure.normalize(error)
        }
    }

    public func remember(_ summary: OpenedRepositorySummary) async {
        entries = normalized([summary] + entries)
        await persist()
    }

    public func removeEntries(sourceAccountDID: String) async {
        entries.removeAll { $0.sourceAccountDID == sourceAccountDID }
        await persist()
    }

    private func normalized(_ values: [OpenedRepositorySummary]) -> [OpenedRepositorySummary] {
        var seen = Set<String>()
        return values.enumerated()
            .sorted {
                $0.element.lastOpenedAt == $1.element.lastOpenedAt
                    ? $0.offset < $1.offset
                    : $0.element.lastOpenedAt > $1.element.lastOpenedAt
            }
            .compactMap { seen.insert($0.element.id).inserted ? $0.element : nil }
            .prefix(maximumCount)
            .map(\.self)
    }

    private func persist() async {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(RecentRepositoryEnvelope(version: 1, entries: entries))
            try await persistence.saveAtomically(data)
            failure = nil
        } catch {
            failure = BrowserFailure.normalize(error)
        }
    }
}
```

Construct the normal app-scoped store with `RecentRepositoryStore(persistence: try FileRecentRepositoryPersistence.live())`. The file actor writes `Application Support/ATProtoDrive/RecentRepositories-v1.json` with `Data.write(options: .atomic)`, creates only that parent directory, and stores envelope version 1. It rejects unknown versions visibly, stable-sorts newest first, deduplicates by DID plus source-account qualification, and caps after every restore/write. The remembered PDS is display/history metadata only: reopening a row always resolves the DID document again and replaces the summary with the current validated PDS before any repository request. `removeEntries(sourceAccountDID:)` is reserved for Plan 4's local account cleanup; anonymous entries survive. Fixture/tests inject one app-scoped `MemoryRecentRepositoryPersistence`, which never accesses disk or `UserDefaults`. A temp-directory integration test initializes `FileRecentRepositoryPersistence` with a throwing `writeAtomically` closure and verifies the existing file remains a decodable complete old envelope; a successful retry replaces it with one complete new envelope.

The projection accepts `[SidebarAccountSummary]` and a stable merge of the current window's `BrowserSession.openedPublicRepositories` followed by app-scoped `RecentRepositoryStore.entries`, deduplicated by DID for display while retaining source qualification in persistence. It emits account groups with exactly the eight approved destinations, a visible **Opened & Recent** section with one row per merged repository, then global rows for Open Public Repository, Open Space by URI, and Add Account. Each row has one SF Symbol, one title, no count, and at most one secondary line. Use `.listStyle(.sidebar)` and bind row tags to `BrowserSession.selectedSource`.

```swift
public struct SidebarAccountSummary: Hashable, Sendable {
    public let did: String
    public let handle: String
}

public struct DriveSidebarRow: Identifiable, Hashable, Sendable {
    public var id: String { source.stableID }
    public let source: BrowserSource
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let section: DriveSidebarSection
    public var accountDID: String? {
        guard case .account(let did, _) = source else { return nil }
        return did
    }
    public var accountDestination: AccountDestination? {
        guard case .account(_, let destination) = source else { return nil }
        return destination
    }
}

public enum DriveSidebarProjection {
    public static func rows(
        accounts: [SidebarAccountSummary],
        openedRepositories: [OpenedRepositorySummary]
    ) -> [DriveSidebarRow]
}
```

Define `DriveSidebarSection` as `.account(String)`, `.openedAndRecent`, and `.utilities`. Recent rows show handle-or-DID as title and DID as the secondary line, use `externaldrive.connected.to.line.below`, and select `.openedPublicRepository(did:)`. Task 5 records opened/recent summaries only after a successful, identity-validated load, so a failed or mismatched repository is never added.

Implement `BrowserSource.stableID` with the exact string interpolations `"account|\(did)|\(destination.rawValue)"`, `"public|\(did)"`, and `"global|\(destination.rawValue)"`.

Connected-account Public Records selects `.account(did: account.id, destination: .publicRecords)`. Until Task 5 wires repository opening, `ContentBrowserView` renders `ProgressView("Loading public repository…")` for that destination; it must not construct or pass the account's authenticated client.

- [ ] **Step 4: Implement the two-column root and preserve the old Space surface behind one adapter**

```swift
public var body: some View {
    @Bindable var session = session
    NavigationSplitView(columnVisibility: $session.columnVisibility) {
        DriveSidebarView(session: session, recentRepositoryStore: recentRepositoryStore)
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
    } detail: {
        ContentBrowserView(
            session: session,
            publicRepositoryStore: publicRepositoryStore,
            recentRepositoryStore: recentRepositoryStore
        )
    }
    .inspector(isPresented: $session.isInspectorPresented) {
        ContentUnavailableView(
            "No Selection",
            systemImage: "sidebar.right",
            description: Text("Select an item to inspect its details.")
        )
            .inspectorColumnWidth(min: 260, ideal: 340, max: 480)
    }
}
```

Move `MainWindowView` out of `ATProtoDriveApp.swift`; delete `WindowSelectionModel`. `ATProtoDriveApp` retains the single app-scoped `AccountStore`, stateless/app-scoped `any PublicRepositoryServing`, and app-scoped `RecentRepositoryStore`. A `BrowserSceneRoot` created by `WindowGroup` owns a new `BrowserSession` and `PublicRepositoryStore(service:)` for each scene while receiving the shared recent store. Add a two-window test that shares service and durable recents but proves repository target, record stores, selection, window-opened rows, search, sort, navigation history, and inspector visibility do not cross scenes; a successfully persisted recent is intentionally visible in both.

```swift
@MainActor
private struct BrowserSceneRoot: View {
    @State private var session: BrowserSession
    @State private var publicRepositoryStore: PublicRepositoryStore
    private let recentRepositoryStore: RecentRepositoryStore

    init(
        publicRepositoryService: any PublicRepositoryServing,
        recentRepositoryStore: RecentRepositoryStore
    ) {
        _session = State(initialValue: BrowserSession())
        _publicRepositoryStore = State(initialValue: PublicRepositoryStore(
            service: publicRepositoryService
        ))
        self.recentRepositoryStore = recentRepositoryStore
    }

    var body: some View {
        MainWindowView(
            session: session,
            publicRepositoryStore: publicRepositoryStore,
            recentRepositoryStore: recentRepositoryStore
        )
    }
}
```

For `.account(did: selectedDID, destination: .spaces)`, route to `LegacySpacesCompatibilityView(accountDID: selectedDID)`. Resolve only `accountStore.account(for: selectedDID)` and `accountStore.spaceModel(for: selectedDID)`; if that exact account is unavailable, show a disconnected state and never fall back to `activeAccount` or the first account. Label the route **Spaces — Experimental (Read Only)**. Because the existing `SidebarView`, `SpaceDetailView`, and `RecordTableView` expose create/edit/delete/member/blob controls, do not embed them directly. Render a minimal compatibility list/detail/table over their existing read models with every mutation toolbar, context menu, keyboard command, drag destination, editor sheet, and delete confirmation absent. `LegacySpacesCompatibilityProjection.capabilities` is exactly `.readOnly`, and its action list is empty. Plan 2 replaces this adapter with the reviewed CRUD surface. Do not let compatibility state enter `BrowserSession`, and do not copy Space data into public stores.

```swift
public enum LegacySpaceCompatibilityCapability: Hashable, Sendable {
    case readOnly
}

public enum LegacySpaceMutationAction: Hashable, Sendable {
    case createSpace, updateSpace, deleteSpace, addMember, removeMember
    case createRecord, updateRecord, deleteRecord, uploadBlob
}

public struct LegacySpacesCompatibilityProjection: Hashable, Sendable {
    public let accountDID: String?
    public let capabilities: LegacySpaceCompatibilityCapability = .readOnly
    public let availableActions: [LegacySpaceMutationAction] = []

    public init(selectedAccountDID: String, accounts: [SidebarAccountSummary]) {
        accountDID = accounts.contains(where: { $0.did == selectedAccountDID })
            ? selectedAccountDID
            : nil
    }
}
```

- [ ] **Step 5: Pass sidebar, domain, and safe record-model tests**

Run the sidebar suite:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-sidebar-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/DriveSidebarTests -only-testing:ATProtoDriveTests/RecentRepositoryStoreTests
```

Run domain and safe record-model regressions in a separate fresh shell:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-shell-regression.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/BrowserDomainTests -only-testing:ATProtoDriveTests/RecordListModelTests
```

Expected: PASS. The existing preference-writing Space and account suites remain excluded until Plan 2 Tasks 1 and 4 respectively isolate their stores. Manually open two windows in Task 7; no session or repository store is shared between them.

- [ ] **Step 6: Seal the task with jj**

```bash
jj status
jj diff --summary
jj describe -m "feat: add Finder-style browser shell"
jj new
```

### Task 5: Add Open Public Repository and collection browsing

**Files:**
- Modify: `ATProtoDrive/Browser/OpenPublicRepositorySheet.swift`
- Modify: `ATProtoDrive/Browser/BrowserCommands.swift`
- Modify by the integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDrive/Browser/BrowserTableShell.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRepositoryView.swift`
- Modify: `ATProtoDriveTests/PublicBrowserPresentationTests.swift`
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `PublicRepositoryStore`, `RecentRepositoryStore`, `RepositoryDescription`, `BrowserSession`, `BrowserPath`, and `LoadState`.
- Produces: `PublicRepositoryPresentation`, `PublicRepositoryOpenCoordinator`, `CollectionRow`, `BrowserRefreshAction`, `InlineErrorBanner`, `UnavailableStateView`, no-account open-by-handle/DID flow, collection table, clickable breadcrumbs, back/forward navigation, focused refresh, explicit collection loading, retry, and stable qualified selection.

- [ ] **Step 1: Write failing presentation projection tests**

```swift
@Test("collection projection preserves server order and stable selection")
func collectionProjection() {
    let description = RepositoryDescription.fixture(collections: [
        "app.bsky.feed.post", "com.example.unknown", "app.bsky.actor.profile"
    ])
    let rows = PublicRepositoryPresentation.collections(description)
    #expect(rows.map(\.nsid) == [
        "app.bsky.feed.post", "com.example.unknown", "app.bsky.actor.profile"
    ])
    #expect(rows[1].title == "com.example.unknown")
    #expect(rows[1].reference == .collection(
        scope: description.repository.scope,
        collection: "com.example.unknown"
    ))
    #expect(rows[1].id == rows[1].reference.stableID)
}

@MainActor
@Test(arguments: ["alice.test", ResolvedRepository.fixture.did])
func openByHandleOrDIDSelectsResolvedSource(identifier: String) async {
    let service = ScriptedPublicRepositoryService.successfulFixture()
    let store = PublicRepositoryStore(service: service)
    let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
    let session = BrowserSession()
    await PublicRepositoryOpenCoordinator.open(
        .publicIdentifier(identifier), store: store, session: session, recents: recents
    )
    #expect(session.selectedSource == .openedPublicRepository(did: ResolvedRepository.fixture.did))
    #expect(session.path?.components == [.repository(ResolvedRepository.fixture.scope)])
    #expect(session.history.count == 1)
    #expect(session.openedPublicRepositories.map(\.did) == [ResolvedRepository.fixture.did])
    #expect(recents.entries.map(\.did) == [ResolvedRepository.fixture.did])
}

@MainActor
@Test("collection loading and breadcrumb history are explicit")
func collectionNavigation() async {
    let store = PublicRepositoryStore(service: ScriptedPublicRepositoryService.successfulFixture())
    let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
    let session = BrowserSession()
    await PublicRepositoryOpenCoordinator.open(
        .publicIdentifier("alice.test"), store: store, session: session, recents: recents
    )
    await PublicRepositoryOpenCoordinator.openCollection(
        "app.bsky.feed.post", store: store, session: session
    )
    #expect(store.recordStore(for: "app.bsky.feed.post")?.state.snapshot != nil)
    #expect(session.canGoBack)
    session.goBack()
    #expect(session.path?.components.count == 1)
    session.goForward()
    #expect(session.path?.components.count == 2)
}

private actor RefreshCallRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
@Test("focused refresh invokes only the active window action")
func focusedRefreshIsWindowLocal() async {
    let first = RefreshCallRecorder()
    let second = RefreshCallRecorder()
    let firstAction = BrowserRefreshAction(perform: { await first.record() })
    _ = BrowserRefreshAction(perform: { await second.record() })
    await firstAction.perform()
    #expect(await first.count == 1)
    #expect(await second.count == 0)
}
```

- [ ] **Step 2: Run the presentation suite and observe failure**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-presentation.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests
```

Expected: FAIL because the projections and coordinator do not exist.

- [ ] **Step 3: Implement the open sheet with visible progress and errors**

Trim input, reject empty text locally, call `PublicRepositoryStore.open(target: .publicIdentifier(input))`, and dismiss only after `.loaded`. On failure, keep the sheet and input open and render the `BrowserFailure.errorDescription` inline. Disable only the submit control while loading; Cancel remains available. The same sheet works when `AccountStore.accounts` is empty.

```swift
@MainActor
public enum PublicRepositoryOpenCoordinator {
    public static func open(
        _ target: RepositoryTarget,
        store: PublicRepositoryStore,
        session: BrowserSession,
        recents: RecentRepositoryStore,
        selectedSource: BrowserSource? = nil
    ) async {
        await store.open(target: target)
        guard case .loaded(let description) = store.state else { return }
        let source = selectedSource ?? .openedPublicRepository(did: description.repository.did)
        session.selectSource(source)
        session.navigate(to: BrowserPath(
            source: source,
            components: [.repository(description.repository.scope)]
        ))
        let sourceAccountDID: String?
        if case .connectedAccount(let did) = target { sourceAccountDID = did }
        else { sourceAccountDID = nil }
        let summary = OpenedRepositorySummary(
            did: description.repository.did,
            handle: description.repository.handle,
            pdsURL: description.repository.pdsURL,
            sourceAccountDID: sourceAccountDID,
            lastOpenedAt: .now
        )
        session.rememberOpenedRepository(summary)
        await recents.remember(summary)
    }

    public static func openCollection(
        _ collection: String,
        store: PublicRepositoryStore,
        session: BrowserSession
    ) async {
        guard let description = store.state.snapshot,
              description.collections.contains(collection),
              await store.loadCollection(collection) != nil,
              let source = session.selectedSource else { return }
        session.navigate(to: BrowserPath(
            source: source,
            components: [
                .repository(description.repository.scope),
                .collection(scope: description.repository.scope, collection: collection)
            ]
        ))
    }
}
```

When `ContentBrowserView` receives `.account(did: let did, destination: .publicRecords)`, call the coordinator with `.connectedAccount(did: did)`, the shared recent store, and `selectedSource: .account(did: did, destination: .publicRecords)`. This preserves the sidebar selection while the service independently resolves the current PDS and performs anonymous reads; the summary's `sourceAccountDID` lets Plan 4 remove only account-derived recents.

- [ ] **Step 4: Implement the repository and collection surface**

`PublicRepositoryView` shows handle, DID, target PDS, handle-correctness warning, and a SwiftUI `Table` of every `describeRepo.collections` value. Activating a row awaits `PublicRepositoryOpenCoordinator.openCollection`; the route changes only after `PublicRepositoryStore.loadCollection(_:)` creates the correctly scoped store and completes its first page. Unknown collections use their exact NSID as title and remain selectable. Selection is a `ResourceReference.collection`, never a bare NSID.

```swift
public struct CollectionRow: Identifiable, Hashable, Sendable {
    public var id: String { reference.stableID }
    public let nsid: String
    public let title: String
    public let reference: ResourceReference
}

public enum KnownCollectionNames {
    private static let titles = [
        "app.bsky.feed.post": "Posts",
        "app.bsky.actor.profile": "Profile"
    ]
    public static func title(for nsid: String) -> String? { titles[nsid] }
}

public enum PublicRepositoryPresentation {
    public static func collections(_ description: RepositoryDescription) -> [CollectionRow] {
        description.collections.map { nsid in
            CollectionRow(
                nsid: nsid,
                title: KnownCollectionNames.title(for: nsid) ?? nsid,
                reference: .collection(
                    scope: description.repository.scope,
                    collection: nsid
                )
            )
        }
    }
}
```

All other collection inputs return nil and therefore display the exact NSID.

`BrowserTableShell` renders these state rules:

```swift
switch state {
case .idle, .loading(previous: nil):
    ProgressView("Loading repository…")
case .loaded(let snapshot):
    content(snapshot)
case .loading(previous: let snapshot?):
    content(snapshot).overlay(alignment: .topTrailing) { ProgressView().controlSize(.small) }
case .failed(previous: let snapshot?, failure: let failure):
    content(snapshot).safeAreaInset(edge: .top) {
        InlineErrorBanner(message: failure.localizedDescription, actionTitle: "Retry", retry: retry)
    }
case .failed(previous: nil, failure: let failure):
    UnavailableStateView(failure: failure, retry: retry)
}
```

The breadcrumb displays handle-or-DID, **Public Records**, and the selected collection; all protocol identifiers remain copyable. Every segment is a `Button`: clicking the repository segment navigates to the one-component prefix, clicking the collection segment preserves the current path, and no breadcrumb reconstructs a scope from display text. Toolbar Back and Forward buttons call `session.goBack()`/`goForward()`, expose disabled states from `canGoBack`/`canGoForward`, and have Command-[ and Command-] commands.

Add a focused scene refresh action so Command-R and the toolbar refresh control affect only the active browser route:

```swift
@MainActor
public struct BrowserRefreshAction: Sendable {
    public let perform: @MainActor @Sendable () async -> Void
    public init(perform: @escaping @MainActor @Sendable () async -> Void) {
        self.perform = perform
    }
}

extension FocusedValues {
    @Entry var browserRefreshAction: BrowserRefreshAction?
}
```

`ContentBrowserView` publishes a repository action that awaits `PublicRepositoryStore.refresh()` at the repository root and a collection action that awaits `PublicRecordStore.refresh()` for a collection path. `ATProtoDriveCommands` reads `@FocusedValue(\.browserRefreshAction)`; it never looks up a global store. Reopening a recent row invokes the coordinator with its DID and stays in the current window's store.

- [ ] **Step 5: Pass presentation and store tests**

Run presentation tests:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-presentation-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests
```

Run store regressions in a separate fresh shell:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-store-regression.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicRecordStoreTests
```

Expected: PASS.

- [ ] **Step 6: Seal the task with jj**

```bash
jj status
jj diff --summary
jj describe -m "feat: browse public repository collections"
jj new
```

### Task 6: Add the sortable record table, search, pagination, and inspector

**Files:**
- Modify: `ATProtoDrive/Browser/SearchQuery.swift`
- Modify by the integration owner: `ATProtoDrive/Browser/MainWindowView.swift`
- Modify: `ATProtoDrive/Browser/BrowserTableShell.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRecordTable.swift`
- Modify by the integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDriveTests/PublicBrowserPresentationTests.swift`
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `PublicRecordStore`, `RecordRow.origin`, `BrowserSession.searchQuery`, and `ResourceReference.record`.
- Produces: `SearchQueryParser`, `SearchQuery.matches(record:)`, `PublicRecordItem`, `PublicRecordSurfaceState`, `RecordTimestampField`, `BrowserInspectorValue`, `BrowserInspectorProjection.record`, token-capable search, sortable source-labeled timestamps, explicit empty/unsupported states, automatic and explicit paging, qualified stable selection, and friendly/raw inspector sections.

- [ ] **Step 1: Add failing search and inspector tests**

```swift
@Test("record search combines text and collection token")
func recordSearch() {
    let did = ResolvedRepository.fixture.did
    let post = RecordRow.fixture(
        uri: "at://\(did)/app.bsky.feed.post/one",
        collection: "app.bsky.feed.post",
        rkey: "one",
        json: #"{"text":"macOS drive"}"#
    )
    let profile = RecordRow.fixture(
        uri: "at://\(did)/app.bsky.actor.profile/self",
        collection: "app.bsky.actor.profile",
        rkey: "self",
        json: #"{"displayName":"Drive"}"#
    )
    let query = SearchQuery(text: "drive", tokens: [.collection("app.bsky.feed.post")])
    #expect([post, profile].filter { query.matches(record: $0) } == [post])
}

@Test("typed search extracts supported tokens and reports unsupported ones")
func tokenSearch() {
    let query = SearchQueryParser.parse(
        "drive collection:app.bsky.feed.post owner:\(ResolvedRepository.fixture.did) mime:image/png"
    )
    #expect(query.text == "drive")
    #expect(query.tokens.contains(.collection("app.bsky.feed.post")))
    #expect(query.tokens.contains(.owner(ResolvedRepository.fixture.did)))
    #expect(query.unsupportedTokens(for: .publicRecord) == [.mimeType("image/png")])
}

@Test("timestamps retain source field labels and are never repository metadata")
func timestampProjection() {
    let row = RecordRow.fixture(
        uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one",
        json: #"{"createdAt":"2026-08-23T12:34:56Z","updatedAt":"not-a-date"}"#
    )
    let fields = RecordTimestampProjection.fields(in: row)
    #expect(fields.map(\.field) == ["createdAt"])
    #expect(fields.first?.sourceValue == "2026-08-23T12:34:56Z")
    #expect(!fields.contains { $0.field == "Modified" })
}

@Test("empty collection, no matches, and unsupported filter are distinct")
func emptyAndUnsupportedStates() {
    #expect(PublicRecordPresentation.surface(
        rows: [], repository: .fixture, query: .init()
    ) == .emptyCollection)
    #expect(PublicRecordPresentation.surface(
        rows: [.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one")],
        repository: .fixture,
        query: .init(text: "absent")
    ) == .noMatches)
    #expect(PublicRecordPresentation.surface(
        rows: [],
        repository: .fixture,
        query: .init(tokens: [.space("at://did:plc:z72i7hdynmk6r22z27h6tvur/space/type/key")])
    ) == .unsupportedTokens([.space("at://did:plc:z72i7hdynmk6r22z27h6tvur/space/type/key")]))
}

@Test("inspector keeps friendly and exact public identity")
func inspectorProjection() {
    let row = RecordRow.fixture(uri: "at://\(ResolvedRepository.fixture.did)/app.test.item/one", collection: "app.test.item", rkey: "one")
    let locator = RecordLocator(
        scope: ResolvedRepository.fixture.scope,
        uri: row.uri,
        collection: row.collection,
        rkey: row.rkey,
        cid: row.cid
    )
    let value = BrowserInspectorProjection.record(row, locator: locator)
    #expect(value.access == .publicRepository(did: ResolvedRepository.fixture.did))
    #expect(value.fields["URI"] == row.uri)
    #expect(value.fields["CID"] == row.cid)
    #expect(value.rawJSON == row.json)
}
```

- [ ] **Step 2: Run the presentation suite and observe failure**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-record-presentation-fail.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests
```

Expected: FAIL because query parsing/matching, timestamp/surface projections, and qualified inspector projection are missing.

- [ ] **Step 3: Implement deterministic search and sorting**

`SearchToken` defines `.source(String)`, `.account(String)`, `.space(String)`, `.owner(String)`, `.collection(String)`, `.kind(String)`, `.mimeType(String)`, and `.transferState(String)` so later plans extend behavior without renaming the type. `SearchQueryParser.parse(_:)` recognizes case-insensitive `source:`, `account:`, `space:`, `owner:`, `collection:`, `kind:`, `mime:`, and `state:` prefixes, supports a quoted value with backslash-escaped quote/backslash, and leaves an unterminated or unknown prefix in free text. Tokens keep their original value but keys are normalized. Tests cover repeated tokens, quoted values containing spaces, escaped quotes, unknown prefixes, and blank input.

Public records evaluate free text case-insensitively against collection, rkey, URI, CID, and raw JSON; `.collection` and `.owner` tokens are exact case-insensitive matches. `.source(public)`, `.kind(record)`, and a matching connected-account token are supported. `unsupportedTokens(for: .publicRecord)` returns `.space`, `.mimeType`, `.transferState`, and any source/kind value that does not describe this surface. The view renders an explicit unsupported-filter state with removable token chips before matching; it never mislabels unsupported search as an empty collection.

```swift
public extension SearchQuery {
    func matches(record: RecordRow, repository: ResolvedRepository? = nil) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let textMatches = needle.isEmpty || [
            record.collection, record.rkey, record.uri, record.cid, record.json
        ].contains { $0.lowercased().contains(needle) }
        guard textMatches else { return false }
        return tokens.allSatisfy { token in
            switch token {
            case .collection(let value):
                return record.collection.caseInsensitiveCompare(value) == .orderedSame
            case .owner(let value):
                let owner: String?
                switch record.origin {
                case .publicRepository(let did): owner = did
                case .space(_, let repoDID): owner = repoDID
                case .unknown: owner = nil
                }
                return owner?.caseInsensitiveCompare(value) == .orderedSame
            case .source(let value):
                return value.caseInsensitiveCompare("public") == .orderedSame
            case .kind(let value):
                return value.caseInsensitiveCompare("record") == .orderedSame
            case .account(let value):
                return repository?.connectedAccountDID?.caseInsensitiveCompare(value) == .orderedSame
            case .space, .mimeType, .transferState:
                return false
            }
        }
    }
}
```

Build fully qualified table rows before rendering:

```swift
public struct PublicRecordItem: Identifiable, Hashable, Sendable {
    public let record: RecordRow
    public let reference: ResourceReference
    public var id: String { reference.stableID }

    public init(record: RecordRow, repository: ResolvedRepository) {
        let locator = RecordLocator(
            scope: repository.scope,
            uri: record.uri,
            collection: record.collection,
            rkey: record.rkey,
            cid: record.cid
        )
        self.record = record
        self.reference = .record(locator)
    }
}

public enum PublicRecordSurfaceState: Equatable, Sendable {
    case rows([PublicRecordItem])
    case emptyCollection
    case noMatches
    case unsupportedTokens([SearchToken])
}

public enum SearchSurface: Hashable, Sendable {
    case publicRecord
}

public struct RecordTimestampField: Hashable, Sendable {
    public let field: String
    public let date: Date
    public let sourceValue: String
}
```

Extend `PublicRecordPresentation` with `surface(rows:repository:query:)`. It checks unsupported tokens first, then projects rows to `PublicRecordItem`, then distinguishes a truly empty collection from nonempty input filtered to no matches; content returns `.rows`. This precedence is covered with empty input plus an unsupported token.

Render `.emptyCollection` as **No records in this collection**, `.noMatches` as **No records match this search** with **Clear Search**, and `.unsupportedTokens` as **This filter is not available for public records** with one removable chip per unsupported token. None of these states uses `LoadState.failed`, and a failed load is never rendered as any empty state.

`RecordTimestampProjection` decodes only top-level JSON string fields and accepts strict RFC 3339/ISO 8601 values with or without fractional seconds. It returns fields in lexical field order for deterministic rendering. Column labels are the exact source keys such as **createdAt**; never call them **Created**, **Modified**, or repository timestamps. Invalid, nested, numeric, or missing values do not create a column. Add sorting tests for mixed missing/valid values and equal timestamps.

`PublicRecordTable` uses SwiftUI `Table` columns **Type**, **Record Key**, **URI**, **CID**, plus those source-labeled timestamp columns. Sort a presentation copy, never the store's paging order. Use token-capable `.searchable(text:tokens:placement:prompt:token:)`, with suggestions for the supported public tokens and removable chips for every parsed token. The table binding may expose `Set<PublicRecordItem.ID>` only at SwiftUI's edge; immediately map each selected ID through the current `[PublicRecordItem.ID: ResourceReference]` table and call `session.replaceSelection(with:)` with qualified values. No record URI or rkey is ever stored as an unqualified selection.

Keep the session's complete qualified selection separate from the currently visible-ID intersection. On a user change, compute `visibleUniverse = Set(items.map(\.reference))`, retain `Set(session.selectedReferences.values).subtracting(visibleUniverse)`, union only IDs successfully mapped to current `ResourceReference` values, and pass that set to `replaceSelection(with:)`. Filtering and sorting update only the visible projection and do not write an empty selection back. After a successful refresh, rebuild the exact available `Set<ResourceReference>` from store rows and prune only selected record references in the current collection whose `(scope, URI, CID)` disappeared; page append never prunes. Add tests for filter-away/filter-back, sort, append, unchanged refresh, and same-URI/new-CID refresh.

- [ ] **Step 4: Wire accessible and automatic pagination**

The last visible row starts `loadNextPage()` only when `canLoadMore` and no page is running. The table footer always provides an explicit **Load More** button under the same guard. When `appendFailure` and `retryCursor` are set, current rows remain visible and the footer changes to **Retry Page**; that button calls `retryFailedPage()` and cannot call ordinary `loadNextPage()`. Tests assert the retry sends the exact failed opaque cursor and does not duplicate successful rows. Cursor values never appear as labels, errors, logs, or analytics.

- [ ] **Step 5: Implement the optional inspector**

For one public record, show Preview/Summary first, then Identity & Location, Access, Blob References (known references only; mark the index incomplete until Plan 3), Raw JSON, and exact URI/CID/DID/collection/rkey/PDS endpoint. Render JSON as selectable monospaced text. Do not use `WKWebView`, and do not add HTML/SVG preview here. Multi-selection shows count and common source; no selection shows a quiet prompt. Add toolbar and View-menu commands for Toggle Inspector and Focus Search.

```swift
public struct BrowserInspectorValue: Equatable, Sendable {
    public let access: AccessClassification?
    public let fields: [String: String]
    public let rawJSON: String
}

public enum BrowserInspectorProjection {
    public static func record(_ row: RecordRow, locator: RecordLocator) -> BrowserInspectorValue {
        let access: AccessClassification?
        switch row.origin {
        case .publicRepository(let did): access = .publicRepository(did: did)
        case .space(let space, let repoDID):
            access = .permissionedSpace(spaceURI: space.uriString(), writerDID: repoDID)
        case .unknown: access = nil
        }
        precondition(locator.uri == row.uri && locator.cid == row.cid)
        return .init(
            access: access,
            fields: [
                "URI": locator.uri,
                "CID": locator.cid,
                "Collection": locator.collection,
                "Record Key": locator.rkey,
                "Repository Scope": locator.scope.stableID
            ],
            rawJSON: row.json
        )
    }
}
```

The UI never invents a classification for `.unknown`: if it is encountered, show **Source unavailable** and disable source-sensitive actions. Public rows from Task 2 always carry a real DID.

Replace Task 4's temporary no-selection inspector in `MainWindowView` with:

```swift
BrowserInspectorView(
    reference: session.primarySelection,
    record: session.primarySelection.flatMap(publicRepositoryStore.record(for:))
)
.inspectorColumnWidth(min: 260, ideal: 340, max: 480)
```

When `reference` is `.record(let locator)`, enrich the inspector with the locator's complete scope; for `.publicRepository(_, let pdsURL)`, add `"PDS": pdsURL.absoluteString` to Identity & Location.

- [ ] **Step 6: Pass presentation, store, and domain tests**

Run the presentation suite:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-record-presentation-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests
```

Run store and domain regressions in a separate fresh shell:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-record-regression.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicRecordStoreTests -only-testing:ATProtoDriveTests/BrowserDomainTests
```

Expected: PASS.

- [ ] **Step 7: Seal the task with jj**

```bash
jj status
jj diff --summary
jj describe -m "feat: add public record table and inspector"
jj new
```

### Task 7: Add a deterministic no-account public-browser fixture and runtime checkpoint

**Files:**
- Modify: `ATProtoDrive/Debug/PublicBrowserFixture.swift`
- Modify by the integration owner: `ATProtoDrive/ATProtoDriveApp.swift`
- Modify: `ATProtoDrive/Browser/MainWindowView.swift`
- Modify: `ATProtoDriveTests/PublicBrowserFixtureTests.swift`
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `PublicRepositoryServing`, `BrowserSession`, `PublicRepositoryStore`, `RecentRepositoryStore`, and the complete public browser UI.
- Produces: `ATPROTODRIVE_FIXTURE_MODE=public-browser`, one app-scoped deterministic fixture service, per-scene session/store/bootstrap state, bounded readiness, deterministic pages, an initial open repository, and reproducible 1280x800 screenshot evidence.

- [ ] **Step 1: Write the failing fixture traversal test**

```swift
@MainActor
@Test("one app-scoped fixture service drives isolated, bounded scene state")
func fixtureTraversal() async throws {
    let service = FixturePublicRepositoryService()
    let recents = RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
    let first = BrowserFixtureScene(service: service, recents: recents)
    let second = BrowserFixtureScene(service: service, recents: recents)
    try await first.bootstrap(timeout: .seconds(1))
    #expect(PublicBrowserFixture.accounts.isEmpty)
    #expect(first.readiness == .ready)
    #expect(second.readiness == .idle)
    #expect(second.repositoryStore.target == nil)
    #expect(recents.entries.map(\.did) == [PublicBrowserFixture.did])
    let description = try #require(first.repositoryStore.state.snapshot)
    #expect(description.collections == ["app.bsky.feed.post", "com.example.drive.file"])
    let records = try #require(first.repositoryStore.recordStore(for: "app.bsky.feed.post"))
    while records.canLoadMore { await records.loadNextPage() }
    #expect(records.rows.map(\.rkey) == ["first", "second", "third"])
    #expect(first.session.primarySelection?.stableID.contains(description.repository.scope.stableID) == true)
}

@MainActor
@Test("fixture bootstrap times out with a visible typed failure")
func fixtureTimeout() async {
    let service = NeverCompletingPublicRepositoryService()
    let scene = BrowserFixtureScene(
        service: service,
        recents: RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())
    )
    await #expect(throws: BrowserFailure.transport("Fixture readiness timed out")) {
        try await scene.bootstrap(timeout: .milliseconds(20))
    }
    #expect(scene.readiness.isFailure)
}
```

- [ ] **Step 2: Run the fixture suite and observe failure**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-fixture.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicBrowserFixtureTests
```

Expected: FAIL because `FixturePublicRepositoryService`, `BrowserFixtureScene`, and bounded fixture bootstrap are undefined.

- [ ] **Step 3: Implement deterministic fixture injection**

Under `#if DEBUG`, implement an actor conforming to `PublicRepositoryServing` with one valid resolved DID/PDS, two collections, three records split across opaque cursors, one unknown `$type`, and one final empty page. `ATProtoDriveApp` reads only the exact environment value `ATPROTODRIVE_FIXTURE_MODE=public-browser`. In fixture mode, the app owns exactly one `FixturePublicRepositoryService` plus one `RecentRepositoryStore(persistence: MemoryRecentRepositoryPersistence())` and skips `AccountStore.restore()`; each `WindowGroup` scene still constructs its own `BrowserSession`, `PublicRepositoryStore`, and `FixtureReadiness` through `BrowserSceneRoot`. Normal launches own one stateless `PublicRepositoryService` plus `RecentRepositoryStore(persistence: try FileRecentRepositoryPersistence.live())`, create the same per-scene state, and restore accounts/recents.

```swift
#if DEBUG
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
    public static let accounts: [SidebarAccountSummary] = []

    @MainActor
    public static func bootstrap(
        session: BrowserSession,
        repositoryStore: PublicRepositoryStore,
        recentRepositoryStore: RecentRepositoryStore,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await PublicRepositoryOpenCoordinator.open(
                    .publicIdentifier("fixture.test"),
                    store: repositoryStore,
                    session: session,
                    recents: recentRepositoryStore
                )
                await PublicRepositoryOpenCoordinator.openCollection(
                    "app.bsky.feed.post",
                    store: repositoryStore,
                    session: session
                )
                guard let store = repositoryStore.recordStore(for: "app.bsky.feed.post"),
                      let first = store.rows.first,
                      let repository = repositoryStore.state.snapshot?.repository else {
                    throw BrowserFailure.decodeFailure(endpoint: "fixture.bootstrap", statusCode: 200)
                }
                let item = PublicRecordItem(record: first, repository: repository)
                session.replaceSelection(with: [item.reference])
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BrowserFailure.transport("Fixture readiness timed out")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

public actor FixturePublicRepositoryService: PublicRepositoryServing {
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
        return .init(
            uri: "at://\(repository.did)/\(collection)/\(rkey)",
            collection: collection,
            rkey: rkey,
            cid: cidByKey[rkey] ?? "bafyreifxe4xz3d6bcj47ctgoq7tnifjzrcqsnfcqghzcte7pfssbhzuoee",
            json: "{\n  \"$type\": \"\(type)\",\n  \"name\": \"\(rkey.capitalized)\"\n}",
            origin: .publicRepository(did: repository.did)
        )
    }
}
#endif
```

Use this test harness in `PublicBrowserFixtureTests.swift`:

```swift
@MainActor
final class BrowserFixtureScene {
    let session = BrowserSession()
    let repositoryStore: PublicRepositoryStore
    let recentRepositoryStore: RecentRepositoryStore
    private(set) var readiness: FixtureReadiness = .idle

    init(service: any PublicRepositoryServing, recents: RecentRepositoryStore) {
        repositoryStore = PublicRepositoryStore(service: service)
        recentRepositoryStore = recents
    }

    func bootstrap(timeout: Duration) async throws {
        readiness = .loading
        do {
            try await PublicBrowserFixture.bootstrap(
                session: session,
                repositoryStore: repositoryStore,
                recentRepositoryStore: recentRepositoryStore,
                timeout: timeout
            )
            readiness = .ready
        } catch {
            let failure = BrowserFailure.normalize(error)
            readiness = .failed(failure)
            throw failure
        }
    }
}
```

`NeverCompletingPublicRepositoryService.resolve(target:)` suspends with `try await Task.sleep(for: .seconds(60))`, so cancellation from the timeout completes promptly; its other protocol methods throw `BrowserFailure.unsupported("Unexpected fixture operation")`. `BrowserSceneRoot` follows the same readiness transitions as the harness, renders a failure inline, and sets `.accessibilityIdentifier("public-browser-ready")` only after bootstrap returns successfully. The timeout task is always cancelled after the work task wins, and the work task checks cancellation after every await. Set the window scene's default size to 1280x800 without fixing or disabling user resizing.

- [ ] **Step 4: Pass fixture and all public-browser suites**

Run the fixture plus every public-browser suite in one fresh shell:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-fixture-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/BrowserDomainTests -only-testing:ATProtoDriveTests/DIDDocumentPDSResolverTests -only-testing:ATProtoDriveTests/PublicRepositoryServiceTests -only-testing:ATProtoDriveTests/PublicRecordStoreTests -only-testing:ATProtoDriveTests/DriveSidebarTests -only-testing:ATProtoDriveTests/RecentRepositoryStoreTests -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests -only-testing:ATProtoDriveTests/PublicBrowserFixtureTests
```

Expected: PASS with no live network, Keychain, OAuth, account restore, or production-preference access.

- [ ] **Step 5: Build, launch, navigate, and capture the runtime checkpoint**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-runtime.XXXXXX)"
ATD_DERIVED="$VERIFY_ROOT/DerivedData"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO build
ATPROTODRIVE_FIXTURE_MODE=public-browser \
  "$ATD_DERIVED/Build/Products/Debug/ATProtoDrive.app/Contents/MacOS/ATProtoDrive" \
  >"$VERIFY_ROOT/app.log" 2>&1 &
ATD_PID=$!
/usr/bin/osascript -e 'tell application "ATProtoDrive" to activate'
ATD_READY=false
for ATTEMPT in {1..40}; do
  ATD_READY="$(/usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "ATProtoDrive"
    if not (exists window 1) then return "false"
    return (exists (first UI element of entire contents of window 1 whose value of attribute "AXIdentifier" is "public-browser-ready")) as string
  end tell
end tell
APPLESCRIPT
)"
  if [[ "$ATD_READY" == "true" ]]; then break; fi
  /bin/sleep 0.25
done
if [[ "$ATD_READY" != "true" ]]; then
  kill "$ATD_PID"
  wait "$ATD_PID" 2>/dev/null || true
  exit 1
fi
/usr/sbin/screencapture -x "$VERIFY_ROOT/public-browser.png"
kill "$ATD_PID"
wait "$ATD_PID" 2>/dev/null || true
```

Expected: BUILD SUCCEEDED; readiness appears within 10 seconds or the command fails; the app remains alive until stopped; the screenshot shows the source sidebar, opened/recent repository row, collection/record browser, toolbar token search, clickable breadcrumb, and optional inspector at 1280x800. Repeat the complete fresh-shell launch once with the inspector hidden and once with **File > New Window**; select a different collection in each window and confirm neither selection nor target/store state changes the other. Inspect `app.log` for crashes, assertion failures, token text, record bodies, or unexpected network calls; none are acceptable.

- [ ] **Step 6: Seal the task with jj**

```bash
jj status
jj diff --summary
jj describe -m "test: add deterministic public browser runtime"
jj new
```

### Task 8: Run the public-browser acceptance gate and document the handoff

**Files:**
- Modify only if a command or observed behavior changed: `docs/superpowers/plans/2026-08-23-atprotodrive-v1-public-browser.md`
- Do not modify: product sources unless a failing gate sends work back to the owning task
- Do not modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: every artifact from Tasks 1-7.
- Produces: current-worktree unit, build, launch, screenshot, live-public, and regression evidence for the next three implementation plans.

- [ ] **Step 1: Run the complete Plan 1 deterministic matrix without touching production preferences**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-acceptance.XXXXXX)"
ATD_DERIVED="$VERIFY_ROOT/DerivedData"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ATD_DERIVED" \
  -resultBundlePath "$VERIFY_ROOT/UnitTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:ATProtoDriveTests/BrowserDomainTests \
  -only-testing:ATProtoDriveTests/DIDDocumentPDSResolverTests \
  -only-testing:ATProtoDriveTests/PublicRepositoryServiceTests \
  -only-testing:ATProtoDriveTests/PublicRecordStoreTests \
  -only-testing:ATProtoDriveTests/DriveSidebarTests \
  -only-testing:ATProtoDriveTests/RecentRepositoryStoreTests \
  -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests \
  -only-testing:ATProtoDriveTests/PublicBrowserFixtureTests \
  -only-testing:ATProtoDriveTests/RecordListModelTests \
  -only-testing:ATProtoDriveTests/RecordListModelPipelineTests \
  -only-testing:ATProtoDriveTests/RepoVerifierTests
```

Expected: TEST SUCCEEDED. This deliberate matrix excludes `AccountStoreTests`, `SpaceListModelTests`, `SpaceDetailModelTests`, and `WritePipelineTests` because the baseline versions mutate production `UserDefaults.standard` keys, and excludes the opt-in live OAuth test. Do not substitute a full-target run until Plan 2 Task 1 has isolated Space persistence and Plan 2 Task 4 has isolated account preferences and explicitly gated live authentication.

- [ ] **Step 2: Verify one current public PDS without signing in**

Launch the normally configured app, leave Accounts empty, choose **Open Public Repository**, enter a current public handle, and record the resolved DID and PDS from the inspector. Close that route and repeat with the exact DID; it must resolve to the same secure PDS without requiring a declared handle. Open the first and last reported collections, load through their terminal pages, inspect raw JSON, then disable networking and Refresh. Expected: the loaded rows remain visible under a stale/offline banner and Retry succeeds after networking returns. Record the handle, DID, observation time, origin-only PDS endpoint, and whether the DID was `did:plc` or hostname-level `did:web`; do not claim live Spaces evidence in this plan.

- [ ] **Step 3: Audit the hard public/private and UX boundaries**

Confirm from code and runtime evidence:

- no `PublicRepositoryService` initializer or method accepts `AccountStore.Account`, authenticated `ATProtoClient`, token, DPoP material, or `SpaceCredentialManager`;
- `DIDDocumentPDSResolver` supports `did:plc` and hostname-level `did:web`, rejects path-form `did:web` and non-local encoded ports, gates localhost behind explicit development policy, requires exact document identity plus an origin-only allowed `#atproto_pds`, and never selects `#atproto_space_host`;
- every public record selection and locator includes the resolved PDS-qualified `RepositoryScope`; this plan has no public blob fetch or inventory API;
- no-account Open Public Repository remains enabled;
- window-opened and app-scoped recent repositories are visibly merged in the sidebar; recents use versioned atomic persistence and always re-resolve DID/PDS before opening;
- two windows have independent source, target/store cache, path, qualified record selection, search, sort, history, opened rows, and inspector visibility while intentionally sharing durable recents;
- the root has two navigation columns and one optional inspector, with no nested `HSplitView` in the public route;
- Back, Forward, clickable breadcrumb prefixes, and focused Refresh affect only the active scene and route;
- unknown collections and unknown JSON fields remain visible;
- a 2xx/nil response produces a visible failure and never an empty success;
- stale refresh leaves the previous snapshot visible;
- append failure retains the exact retry cursor and rows; pagination preserves opaque cursors, accepts empty intermediate pages, stops cycles, and removes duplicate `(URI,CID)` rows;
- empty collection, no search matches, stale, failed, and unsupported-token states are visually distinct;
- token-capable search and source-labeled record timestamp columns never imply repository modification time;
- records expose exact URI, CID, DID, collection, rkey, PDS, access class, and raw JSON;
- the legacy Space adapter resolves only the selected account and exposes no mutation action;
- Space mutation, account deletion, migration, import, restore, backups, transfers, and blob inventory have not leaked into this plan.

- [ ] **Step 4: Run a final build and inspect the jj delta**

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-public-final-build.XXXXXX)"
ATD_DERIVED="$VERIFY_ROOT/DerivedData"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO build
jj status
jj diff --summary
```

Expected: BUILD SUCCEEDED; the delta contains only this public-browser foundation and its evidence/documentation changes.

- [ ] **Step 5: Seal the acceptance evidence with jj**

```bash
jj status
jj diff --summary
jj describe -m "docs: record public browser acceptance evidence"
jj new
```

## Coverage and Acceptance Checklist

- [ ] Public handle and DID resolution works without an account and always targets the resolved PDS anonymously.
- [ ] `did:plc` and hostname-level `did:web` resolution validates the exact document ID and an origin-only HTTPS `#atproto_pds` without requiring a handle; path-form/non-local-port DIDs and path-prefixed PDS endpoints are rejected, and localhost works only under explicit development policy.
- [ ] `describeRepo` renders every reported collection, including unknown NSIDs.
- [ ] Each collection starts with one page and appends on demand without eager repository-wide loading.
- [ ] Opaque cursors, empty intermediate pages, duplicate rows, and cursor cycles have deterministic tests.
- [ ] Append failure retains its exact cursor and offers one explicit retry without losing visible rows.
- [ ] Failed opens and refreshes are visible; stale data remains visible and retryable.
- [ ] The public record table supports text and token search, source-labeled timestamp sorting, and distinct empty/no-match/unsupported states without mutating paging order or losing valid qualified selection.
- [ ] The inspector shows friendly context followed by raw JSON and exact identifiers/access classification.
- [ ] No-account sidebar utilities, visible opened/recent repositories, account Public Records, and account-bound read-only legacy Space compatibility remain reachable.
- [ ] Each window owns an independent `BrowserSession` and `PublicRepositoryStore`; accounts, durable recents, and the stateless service remain app-scoped.
- [ ] The running macOS app has bounded-readiness screenshot evidence for sidebar, table, token search, clickable breadcrumbs, and inspector.
- [ ] Every Plan 1 suite and safe baseline regression is green; production-preference suites remain explicitly deferred until Plan 2 Tasks 1 and 4 seal their Space and account isolation changes.

## Dependencies and Handoff

Implementation order is strict: Tasks 1-3 establish shared types and anonymous data access; Tasks 4-6 build the window and public UI; Tasks 7-8 provide deterministic and live evidence. Do not start sibling plan implementation until Task 3 has sealed its interfaces.

The next plans consume this one as follows:

1. `2026-08-23-atprotodrive-v1-spaces-crud.md` replaces `LegacySpacesCompatibilityView`, uses `BrowserSource`/`BrowserPath`/`RecordOrigin.space`, may reuse `DIDDocumentPDSResolving` only for writer `#atproto_pds` routing, resolves Space authority hosts separately, and must keep Space credentials out of `PublicRepositoryService`. Plan 1 owns the original declarations in `Domain/ResourceReference.swift` and `Browser/BrowserSession.swift` through its Task 8 seal; Plan 2 then becomes the sole follow-on editor of those two files and extends the existing types instead of redeclaring or shadowing them. Plan 2 must update every exhaustive `ResourceReference`, `RepositoryScope`, path-scope, stable-ID, and selection switch for its added Space behavior. Its gate must construct otherwise identical permissioned scopes/record references for two different `accountDID` values and prove stable IDs, `BrowserSession` selection acceptance, lookup, and cache routing remain account-qualified with no crossover.
2. `2026-08-23-atprotodrive-v1-files-backups-transfers.md` consumes `RepositoryScope`, `RecordLocator`, `BlobLocator`, `ResourceReference`, and `AccessClassification`; it adds the qualified blob index and preview/download services without changing public record routing.
3. `2026-08-23-atprotodrive-v1-account-acceptance.md` supplies `AccountConnectionStatus`, deterministic full-app UI tests, commands, and final screenshots; its local account cleaner calls `RecentRepositoryStore.removeEntries(sourceAccountDID:)`, preserves anonymous recents, and must preserve per-window `BrowserSession` ownership plus the no-account public path proven here.

If a later plan needs a new source kind or search token, add a case while preserving the names and meaning above. Do not merge public and Space services behind a mode flag.

## Acceptance evidence (2026-08-23)

- Step 1 deterministic matrix: TEST SUCCEEDED — 131 tests, 11 suites, 0 failures (fresh DerivedData, unsigned).
- Step 3 code-boundary audit: 10/10 claims verified against sources.
- Step 4 final build: BUILD SUCCEEDED; delta contains only the Tasks 1–7 seals.
- Step 2 and runtime screenshots: parked. Observed behavior change — fixture-mode launch raises a Keychain consent (AccountStore reads the current-DID item at init), and AppleScript UI driving raises a TCC consent; automated acceptance does not grant security consents. Live public browsing, offline/stale-banner proof, and UI screenshots require a consented manual session; Plan 4's signed runtime gate re-covers these surfaces.
