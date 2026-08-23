# ATProtoDrive v1 Files, Backups, and Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build qualified public/Space blob browsing, safe local preview and export, durable transfer orchestration, verified `.atprotodrivebackup` packages, attachment workflows, and access-aware cross-source copies.

**Architecture:** Blob identity is always `RepositoryScope + CID`; records, caches, previews, transfers, and backups never collapse that identity to a bare CID. `TransferQueue` is an app-scoped actor that persists value-only descriptors and checkpoints, while `TransferStore` projects snapshots to SwiftUI. `BackupService` exports one or more independently verified repository CARs, derives blob references from those exact snapshots, writes a qualified package through `AtomicPackageWriter`, and marks completion only after CAR and blob verification.

**Tech Stack:** Swift 6, SwiftUI and Observation, structured concurrency and actors, AppKit (`NSSavePanel`, `NSFilePromiseProvider`, `NSWorkspace`), Quick Look, Uniform Type Identifiers, Foundation file coordination and security-scoped bookmarks, CryptoKit, SQLite3 scratch indexes, Petrel, SwanSpaces, and the local Swan `SwanPublicRepository` product.

**Spec:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`

**Dependencies:** Execute after `2026-08-23-atprotodrive-v1-public-browser.md` and `2026-08-23-atprotodrive-v1-spaces-crud.md`. This plan consumes Plan 1's generic `DIDDocumentPDSResolving`, `AccessClassification`, `ResourceReference`, `BrowserItem`, `BrowserSession`, `LoadState`, `BrowserFailure`, `RecordOrigin`, `RecordRow`, and `PublicRepositoryService`; and Plan 2's `SpaceRepositoryService`, `SpaceRepositoryServing.listWriters`, writer-host credential routing, protocol-profile/version gates, `AccessContext`, `AuthorizationScopePlanner`, and `MutationCoordinator`. It uses `SpaceRef` from SwanSpaces. Execute before `2026-08-23-atprotodrive-v1-account-acceptance.md`, which owns the final UI-test target, deterministic fixture launch mode, and whole-product screenshot/runtime gate.

## Global Constraints

- Deployment target remains macOS 15.0 and the code must compile under Swift 6 strict concurrency.
- Keep public repository and permissioned Space network services, authorization, cache roots, temporary files, and backup paths concrete and separate.
- Use this exact operational identity:

  ```swift
  public enum RepositoryScope: Hashable, Codable, Sendable {
    case publicRepository(did: String, pdsURL: URL)
    case permissionedSpace(spaceURI: String, writerDID: String, accountDID: String)
  }
  ```

- Key every blob, reference-index, preview, transfer, and backup artifact by `RepositoryScope` plus CID. A CID by itself is never a key.
- `AccessClassification` is the user-facing and persisted trust label; `RepositoryScope` is the operational routing identity. Do not replace either with `isPrivate`.
- Permissioned blob reads always use `com.atproto.space.listBlobs` and `com.atproto.space.getBlob` with a Space credential. Never retry them through `com.atproto.sync.*`.
- Public reads use an unauthenticated target-PDS client. Public writes and uploads use the exact connected-account client selected by DID; never fall back to the active account.
- The generated Petrel blob/CAR endpoints currently buffer `Data`; do not use those generated convenience methods for blob or CAR payloads. The transport layer in Task 2 streams bounded chunks directly to a destination, updates SHA-256 and expected-CID verification incrementally, synchronizes the destination, and atomically publishes it. Public streaming remains anonymous. Space streaming reuses Plan 2's exact writer-host resolver and `SpaceCredentialManager` DPoP route.
- Preserve every blob-reference occurrence and its RFC 6901 JSON Pointer. Do not deduplicate occurrences that share a CID.
- Preview bytes live under a data-plane-qualified temporary root. HTML and SVG are download-only and never enter Quick Look or a web view.
- Durable jobs persist descriptors, component checkpoints, hashes, redacted errors, and security-scoped bookmarks only. Never persist `ATProtoClient`, Space credentials, OAuth tokens, raw record bodies, or blob bytes in transfer metadata.
- `TransferState` has exactly these cases: `queued`, `discovering`, `waitingForPermission`, `running`, `verifying`, `completed`, `interrupted`, `cancelled`, and `failed`.
- A CAR export does not include blob payloads and is not a complete backup. CAR authenticity verification and blob content hashing are separate stages.
- Backup packages use the `.atprotodrivebackup` extension and the logical layout approved in the spec. Do not introduce `.atpbackup` or a different extension.
- Whole-Space completion is qualified against the fully paginated authority-claimed writer set. It is not a globally atomic snapshot, current membership proof, or a single cross-host instant.
- No restore, import, migration, generic blob deletion, or atomic cross-repository move surface is added.
- Keep existing loaded content visible when refresh fails. Use `LoadState` and `BrowserFailure`; do not translate a failed refresh into an empty success.
- This project uses classic `PBXGroup` and `PBXSourcesBuildPhase` entries. The one cross-plan integration owner named by the plan index is the sole editor of `ATProtoDrive.xcodeproj/project.pbxproj`, shared schemes, `ATProtoDrive/ATProtoDriveApp.swift`, and root `ATProtoDrive/Browser/ContentBrowserView.swift`. Every feature task hands that owner its exact app/test membership and shared-file change list; the owner lands that wiring in the same task change before its build/test gate and seal. Feature workers never create alternate PBX edits or compile-only stubs.
- Task 9 is the sole owner of `ATProtoDrive/ATProtoDrive.entitlements`. Task 10 is the sole owner of the `SwanPublicRepository` package-product link. Other tasks must not rewrite either configuration.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`) and UUID-qualified temporary directories. Do not use shared fixed paths under `/tmp`.
- Seal each task with the concrete `jj describe` message shown in that task, then run its `jj new` immediately before reporting.

---

## File Map

### Blob domain and services

- Create `ATProtoDrive/Blobs/BlobTypes.swift` — blob reference, inventory, availability, and verification domain values built on Plan 1's qualified locators.
- Create `ATProtoDrive/Blobs/BlobReferenceScanner.swift` — recursive AT Protocol value traversal with RFC 6901 pointer emission.
- Create `ATProtoDrive/Blobs/BlobReferenceIndex.swift` — actor-backed reverse index scoped by repository.
- Create `ATProtoDrive/Blobs/RecordInventoryScanner.swift` — qualified public/Space collection-and-record pagination feeding the reverse index.
- Create `ATProtoDrive/Support/StreamingArtifactDestination.swift` — bounded file destination, incremental SHA-256/CID verification, fsync, and atomic replacement.
- Create `ATProtoDrive/Blobs/PublicBlobService.swift` — anonymous `com.atproto.sync.listBlobs/getBlob` adapter.
- Create `ATProtoDrive/Blobs/SpaceBlobService.swift` — credentialed `com.atproto.space.listBlobs/getBlob` adapter.
- Modify `../Petrel/Sources/Petrel/Auth/Space/SpaceCredentialManager.swift` — add credentialed bounded streaming GET without weakening redirect/DPoP rules.
- Create `../Petrel/Tests/PetrelTests/SpaceCredentialStreamingTests.swift` — prove bounded delivery, exact HTU/path, DPoP route, and cancellation.
- Create `ATProtoDrive/Blobs/BlobInventoryStore.swift` — pagination, deduplication, progress, reference-scan completeness, and stale-state preservation.
- Create `ATProtoDrive/Blobs/BlobBrowserView.swift` — typed sortable blob table.
- Create `ATProtoDrive/Blobs/BlobInspectorView.swift` — preview, references, integrity, and exact identifiers.
- Create `ATProtoDrive/Blobs/PreviewPolicy.swift` — safe preview/download disposition.
- Create `ATProtoDrive/Blobs/QualifiedTemporaryFileStore.swift` — scope-digested preview materialization and cleanup.
- Create `ATProtoDrive/Blobs/QuickLookCoordinator.swift` — window-scoped `.quickLookPreview` URL ownership.
- Create `ATProtoDrive/Blobs/SavePanelPresenter.swift` — asynchronous sheet-modal save destination selection.
- Create `ATProtoDrive/Blobs/PromisedFileDragSource.swift` — `NSFilePromiseProviderDelegate` bridge for drag-to-Finder copies.

### Transfers and attachment

- Create `ATProtoDrive/Transfers/TransferTypes.swift` — job kinds, exact states, endpoints, components, progress, snapshots, and redacted failures.
- Create `ATProtoDrive/Transfers/TransferPersistence.swift` — versioned atomic Application Support JSON repository.
- Create `ATProtoDrive/Support/PersistenceCoding.swift` — stable sorted-key/ISO-8601 JSON encoder and decoder used by transfer and backup formats.
- Create `ATProtoDrive/Transfers/TransferQueue.swift` — actor state machine, bounded scheduler, cancellation, retry, and component resume.
- Create `ATProtoDrive/Transfers/TransferStore.swift` — `@MainActor @Observable` read-only projection.
- Create `ATProtoDrive/Transfers/ActivityView.swift` — persistent activity table and controls.
- Create `ATProtoDrive/Transfers/ActivityInspectorView.swift` — stages, partial remote outcomes, components, and redacted errors.
- Create `ATProtoDrive/Transfers/AttachmentCoordinator.swift` — upload, draft insertion, record commit, and reachability verification.
- Create `ATProtoDrive/Transfers/CrossSourceCopyCoordinator.swift` — access transition analysis and non-atomic copy execution.
- Create `ATProtoDrive/Transfers/TransferExecutors.swift` — fixed kind-keyed executor registry and all six relaunch-reconstructable executors.
- Modify `ATProtoDrive/Records/RecordListModel.swift` — remove migrated blob/file helpers after all call sites use focused types.
- Modify `ATProtoDrive/Write/RecordEditorSheet.swift` — dispatch Attach File through the coordinator and display partial outcome.

### Backups and verification

- Create `ATProtoDrive/Backups/BackupManifest.swift` — format-version-1 Codable package contract.
- Create `ATProtoDrive/Backups/BackupTypes.swift` — requests, plans, repository/blob artifacts, completeness, and reports.
- Create `ATProtoDrive/Backups/RecordsIndex.swift` — readable record index derived from a verified CAR snapshot.
- Create `ATProtoDrive/Backups/AtomicPackageWriter.swift` — private sibling staging, durability, verification, and atomic publication.
- Create `ATProtoDrive/Backups/BackupPackageDocument.swift` — exported package UTType/document declarations and async save-panel request.
- Create `ATProtoDrive/Backups/SecurityScopedBookmarkStore.swift` — destination bookmark persistence and stale-bookmark refresh.
- Create `ATProtoDrive/Backups/BackupService.swift` — plan discovery and public/single-writer/whole-Space execution.
- Create `ATProtoDrive/Backups/VerifiedBackupPreflightProvider.swift` — complete/verified, exact-subject evidence for Plan 2's Back Up First gates.
- Create `ATProtoDrive/Backups/BackupCatalog.swift` — bookmark/recents-backed package catalog and package validation.
- Create `ATProtoDrive/Backups/BackupBrowserView.swift` — local package and records-index browser.
- Create `ATProtoDrive/Backups/BackupInspectorView.swift` — manifest, completeness, verification, reveal, and Trash controls.
- Create `ATProtoDrive/Verify/FileCARByteSource.swift` — bounded file reader shared by public and Space verification adapters.
- Create `ATProtoDrive/Verify/PublicCARVerifier.swift` — target-DID-bound public commit/MST/CID verification through SwanPublicRepository.
- Create `ATProtoDrive/Verify/SpaceCARFileVerifier.swift` — file source, disposable SQLite index, file sink, and current Space verification adapter.
- Modify `ATProtoDrive/Verify/RepoVerifier.swift` — retain signing-key parsing/report mapping while delegating file verification.
- Modify `ATProtoDrive/ATProtoDrive.entitlements` — add app-scoped security-scoped bookmark entitlement.
- Modify by the cross-plan integration owner: `ATProtoDrive/Info.plist` — exported `blue.catbird.atprotodrive.backup` package type and document declarations.
- Modify by the cross-plan integration owner: `ATProtoDrive/ATProtoDriveApp.swift` — inject one app-scoped queue/projection, route blob/backup/activity sources, and start restore/scheduling.
- Modify by the cross-plan integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift` — route Public Blobs, Space Blobs, Backups, and Activity to typed feature views.
- Modify `ATProtoDrive/Browser/BrowserInspectorView.swift` — route blob, backup, and transfer selection to feature inspectors.
- Hand to the cross-plan integration owner: every source/test membership, SQLite3 linkage if required by the selected Xcode SDK, and the single `SwanPublicRepository` product link in `ATProtoDrive.xcodeproj/project.pbxproj`.

### Tests

- Create `ATProtoDriveTests/BlobFixtureSupport.swift` — fixed qualified scopes/records, scripted list/stream transports, scanner pages, temporary roots, save/promise fixtures, and call recorders used only by Tasks 1–4.
- Create `ATProtoDriveTests/BlobReferenceIndexTests.swift`.
- Create `ATProtoDriveTests/RecordInventoryScannerTests.swift`.
- Create `ATProtoDriveTests/BlobServiceTests.swift`.
- Create `ATProtoDriveTests/BlobInventoryStoreTests.swift`.
- Create `ATProtoDriveTests/BlobLocalInteractionTests.swift`.
- Create `ATProtoDriveTests/TransferPersistenceTests.swift`.
- Create `ATProtoDriveTests/TransferQueueTests.swift`.
- Create `ATProtoDriveTests/AttachmentCoordinatorTests.swift`.
- Create `ATProtoDriveTests/BackupManifestTests.swift`.
- Create `ATProtoDriveTests/AtomicPackageWriterTests.swift`.
- Create `ATProtoDriveTests/PublicCARVerifierTests.swift`.
- Create `ATProtoDriveTests/SpaceCARFileVerifierTests.swift`.
- Create `ATProtoDriveTests/BackupServiceTests.swift`.
- Create `ATProtoDriveTests/BackupCatalogTests.swift`.
- Create `ATProtoDriveTests/BackupPreflightProviderTests.swift`.
- Create `ATProtoDriveTests/SpaceBlobCleanupTests.swift`.
- Create `ATProtoDriveTests/CrossSourceCopyCoordinatorTests.swift`.
- Create `ATProtoDriveTests/TestPublicCARFixtureHelper.swift`.
- Create `ATProtoDriveTests/TransferFixtureSupport.swift` — deterministic payload/job/executor/persistence fixtures shared by Tasks 5–12.
- Create `ATProtoDriveTests/BackupFixtureSupport.swift` — executable schema/package/writer/authority-claim fixtures shared by Tasks 8–11.
- Modify `ATProtoDriveTests/TestCARFixtureHelper.swift` — accept caller-provided UUID-qualified directories and stop relying on any fixed temporary path.

### Exact fixture ownership

No test step relies on an implied helper. `BlobFixtureSupport.swift` owns `RepositoryScope.fixturePublic/fixtureSpace`, `RecordLocator.fixturePublic`, `BlobLocator.fixturePublic/fixtureSpace/fixtureOtherSpace/fixtureForeignSpace`, `ScriptedAnonymousStream`, `ScriptedBlobPageTransport`, `RecordingSpaceCredentialStreamRouter`, `BlobServiceFixture`, `ScriptedRecordInventoryPages`, `BlockingRecordInventoryScanner`, `SequencedBlobPages`, `ScopeChangeFixture`, `FilePromiseFixture`, `SecurityScopedFileFixture`, and UUID-root/mode helpers. Its scripted transports accept ordered `Result` values, consume once under an actor, record request URL/account/Space/path/query/chunk size, and throw `FixtureError.exhausted` if overcalled.

`TransferFixtureSupport.swift` owns every `TransferJobDescriptor`/snapshot/component/result factory, `TransitionFixture`, in-memory persistence with atomic-save/event counters, all six scripted executors, `QueueFixture`, `AttachmentCallRecorder`, `AttachmentServerFixture`, and the cross-copy `CopyFixture`. `BackupFixtureSupport.swift` owns complete public/single-writer/whole-Space request/plan/claim/observation/artifact/manifest/package fixtures, `AtomicWriterFixture`, `BackupServiceFixture`, `BackupCatalogFixture`, preview-cleanup fixture, durability injection, and caller-owned package roots. Each helper has one initializer taking its script/state; no helper reaches the network, Keychain, production UserDefaults, shared `/tmp`, or the app's live Application Support directory.

Use these exact actor seams instead of defining task-local fakes:

```swift
public enum FixtureError: Error, Sendable { case exhausted, scripted(String) }

public enum ScriptedResult<Value: Sendable>: Sendable {
  case success(Value)
  case failure(FixtureError)
}

public actor OrderedScript<Input: Sendable, Output: Sendable> {
  private var results: [ScriptedResult<Output>]
  public private(set) var inputs: [Input] = []
  public init(_ results: [ScriptedResult<Output>]) { self.results = results }
  public func next(_ input: Input) throws -> Output {
    inputs.append(input)
    guard !results.isEmpty else { throw FixtureError.exhausted }
    switch results.removeFirst() {
    case .success(let value): return value
    case .failure(let error): throw error
    }
  }
}

public actor QueueEventRecorder {
  public private(set) var values: [String] = []
  public func record(_ value: String) { values.append(value) }
}

public actor InMemoryTransferPersistence: TransferJobPersisting {
  private var jobs: [TransferJobSnapshot]
  private let events: QueueEventRecorder?
  public private(set) var atomicSaveCount = 0
  public init(jobs: [TransferJobSnapshot] = [], events: QueueEventRecorder? = nil) {
    self.jobs = jobs
    self.events = events
  }
  public func load() async throws -> [TransferJobSnapshot] { jobs }
  public func save(_ jobs: [TransferJobSnapshot]) async throws {
    self.jobs = jobs
    atomicSaveCount += 1
    await events?.record("persist")
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
```

---

### Task 1: Define Qualified Blob Identity and Preserve Every Reference Occurrence

**Files:**
- Create: `ATProtoDrive/Blobs/BlobTypes.swift`
- Create: `ATProtoDrive/Blobs/BlobReferenceScanner.swift`
- Create: `ATProtoDrive/Blobs/BlobReferenceIndex.swift`
- Create: `ATProtoDriveTests/BlobFixtureSupport.swift`
- Create: `ATProtoDriveTests/BlobReferenceIndexTests.swift`
- Hand off app/test membership to the cross-plan integration owner; do not edit `project.pbxproj` in the feature lane.

**Interfaces:**
- Consumes: Plan 1's `RepositoryScope`, `RecordLocator`, `BlobLocator`, `AccessClassification`, `RecordOrigin`, and `RecordRow`, plus Petrel `ATProtocolValueContainer`.
- Produces: `BlobReferenceOccurrence`, `BlobDescriptor`, `BlobAvailability`, `BlobVerificationState`, `BlobCIDPage`, `BlobReferenceScanProgress`, `BlobReferenceScanner.scan(value:record:)`, and actor `BlobReferenceIndex`.

- [ ] **Step 1: Write the failing scanner and qualified-index tests**

  ```swift
  import Foundation
  import Petrel
  import Testing
  @testable import ATProtoDrive

  @Suite("Qualified blob reference index")
  struct BlobReferenceIndexTests {
    @Test("keeps every occurrence and separates identical CIDs by repository scope")
    func occurrencesAreQualified() async throws {
      let publicScope = RepositoryScope.publicRepository(
        did: "did:plc:alice",
        pdsURL: try #require(URL(string: "https://alice.example"))
      )
      let spaceScope = RepositoryScope.permissionedSpace(
        spaceURI: "at://did:plc:owner/space/app.example.drive/shared",
        writerDID: "did:plc:alice",
        accountDID: "did:plc:alice"
      )
      let cid = "bafkreigh2akiscaildcq"
      let value: ATProtocolValueContainer = .object([
        "images": .array([
          .object(["$type": .string("blob"), "ref": .object(["$link": .string(cid)])]),
          .object(["$type": .string("blob"), "ref": .object(["$link": .string(cid)])])
        ])
      ])
      let publicRecord = RecordLocator(
        scope: publicScope,
        uri: "at://did:plc:alice/app.example.file/one",
        collection: "app.example.file",
        rkey: "one",
        cid: "bafyreipublic"
      )
      let spaceRecord = RecordLocator(
        scope: spaceScope,
        uri: "at://did:plc:owner/space/app.example.drive/shared/did:plc:alice/app.example.file/one",
        collection: "app.example.file",
        rkey: "one",
        cid: "bafyreispace"
      )
      let index = BlobReferenceIndex()

      try await index.replaceReferences(for: publicRecord, value: value)
      try await index.replaceReferences(for: spaceRecord, value: value)

      let publicRefs = await index.references(to: BlobLocator(scope: publicScope, cid: cid))
      let spaceRefs = await index.references(to: BlobLocator(scope: spaceScope, cid: cid))
      #expect(publicRefs.map(\.jsonPointer) == ["/images/0", "/images/1"])
      #expect(spaceRefs.map(\.jsonPointer) == ["/images/0", "/images/1"])
      #expect(await index.snapshot().keys.count == 2)
    }

    @Test("escapes RFC 6901 object keys and replaces stale record references")
    func pointerEscapingAndReplacement() async throws {
      let scope = RepositoryScope.publicRepository(
        did: "did:plc:alice",
        pdsURL: try #require(URL(string: "https://alice.example"))
      )
      let record = RecordLocator(
        scope: scope,
        uri: "at://did:plc:alice/app.example.file/key",
        collection: "app.example.file",
        rkey: "key",
        cid: "bafyreione"
      )
      let first: ATProtocolValueContainer = .object([
        "a/b~c": .object([
          "$type": .string("blob"),
          "ref": .object(["$link": .string("bafkreifirst")])
        ])
      ])
      let second: ATProtocolValueContainer = .object([
        "next": .object([
          "$type": .string("blob"),
          "ref": .object(["$link": .string("bafkreisecond")])
        ])
      ])
      let index = BlobReferenceIndex()
      try await index.replaceReferences(for: record, value: first)
      #expect(await index.references(to: .init(scope: scope, cid: "bafkreifirst")).first?.jsonPointer == "/a~1b~0c")

      try await index.replaceReferences(for: record, value: second)
      #expect(await index.references(to: .init(scope: scope, cid: "bafkreifirst")).isEmpty)
      #expect(await index.references(to: .init(scope: scope, cid: "bafkreisecond")).count == 1)
    }

    @Test("scans blobs inside decoded known and unknown record containers")
    func decodedRepresentations() throws {
      let record = RecordLocator.fixturePublic()
      let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
      let known = try JSONDecoder().decode(
        ATProtocolValueContainer.self,
        from: Data(#"{"$type":"app.bsky.actor.profile","avatar":{"$type":"blob","ref":{"$link":"bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"},"mimeType":"image/png","size":12}}"#.utf8)
      )
      guard case .knownType = known else {
        Issue.record("Expected generated known-type dispatch")
        return
      }
      #expect(try BlobReferenceScanner.scan(value: known, record: record).map(\.blob.cid) == [cid])

      let unknown = try JSONDecoder().decode(
        ATProtocolValueContainer.self,
        from: Data(#"{"$type":"app.example.unknown","nested":{"$type":"blob","ref":{"$link":"bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"},"mimeType":"image/png","size":12}}"#.utf8)
      )
      #expect(try BlobReferenceScanner.scan(value: unknown, record: record).first?.jsonPointer == "/nested")
    }
  }
  ```

- [ ] **Step 2: Run the focused test and verify the expected failure**

  Run:

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task1.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/BlobReferenceIndexTests
  ```

  Expected: FAIL because `BlobReferenceOccurrence`, `BlobReferenceScanner`, and `BlobReferenceIndex` do not exist.

- [ ] **Step 3: Add the blob-domain values and complete recursive scanner**

  ```swift
  public struct BlobReferenceOccurrence: Hashable, Codable, Sendable {
    public let blob: BlobLocator
    public let record: RecordLocator
    public let jsonPointer: String
    public let mimeType: String?
    public let declaredSize: Int?
  }

  public enum BlobAvailability: String, Hashable, Codable, Sendable {
    case unknown
    case available
    case missing
  }

  public enum BlobVerificationState: Hashable, Codable, Sendable {
    case notVerified
    case hashVerified(sha256: String)
    case failed(reason: String)
  }

  public struct BlobDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String { locator.stableID }
    public let locator: BlobLocator
    public let mimeType: String?
    public let declaredSize: Int?
    public let referenceCount: Int
    public let referenceIndexComplete: Bool
    public let availability: BlobAvailability
    public let verification: BlobVerificationState
  }

  public struct BlobCIDPage: Equatable, Sendable {
    public let cids: [String]
    public let cursor: String?
  }

  public enum BlobReferenceScanner {
    public static func scan(
      value: ATProtocolValueContainer,
      record: RecordLocator
    ) throws -> [BlobReferenceOccurrence] {
      var result: [BlobReferenceOccurrence] = []
      walk(value, pointer: "", record: record, into: &result)
      return result
    }

    private static func escape(_ key: String) -> String {
      key.replacingOccurrences(of: "~", with: "~0")
        .replacingOccurrences(of: "/", with: "~1")
    }

    private static func walk(
      _ value: ATProtocolValueContainer,
      pointer: String,
      record: RecordLocator,
      into result: inout [BlobReferenceOccurrence]
    ) {
      switch value {
      case .knownType:
        // Re-encode the existential through the container, then project JSON values to
        // raw containers without generated dispatch. This preserves nested Blob fields.
        if let projected = try? RawATProtocolProjection.project(value) {
          walk(projected, pointer: pointer, record: record, into: &result)
        }
      case .object(let fields):
        if let occurrence = occurrence(type: nil, fields: fields, pointer: pointer, record: record) {
          result.append(occurrence)
        }
        for key in fields.keys.sorted() {
          guard let child = fields[key] else { continue }
          walk(child, pointer: "\(pointer)/\(escape(key))", record: record, into: &result)
        }
      case .array(let values):
        for (index, child) in values.enumerated() {
          walk(child, pointer: "\(pointer)/\(index)", record: record, into: &result)
        }
      case .unknownType(let type, let child):
        if case .object(let fields) = child,
           let occurrence = occurrence(type: type, fields: fields, pointer: pointer, record: record) {
          result.append(occurrence)
        }
        walk(child, pointer: pointer, record: record, into: &result)
      default:
        break
      }
    }

    private static func occurrence(
      type: String?,
      fields: [String: ATProtocolValueContainer],
      pointer: String,
      record: RecordLocator
    ) -> BlobReferenceOccurrence? {
      let isBlob = type == "blob" || {
        if case .string("blob")? = fields["$type"] { return true }
        return false
      }()
      guard isBlob else { return nil }
      let cid: String?
      switch fields["ref"] {
      case .link(let link):
        cid = link.cid.description
      case .object(let object):
        if case .string(let value)? = object["$link"] { cid = value } else { cid = nil }
      default:
        cid = nil
      }
      guard let cid else { return nil }
      let mimeType: String?
      if case .string(let value)? = fields["mimeType"] { mimeType = value } else { mimeType = nil }
      let declaredSize: Int?
      if case .number(let value)? = fields["size"] { declaredSize = value } else { declaredSize = nil }
      return BlobReferenceOccurrence(
        blob: BlobLocator(scope: record.scope, cid: cid),
        record: record,
        jsonPointer: pointer.isEmpty ? "" : pointer,
        mimeType: mimeType,
        declaredSize: declaredSize
      )
    }
  }

  private enum RawATProtocolProjection {
    static func project(_ value: ATProtocolValueContainer) throws -> ATProtocolValueContainer {
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
      return try container(object)
    }

    private static func container(_ value: Any) throws -> ATProtocolValueContainer {
      switch value {
      case let object as [String: Any]:
        return .object(try object.mapValues(container))
      case let array as [Any]:
        return .array(try array.map(container))
      case let string as String:
        return .string(string)
      case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
        return .bool(number.boolValue)
      case let number as NSNumber:
        return .number(number.intValue)
      case is NSNull:
        return .null
      default:
        throw BlobReferenceScanError.unsupportedProjectedValue
      }
    }
  }
  ```

  Emit before descending so nested blobs are preserved. Do not use a CID set inside the scanner.

- [ ] **Step 4: Implement the actor with record-scoped replacement**

  ```swift
  public actor BlobReferenceIndex {
    private struct RecordReferenceKey: Hashable {
      let scope: RepositoryScope
      let uri: String
    }
    private var occurrencesByBlob: [BlobLocator: Set<BlobReferenceOccurrence>] = [:]
    private var blobsByRecord: [RecordReferenceKey: Set<BlobLocator>] = [:]

    public func replaceReferences(
      for record: RecordLocator,
      value: ATProtocolValueContainer
    ) throws {
      removeRecord(record)
      let occurrences = try BlobReferenceScanner.scan(value: value, record: record)
      let recordKey = RecordReferenceKey(scope: record.scope, uri: record.uri)
      for occurrence in occurrences {
        occurrencesByBlob[occurrence.blob, default: []].insert(occurrence)
        blobsByRecord[recordKey, default: []].insert(occurrence.blob)
      }
    }

    public func removeRecord(_ record: RecordLocator) {
      let recordKey = RecordReferenceKey(scope: record.scope, uri: record.uri)
      removeRecord(key: recordKey)
    }

    private func removeRecord(key recordKey: RecordReferenceKey) {
      for blob in blobsByRecord.removeValue(forKey: recordKey) ?? [] {
        occurrencesByBlob[blob]?.removeAll {
          $0.record.scope == recordKey.scope && $0.record.uri == recordKey.uri
        }
        if occurrencesByBlob[blob]?.isEmpty == true {
          occurrencesByBlob.removeValue(forKey: blob)
        }
      }
    }

    public func references(to blob: BlobLocator) -> [BlobReferenceOccurrence] {
      Array(occurrencesByBlob[blob] ?? []).sorted {
        ($0.record.uri, $0.jsonPointer) < ($1.record.uri, $1.jsonPointer)
      }
    }

    public func snapshot() -> [BlobLocator: [BlobReferenceOccurrence]] {
      occurrencesByBlob.mapValues { Array($0) }
    }

    public func removeSpace(spaceURI: String, accountDID: String) {
      let matchingRecords = blobsByRecord.keys.filter { key in
        guard case .permissionedSpace(let candidateSpace, _, let candidateAccount) = key.scope else {
          return false
        }
        return candidateSpace == spaceURI && candidateAccount == accountDID
      }
      for key in matchingRecords {
        removeRecord(key: key)
      }
    }
  }
  ```

- [ ] **Step 5: Hand the exact four-file membership list to the cross-plan integration owner, then run the tests**

  Run the Step 2 command again.

  Expected: PASS with three tests; the known/unknown decoded cases each emit the correct pointer. The integration-owner diff contains one file reference and one build-file entry per new Swift file, with no duplicate UUID.

- [ ] **Step 6: Seal the qualified blob-domain change**

  ```bash
  jj status
  jj diff --summary
  jj describe -m "blobs: qualify identities and index every reference"
  jj new
  ```

### Task 2: Add True Streaming Public and Permissioned Blob Services

**Files:**
- Create: `ATProtoDrive/Support/StreamingArtifactDestination.swift`
- Create: `ATProtoDrive/Blobs/PublicBlobService.swift`
- Create: `ATProtoDrive/Blobs/SpaceBlobService.swift`
- Modify: `ATProtoDriveTests/BlobFixtureSupport.swift`
- Create: `ATProtoDriveTests/BlobServiceTests.swift`
- Modify: `../Petrel/Sources/Petrel/Auth/Space/SpaceCredentialManager.swift`
- Create: `../Petrel/Tests/PetrelTests/SpaceCredentialStreamingTests.swift`
- Hand off ATProtoDrive app/test membership to the cross-plan integration owner; do not edit `project.pbxproj` in the feature lane.

**Interfaces:**
- Consumes: Plan 1 `DIDDocumentPDSResolving`; Plan 2's exact account-DID, Space-profile, contextual `.spaceRead(space:)`, writer-host routing, and `SpaceCredentialManager` contracts; `RepositoryScope`, `BlobLocator`, and `BlobCIDPage`.
- Produces: `ByteStreamDestination`, actor `StreamingArtifactDestination`, `StreamedArtifactReceipt`, `PublicBlobServing`, `SpaceBlobServing`, `SpaceCredentialStreamRouting`, concrete public/Space services, and `BlobServiceError`.

- [ ] **Step 1: Write failing bounded-stream, expected-CID, routing, and pagination tests**

  ```swift
  import Foundation
  import Petrel
  import Testing
  @testable import ATProtoDrive

  @Suite("Blob data-plane services")
  struct BlobServiceTests {
    @Test("public blob streams bounded chunks and publishes only after CID verification")
    func publicStreaming() async throws {
      let payload = Data(repeating: 0x41, count: 200_000)
      let cid = CID.fromBlob(payload).string
      let destination = try StreamingArtifactDestination.fixture(expectedCID: cid)
      let transport = ScriptedAnonymousStream(chunks: payload.chunks(maximum: 32_768))
      let service = PublicBlobService(listPageTransport: .fixture(), stream: transport)
      let receipt = try await service.fetch(.fixturePublic(cid: cid), to: destination)
      #expect(receipt.byteCount == Int64(payload.count))
      #expect(receipt.expectedCIDConfirmed)
      #expect(await transport.maximumDeliveredChunk <= 65_536)
      #expect(try Data(contentsOf: receipt.fileURL) == payload)
    }

    @Test("wrong CID never publishes for either data plane")
    func wrongCIDFailsClosed() async throws {
      for fixture in try BlobServiceFixture.publicAndSpace(payload: Data("not expected".utf8)) {
        let destination = try StreamingArtifactDestination.fixture(
          expectedCID: CID.fromBlob(Data("expected".utf8)).string
        )
        await #expect(throws: StreamingArtifactError.cidMismatch) {
          _ = try await fixture.fetch(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: await destination.finalURL.path))
      }
    }

    @Test("Space list and fetch use writer host, exact paths, opaque query, and DPoP route")
    func spaceWriterRouting() async throws {
      let context = AccessContext.spaceRead(space: .fixtureSpaceRef)
      let requiredScope = try AuthorizationScopePlanner().requiredScope(for: context)
      let authorizer = RecordingSpaceBlobAuthorizer(
        grantKnowledge: .known(grantedScopes: [requiredScope]),
        credentialProbe: .mustNotBeCalled
      )
      let router = RecordingSpaceCredentialStreamRouter(
        writerHost: try #require(URL(string: "https://writer.example")),
        listBody: #"{"cids":[],"cursor":"next+/="}"#
      )
      let service = SpaceBlobService(
        accountDID: "did:plc:alice",
        authorizer: authorizer,
        router: router
      )
      let scope = RepositoryScope.permissionedSpace(
        spaceURI: SpaceRef.fixtureSpaceRef.uriString(),
        writerDID: "did:plc:bob",
        accountDID: "did:plc:alice"
      )
      _ = try await service.listPage(scope: scope, cursor: "opaque+/=", limit: 100)
      let destination = try StreamingArtifactDestination.fixture(expectedCID: CID.fromBlob(Data()).string)
      _ = try await service.fetch(.init(scope: scope, cid: CID.fromBlob(Data()).string), to: destination)

      let calls = await router.calls
      #expect(calls.map(\.host) == ["writer.example", "writer.example"])
      #expect(calls.map(\.path) == [
        "/xrpc/com.atproto.space.listBlobs", "/xrpc/com.atproto.space.getBlob"
      ])
      #expect(calls[0].query["cursor"] == "opaque+/=")
      #expect(calls.allSatisfy { $0.accountDID == "did:plc:alice" && $0.usedSpaceCredential && $0.usedDPoP })
      #expect(await authorizer.requests == [
        .init(accountDID: "did:plc:alice", writerDID: "did:plc:bob", context: context),
        .init(accountDID: "did:plc:alice", writerDID: "did:plc:bob", context: context)
      ])
      #expect(await router.accountPDSCallCount == 0)
      #expect(await router.publicSyncCallCount == 0)
    }

    @Test("differently scoped account and locator fail before transport")
    func exactScopeRequired() async throws {
      let router = RecordingSpaceCredentialStreamRouter.fixture()
      let service = SpaceBlobService(
        accountDID: "did:plc:alice",
        authorizer: RecordingSpaceBlobAuthorizer.fixtureKnownGrant(),
        router: router
      )
      await #expect(throws: BlobServiceError.accountMismatch) {
        _ = try await service.listPage(scope: .fixtureSpace(accountDID: "did:plc:mallory"), cursor: nil, limit: 100)
      }
      await #expect(throws: BlobServiceError.locatorScopeMismatch) {
        _ = try await service.fetch(.fixtureForeignSpace(), to: StreamingArtifactDestination.discarding())
      }
      #expect(await router.calls.isEmpty)
    }

    @Test("own writer accepts read_self; foreign writer requires exact Space read")
    func writerAwareGrantEvidence() async throws {
      let context = AccessContext.spaceRead(space: .fixtureSpaceRef)
      let ownReadScope = try SpaceBlobReadScope.requiredScope(
        accountDID: "did:plc:alice", writerDID: "did:plc:alice", space: .fixtureSpaceRef
      )
      let wholeSpaceScope = try SpaceBlobReadScope.requiredScope(
        accountDID: "did:plc:alice", writerDID: "did:plc:bob", space: .fixtureSpaceRef
      )
      #expect(ownReadScope == "space:*?authority=*&skey=*&action=read_self")
      #expect(wholeSpaceScope == try AuthorizationScopePlanner().requiredScope(for: context))

      let ownProbe = RecordingSpaceCredentialProbe(result: .mustNotBeCalled)
      let ownAuthorizer = LiveSpaceBlobAuthorizer(
        accountDID: "did:plc:alice",
        grants: ScriptedSpaceGrantKnowledge(values: [
          "did:plc:alice": .known(grantedScopes: [ownReadScope])
        ]),
        probe: ownProbe,
        now: { .fixtureNow }
      )
      let ownEvidence = try await ownAuthorizer.authorize(.init(
        accountDID: "did:plc:alice", writerDID: "did:plc:alice", context: context
      ))
      #expect(ownEvidence.requiredScope == ownReadScope)
      #expect(ownEvidence.source == .storedExactGrant)
      #expect(await ownProbe.requests.isEmpty)

      let unknownOwnProbe = RecordingSpaceCredentialProbe(result: .success)
      let unknownOwn = LiveSpaceBlobAuthorizer(
        accountDID: "did:plc:alice",
        grants: ScriptedSpaceGrantKnowledge(values: ["did:plc:alice": .unknown]),
        probe: unknownOwnProbe,
        now: { .fixtureNow }
      )
      let unknownOwnEvidence = try await unknownOwn.authorize(.init(
        accountDID: "did:plc:alice", writerDID: "did:plc:alice", context: context
      ))
      #expect(unknownOwnEvidence.requiredScope == ownReadScope)
      #expect(await unknownOwnProbe.requests == [
        .init(
          accountDID: "did:plc:alice", writerDID: "did:plc:alice",
          space: .fixtureSpaceRef, requiredScope: ownReadScope
        )
      ])

      let baselineOnlyProbe = RecordingSpaceCredentialProbe(result: .mustNotBeCalled)
      let baselineOnly = LiveSpaceBlobAuthorizer(
        accountDID: "did:plc:alice",
        grants: ScriptedSpaceGrantKnowledge(
          values: ["did:plc:alice": .known(grantedScopes: [ownReadScope])]
        ),
        probe: baselineOnlyProbe,
        now: { .fixtureNow }
      )
      await #expect(throws: BlobServiceError.permissionRequired(
        accountDID: "did:plc:alice", requiredScope: wholeSpaceScope
      )) {
        _ = try await baselineOnly.authorize(.init(
          accountDID: "did:plc:alice", writerDID: "did:plc:bob", context: context
        ))
      }
      #expect(await baselineOnlyProbe.requests.isEmpty)

      let unknownProbe = RecordingSpaceCredentialProbe(result: .success)
      let unknown = LiveSpaceBlobAuthorizer(
        accountDID: "did:plc:alice",
        grants: ScriptedSpaceGrantKnowledge(values: ["did:plc:alice": .unknown]),
        probe: unknownProbe,
        now: { .fixtureNow }
      )
      let unknownEvidence = try await unknown.authorize(.init(
        accountDID: "did:plc:alice", writerDID: "did:plc:bob", context: context
      ))
      #expect(unknownEvidence.requiredScope == wholeSpaceScope)
      #expect(await unknownProbe.requests == [
        .init(
          accountDID: "did:plc:alice", writerDID: "did:plc:bob",
          space: .fixtureSpaceRef, requiredScope: wholeSpaceScope
        )
      ])

      let deniedProbe = RecordingSpaceCredentialProbe(result: .permissionDenied)
      let denied = LiveSpaceBlobAuthorizer(
        accountDID: "did:plc:alice",
        grants: ScriptedSpaceGrantKnowledge(values: ["did:plc:alice": .unknown]),
        probe: deniedProbe,
        now: { .fixtureNow }
      )
      await #expect(throws: BlobServiceError.permissionRequired(
        accountDID: "did:plc:alice", requiredScope: wholeSpaceScope
      )) {
        _ = try await denied.authorize(.init(
          accountDID: "did:plc:alice", writerDID: "did:plc:bob", context: context
        ))
      }
    }

    @Test("public pages preserve cursor and reject 2xx without output")
    func publicMetadata() async throws {
      let service = PublicBlobService(
        listPageTransport: .scripted([
          .success(status: 200, cids: ["bafkone", "bafkone"], cursor: "next+/="),
          .success(status: 200, cids: nil, cursor: nil)
        ]),
        stream: ScriptedAnonymousStream(chunks: [])
      )
      let scope = RepositoryScope.fixturePublic()
      #expect(try await service.listPage(scope: scope, cursor: "opaque+/=", limit: 100).cursor == "next+/=")
      await #expect(throws: BlobServiceError.emptyResponse) {
        _ = try await service.listPage(scope: scope, cursor: nil, limit: 100)
      }
    }
  }
  ```

- [ ] **Step 2: Run the focused tests and verify the intended failures**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task2.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/BlobServiceTests
  swift test --package-path ../Petrel --filter SpaceCredentialStreamingTests
  ```

  Expected: FAIL because the byte destination, streaming Petrel operation, and public/Space streaming services do not exist.

- [ ] **Step 3: Implement one bounded destination with incremental hash and CID binding**

  ```swift
  public protocol ByteStreamDestination: Sendable {
    func append(_ chunk: Data) async throws
    func finish() async throws -> StreamedArtifactReceipt
    func abort() async
  }

  public struct StreamedArtifactReceipt: Hashable, Codable, Sendable {
    public let fileURL: URL
    public let byteCount: Int64
    public let sha256: String
    public let expectedCID: String?
    public let expectedCIDConfirmed: Bool
  }

  public actor StreamingArtifactDestination: ByteStreamDestination {
    private enum State { case active, finished, aborted }
    public let finalURL: URL
    private let partialURL: URL
    private let expectedBlob: BlobCIDExpectation?
    private let allowsReplacement: Bool
    private let handle: FileHandle
    private var sha256 = SHA256()
    private var count: Int64 = 0
    private var state: State = .active

    public init(finalURL: URL, expectedBlobCID: String?, allowsReplacement: Bool = false) throws {
      self.finalURL = finalURL
      self.partialURL = finalURL.appendingPathExtension("partial-\(UUID().uuidString)")
      self.expectedBlob = try expectedBlobCID.map(BlobCIDExpectation.init)
      self.allowsReplacement = allowsReplacement
      try FileManager.default.createDirectory(
        at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard FileManager.default.createFile(
        atPath: partialURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
      ) else { throw StreamingArtifactError.cannotCreatePartial }
      self.handle = try FileHandle(forWritingTo: partialURL)
    }

    public func append(_ chunk: Data) async throws {
      guard state == .active else { throw StreamingArtifactError.destinationClosed }
      guard !chunk.isEmpty, chunk.count <= 65_536 else {
        throw StreamingArtifactError.invalidChunkSize(chunk.count)
      }
      try handle.write(contentsOf: chunk)
      sha256.update(data: chunk)
      count += Int64(chunk.count)
    }

    public func finish() async throws -> StreamedArtifactReceipt {
      guard state == .active else { throw StreamingArtifactError.destinationClosed }
      let digest = Data(sha256.finalize())
      if let expectedBlob, expectedBlob.sha256Digest != digest {
        abortSynchronously()
        throw StreamingArtifactError.cidMismatch
      }
      try handle.synchronize()
      try handle.close()
      if FileManager.default.fileExists(atPath: finalURL.path) {
        guard allowsReplacement else {
          abortSynchronously()
          throw StreamingArtifactError.destinationExists
        }
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partialURL)
      } else {
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
      }
      state = .finished
      return .init(
        fileURL: finalURL, byteCount: count,
        sha256: digest.map { String(format: "%02x", $0) }.joined(),
        expectedCID: expectedBlob?.cid, expectedCIDConfirmed: expectedBlob != nil
      )
    }

    public func abort() async { abortSynchronously() }

    private func abortSynchronously() {
      guard state == .active else { return }
      try? handle.close()
      try? FileManager.default.removeItem(at: partialURL)
      state = .aborted
    }
  }
  ```

  `BlobCIDExpectation` decodes the CIDv1 base32 bytes and validates exactly: version `1`, raw codec `0x55`, multihash code `0x12` (SHA-256), digest length `32`, and no trailing bytes. It does not call `CID.fromBlob(Data(contentsOf:))`. The same incremental SHA-256 state therefore proves the expected blob CID and produces the artifact checksum without buffering. Unsupported CID codecs/hashes fail before the network call. `abort()` closes and removes only the sibling partial. Tests feed 1-byte, 32-KiB, and 64-KiB chunks, inject an fsync failure, and assert no final file appears on cancellation, HTTP failure, hash mismatch, or CID mismatch.

- [ ] **Step 4: Add anonymous public streaming and DPoP Space streaming**

  ```swift
  public protocol PublicBlobServing: Sendable {
    func listPage(scope: RepositoryScope, cursor: String?, limit: Int) async throws -> BlobCIDPage
    func fetch(_ blob: BlobLocator, to destination: any ByteStreamDestination) async throws -> StreamedArtifactReceipt
  }

  public protocol SpaceBlobServing: Sendable {
    func listPage(scope: RepositoryScope, cursor: String?, limit: Int) async throws -> BlobCIDPage
    func fetch(_ blob: BlobLocator, to destination: any ByteStreamDestination) async throws -> StreamedArtifactReceipt
  }

  public enum SpaceGrantKnowledge: Hashable, Sendable {
    case known(grantedScopes: Set<String>)
    case unknown
  }

  public enum SpaceReadEvidenceSource: String, Hashable, Sendable {
    case storedExactGrant
    case accountBoundCredentialProbe
  }

  public struct SpaceReadAuthorizationEvidence: Hashable, Sendable {
    public let accountDID: String
    public let writerDID: String
    public let context: AccessContext
    public let requiredScope: String
    public let source: SpaceReadEvidenceSource
    public let evaluatedAt: Date
  }

  public struct SpaceBlobAuthorizationRequest: Hashable, Sendable {
    public let accountDID: String
    public let writerDID: String
    public let context: AccessContext
  }

  public enum SpaceBlobReadScope {
    public static func requiredScope(
      accountDID: String, writerDID: String, space: SpaceRef
    ) throws -> String {
      if writerDID == accountDID {
        let tokens = try AuthorizationScopePlanner().baseScope
          .split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 2, tokens[0] == "atproto",
              tokens[1] == "space:*?authority=*&skey=*&action=read_self" else {
          throw BlobServiceError.authorizationEvidenceMismatch
        }
        return tokens[1]
      }
      return try AuthorizationScopePlanner().requiredScope(for: .spaceRead(space: space))
    }
  }

  public protocol SpaceBlobAuthorizing: Sendable {
    func authorize(_ request: SpaceBlobAuthorizationRequest) async throws
      -> SpaceReadAuthorizationEvidence
  }

  public struct SpaceCredentialProbeRequest: Hashable, Sendable {
    public let accountDID: String
    public let writerDID: String
    public let space: SpaceRef
    public let requiredScope: String
  }

  public protocol SpaceCredentialAccessProbing: Sendable {
    func probe(_ request: SpaceCredentialProbeRequest) async throws
  }

  public protocol SpaceGrantKnowledgeProviding: Sendable {
    func knowledge(for accountDID: String) async -> SpaceGrantKnowledge
  }

  public struct LiveSpaceBlobAuthorizer: SpaceBlobAuthorizing, Sendable {
    private let configuredAccountDID: String
    private let grants: any SpaceGrantKnowledgeProviding
    private let probe: any SpaceCredentialAccessProbing
    private let now: @Sendable () -> Date

    public init(
      accountDID: String,
      grants: any SpaceGrantKnowledgeProviding,
      probe: any SpaceCredentialAccessProbing,
      now: @escaping @Sendable () -> Date = { Date() }
    ) {
      self.configuredAccountDID = accountDID
      self.grants = grants
      self.probe = probe
      self.now = now
    }

    public func authorize(_ request: SpaceBlobAuthorizationRequest) async throws
      -> SpaceReadAuthorizationEvidence {
      guard request.accountDID == configuredAccountDID,
            case .spaceRead(let space) = request.context else {
        throw BlobServiceError.authorizationEvidenceMismatch
      }
      let requiredScope = try SpaceBlobReadScope.requiredScope(
        accountDID: configuredAccountDID, writerDID: request.writerDID, space: space
      )
      let source: SpaceReadEvidenceSource
      switch await grants.knowledge(for: configuredAccountDID) {
      case .known(let grantedScopes):
        guard grantedScopes.contains(requiredScope) else {
          throw BlobServiceError.permissionRequired(
            accountDID: configuredAccountDID, requiredScope: requiredScope
          )
        }
        source = .storedExactGrant
      case .unknown:
        do {
          try await probe.probe(.init(
            accountDID: configuredAccountDID, writerDID: request.writerDID,
            space: space, requiredScope: requiredScope
          ))
        } catch SpaceCredentialProbeError.permissionDenied {
          throw BlobServiceError.permissionRequired(
            accountDID: configuredAccountDID, requiredScope: requiredScope
          )
        }
        source = .accountBoundCredentialProbe
      }
      return .init(
        accountDID: configuredAccountDID, writerDID: request.writerDID,
        context: request.context,
        requiredScope: requiredScope, source: source, evaluatedAt: now()
      )
    }
  }

  public enum SpaceCredentialProbeError: Error, Hashable, Sendable {
    case permissionDenied
  }

  public enum BlobServiceError: Error, Hashable, Sendable {
    case invalidScope
    case accountMismatch
    case locatorScopeMismatch
    case permissionRequired(accountDID: String, requiredScope: String)
    case authorizationEvidenceMismatch
    case invalidLimit
    case emptyResponse
    case metadataTooLarge
    case httpStatus(Int)
  }

  public struct SpaceBlobService: Sendable {
    private let accountDID: String
    private let authorizer: any SpaceBlobAuthorizing
    private let router: any SpaceCredentialStreamRouting

    public init(
      accountDID: String,
      authorizer: any SpaceBlobAuthorizing,
      router: any SpaceCredentialStreamRouting
    ) {
      self.accountDID = accountDID
      self.authorizer = authorizer
      self.router = router
    }

    private func authorize(
      scope: RepositoryScope
    ) async throws -> (space: SpaceRef, writerDID: String) {
      guard case let .permissionedSpace(spaceURI, writerDID, scopedAccountDID) = scope else {
        throw BlobServiceError.invalidScope
      }
      guard scopedAccountDID == accountDID else { throw BlobServiceError.accountMismatch }
      guard let space = try? SpaceRef(uriString: spaceURI) else {
        throw BlobServiceError.invalidScope
      }
      let context = AccessContext.spaceRead(space: space)
      let evidence = try await authorizer.authorize(.init(
        accountDID: accountDID, writerDID: writerDID, context: context
      ))
      let requiredScope = try SpaceBlobReadScope.requiredScope(
        accountDID: accountDID, writerDID: writerDID, space: space
      )
      guard evidence.accountDID == accountDID,
            evidence.writerDID == writerDID,
            evidence.context == context,
            evidence.requiredScope == requiredScope else {
        throw BlobServiceError.authorizationEvidenceMismatch
      }
      return (space, writerDID)
    }
  }

  public struct SpaceCredentialStreamRequest: Hashable, Sendable {
    public let accountDID: String
    public let space: SpaceRef
    public let writerDID: String
    public let method: String
    public let queryItems: [URLQueryItem]
  }

  public protocol SpaceCredentialStreamRouting: Sendable {
    func data(_ request: SpaceCredentialStreamRequest, maximumBytes: Int) async throws -> (Int, Data)
    func stream(_ request: SpaceCredentialStreamRequest, to destination: any ByteStreamDestination) async throws -> Int
  }
  ```

  `PublicBlobService` resolves/validates the DID and target PDS with Plan 1's `DIDDocumentPDSResolving`, builds `/xrpc/com.atproto.sync.getBlob` with `URLComponents`, and uses an ephemeral anonymous `URLSession.bytes(for:)`. It buffers at most 64 KiB before each `destination.append`, accepts only 2xx, then calls `finish`; no `AccountStore.Account`, OAuth header, or Space credential enters this type. `listBlobs` may use the generated metadata endpoint because its JSON page is bounded and contains no payload bytes.

  `LiveSpaceCredentialStreamRouter` validates `request.accountDID` against the exact restored account, resolves `request.writerDID` with the same generic PDS resolver used by Plan 2, validates the current Space profile/version, builds the writer-host URL with `URLComponents`, and invokes only `SpaceCredentialManager.getStreaming(url:space:chunkSize:consume:)`. Add this public Petrel method beside `get(url:space:)`: it repeats the same secure-or-loopback, credential, `Authorization: DPoP`, canonical HTU, DPoP-proof, redirect, response, and cancellation checks, but consumes `URLSession.AsyncBytes` into chunks no larger than the requested capped 64 KiB. Petrel tests use a custom URL protocol to assert exact `Authorization`/`DPoP`, HTU/path, bounded chunks, non-2xx handling, and cancellation.

  `LiveSpaceBlobAuthorizer` is initialized with the exact connected account DID, an async `SpaceGrantKnowledge` provider backed by Plan 2's `AccountConnectionStatus.connected(grantedScopes:)`, `AuthorizationScopePlanner`, and an account-bound `SpaceCredentialAccessProbing`. `SpaceBlobReadScope` makes the decision from the explicit writer DID: the connected account's own writer requires the one canonical `space:*?authority=*&skey=*&action=read_self` token already present in Plan 2's base scope, while any foreign writer requires `AuthorizationScopePlanner.requiredScope(for: .spaceRead(space: exactSpace))`. With `.known`, the authorizer accepts only that writer-aware exact token; baseline `read_self` must never authorize a foreign writer, and another Space or wildcard whole-Space grant is rejected. With `.unknown`, it never assumes access: it asks the probe to validate the exact account, writer, Space, and derived scope, returns `.accountBoundCredentialProbe` only on success, and maps denial to `.permissionRequired`. Neither path persists a credential or treats transport failure as consent.

  `SpaceBlobService` validates `.permissionedSpace(spaceURI:writerDID:scopedAccountDID:)`, requires `scopedAccountDID == service.accountDID`, constructs the exact Space context, and passes both account and writer DID to `SpaceBlobAuthorizing.authorize` before either Space RPC. It independently recomputes the same writer-aware scope and requires the evidence to repeat the exact account DID, writer DID, context, and scope; mismatched evidence throws `.authorizationEvidenceMismatch`. Thus ordinary My Records blob browsing works under baseline `read_self`, while Whole Space and every foreign-writer blob read remain contextual-reconsent operations. Only then does it route both methods through:

  ```swift
  .init(
    accountDID: accountDID,
    space: try SpaceRef(uriString: spaceURI),
    writerDID: writerDID,
    method: "com.atproto.space.getBlob", // list uses com.atproto.space.listBlobs
    queryItems: [
      .init(name: "space", value: spaceURI), .init(name: "repo", value: writerDID),
      .init(name: "cid", value: blob.cid)
    ]
  )
  ```

  Never expose a public-sync fallback closure. The list metadata response is capped at 4 MiB and decoded only after 2xx. Preserve cursor strings as values; let `URLComponents` encode them once.

- [ ] **Step 5: Hand off membership, run tests, and build**

  The cross-plan integration owner adds the three new ATProtoDrive sources and `BlobServiceTests.swift` to their targets in this task change. The Petrel package owns its source/test membership automatically. Run Step 2 again, then:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  ```

  Expected: PASS; both payload routes are bounded and expected-CID-bound, the Space spy records only the writer host and DPoP route, and no generated blob/CAR payload API remains in these services.

- [ ] **Step 6: Seal the service split**

  ```bash
  jj status
  jj diff --summary
  jj describe -m "blobs: stream qualified public and Space payloads"
  jj new
  ```

### Task 3: Build Qualified Record Scans, Paginated Blob Inventory, and Finder Tables

**Files:**
- Create: `ATProtoDrive/Blobs/RecordInventoryScanner.swift`
- Create: `ATProtoDrive/Blobs/BlobInventoryStore.swift`
- Create: `ATProtoDrive/Blobs/BlobBrowserView.swift`
- Create: `ATProtoDrive/Blobs/BlobInspectorView.swift`
- Create: `ATProtoDriveTests/RecordInventoryScannerTests.swift`
- Create: `ATProtoDriveTests/BlobInventoryStoreTests.swift`
- Modify: `ATProtoDriveTests/BlobFixtureSupport.swift`
- Modify: `ATProtoDrive/Blobs/BlobReferenceIndex.swift`
- Modify: `ATProtoDrive/Browser/SearchQuery.swift` — add `.verification(String)` without renaming existing tokens.
- Modify by the cross-plan integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: both blob services; Plan 1 public repository paging and generic PDS identity; Plan 2 `SpaceRepositoryServing.collections/listRecords`, writer-host routing, profile gate, and `.spaceRead`; `BrowserSession`, `LoadState`, and `BrowserFailure`.
- Produces: `CollectionInventoryPage`, `RecordInventoryScanReceipt`, `RecordInventoryScanning`, separate `PublicRecordInventoryScanner`/`SpaceRecordInventoryScanner`, `BlobInventorySnapshot`, `BlobInventoryStore`, `BlobBrowserView`, and `BlobInspectorView`.

- [ ] **Step 1: Write failing collection/record scan, inventory paging, cancellation, and stale-state tests**

  ```swift
  @Suite("Qualified record inventory")
  struct RecordInventoryScannerTests {
    @Test("pages every collection and record before atomically replacing scope references")
    func normalExhaustionIsComplete() async throws {
      let pages = ScriptedRecordInventoryPages(
        collections: [
          .init(names: ["app.example.a"], cursor: "collections-2"),
          .init(names: ["app.example.b"], cursor: nil)
        ],
        records: [
          "app.example.a": [.fixture(rkey: "1", blobCID: "bafk1", cursor: "a2"), .fixture(rkey: "2", blobCID: "bafk2", cursor: nil)],
          "app.example.b": [.fixture(rkey: "3", blobCID: "bafk3", cursor: nil)]
        ]
      )
      let index = BlobReferenceIndex()
      let receipt = try await QualifiedRecordInventoryScanner(pages: pages).scan(
        scope: .fixturePublic(), index: index, progress: { _ in }
      )
      #expect(receipt.collectionsScanned == 2)
      #expect(receipt.recordsScanned == 3)
      #expect(receipt.endedByNormalExhaustion)
      #expect(await index.references(in: .fixturePublic()).count == 3)
    }

    @Test("repeat cursor and cancellation never publish a complete replacement")
    func abnormalEndIsNotComplete() async throws {
      let existing = BlobReferenceIndex.fixture(scope: .fixturePublic(), blobCID: "bafk-old")
      let scanner = QualifiedRecordInventoryScanner(
        pages: .repeatingRecordCursor("cycle"), cancellationProbe: { throw CancellationError() }
      )
      await #expect(throws: CancellationError.self) {
        _ = try await scanner.scan(scope: .fixturePublic(), index: existing, progress: { _ in })
      }
      #expect(await existing.references(in: .fixturePublic()).map(\.blob.cid) == ["bafk-old"])
    }

    @Test("successful rescan removes deleted records and replaces changed references")
    func replacementSemantics() async throws {
      let index = BlobReferenceIndex.fixture(scope: .fixtureSpace(), blobCID: "bafk-old")
      _ = try await SpaceRecordInventoryScanner.fixture(records: [
        .fixtureSpace(rkey: "same", recordCID: "bafy-new", blobCID: "bafk-new")
      ]).scan(scope: .fixtureSpace(), index: index, progress: { _ in })
      #expect(await index.references(in: .fixtureSpace()).map(\.blob.cid) == ["bafk-new"])
    }
  }

  @Suite("Blob inventory store")
  @MainActor
  struct BlobInventoryStoreTests {
    @Test("deduplicates blob pages and completes only after blob and record exhaustion")
    func dualScanCompletion() async throws {
      let records = BlockingRecordInventoryScanner()
      let store = BlobInventoryStore(
        scope: .fixturePublic(),
        blobPages: SequencedBlobPages([
          .init(cids: ["bafk1", "bafk2"], cursor: "next"),
          .init(cids: ["bafk2", "bafk3"], cursor: nil)
        ]),
        recordScanner: records,
        referenceIndex: BlobReferenceIndex()
      )
      await store.reload()
      await store.loadMore()
      #expect(store.snapshot.blobs.map(\.locator.cid) == ["bafk1", "bafk2", "bafk3"])
      #expect(!store.snapshot.isComplete)
      await records.finishNormally(records: 3)
      await store.waitForReferenceScanForTesting()
      #expect(store.snapshot.isComplete)
      #expect(store.snapshot.referenceScan.isComplete)
    }

    @Test("scope change cancels the old scanner and a failed refresh retains selection and rows")
    func scopeChangeAndStaleData() async throws {
      let fixture = ScopeChangeFixture()
      let store = fixture.store
      await store.reload()
      store.setScope(.fixtureSpace())
      #expect(await fixture.publicScanner.wasCancelled)
      await store.reload() // scripted 503
      guard case .failed(previous: .some, failure: _) = store.loadState else {
        Issue.record("Expected stale failed state")
        return
      }
      #expect(store.snapshot.blobs.map(\.locator.cid) == fixture.lastGoodCIDs)
    }
  }
  ```

- [ ] **Step 2: Run the focused suites and verify the intended failures**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task3.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO test \
    -only-testing:ATProtoDriveTests/RecordInventoryScannerTests \
    -only-testing:ATProtoDriveTests/BlobInventoryStoreTests
  ```

  Expected: FAIL because the qualified scanner and inventory store do not exist.

- [ ] **Step 3: Implement atomic qualified record scans over concrete data planes**

  ```swift
  public struct CollectionInventoryPage: Equatable, Sendable {
    public let names: [String]
    public let cursor: String?
  }

  public struct RecordInventoryScanReceipt: Equatable, Sendable {
    public let scope: RepositoryScope
    public let collectionsScanned: Int
    public let recordsScanned: Int
    public let endedByNormalExhaustion: Bool
  }

  public protocol RecordInventoryScanning: Sendable {
    func scan(
      scope: RepositoryScope,
      index: BlobReferenceIndex,
      progress: @escaping @Sendable (BlobReferenceScanProgress) async -> Void
    ) async throws -> RecordInventoryScanReceipt
  }
  ```

  `PublicRecordInventoryScanner` validates the target through Plan 1, treats `describeRepo.collections` as one normally exhausted collection page, and uses `PublicRepositoryServing.listRecords` until each opaque record cursor is nil. `SpaceRecordInventoryScanner` accepts only a permissioned scope for its exact account; it obtains the collection inventory and record pages through Plan 2 `SpaceRepositoryServing`, preserving that service's profile gate, exact writer host, credential route, and contextual `.spaceRead(space:)` behavior. It never infers reference completeness from `listBlobs`.

  The shared paging engine checks cancellation before every request/value decode, rejects repeated collection or record cursors with `RecordInventoryScanError.cursorCycle`, converts each `RecordRow.json` to `ATProtocolValueContainer`, scans every value, and accumulates a temporary `[RecordLocator: [BlobReferenceOccurrence]]`. Only normal nil-cursor exhaustion calls:

  ```swift
  public actor BlobReferenceIndex {
    public func replaceScope(
      _ scope: RepositoryScope,
      with completeSnapshot: [RecordLocator: [BlobReferenceOccurrence]]
    ) throws
    public func references(in scope: RepositoryScope) -> [BlobReferenceOccurrence]
  }
  ```

  This atomic scope replacement removes deleted records and old CIDs while a cancellation/failure preserves the prior complete index. Report progress after every collection and record page; `isComplete` is true only in the final receipt.

- [ ] **Step 4: Implement dual-pagination inventory state without lying about completeness**

  ```swift
  public struct BlobReferenceScanProgress: Equatable, Sendable {
    public let scannedCollections: Int
    public let totalCollections: Int?
    public let scannedRecords: Int
    public let isComplete: Bool
  }

  public struct BlobInventorySnapshot: Equatable, Sendable {
    public let blobs: [BlobDescriptor]
    public let nextCursor: String?
    public let blobEnumerationComplete: Bool
    public let referenceScan: BlobReferenceScanProgress
    public var isComplete: Bool { blobEnumerationComplete && referenceScan.isComplete }
  }

  @MainActor @Observable
  public final class BlobInventoryStore {
    public private(set) var snapshot: BlobInventorySnapshot
    public private(set) var loadState: LoadState<BlobInventorySnapshot> = .idle
    public func setScope(_ scope: RepositoryScope)
    public func reload() async
    public func loadMore() async
  }
  ```

  A monotonically increasing scope generation cancels and ignores late results from the prior scanner. Blob paging and record scanning are independent child tasks; the store publishes `.loaded` only for the current generation. `loadMore` is guarded against concurrent calls, preserves opaque cursors, deduplicates by qualified `BlobLocator`, permits empty pages with a new cursor, and treats a repeated cursor as an incomplete paging failure with current rows retained. Refresh failure uses `.failed(previous: previous, failure: ...)`. Reference counts carry `referenceIndexComplete = snapshot.referenceScan.isComplete`; exhaustion of `listBlobs` alone never flips it.

- [ ] **Step 5: Build a sortable, searchable, selection-safe Finder table and inspector**

  Change `BlobDescriptor.ID` to `String` and implement `id == locator.stableID`. `BlobTableProjection` filters a presentation copy with `BrowserSession.searchQuery` and sorts it from `BrowserSession.sort`; it never reorders paging state. Text matches suggested name, MIME, CID, owner DID, and source label. Tokens support exact `.source`, `.owner`, `.mimeType`, `.kind("blob")`, and the new `.verification` value; unsupported tokens fail closed.

  ```swift
  public struct BlobBrowserView: View {
    @Bindable var store: BlobInventoryStore
    @Bindable var session: BrowserSession

    public var body: some View {
      let rows = BlobTableProjection.rows(
        store.snapshot.blobs, query: session.searchQuery, sort: session.sort
      )
      Table(rows, selection: selectionBinding(rows: rows), sortOrder: sortBinding) {
        TableColumn("Name", value: \.derivedLabel)
        TableColumn("Type", value: \.displayMIMEType)
        TableColumn("Size") { blob in
          Text(blob.declaredSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
          } ?? "Unknown")
        }
        TableColumn("Owner", value: \.ownerDID)
        TableColumn("Data Plane", value: \.dataPlaneLabel)
        TableColumn("References", value: \.referenceCount)
        TableColumn("Availability", value: \.availabilityLabel)
        TableColumn("Verification", value: \.verificationLabel)
        TableColumn("CID", value: \.locator.cid)
      }
    }
  }
  ```

  `selectionBinding` converts visible `Set<String>` IDs to exact `ResourceReference.blob(locator)` values and calls `session.replaceSelection(with:)`; raw CIDs never enter `BrowserSession`. After refresh/filter/sort/page append, keep only selected references still present in the same complete scope. The last visible row starts guarded automatic `loadMore`; the footer always exposes **Load More** or **Retry Page**. Add tests for source/owner/MIME/verification token combinations, sort stability, retained qualified selection, automatic-page error recovery, and scope-change selection clearing.

  Inspector sections are Preview, Identity and Location, Access, References, Integrity, and Exact Identifiers. Derived names/extensions are labeled **Suggested filename**. The integration owner exhaustively routes public-blob and Space-blob sources; selected values are already typed `ResourceReference.blob`, never downcast from a string.

- [ ] **Step 6: Hand off membership/shared routing, run tests, and build**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO test \
    -only-testing:ATProtoDriveTests/RecordInventoryScannerTests \
    -only-testing:ATProtoDriveTests/BlobInventoryStoreTests
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  ```

  Expected: PASS; a failed refresh retains rows and selection, and “complete” appears only after both independent scans end normally.

- [ ] **Step 7: Seal the inventory and UI slice**

  ```bash
  jj status
  jj diff --summary
  jj describe -m "blobs: add qualified inventory scans and Finder table"
  jj new
  ```

### Task 4: Materialize CID-Verified Previews, Async Downloads, and Swift 6 File Promises

**Files:**
- Create: `ATProtoDrive/Blobs/PreviewPolicy.swift`
- Create: `ATProtoDrive/Blobs/QualifiedTemporaryFileStore.swift`
- Create: `ATProtoDrive/Blobs/QuickLookCoordinator.swift`
- Create: `ATProtoDrive/Blobs/SavePanelPresenter.swift`
- Create: `ATProtoDrive/Blobs/PromisedFileDragSource.swift`
- Create: `ATProtoDriveTests/BlobLocalInteractionTests.swift`
- Modify: `ATProtoDriveTests/BlobFixtureSupport.swift`
- Modify: `ATProtoDrive/Blobs/BlobBrowserView.swift`
- Modify: `ATProtoDrive/Blobs/BlobInspectorView.swift`
- Modify: `ATProtoDrive/Records/RecordInspectorView.swift`
- Modify: `ATProtoDrive/Records/RecordListModel.swift`
- Hand off source/test membership and root `.quickLookPreview` placement to the cross-plan integration owner.

**Interfaces:**
- Consumes: `BlobLocator`, `BlobDescriptor`, both streaming blob services, and `StreamingArtifactDestination`.
- Produces: `PreviewDisposition`, `PreviewPolicy`, actor `QualifiedTemporaryFileStore`, `QuickLookCoordinator`, `SavePanelPresenting`, `AppKitSavePanelPresenter`, Swift 6-correct `BlobFilePromiseDelegate`, and `PromisedFileDragSource`.

- [ ] **Step 1: Write failing policy, relaunch-cleanup, permissions, async-save, and file-promise tests**

  ```swift
  @Suite("Blob local interactions")
  struct BlobLocalInteractionTests {
    @Test("HTML and SVG are download-only")
    func activeFormatsFailClosed() {
      #expect(PreviewPolicy.disposition(mimeType: "text/html", filename: "page.html").isDownloadOnly)
      #expect(PreviewPolicy.disposition(mimeType: "image/svg+xml", filename: "image.svg").isDownloadOnly)
      #expect(PreviewPolicy.disposition(mimeType: "application/pdf", filename: "file.pdf") == .quickLook)
    }

    @Test("qualified paths, CID verification, and permissions survive a new store instance")
    func deterministicHierarchyAndRelaunchCleanup() async throws {
      let root = try TemporaryDirectory.make()
      let matching = BlobLocator.fixtureSpace(cid: CID.fromBlob(Data("space".utf8)).string)
      let other = BlobLocator.fixtureOtherSpace(cid: CID.fromBlob(Data("other".utf8)).string)
      let first = try QualifiedTemporaryFileStore(root: root)
      let matchingURL = try await first.materialize(matching, mimeType: "image/png", fetch: .bytes("space"))
      let otherURL = try await first.materialize(other, mimeType: "image/png", fetch: .bytes("other"))
      #expect(try posixMode(matchingURL.deletingLastPathComponent()) == 0o700)
      #expect(try posixMode(matchingURL) == 0o600)

      let relaunched = try QualifiedTemporaryFileStore(root: root) // no in-memory map
      try await relaunched.removeSpace(
        spaceURI: matching.scope.spaceURIForTesting, accountDID: matching.scope.accountDIDForTesting
      )
      #expect(!FileManager.default.fileExists(atPath: matchingURL.path))
      #expect(FileManager.default.fileExists(atPath: otherURL.path))
    }

    @Test("file promise retains its delegate, uses background queue, and completes once")
    func filePromiseContract() async throws {
      let fixture = try FilePromiseFixture.make()
      weak var weakDelegate = fixture.delegate
      let provider = fixture.dragSource.beginPromise(descriptor: .fixture(), materialize: fixture.materialize)
      #expect(weakDelegate != nil)
      #expect(fixture.delegate.operationQueue(for: provider) !== OperationQueue.main)
      let output = try await fixture.writePromise(provider: provider)
      #expect(try Data(contentsOf: output) == fixture.bytes)
      #expect(await fixture.completions.count == 1)
      fixture.dragSource.endPromise(provider, cancelled: false)
      #expect(weakDelegate == nil)
    }

    @Test("cancelled promise removes partial output and completes once")
    func cancelledPromise() async throws {
      let fixture = try FilePromiseFixture.make(blocking: true)
      let provider = fixture.dragSource.beginPromise(descriptor: .fixture(), materialize: fixture.materialize)
      fixture.dragSource.endPromise(provider, cancelled: true)
      await fixture.waitForCompletion()
      #expect(await fixture.completions.count == 1)
      #expect(try fixture.destinationContents().isEmpty)
    }
  }
  ```

- [ ] **Step 2: Run the focused suite and verify the intended failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task4.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/BlobLocalInteractionTests
  ```

  Expected: FAIL because preview policy, the deterministic store, and the file-promise bridge do not exist.

- [ ] **Step 3: Implement fail-closed preview policy and deterministic qualified paths**

  ```swift
  public enum PreviewDisposition: Equatable, Sendable {
    case quickLook
    case downloadOnly(reason: String)
    public var isDownloadOnly: Bool { if case .downloadOnly = self { true } else { false } }
  }

  public enum PreviewPolicy {
    public static func disposition(mimeType: String?, filename: String) -> PreviewDisposition {
      let type = mimeType?.lowercased()
      let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
      if ["text/html", "application/xhtml+xml", "image/svg+xml"].contains(type) ||
         ["html", "htm", "xhtml", "svg"].contains(ext) {
        return .downloadOnly(reason: "This active format is download-only.")
      }
      return .quickLook
    }
  }

  public actor QualifiedTemporaryFileStore {
    private let root: URL

    public func materialize(
      _ blob: BlobLocator,
      mimeType: String?,
      fetch: @Sendable (any ByteStreamDestination) async throws -> StreamedArtifactReceipt
    ) async throws -> URL {
      let target = try previewURL(for: blob, mimeType: mimeType)
      let destination = try StreamingArtifactDestination(finalURL: target, expectedBlobCID: blob.cid)
      let receipt = try await fetch(destination)
      guard receipt.expectedCIDConfirmed else { throw BlobLocalError.unverifiedBlob }
      return receipt.fileURL
    }
  }
  ```

  `previewURL(for:)` uses these deterministic, digest-only components (full lowercase SHA-256 over canonical UTF-8 strings separated by NUL):

  ```text
  previews/public/<sha256(scope.stableID)>/<sha256(cid)>/<suggested-name>
  previews/spaces/<sha256(accountDID NUL spaceURI)>/<sha256(writerDID)>/<sha256(cid)>/<suggested-name>
  ```

  Create every directory as `0700` and final file as `0600`. `removeSpace(spaceURI:accountDID:)` computes `previews/spaces/<sha256(accountDID NUL spaceURI)>` directly and removes it after canonical-root containment checks; it does not depend on an in-memory map, so it works after relaunch and preserves other Space/public roots and all explicit backups. `BlobFilename` replaces the old helper, strips separators/control characters, and labels its output “suggested.”

- [ ] **Step 4: Add window-scoped Quick Look and asynchronous atomic save**

  ```swift
  @MainActor @Observable
  public final class QuickLookCoordinator {
    public var previewURL: URL?
    public func present(url: URL, mimeType: String?) throws {
      guard PreviewPolicy.disposition(mimeType: mimeType, filename: url.lastPathComponent) == .quickLook
      else { throw BlobLocalError.previewDisallowed }
      previewURL = url
    }
  }

  @MainActor
  public protocol SavePanelPresenting {
    func destination(attachedTo window: NSWindow, suggestedFilename: String, contentType: UTType?) async -> URL?
  }

  @MainActor
  public final class AppKitSavePanelPresenter: SavePanelPresenting {
    public func destination(
      attachedTo window: NSWindow, suggestedFilename: String, contentType: UTType?
    ) async -> URL? {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = suggestedFilename
      panel.allowedContentTypes = [contentType ?? .data]
      return await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: window) {
          continuation.resume(returning: $0 == .OK ? panel.url : nil)
        }
      }
    }
  }
  ```

  The integration owner attaches `.quickLookPreview` to the window root. Download obtains the URL asynchronously, then streams into a sibling partial through `StreamingArtifactDestination`, balances security-scoped access, synchronizes, and atomically replaces only after expected-CID verification. Never call `runModal()` and never load payload `Data`.

- [ ] **Step 5: Implement the Swift 6/AppKit-correct file-promise bridge**

  ```swift
  public final class BlobFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let descriptor: BlobDescriptor
    private let materialize: @Sendable () async throws -> URL
    private let queue: OperationQueue = {
      let queue = OperationQueue()
      queue.name = "blue.catbird.atprotodrive.file-promise"
      queue.maxConcurrentOperationCount = 1
      queue.qualityOfService = .userInitiated
      return queue
    }()

    public nonisolated func operationQueue(
      for filePromiseProvider: NSFilePromiseProvider
    ) -> OperationQueue { queue }

    public nonisolated func filePromiseProvider(
      _ provider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
      BlobFilename.suggested(cid: descriptor.locator.cid, mimeType: descriptor.mimeType)
    }

    public nonisolated func filePromiseProvider(
      _ provider: NSFilePromiseProvider,
      writePromiseTo directoryURL: URL,
      completionHandler: @escaping (Error?) -> Void
    ) {
      let once = CompletionOnce(completionHandler)
      Task.detached { [materialize, descriptor] in
        do {
          try Task.checkCancellation()
          let source = try await materialize()
          let destination = directoryURL.appendingPathComponent(
            BlobFilename.suggested(cid: descriptor.locator.cid, mimeType: descriptor.mimeType)
          )
          try CoordinatedAtomicCopy.copy(source: source, destination: destination)
          once.call(nil)
        } catch { once.call(error) }
      }
    }
  }
  ```

  `CompletionOnce` is lock-protected and `@unchecked Sendable`; every success/error/cancellation path calls it exactly once. `CoordinatedAtomicCopy` uses `NSFileCoordinator`, a sibling partial, fsync, and atomic replacement inside the supplied directory. `PromisedFileDragSource` creates `NSFilePromiseProvider(fileType: UTType(mimeType:)?.identifier ?? UTType.data.identifier, delegate:)`, advertises only `.copy`, and strongly retains `[ObjectIdentifier(provider): delegate/task]` until AppKit's drag-session-ended callback. Ending/cancelling the drag cancels outstanding work, cleans partials, then releases the delegate. Add output, delegate lifetime, background-queue, cancellation, collision, and once-only tests.

- [ ] **Step 6: Replace blocking/unqualified helpers, hand off membership, test, and build**

  Move `RecordInspectorView` and blob inspector call sites to streaming materialization/save/file-promise services. Remove old helpers only after:

  ```bash
  rg -n 'BlobFileHelper|runModal\(|fetch\([^)]*\) async throws -> Data' ATProtoDrive
  ```

  returns no production blob path. Then run:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/BlobLocalInteractionTests
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  ```

  Expected: PASS; active formats fail closed, CID mismatch never previews/exports, cleanup works after store recreation, file promises survive weak AppKit delegate retention, and no blocking panel remains.

- [ ] **Step 7: Seal local blob interactions**

  ```bash
  jj status
  jj diff --summary
  jj describe -m "blobs: add verified previews downloads and file promises"
  jj new
  ```

### Task 5: Persist Exact Transfer States and Per-Kind Relaunch Payloads

**Files:**
- Create: `ATProtoDrive/Transfers/TransferTypes.swift`
- Create: `ATProtoDrive/Transfers/TransferPersistence.swift`
- Create: `ATProtoDrive/Support/PersistenceCoding.swift`
- Create: `ATProtoDriveTests/TransferFixtureSupport.swift`
- Create: `ATProtoDriveTests/TransferPersistenceTests.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: qualified scopes/locators, `AccessClassification`, and security-scoped bookmark bytes.
- Produces: `TransferKind`, exact `TransferState`, immutable `TransferComponentDescriptor`, mutable `TransferComponentCheckpoint`, discriminated `TransferResumePayload`, `TransferResultDescriptor`, `TransferJobDescriptor.requiredAccountDIDs`, snapshots, persistence, and deterministic fixture factories.

- [ ] **Step 1: Write failing all-kind Codable, result, account-requirement, redaction, and relaunch tests**

  ```swift
  @Suite("Transfer persistence")
  struct TransferPersistenceTests {
    @Test("round trips one discriminated payload for every transfer kind")
    func allKindsRoundTrip() async throws {
      let jobs = TransferFixtureSupport.snapshotsForEveryKindAndState()
      let persistence = try JSONTransferPersistence(directory: TemporaryDirectory.make())
      try await persistence.save(jobs)
      let restored = try await persistence.load()
      #expect(restored.map(\.descriptor.kind) == TransferKind.allCases)
      #expect(restored.map(\.descriptor.resumePayload.kind) == TransferKind.allCases)
      #expect(restored[0].result == .downloadedFile(.fixtureVerifiedFile()))

      let data = try Data(contentsOf: await persistence.fileURLForTesting)
      let text = try #require(String(data: data, encoding: .utf8))
      for forbidden in ["accessToken", "refreshToken", "credential", "recordBody", "editedJSON", "blobBytes", "carBytes"] {
        #expect(!text.contains(forbidden))
      }
    }

    @Test("deletion-bound whole-Space payload durably round trips the supplied snapshot")
    func deletionAuthoritySnapshotRoundTrip() throws {
      let snapshot = SpaceDeletionAuthoritySnapshot.fixture(
        observedAt: Date(timeIntervalSince1970: 1_786_000_000)
      )
      let original = TransferResumePayload.fullBackup(.fixture(subject: .wholeSpace(
        spaceURI: snapshot.spaceURI,
        accountDID: snapshot.accountDID,
        authoritySnapshot: snapshot
      )))
      let data = try PersistenceCoding.encoder().encode(original)
      let decoded = try PersistenceCoding.decoder().decode(
        TransferResumePayload.self, from: data
      )
      guard case let .fullBackup(resume) = decoded,
            case let .wholeSpace(spaceURI, accountDID, restoredSnapshot) = resume.subject
      else { Issue.record("Expected deletion-bound full backup"); return }
      #expect(spaceURI == snapshot.spaceURI)
      #expect(accountDID == snapshot.accountDID)
      #expect(restoredSnapshot == snapshot)
    }

    @Test("active work becomes interrupted while permission and terminal states survive relaunch")
    func relaunchNormalization() {
      #expect(TransferState.discovering.normalizedAfterRelaunch == .interrupted)
      #expect(TransferState.running.normalizedAfterRelaunch == .interrupted)
      #expect(TransferState.verifying.normalizedAfterRelaunch == .interrupted)
      #expect(TransferState.waitingForPermission.normalizedAfterRelaunch == .waitingForPermission)
      #expect(TransferState.completed.normalizedAfterRelaunch == .completed)
    }

    @Test("required accounts distinguish anonymous and authenticated work")
    func requiredAccounts() throws {
      #expect(TransferJobDescriptor.fixtureAnonymousPublicDownload().requiredAccountDIDs.isEmpty)
      #expect(TransferJobDescriptor.fixtureSpaceDownload().requiredAccountDIDs == ["did:plc:alice"])
      #expect(TransferJobDescriptor.fixtureCrossCopy().requiredAccountDIDs == ["did:plc:alice", "did:plc:bob"])
    }

    @Test("kind and payload discriminator must agree")
    func discriminatorMismatch() {
      #expect(throws: TransferModelError.kindPayloadMismatch) {
        try TransferJobDescriptor.fixture(kind: .blobDownload, payload: .fullBackup(.fixture()))
      }
    }

    @Test("endpoint, progress, and redacted error decode through validating initializers")
    func validatedLeafTypes() throws {
      for endpoint in TransferFixtureSupport.everyEndpoint() {
        let data = try PersistenceCoding.encoder().encode(endpoint)
        #expect(try PersistenceCoding.decoder().decode(TransferEndpoint.self, from: data) == endpoint)
      }
      #expect(throws: TransferModelError.invalidEndpoint) {
        _ = try TransferEndpoint.localFile(name: "../secret").validated()
      }
      #expect(throws: TransferModelError.invalidProgress) {
        _ = try TransferProgress(
          phase: .transferring, completedUnitCount: 9, totalUnitCount: 8,
          completedComponentCount: 0, totalComponentCount: 1
        )
      }
      #expect(throws: TransferModelError.unsafeRedactedError) {
        _ = try RedactedTransferError(
          category: .network, code: "request.failed",
          userMessage: "https://pds.example/xrpc?access_token=secret",
          recovery: .retry, occurredAt: .fixtureNow
        )
      }
      let progress = try TransferProgress.fixtureVerified()
      let failure = try RedactedTransferError.fixtureNetwork()
      #expect(try PersistenceCoding.decoder().decode(
        TransferProgress.self, from: PersistenceCoding.encoder().encode(progress)
      ) == progress)
      #expect(try PersistenceCoding.decoder().decode(
        RedactedTransferError.self, from: PersistenceCoding.encoder().encode(failure)
      ) == failure)
    }
  }
  ```

  `TransferFixtureSupport.swift` owns concrete, fixed-DID factories for all six payloads, every state, bookmark bytes, component descriptors/checkpoints, results, and redacted failures. Later tests extend this file instead of naming undefined `fixture()` helpers locally.

- [ ] **Step 2: Run the focused suite and verify the intended failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task5.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/TransferPersistenceTests
  ```

  Expected: FAIL because the discriminated payload and split descriptor/checkpoint model do not exist.

- [ ] **Step 3: Define exact states, immutable components, results, and six persistent payloads**

  ```swift
  public enum TransferModelError: Error, Hashable, Sendable {
    case unsupportedVersion(Int)
    case invalidEndpoint
    case invalidProgress
    case unsafeRedactedError
    case kindPayloadMismatch
    case endpointPayloadMismatch
    case duplicateComponentID
    case invalidComponent
    case invalidAccountDID
    case invalidCheckpointSet
    case invalidRetryCount
    case invalidTerminalMetadata
  }

  public enum TransferEndpoint: Hashable, Sendable {
    case repository(RepositoryScope)
    case record(RecordLocator)
    case blob(BlobLocator)
    case space(spaceURI: String, accountDID: String)
    case localFile(name: String)
    case backupPackage(packageID: UUID, filename: String)

    public func validated() throws -> Self {
      switch self {
      case .repository, .record, .blob:
        break // their qualified Plan 1 initializers already reject malformed identities
      case let .space(spaceURI, accountDID):
        guard (try? SpaceRef(uriString: spaceURI)) != nil,
              accountDID.hasPrefix("did:") else { throw TransferModelError.invalidEndpoint }
      case .localFile(let name), .backupPackage(_, let name):
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw TransferModelError.invalidEndpoint }
      }
      return self
    }
  }

  extension TransferEndpoint: Codable {
    private enum CodingKeys: String, CodingKey {
      case version, kind, scope, record, blob, spaceURI, accountDID, name, packageID
    }
    private enum Kind: String, Codable {
      case repository, record, blob, space, localFile, backupPackage
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let version = try container.decode(Int.self, forKey: .version)
      guard version == 1 else { throw TransferModelError.unsupportedVersion(version) }
      switch try container.decode(Kind.self, forKey: .kind) {
      case .repository:
        self = .repository(try container.decode(RepositoryScope.self, forKey: .scope))
      case .record:
        self = .record(try container.decode(RecordLocator.self, forKey: .record))
      case .blob:
        self = .blob(try container.decode(BlobLocator.self, forKey: .blob))
      case .space:
        self = .space(
          spaceURI: try container.decode(String.self, forKey: .spaceURI),
          accountDID: try container.decode(String.self, forKey: .accountDID)
        )
      case .localFile:
        self = .localFile(name: try container.decode(String.self, forKey: .name))
      case .backupPackage:
        self = .backupPackage(
          packageID: try container.decode(UUID.self, forKey: .packageID),
          filename: try container.decode(String.self, forKey: .name)
        )
      }
      _ = try validated()
    }

    public func encode(to encoder: Encoder) throws {
      _ = try validated()
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(1, forKey: .version)
      switch self {
      case .repository(let scope):
        try container.encode(Kind.repository, forKey: .kind)
        try container.encode(scope, forKey: .scope)
      case .record(let record):
        try container.encode(Kind.record, forKey: .kind)
        try container.encode(record, forKey: .record)
      case .blob(let blob):
        try container.encode(Kind.blob, forKey: .kind)
        try container.encode(blob, forKey: .blob)
      case let .space(spaceURI, accountDID):
        try container.encode(Kind.space, forKey: .kind)
        try container.encode(spaceURI, forKey: .spaceURI)
        try container.encode(accountDID, forKey: .accountDID)
      case .localFile(let name):
        try container.encode(Kind.localFile, forKey: .kind)
        try container.encode(name, forKey: .name)
      case let .backupPackage(packageID, filename):
        try container.encode(Kind.backupPackage, forKey: .kind)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(filename, forKey: .name)
      }
    }
  }

  public enum TransferProgressPhase: String, CaseIterable, Hashable, Codable, Sendable {
    case pending, discovering, transferring, verifying, waitingForPermission, finished
  }

  public struct TransferProgress: Hashable, Sendable {
    public let phase: TransferProgressPhase
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64?
    public let completedComponentCount: Int
    public let totalComponentCount: Int

    public init(
      phase: TransferProgressPhase,
      completedUnitCount: Int64,
      totalUnitCount: Int64?,
      completedComponentCount: Int,
      totalComponentCount: Int
    ) throws {
      guard completedUnitCount >= 0,
            totalUnitCount.map({ $0 >= completedUnitCount }) ?? true,
            completedComponentCount >= 0,
            totalComponentCount >= completedComponentCount
      else { throw TransferModelError.invalidProgress }
      self.phase = phase
      self.completedUnitCount = completedUnitCount
      self.totalUnitCount = totalUnitCount
      self.completedComponentCount = completedComponentCount
      self.totalComponentCount = totalComponentCount
    }
  }

  extension TransferProgress: Codable {
    private enum CodingKeys: String, CodingKey {
      case phase, completedUnitCount, totalUnitCount, completedComponentCount, totalComponentCount
    }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        phase: c.decode(TransferProgressPhase.self, forKey: .phase),
        completedUnitCount: c.decode(Int64.self, forKey: .completedUnitCount),
        totalUnitCount: c.decodeIfPresent(Int64.self, forKey: .totalUnitCount),
        completedComponentCount: c.decode(Int.self, forKey: .completedComponentCount),
        totalComponentCount: c.decode(Int.self, forKey: .totalComponentCount)
      )
    }
    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(phase, forKey: .phase)
      try c.encode(completedUnitCount, forKey: .completedUnitCount)
      try c.encodeIfPresent(totalUnitCount, forKey: .totalUnitCount)
      try c.encode(completedComponentCount, forKey: .completedComponentCount)
      try c.encode(totalComponentCount, forKey: .totalComponentCount)
    }
  }

  public enum TransferErrorCategory: String, Hashable, Codable, Sendable {
    case network, permission, sourceChanged, destinationConflict, verification
    case localIO, unsupported, invalidPayload, cancelled
  }

  public enum TransferRecoveryAction: String, Hashable, Codable, Sendable {
    case retry, reconnect, reconsent, chooseDestination, refetch, inspect, none
  }

  public struct RedactedTransferError: Error, Hashable, Sendable {
    public let category: TransferErrorCategory
    public let code: String
    public let userMessage: String
    public let recovery: TransferRecoveryAction
    public let occurredAt: Date

    public init(
      category: TransferErrorCategory,
      code: String,
      userMessage: String,
      recovery: TransferRecoveryAction,
      occurredAt: Date
    ) throws {
      let allowedCode = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
      let forbidden = ["://", "authorization", "dpop", "token=", "credential=", "cookie="]
      guard (1...64).contains(code.count),
            code.unicodeScalars.allSatisfy(allowedCode.contains),
            (1...240).contains(userMessage.count),
            !userMessage.contains("\n"), !userMessage.contains("\r"),
            forbidden.allSatisfy({ !userMessage.localizedCaseInsensitiveContains($0) })
      else { throw TransferModelError.unsafeRedactedError }
      self.category = category
      self.code = code
      self.userMessage = userMessage
      self.recovery = recovery
      self.occurredAt = occurredAt
    }
  }

  extension RedactedTransferError: Codable {
    private enum CodingKeys: String, CodingKey {
      case category, code, userMessage, recovery, occurredAt
    }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        category: c.decode(TransferErrorCategory.self, forKey: .category),
        code: c.decode(String.self, forKey: .code),
        userMessage: c.decode(String.self, forKey: .userMessage),
        recovery: c.decode(TransferRecoveryAction.self, forKey: .recovery),
        occurredAt: c.decode(Date.self, forKey: .occurredAt)
      )
    }
    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(category, forKey: .category)
      try c.encode(code, forKey: .code)
      try c.encode(userMessage, forKey: .userMessage)
      try c.encode(recovery, forKey: .recovery)
      try c.encode(occurredAt, forKey: .occurredAt)
    }
  }

  public enum TransferKind: String, CaseIterable, Hashable, Codable, Sendable {
    case blobDownload, blobAttachmentUpload, repositoryExport
    case fullBackup, backupVerification, crossSourceCopy
  }

  public enum TransferState: String, CaseIterable, Hashable, Codable, Sendable {
    case queued, discovering, waitingForPermission, running, verifying
    case completed, interrupted, cancelled, failed
    public var normalizedAfterRelaunch: Self {
      switch self { case .discovering, .running, .verifying: .interrupted; default: self }
    }
  }

  public struct TransferComponentDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let kind: String
    public let expectedByteCount: Int64?
  }

  public enum TransferComponentState: String, Hashable, Codable, Sendable {
    case pending, running, verified, failed
  }

  public struct TransferComponentCheckpoint: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var state: TransferComponentState
    public var observedSHA256: String?
    public var observedCID: String?
    public var byteCount: Int64?
    public var confirmedRemoteMutation: Bool
  }

  public struct VerifiedLocalFileResult: Hashable, Codable, Sendable {
    public let parentDirectoryBookmark: Data
    public let relativeFilename: String
    public let qualifiedSource: TransferEndpoint
    public let byteCount: Int64
    public let sha256: String
    public let expectedCIDConfirmed: Bool
  }

  public enum TransferResultDescriptor: Hashable, Codable, Sendable {
    case downloadedFile(VerifiedLocalFileResult)
    case repositoryCAR(VerifiedLocalFileResult)
    case backupPackage(packageID: UUID, parentDirectoryBookmark: Data, filename: String, manifestSHA256: String)
  }
  ```

  Define these version-1 payload values in the same file:

  ```swift
  public struct PersistedBlobUploadReceipt: Hashable, Codable, Sendable {
    public let blob: BlobLocator
    public let mimeType: String
    public let byteCount: Int64
    public let uploadedAt: Date
  }

  public struct BlobDownloadResumePayload: Hashable, Codable, Sendable {
    public let blob: BlobLocator
    public let parentDirectoryBookmark: Data
    public let filename: String
  }

  public enum AttachmentPersistedStage: String, Hashable, Codable, Sendable {
    case readLocalFile, uploadBlob, commitRecord, reconcileUncertainWrite, verifyRecordAndBlob
  }

  public struct AttachmentResumePayload: Hashable, Codable, Sendable {
    public let record: RecordLocator
    public let accountDID: String
    public let jsonPointer: String
    public let originalRecordCID: String
    public let mimeType: String
    public let sourceFilename: String
    public var sourceFileBookmark: Data?
    public var uploadedBlob: PersistedBlobUploadReceipt?
    public var stage: AttachmentPersistedStage
  }

  public struct RepositoryExportResumePayload: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let parentDirectoryBookmark: Data
    public let filename: String
    public let expectedRevision: String?
  }

  public enum BackupSubjectDescriptor: Hashable, Codable, Sendable {
    case record(locator: RecordLocator, recordCID: String)
    case repository(RepositoryScope)
    case wholeSpace(
      spaceURI: String,
      accountDID: String,
      authoritySnapshot: SpaceDeletionAuthoritySnapshot?
    )
  }

  public struct FullBackupResumePayload: Hashable, Codable, Sendable {
    public let packageID: UUID
    public let subject: BackupSubjectDescriptor
    public let parentDirectoryBookmark: Data
    public let finalFilename: String
  }

  public struct BackupVerificationResumePayload: Hashable, Codable, Sendable {
    public let packageID: UUID
    public let parentDirectoryBookmark: Data
    public let filename: String
    public let expectedManifestSHA256: String?
  }

  public struct DisclosureDecisionReceipt: Hashable, Codable, Sendable {
    public let policyVersion: Int
    public let source: RecordLocator
    public let sourceCID: String
    public let destination: RepositoryScope
    public let acceptedAt: Date
  }

  public struct ConflictDecisionReceipt: Hashable, Codable, Sendable {
    public let destination: RepositoryScope
    public let collection: String
    public let rkey: String
    public let observedDestinationCID: String
    public let decision: String
    public let acceptedAt: Date
  }

  public struct PersistedBlobMapping: Hashable, Codable, Sendable {
    public let source: BlobLocator
    public let destination: PersistedBlobUploadReceipt
  }

  public struct CrossSourceCopyResumePayload: Hashable, Codable, Sendable {
    public let source: RecordLocator
    public let originalSourceCID: String
    public let sourceAccountDID: String
    public let destination: RepositoryScope
    public let destinationAccountDID: String
    public let collection: String
    public let rkey: String
    public var disclosure: DisclosureDecisionReceipt?
    public var conflict: ConflictDecisionReceipt?
    public var uploadedBlobs: [PersistedBlobMapping]
  }

  public enum TransferResumePayload: Hashable, Sendable {
    case blobDownload(BlobDownloadResumePayload)
    case blobAttachmentUpload(AttachmentResumePayload)
    case repositoryExport(RepositoryExportResumePayload)
    case fullBackup(FullBackupResumePayload)
    case backupVerification(BackupVerificationResumePayload)
    case crossSourceCopy(CrossSourceCopyResumePayload)
    public var kind: TransferKind {
      switch self {
      case .blobDownload: .blobDownload
      case .blobAttachmentUpload: .blobAttachmentUpload
      case .repositoryExport: .repositoryExport
      case .fullBackup: .fullBackup
      case .backupVerification: .backupVerification
      case .crossSourceCopy: .crossSourceCopy
      }
    }
  }

  extension TransferResumePayload: Codable {
    private enum CodingKeys: String, CodingKey { case version, kind, payload }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let version = try container.decode(Int.self, forKey: .version)
      guard version == 1 else {
        throw DecodingError.dataCorruptedError(
          forKey: .version, in: container, debugDescription: "Unsupported transfer payload version \(version)"
        )
      }
      let kind = try container.decode(TransferKind.self, forKey: .kind)
      let payload = try container.superDecoder(forKey: .payload)
      switch kind {
      case .blobDownload: self = .blobDownload(try .init(from: payload))
      case .blobAttachmentUpload: self = .blobAttachmentUpload(try .init(from: payload))
      case .repositoryExport: self = .repositoryExport(try .init(from: payload))
      case .fullBackup: self = .fullBackup(try .init(from: payload))
      case .backupVerification: self = .backupVerification(try .init(from: payload))
      case .crossSourceCopy: self = .crossSourceCopy(try .init(from: payload))
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(1, forKey: .version)
      try container.encode(kind, forKey: .kind)
      let payload = container.superEncoder(forKey: .payload)
      switch self {
      case .blobDownload(let value): try value.encode(to: payload)
      case .blobAttachmentUpload(let value): try value.encode(to: payload)
      case .repositoryExport(let value): try value.encode(to: payload)
      case .fullBackup(let value): try value.encode(to: payload)
      case .backupVerification(let value): try value.encode(to: payload)
      case .crossSourceCopy(let value): try value.encode(to: payload)
      }
    }
  }

  private enum TransferEndpointPayloadValidator {
    static func validate(
      kind: TransferKind,
      source: TransferEndpoint,
      destination: TransferEndpoint,
      payload: TransferResumePayload
    ) throws {
      guard kind == payload.kind else { throw TransferModelError.kindPayloadMismatch }
      switch (payload, source, destination) {
      case let (.blobDownload(value), .blob(blob), .localFile(name)):
        guard blob == value.blob, name == value.filename else {
          throw TransferModelError.endpointPayloadMismatch
        }
      case let (.blobAttachmentUpload(value), .localFile(name), .record(record)):
        guard name == value.sourceFilename, record == value.record else {
          throw TransferModelError.endpointPayloadMismatch
        }
      case let (.repositoryExport(value), .repository(scope), .localFile(name)):
        guard scope == value.scope, name == value.filename else {
          throw TransferModelError.endpointPayloadMismatch
        }
      case let (.fullBackup(value), source, .backupPackage(packageID, filename)):
        guard packageID == value.packageID, filename == value.finalFilename,
              sourceMatches(value.subject, source) else {
          throw TransferModelError.endpointPayloadMismatch
        }
      case let (
        .backupVerification(value),
        .backupPackage(sourceID, sourceName),
        .backupPackage(destinationID, destinationName)
      ):
        guard sourceID == value.packageID, destinationID == value.packageID,
              sourceName == value.filename, destinationName == value.filename else {
          throw TransferModelError.endpointPayloadMismatch
        }
      case let (.crossSourceCopy(value), .record(record), .repository(scope)):
        guard record == value.source, scope == value.destination else {
          throw TransferModelError.endpointPayloadMismatch
        }
      default:
        throw TransferModelError.endpointPayloadMismatch
      }
    }

    private static func sourceMatches(
      _ subject: BackupSubjectDescriptor,
      _ endpoint: TransferEndpoint
    ) -> Bool {
      switch (subject, endpoint) {
      case let (.record(locator, _), .record(endpointLocator)):
        locator == endpointLocator
      case let (.repository(scope), .repository(endpointScope)):
        scope == endpointScope
      case let (.wholeSpace(spaceURI, accountDID, _), .space(endpointURI, endpointAccountDID)):
        spaceURI == endpointURI && accountDID == endpointAccountDID
      default:
        false
      }
    }
  }
  ```

  This manual encoding is a stable discriminated format, not the compiler's enum representation; unknown versions/kinds fail decoding. `BackupSubjectDescriptor.wholeSpace.authoritySnapshot` is nil only for an ordinary user-initiated whole-Space backup that may perform fresh discovery. Plan 2's Back Up First path always supplies its exact snapshot; because that validated snapshot is nested inside `FullBackupResumePayload`, an interruption or relaunch cannot silently replace it by re-enumerating authority state.

- [ ] **Step 4: Define descriptors/snapshots with exact-account and safe-result persistence**

  ```swift
  public struct TransferJobDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let kind: TransferKind
    public let source: TransferEndpoint
    public let destination: TransferEndpoint
    public let requiredAccountDIDs: Set<String>
    public let components: [TransferComponentDescriptor]
    public let resumePayload: TransferResumePayload
    public let createdAt: Date

    public init(
      id: UUID,
      kind: TransferKind,
      source: TransferEndpoint,
      destination: TransferEndpoint,
      requiredAccountDIDs: Set<String>,
      components: [TransferComponentDescriptor],
      resumePayload: TransferResumePayload,
      createdAt: Date
    ) throws {
      _ = try source.validated()
      _ = try destination.validated()
      try TransferEndpointPayloadValidator.validate(
        kind: kind, source: source, destination: destination, payload: resumePayload
      )
      guard Set(components.map(\.id)).count == components.count else {
        throw TransferModelError.duplicateComponentID
      }
      guard components.allSatisfy({
        !$0.id.isEmpty && !$0.kind.isEmpty && ($0.expectedByteCount.map { $0 >= 0 } ?? true)
      }) else { throw TransferModelError.invalidComponent }
      guard requiredAccountDIDs.allSatisfy({ !$0.isEmpty }) else {
        throw TransferModelError.invalidAccountDID
      }
      self.id = id
      self.kind = kind
      self.source = source
      self.destination = destination
      self.requiredAccountDIDs = requiredAccountDIDs
      self.components = components
      self.resumePayload = resumePayload
      self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
      case id, kind, source, destination, requiredAccountDIDs, components, resumePayload, createdAt
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        id: c.decode(UUID.self, forKey: .id),
        kind: c.decode(TransferKind.self, forKey: .kind),
        source: c.decode(TransferEndpoint.self, forKey: .source),
        destination: c.decode(TransferEndpoint.self, forKey: .destination),
        requiredAccountDIDs: c.decode(Set<String>.self, forKey: .requiredAccountDIDs),
        components: c.decode([TransferComponentDescriptor].self, forKey: .components),
        resumePayload: c.decode(TransferResumePayload.self, forKey: .resumePayload),
        createdAt: c.decode(Date.self, forKey: .createdAt)
      )
    }
  }

  public struct TransferJobSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID { descriptor.id }
    public let descriptor: TransferJobDescriptor
    public var state: TransferState
    public var progress: TransferProgress
    public var checkpoints: [TransferComponentCheckpoint]
    public var result: TransferResultDescriptor?
    public var retryCount: Int
    public var updatedAt: Date
    public var completedAt: Date?
    public var failure: RedactedTransferError?
    public var partialOutcomeMessage: String?

    public func validate() throws {
      _ = try descriptor.source.validated()
      _ = try descriptor.destination.validated()
      try TransferEndpointPayloadValidator.validate(
        kind: descriptor.kind, source: descriptor.source,
        destination: descriptor.destination, payload: descriptor.resumePayload
      )
      let expected = Set(descriptor.components.map(\.id))
      let observed = checkpoints.map(\.id)
      guard observed.count == Set(observed).count, Set(observed) == expected else {
        throw TransferModelError.invalidCheckpointSet
      }
      guard retryCount >= 0 else { throw TransferModelError.invalidRetryCount }
      guard progress.totalComponentCount == descriptor.components.count else {
        throw TransferModelError.invalidProgress
      }
      if state == .completed {
        guard completedAt != nil, failure == nil else {
          throw TransferModelError.invalidTerminalMetadata
        }
      } else {
        guard completedAt == nil, result == nil else {
          throw TransferModelError.invalidTerminalMetadata
        }
      }
      guard (failure == nil) == (state != .failed) else {
        throw TransferModelError.invalidTerminalMetadata
      }
    }
  }

  extension TransferJobSnapshot {
    private enum CodingKeys: String, CodingKey {
      case descriptor, state, progress, checkpoints, result, retryCount
      case updatedAt, completedAt, failure, partialOutcomeMessage
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        descriptor: try c.decode(TransferJobDescriptor.self, forKey: .descriptor),
        state: try c.decode(TransferState.self, forKey: .state),
        progress: try c.decode(TransferProgress.self, forKey: .progress),
        checkpoints: try c.decode([TransferComponentCheckpoint].self, forKey: .checkpoints),
        result: try c.decodeIfPresent(TransferResultDescriptor.self, forKey: .result),
        retryCount: try c.decode(Int.self, forKey: .retryCount),
        updatedAt: try c.decode(Date.self, forKey: .updatedAt),
        completedAt: try c.decodeIfPresent(Date.self, forKey: .completedAt),
        failure: try c.decodeIfPresent(RedactedTransferError.self, forKey: .failure),
        partialOutcomeMessage: try c.decodeIfPresent(String.self, forKey: .partialOutcomeMessage)
      )
      try validate()
    }

    public func encode(to encoder: Encoder) throws {
      try validate()
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(descriptor, forKey: .descriptor)
      try c.encode(state, forKey: .state)
      try c.encode(progress, forKey: .progress)
      try c.encode(checkpoints, forKey: .checkpoints)
      try c.encodeIfPresent(result, forKey: .result)
      try c.encode(retryCount, forKey: .retryCount)
      try c.encode(updatedAt, forKey: .updatedAt)
      try c.encodeIfPresent(completedAt, forKey: .completedAt)
      try c.encodeIfPresent(failure, forKey: .failure)
      try c.encodeIfPresent(partialOutcomeMessage, forKey: .partialOutcomeMessage)
    }
  }
  ```

  Validate one checkpoint per component ID and no unknown checkpoint IDs. `requiredAccountDIDs` is empty for anonymous public discovery/download/export and contains only accounts actually needed for authenticated Space/public write work. A payload persists bookmarks, locators, precondition CIDs, pointer, stages, receipts, mappings, and decision receipts only—never bodies, bytes, auth objects, or closures. Before upload, attachment retains the source-file bookmark and filename; once upload is CID-verified it may drop that bookmark because later stages refetch the record and use the receipt. The display-only `.localFile(name:)` endpoint never retains bookmark bytes, so this drop actually removes the last durable local-file capability.

- [ ] **Step 5: Add owner-only, versioned, atomic JSON persistence**

  `PersistenceCoding` uses ISO-8601 dates and sorted keys. `JSONTransferPersistence` stores an envelope `{ "version": 1, "jobs": [...] }` under a `0700` directory and `0600` atomic file, rejects future versions, validates every decoded job, normalizes active states, and rewrites normalized state before returning it. Its public protocol is:

  ```swift
  public protocol TransferJobPersisting: Sendable {
    func load() async throws -> [TransferJobSnapshot]
    func save(_ jobs: [TransferJobSnapshot]) async throws
  }
  ```

  A corrupted/unknown payload is retained as a quarantined `.failed` job only when its outer descriptor and ID can be safely decoded; otherwise move the original file to a UUID-qualified `.invalid` sibling and start empty with a surfaced app error. Never silently discard it.

- [ ] **Step 6: Hand off membership, run the focused suite, inspect JSON, and seal**

  Run Step 2 again. Expected: PASS; every payload/result round-trips, active work becomes interrupted, and a text audit finds no secret/body/byte field.

  ```bash
  jj status
  jj diff --summary
  jj describe -m "transfers: persist per-kind resume payloads and results"
  jj new
  ```

### Task 6: Implement the Complete Transfer State Machine, Executor Registry, and Activity UI

**Files:**
- Create: `ATProtoDrive/Transfers/TransferExecutors.swift`
- Create: `ATProtoDrive/Transfers/TransferQueue.swift`
- Create: `ATProtoDrive/Transfers/TransferStore.swift`
- Create: `ATProtoDrive/Transfers/ActivityView.swift`
- Create: `ATProtoDrive/Transfers/ActivityInspectorView.swift`
- Create: `ATProtoDriveTests/TransferQueueTests.swift`
- Modify by the cross-plan integration owner: `ATProtoDrive/ATProtoDriveApp.swift`
- Modify by the cross-plan integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: all Task 5 types, `BrowserSession`, and `ResourceReference`.
- Produces: `TransferOperationExecuting`, fixed `TransferExecutorRegistry`, all six kind adapters, `TransferExecutionContext/Result`, exhaustive `TransferStateMachine`, resume planner, actor `TransferQueue`, observable `TransferStore`, and Activity views.

- [ ] **Step 1: Write failing registry, transition, queue cancellation/retry/restore, account-removal, ordering, and result tests**

  ```swift
  @Suite("Transfer queue")
  struct TransferQueueTests {
    @Test("registry rejects duplicate and missing kinds")
    func completeRegistry() throws {
      #expect(throws: TransferRegistryError.duplicate(.blobDownload)) {
        try TransferExecutorRegistry(TransferFixtureSupport.duplicateBlobExecutors())
      }
      #expect(throws: TransferRegistryError.missing(Set([.crossSourceCopy]))) {
        try TransferExecutorRegistry(TransferFixtureSupport.executors(excluding: [.crossSourceCopy]))
      }
    }

    @Test("transition table includes queued cancellation and rejects every unspecified edge")
    func exhaustiveTransitions() {
      for from in TransferState.allCases {
        for to in TransferState.allCases {
          #expect(TransferStateMachine.canTransition(from: from, to: to) == TransitionFixture.expected(from, to))
        }
      }
      #expect(TransferStateMachine.canTransition(from: .queued, to: .cancelled))
      #expect(!TransferStateMachine.canTransition(from: .completed, to: .queued))
    }

    @Test("bounded execution cancels queued and in-flight jobs between components")
    func cancellation() async throws {
      let executor = BlockingTransferExecutor(kind: .blobDownload)
      let fixture = try QueueFixture(executorOverride: executor, maximumConcurrentJobs: 1)
      let runningID = try await fixture.queue.enqueue(.fixturePublicDownload(id: UUID()))
      let queuedID = try await fixture.queue.enqueue(.fixturePublicDownload(id: UUID()))
      await fixture.queue.start()
      await executor.waitUntilComponentStarted()
      try await fixture.queue.cancel(id: queuedID)
      try await fixture.queue.cancel(id: runningID)
      #expect(await fixture.queue.snapshot(id: queuedID)?.state == .cancelled)
      #expect(await fixture.queue.snapshot(id: runningID)?.state == .cancelled)
      #expect(await executor.maximumObservedConcurrency == 1)
      #expect(await executor.componentsStarted == 1)
    }

    @Test("deliberate retry and restore reconstruct by payload kind and preserve result")
    func retryRestoreAndReveal() async throws {
      let persistence = InMemoryTransferPersistence(jobs: [
        .fixtureInterruptedDownload(), .fixtureCompletedDownloadWithResult()
      ])
      let first = try QueueFixture(persistence: persistence)
      try await first.queue.restore()
      try await first.queue.retry(id: TransferFixtureSupport.interruptedID)
      await first.queue.start()
      await first.waitForCompletion(TransferFixtureSupport.interruptedID)

      let relaunched = try QueueFixture(persistence: persistence)
      try await relaunched.queue.restore()
      #expect(await relaunched.registry.executedKinds.contains(.blobDownload))
      #expect(await relaunched.queue.snapshot(id: TransferFixtureSupport.completedID)?.result == .downloadedFile(.fixtureVerifiedFile()))
    }

    @Test("persistence happens before each public snapshot")
    func persistenceBeforePublication() async throws {
      let events = QueueEventRecorder()
      let queue = try QueueFixture(eventRecorder: events).queue
      _ = try await queue.enqueue(.fixtureAnonymousPublicDownload())
      #expect(await events.values.prefix(2) == ["persist:queued", "publish:queued"])
    }

    @Test("removing exact accounts waits only their authenticated work")
    func exactAccountRemoval() async throws {
      let fixture = try QueueFixture(jobs: [
        .fixtureAnonymousPublicDownload(), .fixtureSpaceDownload(accountDID: "did:plc:alice"),
        .fixtureSpaceDownload(accountDID: "did:plc:bob")
      ])
      let receipt = try await fixture.queue.markAccountsUnavailable(["did:plc:alice"])
      #expect(await fixture.queue.state(of: TransferFixtureSupport.anonymousID) == .queued)
      #expect(await fixture.queue.state(of: TransferFixtureSupport.aliceID) == .waitingForPermission)
      #expect(await fixture.queue.state(of: TransferFixtureSupport.bobID) == .queued)
      #expect(receipt.parkedJobIDs == [TransferFixtureSupport.aliceID])
      #expect(await fixture.persistence.atomicSaveCount == 1)
    }

    @Test("repeated account parking returns a fresh receipt without new queue work")
    func accountParkingRetryIsIdempotent() async throws {
      let events = QueueEventRecorder()
      let fixture = try QueueFixture(
        jobs: [.fixtureSpaceDownload(
          id: TransferFixtureSupport.aliceID, accountDID: "did:plc:alice"
        )],
        eventRecorder: events
      )
      let first = try await fixture.queue.markAccountsUnavailable(["did:plc:alice"])
      let savesAfterFirst = await fixture.persistence.atomicSaveCount
      let publicationsAfterFirst = await events.publicationCount
      let cancellationsAfterFirst = await events.cancellationRequestCount

      let second = try await fixture.queue.markAccountsUnavailable(["did:plc:alice"])

      #expect(first.parkedJobIDs == [TransferFixtureSupport.aliceID])
      #expect(second.accountDIDs == ["did:plc:alice"])
      #expect(second.parkedJobIDs == first.parkedJobIDs)
      #expect(second.terminationBarrierPassedAt >= first.terminationBarrierPassedAt)
      #expect(await fixture.queue.state(of: TransferFixtureSupport.aliceID) == .waitingForPermission)
      #expect(await fixture.persistence.atomicSaveCount == savesAfterFirst)
      #expect(await events.publicationCount == publicationsAfterFirst)
      #expect(await events.cancellationRequestCount == cancellationsAfterFirst)
    }

    @Test("account parking is durable and waits for a cancellation fence before returning")
    func accountParkingTerminationBarrier() async throws {
      let lateCallbacks = LateCallbackProbe()
      let executor = CancellationFencedBlockingExecutor(
        kind: .blobDownload, lateCallbackProbe: lateCallbacks
      )
      let fixture = try QueueFixture(
        executorOverride: executor,
        jobs: [.fixtureSpaceDownload(id: TransferFixtureSupport.aliceID, accountDID: "did:plc:alice")]
      )
      await fixture.queue.start()
      await executor.waitUntilStarted()
      let savesBeforeParking = await fixture.persistence.atomicSaveCount

      let parking = Task {
        let receipt = try await fixture.queue.markAccountsUnavailable(["did:plc:alice"])
        await lateCallbacks.recordParkingReturned()
        return receipt
      }
      await executor.waitUntilCancellationObserved()
      #expect(await fixture.persistence.lastSavedState(id: TransferFixtureSupport.aliceID) == .waitingForPermission)
      #expect(await fixture.queue.state(of: TransferFixtureSupport.aliceID) == .waitingForPermission)
      #expect(!(await lateCallbacks.parkingReturned))

      await executor.attemptLateCallbacksThenTerminate()
      let receipt = try await parking.value
      #expect(receipt.accountDIDs == ["did:plc:alice"])
      #expect(receipt.parkedJobIDs == [TransferFixtureSupport.aliceID])
      #expect(await lateCallbacks.events == [
        .reportRejectedAsStale, .checkpointRejectedAsStale,
        .executorTerminated, .completionRejectedAsStale, .parkingReturned
      ])
      #expect(await fixture.queue.state(of: TransferFixtureSupport.aliceID) == .waitingForPermission)
      #expect(await fixture.persistence.atomicSaveCount == savesBeforeParking + 1)
    }
  }
  ```

- [ ] **Step 2: Run the focused suite and verify the intended failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task6.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/TransferQueueTests
  ```

  Expected: FAIL because the registry, state machine, and queue do not exist.

- [ ] **Step 3: Implement a fixed, complete executor registry and safe result boundary**

  ```swift
  public protocol TransferOperationExecuting: Sendable {
    var kind: TransferKind { get }
    func execute(
      payload: TransferResumePayload,
      descriptors: [TransferComponentDescriptor],
      checkpoints: [TransferComponentCheckpoint],
      context: TransferExecutionContext
    ) async throws -> TransferExecutionResult
  }

  public struct TransferExecutionResult: Sendable {
    public let checkpoints: [TransferComponentCheckpoint]
    public let result: TransferResultDescriptor?
    public let partialOutcomeMessage: String?
  }

  public struct TransferExecutionContext: Sendable {
    public let report: @Sendable (TransferProgress) async throws -> Void
    public let checkpoint: @Sendable ([TransferComponentCheckpoint], TransferResumePayload) async throws -> Void
  }

  public struct TransferExecutorRegistry: Sendable {
    private let values: [TransferKind: any TransferOperationExecuting]
    public init(_ executors: [any TransferOperationExecuting]) throws
    public func executor(for kind: TransferKind) throws -> any TransferOperationExecuting
  }

  public struct TransferAccountParkingReceipt: Hashable, Sendable {
    public let accountDIDs: Set<String>
    public let parkedJobIDs: [UUID] // UUID-string sort order
    public let terminationBarrierPassedAt: Date
  }

  public enum TransferQueueError: Error, Hashable, Sendable {
    case unknownJob(UUID)
    case invalidTransition(from: TransferState, to: TransferState)
    case invalidAccountDID
    case staleExecutionGeneration(jobID: UUID, expected: UInt64, received: UInt64)
  }
  ```

  Initialization rejects duplicate kinds and requires exactly `Set(TransferKind.allCases)`. Supply `BlobDownloadTransferExecutor`, `AttachmentTransferExecutor`, `RepositoryExportTransferExecutor`, `FullBackupTransferExecutor`, `BackupVerificationTransferExecutor`, and `CrossSourceCopyTransferExecutor`. The blob executor is functional now and streams to a bookmark-resolved destination with expected-CID verification. The five adapters decode only their exact payload and call narrow driver protocols declared here; Tasks 7, 11, and 12 provide the live drivers without changing registry shape. A mismatched payload or absent live driver becomes a redacted `.failed(.unsupported)` state, never a crash or silent completion.

  Results contain only Task 5's verified bookmark/name/hash/qualified-identity descriptor. Queue completion persists the result before publication so Reveal/Open survives relaunch.

- [ ] **Step 4: Implement one exhaustive state machine and component-safe resume**

  Legal ordinary edges are:

  ```text
  queued -> discovering | cancelled
  discovering -> waitingForPermission | running | failed | cancelled
  waitingForPermission -> queued | failed | cancelled
  running -> verifying | interrupted | failed | cancelled
  verifying -> completed | interrupted | failed | cancelled
  interrupted | failed | cancelled -> queued  (explicit retry only)
  completed -> no state
  ```

  The exact-account administrative operation additionally allows any nonterminal authenticated job in `queued`, `discovering`, `running`, `verifying`, `interrupted`, or `failed` to move atomically to `waitingForPermission`. A matching job already in `waitingForPermission` is already parked: it is included in the returned receipt but undergoes no transition. This edge is legal only inside `markAccountsUnavailable` and is tested separately; anonymous/unrelated/completed/cancelled jobs are byte-for-byte unchanged.

  `TransferResumePlanner` compares each verified checkpoint's observed SHA-256/CID to the current local artifact. Valid matches skip; missing/changed files restart that component. `Task.checkCancellation()` runs before and after every component and before every irreversible operation. Never automatically retry a checkpoint with `confirmedRemoteMutation`; its executor first reconciles remote state.

- [ ] **Step 5: Implement the bounded actor, atomic exact-account API, and persistence-before-publication**

  ```swift
  public actor TransferQueue {
    public init(
      persistence: any TransferJobPersisting,
      registry: TransferExecutorRegistry,
      maximumConcurrentJobs: Int
    ) throws
    public func enqueue(_ descriptor: TransferJobDescriptor) async throws -> UUID
    public func restore() async throws
    public func start() async
    public func cancel(id: UUID) async throws
    public func retry(id: UUID) async throws
    public func resume(id: UUID) async throws
    public func snapshot(id: UUID) -> TransferJobSnapshot?
    public func state(of id: UUID) -> TransferState?
    public func markAccountsUnavailable(_ accountDIDs: Set<String>) async throws
      -> TransferAccountParkingReceipt
    public func markAccountsAvailable(_ accountDIDs: Set<String>) async throws
    public func snapshots() -> AsyncStream<[TransferJobSnapshot]>
  }
  ```

  Every mutation follows: validate full next job dictionary → one atomic `persistence.save` → replace actor dictionary → yield snapshot. `snapshot(id:)` and `state(of:)` are actor-isolated, read-only point observations over the last persisted-and-published dictionary; tests and Plan 4 never reach into queue storage.

  Every execution captures `executionGeneration[jobID]`. Both `TransferExecutionContext` closures and the final result callback re-enter the actor with that captured generation; a mismatch throws/records `TransferQueueError.staleExecutionGeneration` and cannot mutate, persist, or publish. `markAccountsUnavailable` performs this exact barrier:

  1. Validate the nonempty exact DID set and select only nonterminal jobs whose `requiredAccountDIDs` intersect it. Partition them into `alreadyParked` (`waitingForPermission`) and `toPark` (the six administrative-source states above). Only `toPark` has its execution generation synchronously incremented, fencing callbacks from old tasks.
  2. If `toPark` is nonempty, build its `waitingForPermission` snapshots from the last durable checkpoints, validate the whole dictionary, save that dictionary once, replace it, and yield exactly once. If this save fails, keep the last published dictionary, cancel and await the already-fenced handles, surface a queue-persistence fault, and throw; Plan 4 must retain the account/client and no removal proceeds. A later retry can durably park the still-selected snapshots, while a process relaunch normalizes any formerly active durable state to `interrupted`.
  3. Cancel every `toPark` task handle, then await every handle's `value`. A cancelled executor may unwind or attempt callbacks, but all old-generation report/checkpoint/completion callbacks are rejected. Remove a handle only after its exact task terminates. Never cancel, await, reschedule, or otherwise touch an `alreadyParked` job.
  4. Return `TransferAccountParkingReceipt` only after the termination barrier, with the UUID-string-sorted union of `alreadyParked` and newly parked job IDs. When every match was already parked, return a fresh receipt immediately with a fresh `terminationBarrierPassedAt`; perform no persistence save, publication yield, generation increment, cancellation, or executor work. This makes retries after Plan 4 receives a receipt but fails to persist its tombstone step operationally idempotent. Plan 4 must call and await this method **first**, and may remove OAuth/client/cache state only after the receipt returns.

  `CancellationFencedBlockingExecutor` and `LateCallbackProbe` are the shared deterministic test doubles defined in `TransferFixtureSupport.swift`; the former blocks until cancellation, deliberately attempts a progress and checkpoint callback after cancellation, then returns a result. The fixture's queue rejection observer records the stale final-result callback as `.completionRejectedAsStale`, proving the executor's return cannot overwrite the parked snapshot. `markAccountsAvailable` requeues only waiting jobs whose full required set is available and only after the user has reconnected/reconsented. Restore validates/reconstructs each executor from its payload; recoverable interrupted jobs remain resumable, and an unrecoverable payload is `.failed` with “Needs attention” copy while the exact nine-state enum remains unchanged.

- [ ] **Step 6: Bind the observable projection and Activity surfaces**

  ```swift
  @MainActor @Observable
  public final class TransferStore {
    public private(set) var jobs: [TransferJobSnapshot] = []
    public func bind(to queue: TransferQueue) {
      observationTask?.cancel()
      observationTask = Task {
        for await snapshots in await queue.snapshots() {
          guard !Task.isCancelled else { return }
          jobs = snapshots.sorted { $0.descriptor.createdAt > $1.descriptor.createdAt }
        }
      }
    }
  }
  ```

  `ActivityView` columns are Item, Kind, State, Progress, Updated, and Source. Actions come only from state-machine eligibility. `ActivityInspectorView` shows immutable components beside mutable checkpoints, exact required account DIDs, retry count, redacted failure, destination/access, partial remote outcomes, and persisted result. Reveal is enabled only for a verified result whose bookmark resolves and whose current SHA-256 still matches; it invokes a Task 11 `@MainActor` presenter.

- [ ] **Step 7: Have the integration owner inject one app-scoped queue, then test/build**

  The integration owner constructs the complete registry from app dependencies, owns one queue/store for all windows, calls `restore()` before `start()`, binds the store once, and routes Activity. Windows own selection only.

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/TransferQueueTests
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  ```

  Expected: PASS; all six kinds register, at most the bound runs, cancel/retry/restore and reveal survive persistence, and exact-account removal does not touch anonymous/unrelated work.

- [ ] **Step 8: Seal the queue and Activity slice**

  ```bash
  jj status
  jj diff --summary
  jj describe -m "transfers: add complete durable queue and activity UI"
  jj new
  ```

### Task 7: Make Attach File Durable and Honest About Partial Remote Outcomes

**Files:**
- Create: `ATProtoDrive/Transfers/AttachmentCoordinator.swift`
- Create: `ATProtoDriveTests/AttachmentCoordinatorTests.swift`
- Modify: `ATProtoDrive/Write/RecordEditorSheet.swift`
- Modify: `ATProtoDrive/Mutation/MutationCoordinator.swift`
- Modify: `ATProtoDrive/Transfers/TransferQueue.swift`
- Modify: `ATProtoDrive/Transfers/TransferExecutors.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: Plan 2 `MutationCoordinator`, `MutationOutcome`, `MutationPartialOutcome`, and exact access checks; Task 5 `AttachmentResumePayload`/`PersistedBlobUploadReceipt`; queue/executor contracts; Petrel `Blob`; and qualified locators.
- Produces: non-Codable `RecordAttachmentDraft`, `AttachmentOutcome`, `RecordAttachmentCommitting`, live `AttachmentTransferDriver`, and `AttachmentCoordinator.attach(sourceBookmark:mimeType:draft:)`.

- [ ] **Step 1: Write failing staged-success and uploaded-but-unreferenced tests**

  ```swift
  @Suite("Attachment coordinator")
  struct AttachmentCoordinatorTests {
    @Test("success requires upload, record commit, record refetch, and blob reachability")
    func verifiedSuccess() async throws {
      let calls = AttachmentCallRecorder()
      let coordinator = AttachmentCoordinator(
        upload: { data, mimeType, accountDID in
          await calls.record("upload:\(data.count):\(mimeType):\(accountDID)")
          return .fixture(cid: "bafkblob")
        },
        commit: { draft, blob in
          await calls.record("commit:\(draft.record.uri):\(blob.blob.cid)")
          return .verified(.fixture(uri: draft.record.uri, cid: "bafynew", blobCID: blob.blob.cid))
        },
        refetchRecord: { locator, pointer, expectedBlobCID in
          await calls.record("record")
          return .fixture(locator: locator, blobAt: pointer, blobCID: expectedBlobCID)
        },
        verifyBlob: { blob in
          await calls.record("blob")
          return .fixture(blob: blob, expectedCIDConfirmed: true)
        }
      )
      let outcome = try await coordinator.attach(
        sourceBookmark: try SecurityScopedFileFixture.bookmark(bytes: [1, 2, 3]),
        mimeType: "image/png",
        draft: .fixture(jsonPointer: "/image")
      )
      #expect(outcome.isVerifiedSuccess)
      #expect(await calls.values == [
        "upload:3:image/png:did:plc:alice", "commit:at://did:plc:alice/app.example.file/one:bafkblob",
        "record", "blob"
      ])
    }

    @Test("record failure reports a retryable unreferenced upload without claiming rollback")
    func partialOutcome() async throws {
      let coordinator = AttachmentCoordinator.fixture(commitError: TestError.conflict)
      let outcome = try await coordinator.attach(
        sourceBookmark: try SecurityScopedFileFixture.bookmark(bytes: [4]),
        mimeType: "application/octet-stream",
        draft: .fixture(jsonPointer: "/payload")
      )
      guard case .uploadedButUnreferenced(let receipt, let retry) = outcome else {
        Issue.record("Expected uploadedButUnreferenced")
        return
      }
      #expect(receipt.blob.cid == "bafkblob")
      #expect(retry.payload.stage == .commitRecord)
      #expect(retry.rollbackWasAttempted == false)
    }

    @Test("response loss after server commit reconciles before retry and performs one mutation")
    func uncertainWriteReconcilesCommittedRecord() async throws {
      let server = AttachmentServerFixture(commitThenLoseResponse: true)
      let coordinator = AttachmentCoordinator.fixture(server: server)
      let first = try await coordinator.attach(
        sourceBookmark: try SecurityScopedFileFixture.bookmark(bytes: [4]),
        mimeType: "application/octet-stream",
        draft: .fixture(jsonPointer: "/payload")
      )
      guard case .remoteWriteUnverified = first else {
        Issue.record("Expected remoteWriteUnverified")
        return
      }
      let reconciled = try await coordinator.resume(jobID: coordinator.jobID)
      #expect(reconciled.isVerifiedSuccess)
      #expect(await server.mutationCallCount == 1)
      #expect(await server.refetchedBlobCID(at: "/payload") == server.uploadedCID)
    }

    @Test("true pre-commit failure becomes unreferenced only after refetch proves absence")
    func trueFailureIsProved() async throws {
      let server = AttachmentServerFixture(failBeforeCommit: true)
      let outcome = try await AttachmentCoordinator.fixture(server: server).attach(
        sourceBookmark: try SecurityScopedFileFixture.bookmark(bytes: [5]),
        mimeType: "application/octet-stream",
        draft: .fixture(jsonPointer: "/payload")
      )
      guard case .uploadedButUnreferenced(let receipt, _) = outcome else {
        Issue.record("Expected proved unreferenced outcome")
        return
      }
      #expect(await server.refetchCount == 1)
      #expect(receipt.blob.cid == server.uploadedCID)
    }

    @Test("verified success requires exact pointer and CID")
    func exactReferenceRequired() async throws {
      let coordinator = AttachmentCoordinator.fixture(
        refetchedPointer: "/different", refetchedBlobCID: "bafk-other"
      )
      await #expect(throws: AttachmentError.referenceVerificationFailed) {
        _ = try await coordinator.attach(
          sourceBookmark: try SecurityScopedFileFixture.bookmark(bytes: [6]),
          mimeType: "application/octet-stream", draft: .fixture(jsonPointer: "/payload")
        )
      }
    }
  }
  ```

- [ ] **Step 2: Run the focused test and verify the expected failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task7.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/AttachmentCoordinatorTests
  ```

  Expected: FAIL because `AttachmentCoordinator` and its staged outcome types do not exist.

- [ ] **Step 3: Implement the explicit stage contract**

  ```swift
  /// In-memory editor state. Deliberately not Codable: record bodies never enter transfer persistence.
  public struct RecordAttachmentDraft: Hashable, Sendable {
    public let record: RecordLocator
    public let accountDID: String
    public let jsonPointer: String
    public let originalRecordCID: String
    public let editedJSON: String
  }

  public typealias AttachmentUploadReceipt = PersistedBlobUploadReceipt

  public struct AttachmentRetryDescriptor: Hashable, Codable, Sendable {
    public let payload: AttachmentResumePayload
    public let rollbackWasAttempted: Bool
  }

  public enum AttachmentOutcome: Sendable {
    case verified(record: RecordRow, blob: BlobDescriptor)
    case uploadedButUnreferenced(receipt: AttachmentUploadReceipt, retry: AttachmentRetryDescriptor)
    case remoteWriteUnverified(partial: MutationPartialOutcome, retry: AttachmentRetryDescriptor)
  }

  public protocol RecordAttachmentCommitting: Sendable {
    func commitAttachment(
      draft: RecordAttachmentDraft,
      blob: AttachmentUploadReceipt
    ) async throws -> MutationOutcome
  }
  ```

  Make `MutationCoordinator` conform to `RecordAttachmentCommitting`: public records keep CAS; Space records keep the explicit alpha preflight/warning. Before reading bytes, resolve a persisted security-scoped source-file bookmark; validate advertised upload limit and local access. If the exact account lacks `.blobUpload(mimeType:)`, persist the payload and move only that job to `waitingForPermission`; resume after the exact grant is re-read. Record commit separately requires Plan 2's `.publicRecord` or `.spaceRecord` context. Insert/replace exactly at `jsonPointer`, preserve unknown keys, validate, submit once, and preserve the returned `MutationOutcome`.

  For `.verified`, refetch the exact record and require its current value at the RFC 6901 pointer to be a blob whose CID equals the upload receipt, then stream/refetch that CID and require expected-CID verification; a void callback is insufficient. For `.remoteWriteUnverified`, checkpoint `.reconcileUncertainWrite`, receipt, pointer, and original CID, then refetch before exposing any retry. If refetch contains the intended exact reference, finish verification without another mutation. If it proves the original record is unchanged and lacks the ref, report `uploadedButUnreferenced` and permit deliberate commit retry. Any different record/CID becomes a conflict requiring fresh user intent. Never call an uncertain write “unreferenced” merely because the response was lost.

- [ ] **Step 4: Register one queue job and preserve the partial checkpoint**

  The job components are `local-read`, `blob-upload`, `record-commit`, `uncertain-reconciliation`, and `reachability-verification`. Enqueue first with `AttachmentResumePayload.sourceFileBookmark` and no record body. Once upload succeeds, atomically checkpoint the receipt/stage and drop the source bookmark if no later local read is needed. A known pre-submit failure keeps `blob-upload` verified but still refetches before labeling it **Temporary unreferenced upload**. After relaunch, refetch the current record, require its CID to equal `originalRecordCID` before applying only the stored blob-reference patch; otherwise show conflict. A confirmed/uncertain remote mutation checkpoint prevents generic queue retry from resubmitting; only reconciliation may advance it.

- [ ] **Step 5: Wire the editor, run tests/build, and seal**

  `RecordEditorSheet` uses a file importer, creates the security-scoped bookmark before enqueue, shows target repository/access class and advertised limit, and displays the exact partial/uncertain outcome. It does not add a standalone Upload or Delete Blob action. `AttachmentTransferExecutor` now receives the live driver and reconstructs every stage exclusively from `AttachmentResumePayload` plus refetched state.

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task7-build.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/AttachmentCoordinatorTests
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  ```

  Expected: PASS; success proves the exact pointer/CID, a response-lost committed write is never duplicated, and a genuinely absent reference is visible/resumable without a rollback claim.

  ```bash
  jj status
  jj diff --summary
  jj describe -m "transfers: make attachment uploads resumable and honest"
  jj new
  ```

### Task 8: Define the Executable Versioned Backup Schema and Readable Record Index

**Files:**
- Create: `ATProtoDrive/Backups/BackupManifest.swift`
- Create: `ATProtoDrive/Backups/BackupTypes.swift`
- Create: `ATProtoDrive/Backups/RecordsIndex.swift`
- Create: `ATProtoDriveTests/BackupFixtureSupport.swift`
- Create: `ATProtoDriveTests/BackupManifestTests.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: qualified scopes/locators, `AccessClassification`, and CAR-derived records.
- Produces complete Codable definitions for requests, plans, source/claim observations, artifacts, paths, verification, completion, manifest, record index, errors, validation, and deterministic test fixtures.

- [ ] **Step 1: Write failing schema, digest-path, validation, and completeness tests**

  ```swift
  @Suite("Backup manifest v1")
  struct BackupManifestTests {
    @Test("full lowercase SHA-256 paths are deterministic, qualified, and collision resistant")
    func digestPaths() throws {
      let space = "at://did:plc:owner/space/app.example.drive/shared"
      let writer = "did:plc:writer"
      let first = try BackupPath.spaceRepository(spaceURI: space, writerDID: writer)
      let second = try BackupPath.spaceRepository(spaceURI: space + "2", writerDID: writer)
      #expect(first.rawValue == try BackupPath.spaceRepository(spaceURI: space, writerDID: writer).rawValue)
      #expect(first.rawValue != second.rawValue)
      #expect(first.components[1].count == 64 && first.components[2].count == 64)
      #expect(!first.rawValue.contains(space) && !first.rawValue.contains(writer))
    }

    @Test("manifest round trips every exact source and artifact field")
    func roundTrip() throws {
      let manifest = try BackupFixtureSupport.completeWholeSpaceManifest()
      let data = try PersistenceCoding.encoder().encode(manifest)
      let decoded = try PersistenceCoding.decoder().decode(BackupManifest.self, from: data)
      try decoded.validate()
      #expect(decoded == manifest)
      #expect(decoded.formatVersion == 1)
      let authorityVersion = try #require(
        decoded.source.authorityClaim?.writers.first?.authoritySignedVersion
      )
      let writerVersion = try #require(
        decoded.repositories.first?.writerObservation?.writerSignedVersion
      )
      #expect(authorityVersion.repositoryVersion == .spaceSignedCommit(
        revision: authorityVersion.revision, hashBase64: authorityVersion.hashBase64
      ))
      #expect(writerVersion.repositoryVersion == .spaceSignedCommit(
        revision: writerVersion.revision, hashBase64: writerVersion.hashBase64
      ))
      #expect(decoded.repositories.first?.carRootCID != writerVersion.hashBase64)
    }

    @Test("single-writer Space backup validates without an authority claim")
    func singleWriterHasNoSyntheticAuthority() throws {
      let manifest = try BackupFixtureSupport.completeSingleWriterManifest()
      try manifest.validate()
      #expect(manifest.repositories.count == 1)
      let repository = try #require(manifest.repositories.first)
      let observation = try #require(repository.writerObservation)
      #expect(manifest.source.authorityClaim == nil)
      #expect(observation.agreesWithAuthorityClaim == nil)
      #expect(repository.repositoryVersion == .spaceSignedCommit(
        observation.writerSignedVersion
      ))
      guard case .some(.singleWriter(let writerDID, _)) = manifest.spaceCompleteness else {
        Issue.record("Expected single-writer completeness"); return
      }
      #expect(writerDID == observation.writerDID)
    }

    @Test("authority disagreement is retained while writer observation must match the CAR")
    func spaceVersionReconciliation() throws {
      let staleAuthority = try BackupFixtureSupport.completeWholeSpaceManifest(
        authorityAgreesWithObservation: false
      )
      try staleAuthority.validate()
      let claim = try #require(
        staleAuthority.source.authorityClaim?.writers.first?.authoritySignedVersion
      )
      let observation = try #require(
        staleAuthority.repositories.first?.writerObservation
      )
      #expect(claim != observation.writerSignedVersion)
      #expect(observation.agreesWithAuthorityClaim == false)
      #expect(staleAuthority.repositories.first?.repositoryVersion ==
        .spaceSignedCommit(observation.writerSignedVersion))

      for mutation in BackupFixtureSupport.SpaceObservedVersionMutation.allCases {
        #expect(throws: BackupManifestError.spaceVersionMismatch) {
          _ = try BackupFixtureSupport.completeWholeSpaceManifest(
            observedVersionMutation: mutation
          )
        }
      }
    }

    @Test("completion is relative to the full authority claim and never shrinks failed writers")
    func qualifiedCompleteness() {
      let claim = BackupFixtureSupport.authorityClaim(writers: ["did:plc:a", "did:plc:b"])
      let result = SpaceBackupCompleteness.evaluate(
        claim: claim, enumerationEndedNormally: true,
        observations: [BackupFixtureSupport.writerObservation("did:plc:a")], missingBlobCount: 0
      )
      #expect(!result.isComplete)
      #expect(result.claimedWriterDIDs == ["did:plc:a", "did:plc:b"])
      #expect(result.failedWriterDIDs == ["did:plc:b"])
    }

    @Test("rejects traversal, malformed hashes, duplicates, and unqualified blob paths")
    func validation() throws {
      for unsafe in ["../token", "/absolute", "public//repo.car", "public/./repo.car", "public/../repo.car", "public\\repo.car"] {
        #expect(throws: BackupManifestError.unsafeRelativePath) { _ = try BackupComponentPath(unsafe) }
      }
      #expect(throws: BackupManifestError.invalidSHA256) {
        _ = try BackupFixtureSupport.manifest(repositorySHA256: "ABC")
      }
      #expect(throws: BackupManifestError.unqualifiedBlobPath) {
        _ = try BackupFixtureSupport.manifest(blobPath: "blobs/bafk")
      }
    }
  }
  ```

- [ ] **Step 2: Run the focused suite and verify the intended failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task8.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/BackupManifestTests
  ```

  Expected: FAIL because the executable backup schema and validators do not exist.

- [ ] **Step 3: Implement requests, plans, canonical paths, sources, and authority observations**

  ```swift
  public enum BackupRequestSubject: Hashable, Codable, Sendable {
    case record(locator: RecordLocator, recordCID: String)
    case repository(RepositoryScope)
    case wholeSpace(
      spaceURI: String,
      accountDID: String,
      authoritySnapshot: SpaceDeletionAuthoritySnapshot?
    )
  }

  public struct BackupRequest: Hashable, Codable, Sendable {
    public let packageID: UUID
    public let subject: BackupRequestSubject
    public let parentDirectoryBookmark: Data
    public let finalFilename: String
    public let requestedAt: Date
    public init(
      packageID: UUID,
      subject: BackupRequestSubject,
      parentDirectoryBookmark: Data,
      finalFilename: String,
      requestedAt: Date
    ) throws {
      guard !parentDirectoryBookmark.isEmpty else { throw BackupManifestError.missingBookmark }
      guard finalFilename == URL(fileURLWithPath: finalFilename).lastPathComponent,
            finalFilename.hasSuffix(".atprotodrivebackup")
      else { throw BackupManifestError.invalidPackageFilename }
      if case let .wholeSpace(spaceURI, accountDID, .some(authoritySnapshot)) = subject {
        guard authoritySnapshot.spaceURI == spaceURI,
              authoritySnapshot.accountDID == accountDID,
              authoritySnapshot.fullyPaginated else {
          throw BackupManifestError.sourceMismatch
        }
      }
      self.packageID = packageID
      self.subject = subject
      self.parentDirectoryBookmark = parentDirectoryBookmark
      self.finalFilename = finalFilename
      self.requestedAt = requestedAt
    }
  }

  public struct BackupRepositoryPlan: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let carPath: BackupComponentPath
  }

  public struct BackupPlan: Hashable, Codable, Sendable {
    public let request: BackupRequest
    public let repositories: [BackupRepositoryPlan]
    public let requiredAccess: [String] // canonical scopes requested through Plan 2 planner
    public let spaceDiscovery: SpaceBackupDiscoveryEvidence?
    public init(
      request: BackupRequest,
      repositories: [BackupRepositoryPlan],
      requiredAccess: [String],
      spaceDiscovery: SpaceBackupDiscoveryEvidence? = nil
    ) throws {
      guard !repositories.isEmpty else { throw BackupManifestError.emptyPlan }
      guard Set(repositories.map(\.scope)).count == repositories.count,
            Set(repositories.map(\.carPath)).count == repositories.count
      else { throw BackupManifestError.duplicatePath }
      self.request = request
      self.repositories = repositories
      self.requiredAccess = Array(Set(requiredAccess)).sorted()
      self.spaceDiscovery = spaceDiscovery
    }
  }

  public struct SpaceBackupDiscoveryEvidence: Hashable, Codable, Sendable {
    public let claim: SpaceAuthorityClaim
    public let enumerationEndedNormally: Bool
    public let writerObservations: [WriterHostObservation]
  }

  public struct BackupProducer: Hashable, Codable, Sendable {
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let buildVersion: String
    public let formatWriterVersion: Int
  }

  public struct SpaceSignedVersionEvidence: Hashable, Codable, Sendable {
    public let revision: String
    public let hashBase64: String

    public init(revision: String, hashBase64: String) throws {
      guard !revision.isEmpty,
            let hash = Data(base64Encoded: hashBase64), !hash.isEmpty,
            hash.base64EncodedString() == hashBase64
      else { throw BackupManifestError.invalidSpaceSignedVersion }
      self.revision = revision
      self.hashBase64 = hashBase64
    }

    public var repositoryVersion: RepositoryVersion {
      .spaceSignedCommit(revision: revision, hashBase64: hashBase64)
    }

    private enum CodingKeys: String, CodingKey { case revision, hashBase64 }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        revision: c.decode(String.self, forKey: .revision),
        hashBase64: c.decode(String.self, forKey: .hashBase64)
      )
    }
    public func encode(to encoder: Encoder) throws {
      _ = try Self(revision: revision, hashBase64: hashBase64)
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(revision, forKey: .revision)
      try c.encode(hashBase64, forKey: .hashBase64)
    }
  }

  public enum BackupRepositoryVersionEvidence: Hashable, Sendable {
    case publicCommit(cid: String)
    case spaceSignedCommit(SpaceSignedVersionEvidence)

    public var repositoryVersion: RepositoryVersion {
      switch self {
      case .publicCommit(let cid): .publicCommit(cid: cid)
      case .spaceSignedCommit(let evidence): evidence.repositoryVersion
      }
    }
  }

  extension BackupRepositoryVersionEvidence: Codable {
    private enum CodingKeys: String, CodingKey { case version, kind, cid, signedVersion }
    private enum Kind: String, Codable { case publicCommit, spaceSignedCommit }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let version = try c.decode(Int.self, forKey: .version)
      guard version == 1 else { throw BackupManifestError.unsupportedVersion }
      switch try c.decode(Kind.self, forKey: .kind) {
      case .publicCommit:
        let cid = try c.decode(String.self, forKey: .cid)
        guard !cid.isEmpty else { throw BackupManifestError.invalidRepositoryVersion }
        self = .publicCommit(cid: cid)
      case .spaceSignedCommit:
        self = .spaceSignedCommit(
          try c.decode(SpaceSignedVersionEvidence.self, forKey: .signedVersion)
        )
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(1, forKey: .version)
      switch self {
      case .publicCommit(let cid):
        guard !cid.isEmpty else { throw BackupManifestError.invalidRepositoryVersion }
        try c.encode(Kind.publicCommit, forKey: .kind)
        try c.encode(cid, forKey: .cid)
      case .spaceSignedCommit(let signedVersion):
        try c.encode(Kind.spaceSignedCommit, forKey: .kind)
        try c.encode(signedVersion, forKey: .signedVersion)
      }
    }
  }

  public struct AuthorityWriterClaim: Hashable, Codable, Sendable {
    public let writerDID: String
    public let authoritySignedVersion: SpaceSignedVersionEvidence
  }

  public struct SpaceAuthorityClaim: Hashable, Codable, Sendable {
    public let canonicalSpaceURI: String
    public let authorityDID: String
    public let observedAt: Date
    public let enumerationEndedNormally: Bool
    public let writers: [AuthorityWriterClaim]
  }

  public struct WriterHostObservation: Hashable, Codable, Sendable {
    public let writerDID: String
    public let writerPDSURL: URL
    public let writerSignedVersion: SpaceSignedVersionEvidence
    public let observedAt: Date
    /// Nil for an explicitly single-writer backup with no authority claim.
    public let agreesWithAuthorityClaim: Bool?
  }

  public struct BackupSourceDescription: Hashable, Codable, Sendable {
    public let subject: BackupRequestSubject
    public let originalAccesses: [AccessClassification]
    public let sourceAccountDID: String?
    public let repositoryDID: String?
    public let handle: String?
    public let pdsURL: URL?
    public let protocolProfile: String
    public let canonicalSpaceURI: String?
    public let authorityClaim: SpaceAuthorityClaim?
  }
  ```

  `BackupComponentPath` is a validated relative POSIX path with nonempty segments, no absolute prefix, `.`/`..`, backslash, NUL, empty segment, or control character. `BackupPath.digest(_:)` is exactly the full 64-character lowercase hex SHA-256 of the canonical identifier's UTF-8 bytes; when combining identifiers, join them with a NUL before hashing. Do not truncate. Constructors are:

  ```swift
  public enum BackupPath {
    public static func publicRepository() throws -> BackupComponentPath       // public/repo.car
    public static func publicBlob(cid: String) throws -> BackupComponentPath  // public/blobs/<sha256(cid)>-<safeCID>
    public static func spaceRepository(spaceURI: String, writerDID: String) throws -> BackupComponentPath
    public static func spaceBlob(spaceURI: String, writerDID: String, cid: String) throws -> BackupComponentPath
    public static func blob(for locator: BlobLocator) throws -> BackupComponentPath {
      switch locator.scope {
      case .publicRepository:
        return try publicBlob(cid: locator.cid)
      case .permissionedSpace(let spaceURI, let writerDID, _):
        return try spaceBlob(spaceURI: spaceURI, writerDID: writerDID, cid: locator.cid)
      }
    }
    public static func recordsIndex() throws -> BackupComponentPath           // records-index.json
  }
  ```

- [ ] **Step 4: Implement every artifact, verification, completion, and manifest invariant**

  ```swift
  public enum ArtifactVerification: Hashable, Codable, Sendable {
    case pending
    case verified(method: String, verifiedAt: Date)
    case failed(redactedReason: String)
  }

  public struct BackupRepositoryArtifact: Hashable, Codable, Sendable {
    public let scope: RepositoryScope
    public let relativePath: BackupComponentPath
    public let byteCount: Int64
    public let sha256: String
    public let recordCount: Int
    public let repositoryVersion: BackupRepositoryVersionEvidence
    public let carRootCID: String
    public let observedAt: Date
    public let writerObservation: WriterHostObservation?
    public let verification: ArtifactVerification
  }

  public struct BackupBlobArtifact: Hashable, Codable, Sendable {
    public let locator: BlobLocator
    public let relativePath: BackupComponentPath
    public let byteCount: Int64
    public let sha256: String
    public let expectedCIDConfirmed: Bool
    public let verification: ArtifactVerification
  }

  public struct BackupIndexArtifact: Hashable, Codable, Sendable {
    public let relativePath: BackupComponentPath
    public let entryCount: Int
    public let byteCount: Int64
    public let sha256: String
    public let verification: ArtifactVerification
  }

  public struct BackupVerificationStage: Hashable, Codable, Sendable {
    public let name: String
    public let passed: Bool
    public let verifiedAt: Date?
    public let redactedFailure: String?
  }

  public struct BackupVerificationSummary: Hashable, Codable, Sendable {
    public let stages: [BackupVerificationStage]
    public var isVerified: Bool { !stages.isEmpty && stages.allSatisfy(\.passed) }
  }

  public enum BackupCompletionState: Hashable, Codable, Sendable {
    case inProgress
    case complete
    case incomplete(reasons: [String])
  }

  public enum SpaceBackupCompleteness: Hashable, Codable, Sendable {
    case singleWriter(writerDID: String, observation: WriterHostObservation)
    case completeRelativeToAuthorityClaim(claim: SpaceAuthorityClaim, observations: [WriterHostObservation])
    case incomplete(
      claim: SpaceAuthorityClaim, observations: [WriterHostObservation],
      failedWriterDIDs: [String], missingBlobCount: Int, reasons: [String]
    )
    public static func evaluate(
      claim: SpaceAuthorityClaim,
      enumerationEndedNormally: Bool,
      observations: [WriterHostObservation],
      missingBlobCount: Int
    ) -> Self
  }
  ```

  `evaluate` sorts/deduplicates but never removes an authority-claimed writer: a missing or failed writer remains in `failedWriterDIDs`; abnormal enumeration, any failed writer, any missing/CID-mismatched blob, or unverified CAR yields `.incomplete`. Only every claimed writer plus every CAR-referenced blob yields `.completeRelativeToAuthorityClaim`.

  ```swift
  public struct BackupManifest: Hashable, Codable, Sendable {
    public let formatVersion: Int // initializer always 1
    public let packageID: UUID
    public let producer: BackupProducer
    public let createdAt: Date
    public let completedAt: Date?
    public let source: BackupSourceDescription
    public let repositories: [BackupRepositoryArtifact]
    public let blobs: [BackupBlobArtifact]
    public let indexes: [BackupIndexArtifact]
    public let spaceCompleteness: SpaceBackupCompleteness?
    public let completion: BackupCompletionState
    public let verification: BackupVerificationSummary
    public init(
      packageID: UUID,
      producer: BackupProducer,
      createdAt: Date,
      completedAt: Date?,
      source: BackupSourceDescription,
      repositories: [BackupRepositoryArtifact],
      blobs: [BackupBlobArtifact],
      indexes: [BackupIndexArtifact],
      spaceCompleteness: SpaceBackupCompleteness?,
      completion: BackupCompletionState,
      verification: BackupVerificationSummary
    ) throws {
      self.formatVersion = 1
      self.packageID = packageID
      self.producer = producer
      self.createdAt = createdAt
      self.completedAt = completedAt
      self.source = source
      self.repositories = repositories
      self.blobs = blobs
      self.indexes = indexes
      self.spaceCompleteness = spaceCompleteness
      self.completion = completion
      self.verification = verification
      try validate()
    }
    public func validate() throws
  }
  ```

  Validation requires: version 1; unique artifact paths; lowercase 64-hex hashes; nonnegative counts; every repository/blob path equals the canonical `BackupPath` for its exact scope/locator; public artifacts only under `public`; Space artifacts only under both full digests; source canonical IDs agree with scopes; every Space hash is canonical nonempty Base64; every CAR root parses as a CID independently of repository version evidence; completed manifests have `completedAt >= createdAt`, no pending/failed artifact, verified summary, index, and no incomplete Space result. Every Space repository has exactly one writer-host observation, and the authenticated CAR verifier's `repositoryVersion.spaceSignedCommit` must equal that observation's `writerSignedVersion` byte for byte; a missing, duplicate, or unequal observation/CAR pair throws `spaceVersionMismatch`. For `.completeRelativeToAuthorityClaim` and authority-qualified `.incomplete`, require one authority claim row per repository, recompute `agreesWithAuthorityClaim`, and require the stored optional Boolean to equal that result; a legitimate authority-versus-observation disagreement remains representable and does not by itself make a writer incomplete. For `.singleWriter`, require exactly one Space repository, no authority claim, the same writer DID in completeness/scope/observation, and `agreesWithAuthorityClaim == nil`; never invent an authority row. `carRootCID` is parsed and retained independently and is never compared to a signed-version hash. No token/credential field exists. `BackupManifestError` has concrete cases for `unsupportedVersion`, `unsafeRelativePath`, `invalidSHA256`, `invalidSpaceSignedVersion`, `invalidRepositoryVersion`, `spaceVersionMismatch`, `invalidCARRootCID`, `duplicatePath`, `unqualifiedBlobPath`, `scopePathMismatch`, `sourceMismatch`, `invalidCount`, `invalidCompletion`, `missingBookmark`, `invalidPackageFilename`, and `emptyPlan`.

- [ ] **Step 5: Implement the readable index and executable fixtures**

  ```swift
  public struct RecordsIndexEntry: Hashable, Codable, Sendable {
    public let record: RecordLocator
    public let recordType: String?
    public let blobReferences: [BlobReferenceOccurrence]
    public let canonicalJSON: String
  }

  public struct RecordsIndexDocument: Hashable, Codable, Sendable {
    public let formatVersion: Int
    public let generatedFromRepositories: [BackupComponentPath]
    public let entries: [RecordsIndexEntry]
    public init(entries: [RecordsIndexEntry], generatedFromRepositories: [BackupComponentPath]) throws
  }
  ```

  The initializer sorts by scope stable ID, collection, rkey, and CID; rejects duplicate qualified locators; and records only verified CAR sources. This is a readable browsing aid; CAR artifacts remain canonical. `BackupFixtureSupport.swift` provides concrete valid public/single-writer/whole-Space requests, plans, claims, observations, artifacts, manifests, and package trees plus one mutation parameter per validator test; it writes only inside a caller-provided UUID directory. Its `SpaceObservedVersionMutation: CaseIterable` has exactly `.writerObservation` and `.carExtractedRepositoryVersion`; each mutates only that pair while preserving a separately valid `carRootCID`. A separate `authorityAgreesWithObservation: false` fixture proves that the authority disagreement and recomputed false flag survive validation without weakening observation-to-CAR binding.

- [ ] **Step 6: Hand off membership, run tests, and seal**

  Run Step 2 again. Expected: PASS; every type is executable/Codable, canonical paths are full-digest qualified, and no incomplete manifest can claim completion.

  ```bash
  jj status
  jj diff --summary
  jj describe -m "backups: define executable qualified package schema"
  jj new
  ```

### Task 9: Stream and Publish Backup Packages Atomically with Durable Parent Bookmarks

**Files:**
- Create: `ATProtoDrive/Backups/AtomicPackageWriter.swift`
- Create: `ATProtoDrive/Backups/SecurityScopedBookmarkStore.swift`
- Create: `ATProtoDrive/Backups/BackupPackageDocument.swift`
- Create: `ATProtoDriveTests/AtomicPackageWriterTests.swift`
- Modify: `ATProtoDrive/ATProtoDrive.entitlements`
- Modify by the cross-plan integration owner: `ATProtoDrive/Info.plist`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: Task 8 schema and Task 2 bounded destinations.
- Produces: streaming `BackupPackageWriting`, actor `AtomicPackageWriter`, actor `PackageWriteSession`, owner-only `PartialPackageState`, durability checks, parent-directory bookmarks/access, exported package UTType, and async backup destination panel.

- [ ] **Step 1: Write failing streaming, interruption, collision, manifest-last, fsync, resume, and bookmark tests**

  ```swift
  @Suite("Atomic backup package writer")
  struct AtomicPackageWriterTests {
    @Test("large component streams in bounded chunks and manifest is durable last")
    func streamingPublication() async throws {
      let fixture = try AtomicWriterFixture.make(componentBytes: 12 * 1_024 * 1_024)
      let session = try await fixture.writer.begin(request: fixture.request)
      let destination = try await session.destination(for: try BackupPath.publicRepository(), expectedBlobCID: nil)
      try await fixture.streamComponent(to: destination, maximumChunk: 65_536)
      try await session.finish(manifest: fixture.manifest)
      #expect(await fixture.maximumObservedChunk <= 65_536)
      #expect(await fixture.durability.events.suffix(2) == ["file:manifest.json", "directory:parent"])
      #expect(try posixMode(fixture.finalPackage) == 0o700)
      #expect(try posixMode(fixture.finalPackage.appendingPathComponent("public/repo.car")) == 0o600)
    }

    @Test("interruption leaves owner-only partial state and no final package")
    func interruptedWrite() async throws {
      let fixture = try AtomicWriterFixture.make(interruptAfterChunks: 2)
      await #expect(throws: CancellationError.self) { try await fixture.runOneComponent() }
      #expect(!FileManager.default.fileExists(atPath: fixture.finalPackage.path))
      #expect(FileManager.default.fileExists(atPath: fixture.partialStateURL.path))
      #expect(try posixMode(fixture.partialStateURL) == 0o600)
    }

    @Test("resume skips unchanged component and atomically replaces changed staging component")
    func changedAndUnchangedResume() async throws {
      let fixture = try await AtomicWriterFixture.interruptedWithVerifiedComponents()
      try fixture.tamper(path: "public/blobs/blob")
      let resumed = try await fixture.writer.resume(request: fixture.request)
      #expect(await resumed.verifiedComponentPaths == ["public/repo.car"])
      #expect(await resumed.pendingComponentPaths == ["public/blobs/blob"])
      try await fixture.rewriteChangedComponent(session: resumed)
      #expect(try fixture.countFiles(matching: "*.writing-*") == 0)
    }

    @Test("destination collision, fsync failure, and manifest mismatch never publish")
    func publicationFailures() async throws {
      for failure in AtomicWriterFixture.PublicationFailure.allCases {
        let fixture = try AtomicWriterFixture.make(failure: failure)
        await #expect(throws: BackupWriteError.self) { try await fixture.runToFinish() }
        #expect(!fixture.finalPackageWasReplacedWithoutApproval)
        #expect(FileManager.default.fileExists(atPath: fixture.stagingURL.path))
      }
    }

    @Test("parent bookmark resumes when only sibling staging exists and refreshes stale data")
    func parentBookmarkRelaunch() async throws {
      let fixture = try await AtomicWriterFixture.interruptedWithParentBookmark(stale: true)
      let relaunched = try SecurityScopedBookmarkStore(directory: fixture.newProcessStateRoot)
      let access = try await relaunched.accessParent(fixture.bookmarkID)
      defer { access.stop() }
      #expect(access.parentURL == fixture.parent)
      #expect(await relaunched.bookmark(fixture.bookmarkID)?.data != fixture.originalBookmarkData)
      _ = try await fixture.writer.resume(request: fixture.request)
    }

    @Test("incomplete blob evidence is durable and relaunch-resumable")
    func durableIncompleteEvidence() async throws {
      let fixture = try AtomicWriterFixture.make()
      let session = try await fixture.writer.begin(request: fixture.request)
      let path = try BackupPath.publicBlob(cid: "bafk-missing")
      let failure = BackupIncompleteComponent(
        relativePath: path, expectedCID: "bafk-missing", observedSHA256: nil,
        reason: .missing, recordedAt: .fixtureNow
      )
      try await session.recordIncomplete(failure)
      let reference = try await session.preserveIncomplete()
      #expect(!FileManager.default.fileExists(atPath: fixture.finalPackage.path))
      #expect(reference.stagingDirectoryName == fixture.stagingURL.lastPathComponent)
      #expect(!reference.partialStateSHA256.isEmpty)

      let relaunched = try await fixture.writer.resume(request: fixture.request)
      #expect(await relaunched.currentIncompleteComponents() == [failure])
      #expect(await relaunched.pendingComponentPaths().contains(path))
    }

    @Test("relaunch resumes only the exact whole-Space deletion snapshot")
    func exactDeletionSnapshotResume() async throws {
      let fixture = try AtomicWriterFixture.wholeSpaceDeletionBackup()
      let session = try await fixture.writer.begin(request: fixture.request)
      _ = try await session.preserveIncomplete()

      let partial = try fixture.readPartialState()
      #expect(partial.requestSubject == fixture.request.subject)

      let relaunched = try fixture.relaunchWriter()
      _ = try await relaunched.resume(request: fixture.request)
      #expect(try fixture.readPartialState().requestSubject == fixture.request.subject)
    }

    @Test("relaunch rejects a different whole-Space deletion snapshot without touching staging")
    func mismatchedDeletionSnapshotResume() async throws {
      let fixture = try AtomicWriterFixture.wholeSpaceDeletionBackup()
      let session = try await fixture.writer.begin(request: fixture.request)
      let reference = try await session.preserveIncomplete()
      let originalState = try Data(contentsOf: fixture.partialStateURL)
      let mismatchedRequest = try fixture.request(
        replacingAuthoritySnapshot: fixture.differentAuthoritySnapshot
      )

      let relaunched = try fixture.relaunchWriter()
      await #expect(throws: BackupWriteError.requestIdentityMismatch) {
        _ = try await relaunched.resume(request: mismatchedRequest)
      }
      #expect(try Data(contentsOf: fixture.partialStateURL) == originalState)
      #expect(reference.partialStateSHA256 == originalState.sha256Hex)
    }
  }
  ```

- [ ] **Step 2: Run the focused suite and verify the intended failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task9.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/AtomicPackageWriterTests
  ```

  Expected: FAIL because streaming package sessions, partial state, and parent bookmarks do not exist.

- [ ] **Step 3: Implement streaming sibling staging and explicit partial state**

  ```swift
  public struct PartialComponentReceipt: Hashable, Codable, Sendable {
    public let relativePath: BackupComponentPath
    public let byteCount: Int64
    public let sha256: String
    public let expectedCID: String?
    public let expectedCIDConfirmed: Bool
  }

  public enum BackupIncompleteReason: Hashable, Codable, Sendable {
    case missing
    case cidMismatch
    case transport(redactedCode: String)
  }

  public struct BackupIncompleteComponent: Hashable, Codable, Sendable {
    public let relativePath: BackupComponentPath
    public let expectedCID: String?
    public let observedSHA256: String?
    public let reason: BackupIncompleteReason
    public let recordedAt: Date
  }

  public struct ResumableBackupReference: Hashable, Codable, Sendable {
    public let packageID: UUID
    public let parentDirectoryBookmark: Data
    public let finalFilename: String
    public let stagingDirectoryName: String
    public let partialStateSHA256: String
    public let recordedAt: Date
  }

  public struct PartialPackageState: Hashable, Codable, Sendable {
    public let formatVersion: Int // 1
    public let packageID: UUID
    public let finalFilename: String
    /// Exact validated subject, including any deletion authority snapshot.
    public let requestSubject: BackupRequestSubject
    public var components: [PartialComponentReceipt]
    public var incompleteComponents: [BackupIncompleteComponent]
    public let manifestWritten: Bool // always false until finish removes this file
    public let updatedAt: Date
  }

  public protocol BackupPackageWriting: Sendable {
    func begin(request: BackupRequest) async throws -> PackageWriteSession
    func resume(request: BackupRequest) async throws -> PackageWriteSession
  }

  public actor PackageWriteSession {
    public func destination(
      for path: BackupComponentPath,
      expectedBlobCID: String?
    ) throws -> any ByteStreamDestination
    public func checkpoint(_ receipt: StreamedArtifactReceipt, at path: BackupComponentPath) async throws
    public func recordIncomplete(_ component: BackupIncompleteComponent) async throws
    public func preserveIncomplete() async throws -> ResumableBackupReference
    public func currentIncompleteComponents() -> [BackupIncompleteComponent]
    public func pendingComponentPaths() -> Set<BackupComponentPath>
    public func verifiedComponentReceipts() -> [PartialComponentReceipt]
    public func finish(manifest: BackupManifest) async throws -> TransferResultDescriptor
  }
  ```

  Resolve the parent bookmark, start access, and derive final/staging URLs from the validated final filename and package ID:

  ```text
  <parent>/<finalFilename>
  <parent>/.<finalFilename>.partial-<packageID>/
  <staging>/.atprotodrive-partial-v1.json
  ```

  `begin(request:)` atomically writes the initial owner-only partial state before returning a session. That state contains the exact validated `BackupRequest.subject`; for a deletion-bound whole-Space backup this includes the complete `SpaceDeletionAuthoritySnapshot`, not only its digest. The package ID, final filename, and request subject are the durable request identity. Parent bookmark bytes are deliberately outside that identity because stale bookmarks may be refreshed without changing the source or destination.

  Each destination is a Task 2 bounded streaming writer rooted inside staging. It writes a sibling `.writing-UUID`, fsyncs, then uses coordinated atomic replace if a prior staged component exists; `moveItem` is never used over an existing target. After every verified component, fsync it, remove any incomplete entry for that exact path, and atomically rewrite the `0600` partial-state file; directories are `0700`. `recordIncomplete` upserts the exact path/expected CID/reason, synchronizes the state file and staging directory, and never creates `manifest.json`. `preserveIncomplete` synchronizes again and returns the bookmark-backed staging identity plus SHA-256 of the durable partial-state bytes. Cancellation/failure removes only the current `.writing` sibling and preserves the explicit incomplete staging state.

  Resume first validates the partial-state schema and requires exact equality of its package ID, final filename, and `requestSubject` with the supplied validated request. For `.wholeSpace(..., authoritySnapshot: .some(...))`, equality covers the canonical Space URI, account DID, pagination evidence, every sorted writer binding, each authority/observed signed version, and the binding digest. Any mismatch throws `BackupWriteError.requestIdentityMismatch` before component validation, writes, deletion, bookmark refresh, or network work and leaves the durable staging bytes unchanged. Only after that gate may resume stream each existing component through bounded SHA-256/CID verification, keep matching receipts, preserve `incompleteComponents` as pending, and delete/restart changed components. `finish` rejects any remaining incomplete component, validates every manifest artifact against receipts, writes/synchronizes `records-index.json`, writes/synchronizes `manifest.json` last, validates the complete tree, removes/synchronizes partial state, then coordinates publication. Existing final destinations require an explicit replace receipt tied to their file resource identifier; otherwise fail with `.destinationExists`. Any fsync/manifest/tree/publication failure leaves staging incomplete and never changes the final package.

- [ ] **Step 4: Persist parent-directory bookmarks and balance every access**

  ```swift
  public struct SecurityScopedBookmark: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let data: Data
    public let displayName: String
  }

  public struct BackupDestinationAccess: @unchecked Sendable {
    public let parentURL: URL
    public let bookmarkWasStale: Bool
    public func stop()
  }

  public actor SecurityScopedBookmarkStore {
    public func addParent(url: URL, displayName: String) throws -> SecurityScopedBookmark
    public func accessParent(_ id: UUID) throws -> BackupDestinationAccess
    public func remove(_ id: UUID) throws
  }
  ```

  The save panel returns a final package URL, but persistence bookmarks its already-existing parent directory and stores final filename/package ID separately in `BackupRequest`; never bookmark a nonexistent final package. `accessParent` resolves, starts access, refreshes stale bookmark data while access is active, atomically persists it, and returns a token whose idempotent `stop()` balances exactly once. Begin, resume, catalog refresh/open/verify/reveal/Trash each hold their own balanced token for the full filesystem operation.

  Add while preserving existing entitlements:

  ```xml
  <key>com.apple.security.files.bookmarks.app-scope</key>
  <true/>
  ```

- [ ] **Step 5: Declare the package type and async save panel**

  `BackupPackageDocument.swift` defines:

  ```swift
  extension UTType {
    static let atprotoDriveBackup = UTType(exportedAs: "blue.catbird.atprotodrive.backup", conformingTo: .package)
  }

  @MainActor
  public protocol BackupDestinationPresenting {
    func destination(attachedTo window: NSWindow, suggestedFilename: String) async -> URL?
  }
  ```

  Its AppKit implementation uses `NSSavePanel.beginSheetModal`, `allowedContentTypes = [.atprotoDriveBackup]`, forces the `.atprotodrivebackup` extension, and never calls `runModal`. The integration owner adds `UTExportedTypeDeclarations` for identifier `blue.catbird.atprotodrive.backup` conforming to `com.apple.package`, filename extension `atprotodrivebackup`, and a matching `CFBundleDocumentTypes` entry with role Viewer/Editor as appropriate for read-only browsing plus creation.

- [ ] **Step 6: Hand off membership/Info.plist, run tests, inspect entitlements, and seal**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/AtomicPackageWriterTests
  plutil -p ATProtoDrive/ATProtoDrive.entitlements
  plutil -p ATProtoDrive/Info.plist
  ```

  Expected: PASS; entitlement and package/document declarations exist, large components stay bounded, parent-bookmark relaunch works, and final publication occurs only after a durable manifest-last gate.

  ```bash
  jj status
  jj diff --summary
  jj describe -m "backups: stream and atomically publish private packages"
  jj new
  ```

### Task 10: Verify Public and Space CARs from Files Without Loading Whole Archives

**Files:**
- Create: `ATProtoDrive/Verify/FileCARByteSource.swift`
- Create: `ATProtoDrive/Verify/PublicCARVerifier.swift`
- Create: `ATProtoDrive/Verify/SpaceCARFileVerifier.swift`
- Create: `ATProtoDriveTests/TestPublicCARFixtureHelper.swift`
- Create: `ATProtoDriveTests/PublicCARVerifierTests.swift`
- Create: `ATProtoDriveTests/SpaceCARFileVerifierTests.swift`
- Modify: `ATProtoDrive/Verify/RepoVerifier.swift`
- Modify: `ATProtoDriveTests/TestCARFixtureHelper.swift`
- Hand off source/test membership and the single `SwanPublicRepository` product link to the cross-plan integration owner.

**Interfaces:**
- Consumes: Swan `PublicRepositoryCAR`, `PublicRepositoryCARByteSource`, `PublicRepositoryCommitVerifier`, `SpaceCARCodec.verifyStreamingRecovery`, `SpaceCARRecoveryIndex`, `SpaceCARRecoveryRecordSink`, current DID key resolution, and `VerificationReport`.
- Produces: `FileCARByteSource`, `DirectoryPublicCARFrameStore`, `RepositorySigningKeyResolving`, `PublicCARVerifier`, `PublicCARVerificationReport`, `SQLiteSpaceRecoveryIndex`, `DirectorySpaceRecoverySink`, `SpaceCARFileVerificationReport`, and `SpaceCARFileVerifier`.

- [ ] **Step 1: Have the cross-plan integration owner add the SwanPublicRepository product before writing verifier tests**

  Hand the integration owner the exact membership list plus this requirement: in `project.pbxproj`, add one `XCSwiftPackageProductDependency` for product `SwanPublicRepository` using the existing local `../swan` package reference, its single `PBXBuildFile`, app-target Frameworks link, and `packageProductDependencies` entry. Do not add another local package reference. Inspect with:

  ```bash
  rg -n 'SwanPublicRepository|XCLocalSwiftPackageReference "../swan"' ATProtoDrive.xcodeproj/project.pbxproj
  ```

  Expected: one local Swan package reference and one app-target SwanPublicRepository dependency/link.

- [ ] **Step 2: Write failing target-DID, tamper, file-stream, and Space scratch tests**

  ```swift
  @Suite("File CAR verification")
  struct PublicCARVerifierTests {
    @Test("authenticates commit signature, MST, record CIDs, and expected DID")
    func authenticPublicCAR() async throws {
      let fixture = try await TestPublicCARFixtureHelper.make()
      let report = try await PublicCARVerifier(
        keyResolver: FixedRepositoryKeyResolver(key: fixture.publicKey)
      ).verify(carAt: fixture.fileURL, expectedDID: fixture.did)
      #expect(report.isVerified)
      #expect(report.repositoryDID == fixture.did)
      #expect(report.recordCount == 2)
    }

    @Test("rejects a valid CAR whose signed DID is not the selected repository")
    func expectedDIDBinding() async throws {
      let fixture = try await TestPublicCARFixtureHelper.make()
      await #expect(throws: PublicCARVerificationError.repositoryDIDMismatch) {
        _ = try await PublicCARVerifier(
          keyResolver: FixedRepositoryKeyResolver(key: fixture.publicKey)
        ).verify(carAt: fixture.fileURL, expectedDID: "did:plc:mallory")
      }
    }

    @Test("rejects a changed record block")
    func changedBlock() async throws {
      let fixture = try await TestPublicCARFixtureHelper.make(tamperRecordBlock: true)
      await #expect(throws: PublicCARVerificationError.invalidRepository) {
        _ = try await PublicCARVerifier(
          keyResolver: FixedRepositoryKeyResolver(key: fixture.publicKey)
        ).verify(carAt: fixture.fileURL, expectedDID: fixture.did)
      }
    }
  }

  @Suite("Space file CAR verification")
  struct SpaceCARFileVerifierTests {
    @Test("uses a disposable file source, SQLite index, and directory sink")
    func fileBackedVerification() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let fixture = try await TestCARFixtureHelper.makeFixture(directory: root)
      let report = try await SpaceCARFileVerifier().verify(
        carAt: fixture.fileURL,
        authorDID: TestCARFixtureHelper.authorDID,
        space: fixture.spaceRef,
        authorSigningKey: fixture.publicKey.compressedRepresentation,
        scratchDirectory: root.appendingPathComponent("scratch", isDirectory: true)
      )
      #expect(report.outcome == .verified(recordCount: 2))
      #expect(report.repositoryVersion == fixture.signedVersion)
      #expect(report.carRootCID == fixture.carRootCID)
      #expect(report.carRootCID != fixture.signedVersion.hashBase64)
      #expect(!FileManager.default.fileExists(atPath: report.scratchDirectory.path))
    }
  }
  ```

- [ ] **Step 3: Run both focused suites and verify the expected failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task10.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/PublicCARVerifierTests \
    -only-testing:ATProtoDriveTests/SpaceCARFileVerifierTests
  ```

  Expected: FAIL because the file-backed verifier adapters and public fixture helper do not exist.

- [ ] **Step 4: Implement a bounded file source shared by both verifier protocols**

  ```swift
  public actor FileCARByteSource: PublicRepositoryCARByteSource, SpaceCARRecoveryByteSource {
    private let handle: FileHandle

    public init(url: URL) throws {
      self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
      try? handle.close()
    }

    public func read(maximumBytes: Int) async throws -> Data? {
      guard maximumBytes > 0 else { throw FileCARSourceError.invalidReadSize }
      let data = try handle.read(upToCount: min(maximumBytes, 64 * 1_024)) ?? Data()
      return data.isEmpty ? nil : data
    }
  }
  ```

- [ ] **Step 5: Bind public authenticity verification to the selected DID**

  ```swift
  public protocol RepositorySigningKeyResolving: Sendable {
    func verifier(for did: String) async throws -> any PublicRepositoryCommitVerifier
  }

  public actor PublicCARVerifier {
    private let keyResolver: any RepositorySigningKeyResolving

    public func verify(carAt url: URL, expectedDID: String) async throws -> PublicCARVerificationReport {
      let verifier = try await keyResolver.verifier(for: expectedDID)
      let store = try DirectoryPublicCARFrameStore(
        scratchDirectory: scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
      )
      do {
        let parsed = try await PublicRepositoryCAR.parseIncrementally(
          from: FileCARByteSource(url: url),
          to: store
        )
        guard let commitBytes = try await store.block(for: parsed.rootCID) else {
          throw PublicCARVerificationError.missingCommit
        }
        let signedCommit = try await PublicRepositoryCommitCodec.verify(
          signedCommitBytes: commitBytes,
          expectedCommitCID: parsed.rootCID,
          verifier: verifier
        )
        guard signedCommit.descriptor.did == expectedDID else {
          throw PublicCARVerificationError.repositoryDIDMismatch
        }
        let repository = try await RepositoryMSTValidation.validate(
          rootCID: signedCommit.descriptor.dataCID,
          blocks: store
        )
        let report = PublicCARVerificationReport(
          repositoryDID: signedCommit.descriptor.did,
          revision: signedCommit.descriptor.revision.value,
          commitCID: parsed.rootCID.string,
          recordCount: repository.leaves.count,
          isVerified: true
        )
        try await store.removeScratch()
        return report
      } catch {
        let verificationError = error
        do { try await store.removeScratch() }
        catch { throw PublicCARVerificationError.scratchCleanupFailed }
        throw verificationError
      }
    }
  }
  ```

  `DirectoryPublicCARFrameStore` conforms to `PublicRepositoryCARFrameSink` and `PublicRepositoryBlockSource`: it writes each validated frame to a private scratch file, uses a disposable SQLite `(cid, relativePath, byteCount)` index with duplicate-body comparison, and keeps no record bodies in memory. The resolver selects `#atproto` from the current DID document, canonicalizes P-256 or secp256k1 key bytes, and returns a verifier whose `verificationIdentity` hashes the exact key. Verification covers the signed commit, expected DID, commit/data CIDs, MST shape and ordering, and every reachable record block. A SHA-256 file digest alone is never reported as source authenticity. Scratch cleanup failure is a local-storage failure, not a reason to claim verification success.

- [ ] **Step 6: Replace in-memory Space verification scratch with file-backed components**

  ```swift
  public struct SpaceCARFileVerificationReport: Sendable {
    public let outcome: VerificationReport.Outcome
    public let repositoryVersion: SpaceSignedVersionEvidence?
    public let carRootCID: String?
    public let scratchDirectory: URL
  }
  ```

  `SQLiteSpaceRecoveryIndex` uses a disposable SQLite database with `entries(path TEXT PRIMARY KEY, cid TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0)` plus a CID index. It maintains only `LtHash` and counters in memory. `DirectorySpaceRecoverySink` streams each verified record to a private scratch file and retains only the bounded commit body for error classification. Use the exact Swan protocols:

  ```swift
  public actor SQLiteSpaceRecoveryIndex: SpaceCARRecoveryIndex {
    public func insert(_ entry: SpaceCARRecoveryIndexEntry) async throws
    public func nextUnconsumedLexicographicEntry() async throws -> SpaceCARRecoveryIndexEntry?
    public func consumeEntries(forCID cid: CID) async throws -> Int
    public func commitment() -> Data
  }

  public actor DirectorySpaceRecoverySink: SpaceCARRecoveryRecordSink {
    public func receiveRoots(commit: CID, index: CID) async throws
    public func receiveCommit(cid: CID, body: Data) async throws
    public func beginRecord(cid: CID, byteCount: Int) async throws
    public func appendRecordChunk(cid: CID, chunkIndex: Int, bytes: Data) async throws
    public func completeRecord(cid: CID, byteCount: Int, chunkCount: Int) async throws
  }
  ```

  `SpaceCARFileVerifier` invokes `SpaceCARCodec.verifyStreamingRecovery` with `FileCARByteSource`, the SQLite index, and directory sink; maps errors through existing `VerificationReport`; and removes scratch on success or known verification failure. On `.verified`, it must populate `repositoryVersion` from the authenticated Space commit envelope's exact wire revision and canonical Base64 signed-version hash, and populate `carRootCID` from the parsed CAR root. A verified outcome with either field absent is an invalid verification report. These are separate values even when their encodings happen to look similar, and downstream code never derives one from the other. If scratch cleanup itself fails, report a local-storage failure and its exact private path to Activity, never silently ignore it. Keep `RepoVerifier.verify(carData:)` temporarily as a test-compatibility wrapper that first writes UUID-qualified input and delegates to the file path.

- [ ] **Step 7: Fix fixture isolation, run both suites and full RepoVerifier tests, then seal**

  Change `TestCARFixtureHelper.makeFixture(directory:)` to return `fileURL`, `signedVersion`, and `carRootCID`, and require a caller-owned UUID-qualified directory. `TestPublicCARFixtureHelper` builds a two-record signed repository using SwanPublicRepository public APIs and writes it under the supplied directory.

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task10-pass.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/PublicCARVerifierTests \
    -only-testing:ATProtoDriveTests/SpaceCARFileVerifierTests \
    -only-testing:ATProtoDriveTests/RepoVerifierTests
  ```

  Expected: PASS; public wrong-DID/tamper fixtures fail, Space fixtures verify, and no test shares a fixed temporary path.

  ```bash
  jj status
  jj diff --summary
  jj describe -m "verify: authenticate public and Space CAR files"
  jj new
  ```

### Task 11: Stream, Verify, Browse, Resume, Reveal, and Trash Backups

**Files:**
- Create: `ATProtoDrive/Backups/BackupService.swift`
- Create: `ATProtoDrive/Backups/VerifiedBackupPreflightProvider.swift`
- Create: `ATProtoDrive/Backups/BackupCatalog.swift`
- Create: `ATProtoDrive/Backups/BackupWorkspacePresenter.swift`
- Create: `ATProtoDrive/Backups/BackupBrowserView.swift`
- Create: `ATProtoDrive/Backups/BackupInspectorView.swift`
- Create: `ATProtoDriveTests/BackupServiceTests.swift`
- Create: `ATProtoDriveTests/BackupPreflightProviderTests.swift`
- Create: `ATProtoDriveTests/BackupCatalogTests.swift`
- Create: `ATProtoDriveTests/SpaceBlobCleanupTests.swift`
- Modify: `ATProtoDrive/Blobs/BlobReferenceIndex.swift`
- Modify: `ATProtoDrive/Blobs/QualifiedTemporaryFileStore.swift`
- Modify: `ATProtoDrive/Spaces/SpaceDeletionSafety.swift`
- Modify: `ATProtoDrive/Transfers/TransferExecutors.swift`
- Modify: `ATProtoDrive/Transfers/ActivityView.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Modify by the cross-plan integration owner: `ATProtoDrive/ATProtoDriveApp.swift` and `ATProtoDrive/Browser/ContentBrowserView.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: Tasks 1–10; Plan 1 public routing; Plan 2 exact `listWriters`, `.spaceRead(space:)`, writer-host/profile/credential routing, and backup/cleanup seams; fixed Task 6 registry adapters.
- Produces: destination-streaming `RepositoryExporting`, `BackupPlanning`, actor `BackupService`, live backup transfer drivers, exact verification reports, preflight provider, symlink-safe `BackupCatalog`, `@MainActor BackupWorkspacePresenter`, cleanup participants, and backup browser/inspector.

- [ ] **Step 1: Write failing bounded-stream and exact-CAR-snapshot tests**

  ```swift
  @Suite("Backup service")
  struct BackupServiceTests {
    @Test("public and Space CAR/blob payloads stream bounded and blob work comes only from verified CARs")
    func streamingExactSnapshot() async throws {
      let fixture = try BackupServiceFixture.publicAndSpace(maximumChunk: 65_536)
      let reports = try await fixture.runBoth()
      #expect(await fixture.maximumObservedChunk <= 65_536)
      #expect(await fixture.events == [
        "public-car", "verify-public-car", "derive-public", "public-blob:bafk-from-car",
        "space-car:did:plc:writer", "verify-space-car", "derive-space", "space-blob:bafk-from-car"
      ])
      #expect(reports.allSatisfy { $0.completion == .complete })
      #expect(await fixture.listBlobsCallCount == 0)
    }

    @Test("CAR-only or wrong-CID blob remains incomplete")
    func missingOrWrongBlob() async throws {
      for fixture in try BackupServiceFixture.missingAndWrongCIDFixtures() {
        let report = try await fixture.service.create(BackupFixtureSupport.publicRequest())
        guard case .incomplete = report.completion else { Issue.record("Expected incomplete"); return }
        #expect(!report.missingOrInvalidBlobCIDs.isEmpty)
        #expect(report.package == nil)
        let staging = try #require(report.resumableStaging)
        #expect(await fixture.finalPackageExists == false)
        let partial = try await fixture.readPartialState(staging)
        #expect(partial.incompleteComponents.compactMap(\.expectedCID) == report.missingOrInvalidBlobCIDs)

        let relaunched = try await fixture.relaunch()
        let resumed = try await relaunched.packageWriter.resume(request: fixture.request)
        #expect(await resumed.currentIncompleteComponents() == partial.incompleteComponents)
      }
    }
  }
  ```

- [ ] **Step 2: Write failing whole-Space authorization, claim, mismatch, and failed-writer tests**

  ```swift
  @Suite("Whole Space backup")
  struct WholeSpaceBackupTests {
    @Test("read_self waits for exact spaceRead before listWriters and never silently backs up My Records")
    func contextualReadRequired() async throws {
      let fixture = BackupServiceFixture.baselineReadSelfOnly()
      await #expect(throws: TransferExecutionIssue.permissionRequired(.spaceRead(space: .fixtureSpaceRef))) {
        _ = try await fixture.service.create(BackupFixtureSupport.wholeSpaceRequest())
      }
      #expect(await fixture.listWritersCalls == 0)
      #expect(await fixture.transferState == .waitingForPermission)
    }

    @Test("fully paginates listWriters and preserves claim details, mismatch, and failures")
    func authorityClaimEvidence() async throws {
      let fixture = BackupServiceFixture.wholeSpace(
        writerPages: [
          .init(writers: [.init(
            did: "did:plc:a", revision: "claim-a",
            commitHashBase64: Data("authority-hash-a".utf8).base64EncodedString()
          )], cursor: "opaque+/="),
          .init(writers: [.init(
            did: "did:plc:b", revision: "claim-b",
            commitHashBase64: Data("authority-hash-b".utf8).base64EncodedString()
          )], cursor: nil)
        ],
        writerResults: [
          "did:plc:a": .success(
            signedVersion: try .init(
              revision: "writer-a",
              hashBase64: Data("writer-hash-a".utf8).base64EncodedString()
            ),
            carRootCID: CID.fromBlob(Data("verified-car-root-a".utf8)).string
          ),
          "did:plc:b": .failure(.transport)
        ]
      )
      let report = try await fixture.service.create(BackupFixtureSupport.wholeSpaceRequest())
      guard case .incomplete(let claim, let observations, let failed, _, _) = report.spaceCompleteness else {
        Issue.record("Expected incomplete qualified result"); return
      }
      #expect(claim.writers.map(\.writerDID) == ["did:plc:a", "did:plc:b"])
      #expect(claim.writers.first?.authoritySignedVersion.revision == "claim-a")
      #expect(observations.first?.writerSignedVersion.revision == "writer-a")
      #expect(observations.first?.agreesWithAuthorityClaim == false)
      #expect(failed == ["did:plc:b"])
      #expect(await fixture.requestedMethod == "listWriters")
      #expect(await fixture.requestedCursors == [nil, "opaque+/="])
    }
  }
  ```

- [ ] **Step 3: Write failing catalog symlink, verification, preflight, and relaunch cleanup tests**

  ```swift
  @Suite("Backup catalog and deletion evidence")
  struct BackupCatalogTests {
    @Test("rejects traversal and symlink escape before reading a component")
    func containment() async throws {
      for package in try BackupFixtureSupport.traversalAndSymlinkEscapePackages() {
        await #expect(throws: BackupCatalogError.invalidComponentPath) {
          _ = try await BackupCatalog.fixture().open(package.reference)
        }
      }
    }

    @Test("verification stages hashes, CAR authenticity, index, blob CID, and completeness independently")
    func verificationStages() async throws {
      let fixture = try BackupCatalogFixture.validWholeSpace()
      let report = try await fixture.catalog.verify(fixture.reference)
      #expect(report.isVerified)
      #expect(await fixture.events == ["schema", "hashes", "public-or-space-cars", "index", "blob-cids", "completeness"])
    }
  }

  @Suite("Verified backup preflight")
  struct BackupPreflightProviderTests {
    @Test("record evidence binds locator and CID without persisting RecordSnapshot")
    func recordBinding() async throws {
      let snapshot = RecordSnapshot.fixtureSpace(recordCID: "bafy-original")
      let evidence = try await VerifiedBackupPreflightProvider.fixtureRecord(snapshot).backUpRecordBeforeDeletion(snapshot)
      #expect(evidence.subject == .record(locator: snapshot.locator, recordCID: "bafy-original"))
      #expect(evidence.complete && evidence.verified && !evidence.manifestDigest.isEmpty)
    }

    @Test("Space deletion accepts specifically completeRelativeToAuthorityClaim")
    func spaceBinding() async throws {
      let authoritySnapshot = SpaceDeletionAuthoritySnapshot.fixture(
        observedAt: Date(timeIntervalSince1970: 1_786_000_000)
      )
      for completeness in BackupFixtureSupport.incompleteAndSingleWriterCompleteness() {
        await #expect(throws: BackupPreflightError.evidenceMismatch) {
          _ = try await VerifiedBackupPreflightProvider.fixtureSpace(completeness: completeness)
            .backUpSpaceBeforeDeletion(
              space: .fixtureSpaceRef,
              accountDID: "did:plc:owner",
              authoritySnapshot: authoritySnapshot
            )
        }
      }
      let provider = VerifiedBackupPreflightProvider.fixtureCompleteWholeSpace()
      let evidence = try await provider.backUpSpaceBeforeDeletion(
        space: .fixtureSpaceRef,
        accountDID: "did:plc:owner",
        authoritySnapshot: authoritySnapshot
      )
      #expect(evidence.complete && evidence.verified)
      #expect(evidence.subject == .space(
        spaceURI: SpaceRef.fixtureSpaceRef.uriString(),
        authorityBindingDigest: authoritySnapshot.bindingDigest
      ))
      #expect(await provider.persistedAuthoritySnapshots == [authoritySnapshot])
      #expect(await provider.snapshotBoundDiscoveryCount == 1)
      #expect(await provider.listWritersCallCount == 0)
      #expect(await provider.getLatestCommitCallCount == 0)
    }

    @Test("Space deletion rejects each manifest, snapshot, and CAR version-binding mismatch")
    func exactDeletionVersionBindings() async throws {
      for mismatch in BackupFixtureSupport.SpaceDeletionVersionMismatch.allCases {
        let scenario = try BackupFixtureSupport.spaceDeletionVersionMismatch(mismatch)
        await #expect(throws: BackupPreflightError.evidenceMismatch) {
          _ = try await scenario.provider.backUpSpaceBeforeDeletion(
            space: .fixtureSpaceRef,
            accountDID: "did:plc:owner",
            authoritySnapshot: scenario.authoritySnapshot
          )
        }
      }
    }
  }

  @Suite("Space preview cleanup")
  struct SpaceBlobCleanupTests {
    @Test("new store instance removes deterministic Space preview root only")
    func relaunchCleanup() async throws {
      let fixture = try await SpacePreviewCleanupFixture.materialized()
      let relaunchedStore = try QualifiedTemporaryFileStore(root: fixture.root)
      try await SpacePreviewActiveStateCleanup(store: relaunchedStore).purgeActiveState(
        spaceURI: fixture.deletedSpaceURI, accountDID: fixture.accountDID
      )
      #expect(!fixture.deletedPreviewExists)
      #expect(fixture.otherPreviewExists)
      #expect(fixture.explicitBackupExists)
    }
  }
  ```

  `BackupFixtureSupport.SpaceDeletionVersionMismatch: CaseIterable` has exactly `.manifestAuthorityVersusSnapshotAuthority`, `.manifestObservationVersusSnapshotObserved`, and `.carExtractedVersionVersusSnapshotObserved`. `spaceDeletionVersionMismatch(_:)` returns a complete-looking provider plus the caller-supplied snapshot, mutates only the named pair, and leaves `carRootCID` valid and unchanged. A separate matching fixture with authority and observation intentionally unequal must succeed, proving that the preflight binds both snapshot pairs without treating authority staleness itself as CAR corruption.

- [ ] **Step 4: Run focused suites and verify the intended failures**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task11.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO test \
    -only-testing:ATProtoDriveTests/BackupServiceTests \
    -only-testing:ATProtoDriveTests/WholeSpaceBackupTests \
    -only-testing:ATProtoDriveTests/BackupCatalogTests \
    -only-testing:ATProtoDriveTests/BackupPreflightProviderTests \
    -only-testing:ATProtoDriveTests/SpaceBlobCleanupTests
  ```

  Expected: FAIL because the live backup service/catalog/preflight drivers do not exist.

- [ ] **Step 5: Implement destination-streaming public and Space export**

  ```swift
  public protocol RepositoryExporting: Sendable {
    func exportCAR(
      scope: RepositoryScope,
      to destination: any ByteStreamDestination
    ) async throws -> StreamedArtifactReceipt
  }

  public struct VerifiedBackupRepository: Hashable, Sendable {
    public let scope: RepositoryScope
    public let repositoryVersion: BackupRepositoryVersionEvidence
    public let carRootCID: String
    public let recordCount: Int
  }

  public struct DerivedBackupRecordsIndex: Hashable, Sendable {
    public let blobs: [BlobLocator]
  }

  public protocol BackupRepositorySnapshotVerifying: Sendable {
    func verify(carAt: URL, scope: RepositoryScope) async throws -> VerifiedBackupRepository
  }

  public protocol BackupRecordsIndexBuilding: Sendable {
    func build(
      carAt: URL,
      verified: VerifiedBackupRepository
    ) async throws -> DerivedBackupRecordsIndex
  }

  public protocol BackupBlobFetching: Sendable {
    func fetch(
      _ blob: BlobLocator,
      to destination: any ByteStreamDestination
    ) async throws -> StreamedArtifactReceipt
  }

  public protocol BackupBlobServiceSelecting: Sendable {
    func service(for scope: RepositoryScope) throws -> any BackupBlobFetching
  }

  public actor BackupService {
    private let planner: any BackupPlanning
    private let packageWriter: any BackupPackageWriting
    private let exporter: any RepositoryExporting
    private let verifier: any BackupRepositorySnapshotVerifying
    private let recordsIndexBuilder: any BackupRecordsIndexBuilding
    private let blobServices: any BackupBlobServiceSelecting
    private let manifestBuilder: any BackupManifestBuilding
    private let now: @Sendable () -> Date

    public init(
      planner: any BackupPlanning,
      packageWriter: any BackupPackageWriting,
      exporter: any RepositoryExporting,
      verifier: any BackupRepositorySnapshotVerifying,
      recordsIndexBuilder: any BackupRecordsIndexBuilding,
      blobServices: any BackupBlobServiceSelecting,
      manifestBuilder: any BackupManifestBuilding,
      now: @escaping @Sendable () -> Date = { Date() }
    ) {
      self.planner = planner
      self.packageWriter = packageWriter
      self.exporter = exporter
      self.verifier = verifier
      self.recordsIndexBuilder = recordsIndexBuilder
      self.blobServices = blobServices
      self.manifestBuilder = manifestBuilder
      self.now = now
    }

    public func create(_ request: BackupRequest) async throws -> BackupExecutionReport {
      let plan = try await planner.discover(request)
      let session = try await packageWriter.begin(request: request)
      var incomplete: [BackupIncompleteComponent] = []
      for repository in plan.repositories {
        try Task.checkCancellation()
        let destination = try await session.destination(for: repository.carPath, expectedBlobCID: nil)
        let carReceipt = try await exporter.exportCAR(scope: repository.scope, to: destination)
        let verified = try await verifier.verify(carAt: carReceipt.fileURL, scope: repository.scope)
        let derived = try await recordsIndexBuilder.build(carAt: carReceipt.fileURL, verified: verified)
        try await session.checkpoint(carReceipt, at: repository.carPath)
        for blob in derived.blobs {
          let path = try BackupPath.blob(for: blob)
          do {
            let blobDestination = try await session.destination(for: path, expectedBlobCID: blob.cid)
            let receipt = try await blobServices.service(for: blob.scope).fetch(
              blob, to: blobDestination
            )
            guard receipt.expectedCIDConfirmed else {
              let failure = BackupIncompleteComponent(
                relativePath: path, expectedCID: blob.cid, observedSHA256: receipt.sha256,
                reason: .cidMismatch, recordedAt: now()
              )
              try await session.recordIncomplete(failure)
              incomplete.append(failure)
              continue
            }
            try await session.checkpoint(receipt, at: path)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            let reason: BackupIncompleteReason
            switch error {
            case StreamingArtifactError.cidMismatch:
              reason = .cidMismatch
            case BlobServiceError.httpStatus(404):
              reason = .missing
            default:
              reason = .transport(redactedCode: "blob-fetch-failed")
            }
            let failure = BackupIncompleteComponent(
              relativePath: path, expectedCID: blob.cid, observedSHA256: nil,
              reason: reason, recordedAt: now()
            )
            try await session.recordIncomplete(failure)
            incomplete.append(failure)
          }
        }
      }

      if !incomplete.isEmpty {
        let staging = try await session.preserveIncomplete()
        return .init(
          packageID: request.packageID, package: nil, resumableStaging: staging,
          sourceAccountDID: request.subject.sourceAccountDID,
          completion: .incomplete(reasons: incomplete.map(\.reason.userFacingReason)),
          spaceCompleteness: plan.spaceCompleteness(missingBlobCount: incomplete.count),
          missingOrInvalidBlobCIDs: incomplete.compactMap(\.expectedCID)
        )
      }

      let manifest = try await manifestBuilder.makeCompleteManifest(
        plan: plan, componentReceipts: await session.verifiedComponentReceipts()
      )
      let result = try await session.finish(manifest: manifest)
      guard case let .backupPackage(packageID, bookmark, filename, _) = result,
            packageID == request.packageID else {
        throw BackupExecutionError.invalidPackageResult
      }
      return .init(
        packageID: packageID,
        package: .init(
          packageID: packageID, parentDirectoryBookmark: bookmark, filename: filename
        ),
        resumableStaging: nil,
        sourceAccountDID: manifest.source.sourceAccountDID,
        completion: .complete,
        spaceCompleteness: manifest.spaceCompleteness,
        missingOrInvalidBlobCIDs: []
      )
    }
  }

  public protocol BackupPlanning: Sendable {
    func discover(_ request: BackupRequest) async throws -> BackupPlan
  }

  public protocol BackupManifestBuilding: Sendable {
    func makeCompleteManifest(
      plan: BackupPlan,
      componentReceipts: [PartialComponentReceipt]
    ) async throws -> BackupManifest
  }

  public enum BackupExecutionError: Error, Hashable, Sendable {
    case invalidPackageResult
  }

  extension BackupIncompleteReason {
    public var userFacingReason: String {
      switch self {
      case .missing: "Blob was missing at the source"
      case .cidMismatch: "Blob bytes did not match the expected CID"
      case .transport: "Blob transfer did not finish"
      }
    }
  }

  extension BackupRequestSubject {
    public var sourceAccountDID: String? {
      switch self {
      case .record(let locator, _): locator.scope.scopedAccountDID
      case .repository(let scope): scope.scopedAccountDID
      case .wholeSpace(_, let accountDID, _): accountDID
      }
    }
  }

  extension RepositoryScope {
    fileprivate var scopedAccountDID: String? {
      switch self {
      case .publicRepository: nil
      case .permissionedSpace(_, _, let accountDID): accountDID
      }
    }
  }

  extension BackupPlan {
    public func spaceCompleteness(missingBlobCount: Int) -> SpaceBackupCompleteness? {
      guard let spaceDiscovery else { return nil }
      return .evaluate(
        claim: spaceDiscovery.claim,
        enumerationEndedNormally: spaceDiscovery.enumerationEndedNormally,
        observations: spaceDiscovery.writerObservations,
        missingBlobCount: missingBlobCount
      )
    }
  }

  public struct BackupPackageReference: Hashable, Codable, Sendable {
    public let packageID: UUID
    public let parentDirectoryBookmark: Data
    public let filename: String
  }

  public struct BackupExecutionReport: Hashable, Sendable {
    public let packageID: UUID
    public let package: BackupPackageReference?
    public let resumableStaging: ResumableBackupReference?
    public let sourceAccountDID: String?
    public let completion: BackupCompletionState
    public let spaceCompleteness: SpaceBackupCompleteness?
    public let missingOrInvalidBlobCIDs: [String]
  }

  public struct BackupVerificationReport: Hashable, Sendable {
    public let packageID: UUID
    public let completedAt: Date
    public let manifestDigest: String
    public let isVerified: Bool
    public let stages: [BackupVerificationStage]
    public let recordLocator: RecordLocator?
    public let recordCID: String?
    public let canonicalSpaceURI: String?
    public let sourceAccountDID: String?
    public let spaceCompleteness: SpaceBackupCompleteness?
  }
  ```

  The Task 11 fixture owns `missingAndWrongCIDFixtures()`, `readPartialState(_:)`, and `relaunch()`; they read only the explicit sibling state via its bookmark, never an in-memory session. Missing/incorrect blobs therefore return normally with a resumable, unpublished report. Only failure to durably record the incomplete state throws.

  Public CAR streaming constructs anonymous target-PDS `/xrpc/com.atproto.sync.getRepo?did=...`. Space CAR streaming constructs writer-host `/xrpc/com.atproto.space.getRepo?space=...&repo=...` through Task 2's `SpaceCredentialStreamRouting`, preserving Plan 2 exact account/profile/DPoP semantics. Both consume `URLSession.AsyncBytes` in at most 64-KiB chunks. Generated `getRepo`/`getBlob` buffered payload APIs are prohibited in backup production paths. Verify each CAR before deriving its records/blob set; never use concurrent `listBlobs` as snapshot membership.

- [ ] **Step 6: Implement whole-Space discovery with exact Plan 2 method and contextual authorization**

  For `.wholeSpace`, require exact account identity and `AuthorizationScopePlanner.requiredScope(for: .spaceRead(space:))` before any writer discovery. Missing scope throws `TransferExecutionIssue.permissionRequired`, and `FullBackupTransferExecutor` checkpoints payload then moves the job to `waitingForPermission`; it never silently downgrades to My Records.

  `BackupPlanning.discover(_:)` has two explicit whole-Space branches. When `BackupRequestSubject.wholeSpace` carries Plan 2's validated `authoritySnapshot`, require exact Space URI/account equality and derive `SpaceAuthorityClaim` from each binding's authority revision/Base64 hash plus `WriterHostObservation.writerSignedVersion` from its observed revision/Base64 hash. Resolve each writer PDS only for current routing, but call neither `listWriters` nor `getLatestCommit`; those calls would replace the deletion attempt's supplied evidence. The exact snapshot remains nested in `BackupPlan.request`, `FullBackupResumePayload`, and the incomplete sibling state so resume uses it unchanged. When the optional snapshot is nil for an ordinary user-initiated backup, fully page `SpaceRepositoryServing.listWriters(space:cursor:limit:)`, preserve opaque cursors, reject cycles, record one claim timestamp, and independently call writer-PDS `getLatestCommit`.

  In either branch, persist every authority `revision/commitHashBase64` as `AuthorityWriterClaim.writerDID` plus `authoritySignedVersion(revision:hashBase64:)`; Plan 2's `commitHashBase64` is canonical Base64 signed-version hash bytes, never a CID. Resolve and stream each writer from its own PDS/credential route; the supplied or freshly collected observation produces `WriterHostObservation.writerSignedVersion`, while authenticated CAR verification separately produces both `BackupRepositoryArtifact.repositoryVersion.spaceSignedCommit` and `carRootCID`. Recompute and retain whether the authority pair agrees with the writer-host pair; disagreement is useful stale-claim evidence and does not by itself fail the backup. The CAR-extracted pair must equal the writer-host pair exactly; an observation/CAR mismatch records that writer as failed and never removes it from the claim. `carRootCID` remains independent and is never accepted as a signed-version hash. Completion also requires terminal authority enumeration (already proven by a validated supplied snapshot, or observed directly), plus every claimed CAR and CAR-referenced blob verified, and is named `.completeRelativeToAuthorityClaim` with this UI text:

  > Complete relative to the fully paginated authority-claimed writer set observed at the recorded time. Writers were fetched independently; this is not a globally atomic snapshot or authoritative membership proof.

- [ ] **Step 7: Implement symlink-safe catalog and main-actor workspace actions**

  ```swift
  public struct BackupCatalogItem: Identifiable, Hashable, Sendable {
    public var id: UUID { reference.packageID }
    public let reference: BackupPackageReference
    public let manifest: BackupManifest
    public let packageURL: URL
    public let totalByteCount: Int64
  }

  public actor BackupCatalog {
    public func refresh() async -> [BackupCatalogItem]
    public func open(_ reference: BackupPackageReference) async throws -> BackupCatalogItem
    public func verify(_ reference: BackupPackageReference) async throws -> BackupVerificationReport
    public func moveToTrash(_ reference: BackupPackageReference) async throws
  }

  @MainActor
  public protocol BackupWorkspacePresenting {
    func reveal(_ url: URL)
  }
  ```

  `BackupPackageReference` stores parent bookmark ID plus filename/package ID. Every catalog method obtains/balances parent access. Each artifact/record row exposes `.localBackup(backupID: manifest.packageID, original: matchingOriginalAccess)` exactly as defined by the plan index; a whole-Space package stores one `originalAccesses` entry per writer and the package summary labels the set rather than inventing a wildcard writer. For each manifest component, validate `BackupComponentPath`, call `lstat` on every path segment and reject any symbolic link, resolve the package root and candidate canonically, require the candidate path prefix and root device/file identity to remain inside the opened package, then open with no-follow semantics where available. Add a race fixture that swaps a directory for a symlink between validation/open and require failure. Verify schema, hashes, CAR authenticity, index hash, blob expected CIDs, then completeness as separate stages.

  Reveal is not actor-isolated AppKit work: the view resolves a verified URL, then calls an injected `@MainActor BackupWorkspacePresenter` whose implementation uses `NSWorkspace.shared.activateFileViewerSelecting`. Trash requires UI confirmation, then catalog uses `trashItem`, removes only its bookmark, and never touches remote data.

- [ ] **Step 8: Implement exact verified Back Up First evidence**

  Record preflight converts the in-memory `RecordSnapshot` immediately to `BackupRequestSubject.record(locator:recordCID:)`; no snapshot/body enters transfer persistence. After creation, read back exact durable `manifest.json`, SHA-256 those bytes, run catalog verification, and require exact locator/CID/account plus `.complete`.

  Whole-Space preflight consumes Plan 2's caller-supplied `SpaceDeletionAuthoritySnapshot`; it does not enumerate a new writer set or accept an unbound cached package. Construct `BackupRequestSubject.wholeSpace(spaceURI:accountDID:authoritySnapshot: .some(authoritySnapshot))`, map that unchanged to `BackupSubjectDescriptor.wholeSpace`, and durably enqueue the resulting `FullBackupResumePayload` before execution. The backup plan, exported repositories, manifest authority claim, writer-host observations, and authenticated CAR-extracted repository versions must exactly cover the snapshot's fully paginated, sorted writer bindings. For each writer, require manifest authority `(revision, hash)` to equal the snapshot authority pair, manifest observation to equal the snapshot observed pair, and the CAR-extracted `repositoryVersion.spaceSignedCommit` to equal that same snapshot observed pair. A manifest-authority versus snapshot-authority mismatch, manifest-observation versus snapshot-observed mismatch, or CAR versus snapshot-observed mismatch throws `BackupPreflightError.evidenceMismatch`. The snapshot's own authority pair may legitimately differ from its observed pair; preserve and display that disagreement rather than rejecting it. `carRootCID` is validated independently and never participates in the binding digest. After creation, recompute the binding from the durable manifest, require it to equal `authoritySnapshot.bindingDigest`, then require exact canonical Space URI/account, manifest `.complete`, verification true, nonempty durable manifest digest, and specifically:

  ```swift
  guard case .completeRelativeToAuthorityClaim = verified.spaceCompleteness else {
    throw BackupPreflightError.evidenceMismatch
  }
  ```

  Conform with Plan 2's exact `backUpSpaceBeforeDeletion(space:accountDID:authoritySnapshot:)` signature and return its existing `BackupPreflightEvidence.subject.space(spaceURI:authorityBindingDigest:)`. Replace only `UnavailableBackupPreflightProvider`; never redefine evidence, omit the supplied snapshot, or weaken the service checks.

- [ ] **Step 9: Register deterministic active-state cleanup without registering backups**

  `SpaceBlobActiveStateCleanup` removes only index entries matching canonical Space URI/account across all writer scopes. `SpacePreviewActiveStateCleanup` calls Task 4's deterministic digest-root removal, which works after process restart. Register both with Plan 2 `SpaceActiveStateCleanup`. The package writer, explicit backup root, bookmarks, and catalog must not conform and are regression-tested as untouched.

- [ ] **Step 10: Complete backup UI and fixed executor drivers**

  **Back Up…** first presents Task 9's asynchronous save panel, persists the parent bookmark/final filename, then enqueues. `BackupBrowserView` shows package, created/completed, subject, qualified completeness, size, and verification; it browses `records-index.json` read-only with safe local Quick Look. Inspector shows canonical IDs, authority claim and each writer-host observation/mismatch, hashes/stages, incomplete components, Resume, Verify, Reveal, and Move to Trash. It never exposes Restore/Import/Migrate.

  Supply live drivers to the already-fixed `RepositoryExportTransferExecutor`, `FullBackupTransferExecutor`, and `BackupVerificationTransferExecutor`; do not mutate/register executors after queue construction. Persist final `TransferResultDescriptor.backupPackage` so Activity Reveal survives relaunch.

- [ ] **Step 11: Hand off membership/shared routes, run tests/build, and seal**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO test \
    -only-testing:ATProtoDriveTests/BackupServiceTests \
    -only-testing:ATProtoDriveTests/WholeSpaceBackupTests \
    -only-testing:ATProtoDriveTests/BackupCatalogTests \
    -only-testing:ATProtoDriveTests/BackupPreflightProviderTests \
    -only-testing:ATProtoDriveTests/SpaceBlobCleanupTests
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  ```

  Expected: PASS; both data planes stream, missing/mismatched blobs prevent completion, claims retain failed/mismatched writers, catalog rejects symlink escape, and delete evidence requires exact qualified completion.

  ```bash
  jj status
  jj diff --summary
  jj describe -m "backups: stream verify and browse resumable packages"
  jj new
  ```

### Task 12: Add Owned-to-Owned Cross-Source Copy and Complete the Static Subsystem Gate

**Files:**
- Create: `ATProtoDrive/Transfers/CrossSourceCopyCoordinator.swift`
- Create: `ATProtoDrive/Transfers/RecordCopyDragPayload.swift`
- Create: `ATProtoDrive/Transfers/CopyDestinationSheet.swift`
- Create: `ATProtoDriveTests/CrossSourceCopyCoordinatorTests.swift`
- Modify: `ATProtoDrive/Transfers/TransferExecutors.swift`
- Modify: `ATProtoDrive/Transfers/ActivityView.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRecordTable.swift`
- Modify: `ATProtoDrive/Spaces/SpaceRecordTableView.swift`
- Modify: `ATProtoDrive/Browser/BrowserCommands.swift`
- Modify by the cross-plan integration owner: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Hand off source/test membership to the cross-plan integration owner.

**Interfaces:**
- Consumes: Plan 2 `MutationCoordinator/MutationOutcome`, exact ownership/capability contexts, qualified record/blob services, Task 5 cross-copy payload/decision receipts, and Task 6 fixed executor.
- Produces: `CopyAccessTransition`, authorization evidence, in-memory request, durable decisions/mappings, partial/uncertain outcomes, `CrossSourceCopyCoordinator`, typed copy-only drag payload, destination sheet, and focused commands.

- [ ] **Step 1: Write failing two-sided ownership, disclosure, conflict, relaunch, partial, and uncertain-write tests**

  ```swift
  @Suite("Cross-source record copy")
  struct CrossSourceCopyCoordinatorTests {
    @Test("foreign or read-only source and destination each fail before blob transport")
    func bothSidesMustBeOwnedWritable() async throws {
      for scenario in CopyFixture.foreignSourceAndDestinationScenarios() {
        await #expect(throws: scenario.expectedError) {
          _ = try await scenario.coordinator.prepare(scenario.request)
        }
        #expect(await scenario.networkCalls == 0)
      }
    }

    @Test("Space ownership requires writer DID equals connected account and exact Space action")
    func spaceOwnership() async throws {
      let fixture = CopyFixture.spaceSource(writerDID: "did:plc:bob", connectedDID: "did:plc:alice")
      await #expect(throws: CrossSourceCopyError.sourceNotOwned) {
        _ = try await fixture.coordinator.prepare(fixture.request)
      }
      #expect(await fixture.networkCalls == 0)
    }

    @Test("Space to public disclosure receipt is destination bound and survives relaunch")
    func disclosureReceipt() async throws {
      let fixture = CopyFixture.spaceToPublic()
      let payload = try await fixture.confirmDisclosureAndCheckpoint()
      let relaunched = fixture.relaunch(payload: payload)
      _ = try await relaunched.resume()
      #expect(await relaunched.disclosurePromptCount == 0)

      let changedDestination = fixture.relaunch(payload: payload, destination: .fixtureOtherPublic())
      await #expect(throws: CrossSourceCopyError.disclosureRequired) { _ = try await changedDestination.resume() }
    }

    @Test("conflict approval is bound to observed destination CID and stale approval re-prompts")
    func conflictReceipt() async throws {
      let fixture = CopyFixture.destinationConflict(observedCID: "bafy-old")
      let payload = try await fixture.approveReplaceAndCheckpoint()
      await #expect(throws: CrossSourceCopyError.destinationChanged) {
        _ = try await fixture.relaunch(payload: payload, currentDestinationCID: "bafy-new").resume()
      }
      #expect(await fixture.destinationMutationCount == 0)
    }

    @Test("uploaded destination blobs remain confirmed partial outcomes when record create fails")
    func uploadedPartialOutcome() async throws {
      let fixture = CopyFixture.failAfterDestinationUpload()
      let outcome = try await fixture.coordinator.copy(fixture.request)
      guard case .destinationBlobsUploadedButRecordNotCreated(let receipts) = outcome else {
        Issue.record("Expected confirmed partial destination uploads"); return
      }
      #expect(receipts.allSatisfy { $0.destination.blob.cid.hasPrefix("bafk") })
      #expect(outcome.rollbackWasClaimed == false)
    }

    @Test("response-lost committed record reconciles and does not duplicate")
    func uncertainDestinationMutation() async throws {
      let fixture = CopyFixture.commitThenLoseResponse()
      let first = try await fixture.coordinator.copy(fixture.request)
      guard case .remoteWriteUnverified = first else { Issue.record("Expected uncertain write"); return }
      let second = try await fixture.relaunchFromPersistence().resume()
      #expect(second.isVerified)
      #expect(await fixture.destinationMutationCount == 1)
    }

    @Test("source CID mismatch stops before any additional network action")
    func sourceChanged() async throws {
      let fixture = CopyFixture.relaunch(sourceCID: "bafy-original", currentSourceCID: "bafy-new")
      await #expect(throws: CrossSourceCopyError.sourceChanged) { _ = try await fixture.resume() }
      #expect(await fixture.destinationNetworkCalls == 0)
    }

    @Test("rewrites only blob refs and preserves ordinary AT URIs byte-for-byte")
    func preservesLinks() async throws {
      let outcome = try await CopyFixture.withOrdinaryATURILink().run()
      #expect(outcome.destinationCanonicalJSON.contains("bafk-destination"))
      #expect(outcome.destinationCanonicalJSON.contains("at://did:plc:bob/app.example.note/key"))
      #expect(!outcome.sourceWasDeleted && !outcome.wasAtomicMove)
    }
  }
  ```

- [ ] **Step 2: Run the focused suite and verify the intended failure**

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-task12.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests/CrossSourceCopyCoordinatorTests
  ```

  Expected: FAIL because two-sided authorization, durable decisions, and copy UI types do not exist.

- [ ] **Step 3: Gate exact source and destination ownership/capability before network work**

  ```swift
  public enum CopyAccessTransition: String, Hashable, Codable, Sendable {
    case publicToPublic, publicToPermissionedSourceRemainsPublic
    case permissionedToPermissioned, permissionedToPublicIrreversibleDisclosure
  }

  public struct WritableRepositoryEvidence: Hashable, Sendable {
    public let scope: RepositoryScope
    public let connectedAccountDID: String
    public let requiredAccess: AccessContext
  }

  public struct CrossSourceCopyPlan: Hashable, Sendable {
    public let source: RecordLocator
    public let sourceOwnership: WritableRepositoryEvidence
    public let destination: RepositoryScope
    public let destinationOwnership: WritableRepositoryEvidence
    public let destinationCollection: String
    public let proposedRKey: String
    public let accessTransition: CopyAccessTransition
  }
  ```

  `prepare` resolves both sides independently and performs zero payload calls until both pass. A public source is eligible only when its repository DID equals a connected account DID and exact public update/create capability is available; anonymous/foreign public records remain inspect/download-only. A Space source is eligible only when `writerDID == connected account DID`, scoped account matches, profile supports the operation, and Plan 2 exact `.spaceRecord(...action:)` grant is available. Apply the same rules to destination. Record both exact account DIDs in `requiredAccountDIDs`; never infer either from the active account.

- [ ] **Step 4: Persist destination-bound decisions, verified mappings, and uncertain stages**

  The in-memory `CrossSourceCopyRequest` may carry the freshly fetched `RecordSnapshot`; it is deliberately non-Codable. The queue persists only Task 5 `CrossSourceCopyResumePayload`. A disclosure receipt is valid only when policy version, full source locator/CID, and destination scope all match. A conflict receipt is valid only for destination scope/collection/rkey and the exact currently observed destination CID; any nil/different CID re-prompts. Both receipts are written before the next irreversible operation.

  After every destination blob upload, verify the returned CID/reachability and atomically append `PersistedBlobMapping`; those are confirmed remote outcomes. On relaunch, first refetch source and require `originalSourceCID`; then refetch the destination conflict target and revalidate receipts before any additional upload/write. Regenerate the body from the fresh matching source plus verified mappings—never persist raw JSON. Replace only blob occurrences, preserve all ordinary AT URI strings, validate the destination record, and submit through `MutationCoordinator`.

  Preserve `MutationOutcome.remoteWriteUnverified`: checkpoint an uncertain destination-record stage and reconcile exact collection/rkey/value/CID before retry. A verified intended record completes without another write; proven absence may offer deliberate retry; a different value is a conflict. If destination blobs exist but record creation is absent/fails, expose `.destinationBlobsUploadedButRecordNotCreated` with receipts and no rollback claim. The source is never automatically deleted; this is always Copy, never Move or atomic.

- [ ] **Step 5: Add real record-table commands and copy-only drag/drop UI**

  ```swift
  public struct RecordCopyDragPayload: Hashable, Codable, Transferable, Sendable {
    public let record: RecordLocator
    public let originalCID: String
    public static var transferRepresentation: some TransferRepresentation {
      CodableRepresentation(contentType: .atprotoDriveRecordReference)
    }
  }
  ```

  The payload contains only a qualified locator/CID, never a body or credential. Add **Copy to Repository…** to `PublicRecordTable`, `SpaceRecordTableView`, context menus, toolbar, and focused `BrowserCommands`, but only when source ownership evidence is available. The source rows expose this internal typed drag. Repository/collection rows accept only that type, propose `.copy` (never `.move`), and open `CopyDestinationSheet`; they do not mutate on drop.

  `CopyDestinationSheet` lists only connected, exact-account writable destinations, then shows collection/key, access transition, source/destination owners, public-retention or irreversible-disclosure warning, and existing-record conflict. **Continue** is disabled until required disclosure/conflict confirmations are explicit. Submission creates decision receipts, enqueues the durable job, and opens Activity. Add presentation tests for foreign-source command absence, copy proposal, destination filtering, disclosure text, conflict re-prompt, and no source-delete command/operation.

- [ ] **Step 6: Supply the live cross-copy driver and run the entire Plan 3 matrix**

  `CrossSourceCopyTransferExecutor` receives the coordinator driver at fixed registry construction and reconstructs solely from its payload/refetches. Run:

  ```bash
  VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-plan3-final.XXXXXX)"
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" \
    -resultBundlePath "$VERIFY_ROOT/Plan3Tests.xcresult" CODE_SIGNING_ALLOWED=NO test \
    -only-testing:ATProtoDriveTests/BlobReferenceIndexTests \
    -only-testing:ATProtoDriveTests/RecordInventoryScannerTests \
    -only-testing:ATProtoDriveTests/BlobServiceTests \
    -only-testing:ATProtoDriveTests/BlobInventoryStoreTests \
    -only-testing:ATProtoDriveTests/BlobLocalInteractionTests \
    -only-testing:ATProtoDriveTests/TransferPersistenceTests \
    -only-testing:ATProtoDriveTests/TransferQueueTests \
    -only-testing:ATProtoDriveTests/AttachmentCoordinatorTests \
    -only-testing:ATProtoDriveTests/BackupManifestTests \
    -only-testing:ATProtoDriveTests/AtomicPackageWriterTests \
    -only-testing:ATProtoDriveTests/PublicCARVerifierTests \
    -only-testing:ATProtoDriveTests/SpaceCARFileVerifierTests \
    -only-testing:ATProtoDriveTests/RepoVerifierTests \
    -only-testing:ATProtoDriveTests/BackupServiceTests \
    -only-testing:ATProtoDriveTests/WholeSpaceBackupTests \
    -only-testing:ATProtoDriveTests/BackupCatalogTests \
    -only-testing:ATProtoDriveTests/BackupPreflightProviderTests \
    -only-testing:ATProtoDriveTests/SpaceBlobCleanupTests \
    -only-testing:ATProtoDriveTests/CrossSourceCopyCoordinatorTests
  ```

  Expected: PASS with no unexpected skips. Inspect the result summary if any suite is absent.

- [ ] **Step 7: Build, audit invariants, and hand runtime acceptance to Plan 4**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$VERIFY_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
  rg -n 'Delete Blob|Restore Backup|Import Backup|Migrate|Atomic Move|\.atpbackup|runModal\(' ATProtoDrive
  rg -n 'Dictionary<String,.*Blob|\[String:.*Blob|temporaryDirectory\.appendingPathComponent\([^)]*cid' ATProtoDrive
  rg -n 'com\.atproto\.sync\.(listBlobs|getBlob|getRepo)' ATProtoDrive/Blobs/SpaceBlobService.swift ATProtoDrive/Backups/BackupService.swift
  rg -n 'getBlob\([^)]*\) async throws -> Data|getRepo\([^)]*\).*Data' ATProtoDrive
  ```

  Expected: build passes; intentional test/document labels are reviewed, production has no forbidden action, bare-CID key, Space public fallback, or buffered payload signature.

  Plan 3 deliberately does not claim a runtime checkpoint before Plan 4's deterministic fixture runtime exists. Hand Plan 4 the exact required signed/UI flows: safe PDF Quick Look and HTML/SVG block; asynchronous blob and backup save panels; drag-to-Finder promise output; queued/running cancel and deliberate retry; relaunch component resume; Activity Reveal; backup browse/verify/reveal/Trash; two-window qualified selection; copy disclosure/conflict UI; destination-blob partial outcome; and no network/Keychain in fixture mode. Plan 4 must capture those runtime/screenshots and report fixture, live public, and live Spaces evidence separately.

- [ ] **Step 8: Seal the subsystem and hand off**

  ```bash
  jj status
  jj diff --summary
  jj describe -m "drive: complete files backups and transfers"
  jj new
  ```

  Hand the fresh child change and `Plan3Tests.xcresult` to `2026-08-23-atprotodrive-v1-account-acceptance.md`; the signed app path/screenshots are produced there, not asserted here.

---

## Acceptance Coverage

| Approved requirement | Implemented and proved by |
|---|---|
| Every blob identity is source-qualified; every reference occurrence and JSON Pointer is retained | Tasks 1–3 |
| Public and Space inventory/fetch routes stay separate; Space never falls back to public sync | Tasks 2–3, Task 12 invariant audit |
| Clear typed blob browser, metadata/reference progress, inspector, safe Quick Look, download, and drag-to-Finder | Tasks 3–4 |
| Exact durable transfer states, descriptor-only persistence, interrupted-on-launch recovery, bounded concurrency, cancel/retry/component resume/reveal | Tasks 5–6 and Task 11 |
| Attach upload is durable only through an exact verified record/blob reference, reconciles uncertain writes, and exposes proved uploaded-but-unreferenced outcomes | Task 7 |
| `.atprotodrivebackup` manifest, qualified paths, readable index, hashes, private permissions, durable bookmark, atomic staging/publication | Tasks 8–9 |
| Public CAR authenticity uses SwanPublicRepository; Space CAR verification uses current SwanSpaces streaming semantics with file-backed scratch | Task 10 |
| Public, single-writer Space, and whole-Space backup creation; CAR-derived blob set; qualified writer-claim completeness; browse/verify/reveal/Trash; exact verified Back Up First evidence; qualified post-Space-delete blob/preview cleanup | Task 11 |
| Cross-source copy requires source and destination ownership, persists disclosure/conflict decisions and partial uploads, preserves ordinary AT URIs, and never presents create-plus-delete as atomic move | Task 12 |
| No restore/import/migration/generic blob deletion and no hidden public fallback | Global constraints and Task 12 audit |

## Handoff Contract

- The implementation change is ready for the account/final-acceptance plan after every Plan 3 focused suite, unsigned full build, and invariant audit pass in the current worktree. Signed runtime/UI acceptance is an explicit pending Plan 4 gate, not Plan 3 evidence.
- The Plan 3 handoff includes exact parent/child jj change IDs, `Plan3Tests.xcresult`, and the runtime-flow checklist in Task 12. Plan 4 produces and records the signed app path, process identity, screenshots, and current live evidence.
- A green fixture suite proves local behavior, not current public-PDS availability or Spaces-alpha interoperability. Label those evidence classes separately.
- The account/final-acceptance plan owns deterministic UI fixtures, the macOS UI-test target, two-window/multi-account acceptance, final screenshots, and the requirement-by-requirement whole-product audit.
