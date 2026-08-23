# ATProtoDrive v1 Implementation Plan Index

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement these plans task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved ATProtoDrive v1 as a native Finder-like macOS PDS data manager for public repositories, permissioned Spaces, supported private app state, blobs, verified backups, durable transfers, safe record CRUD, and deliberately limited account controls.

**Architecture:** Execute four ordered subsystem plans behind stable, typed boundaries. Public and Space data remain separate through transport, authorization, cache keys, temporary paths, mutation semantics, and verification. `AccountStore` and `TransferQueue` are app-scoped; `BrowserSession` is window-scoped; SwiftUI owns the two-column browser and optional inspector, with narrow AppKit bridges for save panels and promised-file drag.

**Tech Stack:** Swift 6, SwiftUI for macOS 15, Observation, structured concurrency, Petrel, SwanSpaces, SwanPublicRepository, XCTest/XCUITest, Swift Testing, Xcode 16+, `jj`.

**Spec:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`

## Plans and execution order

- [ ] [Plan 1 — Public Browser Foundation](2026-08-23-atprotodrive-v1-public-browser.md)
  - Establishes shared domain types, window-local browser state, load/error semantics, anonymous public-repository services, public record pagination, and the Finder-like shell.
- [ ] [Plan 2 — Spaces and Safe CRUD](2026-08-23-atprotodrive-v1-spaces-crud.md)
  - Moves Space browsing into the content plane, narrows authorization, adds contextual reconsent, and implements public CAS plus explicitly non-atomic current-alpha Space mutations and Space administration.
- [ ] [Plan 3 — Files, Backups, and Transfers](2026-08-23-atprotodrive-v1-files-backups-transfers.md)
  - Adds qualified blob inventories and previews, a durable transfer queue, verified `.atprotodrivebackup` packages, attachment flows, and cross-source copies.
- [ ] [Plan 4 — Account Controls and Final Acceptance](2026-08-23-atprotodrive-v1-account-acceptance.md)
  - Adds status/reconnect/remove-from-app, the read-only private-state provider, deterministic UI fixtures, the UI-test target, and the final requirement-by-requirement runtime gate.

The plans are ordered dependencies, not four independent feature branches. Later plans may begin only after the interfaces they consume have landed and their producing task is green.

## Current protocol constraints pinned by this plan

- ATProto Spaces is an alpha with expected breaking changes. Production code must gate behavior through an explicit supported-profile/capability value and show unsupported states without silently falling back to public endpoints.
- A Space is access-controlled, not end-to-end encrypted. UI copy never calls permissioned records confidential or encrypted.
- `listSpaces` finds Spaces in which the caller already holds a writer repository; it is not a readable-membership list. Manual Open Space by URI, bookmarks, and recents remain required.
- `listRepos` is served by the authority's Space host and reports the authority-claimed writer set. Each writer's `#atproto_pds` remains the source of truth for that repository.
- `com.atproto.space.getLatestCommit` provides a signed revision/hash for last-moment comparison. Current Space write schemas still have no compare-and-swap input, so that read improves preflight evidence but does not make a Space write atomic against another writer.
- Space `action=` grants govern records. Space `manage=` grants govern Space creation/update/deletion and supported administration. Neither is substituted for the other.
- ATProto accepts `did:plc` and hostname-level `did:web` identities. Path-form `did:web` is rejected, non-localhost encoded ports are rejected, and resolved PDS/Space-host services must be canonical origins without user information, path prefixes, queries, or fragments.
- A permissioned record uses the complete `at://{spaceDid}/space/{spaceType}/{skey}/{authorDid}/{collection}/{rkey}` identity. A public-shaped writer URI is never accepted as a Space record locator.
- ATProtoDrive uses a strict `#atproto_space_host` authority policy: exact DID-document identity, exact service ID/type, and no fallback to `#atproto_pds` when the dedicated authority service is absent or malformed.

## Canonical shared contract

These names are fixed across all four plans. An implementing worker may add fields that preserve these semantics, but must not create competing aliases or mode flags.

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

public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(previous: Value?, failure: BrowserFailure)
}

public enum RecordWriteAction: String, Hashable, Sendable {
    case create, update, delete
}

public enum SpaceManagementAction: String, Hashable, Sendable {
    case create, update, delete
}

public enum AccessContext: Hashable, Sendable {
    case publicRecord(collection: String, action: RecordWriteAction)
    case blobUpload(mimeType: String)
    case spaceRecord(
        space: SpaceRef,
        collection: String,
        action: RecordWriteAction
    )
    case spaceRead(space: SpaceRef)
    case createSpace(spaceType: String, requestedSKey: String?)
    case manageSpace(space: SpaceRef, action: SpaceManagementAction)
    case privateAppState(method: String, serviceDID: String)
}

public enum RepositoryVersion: Hashable, Sendable {
    case publicCommit(cid: String)
    case spaceSignedCommit(revision: String, hashBase64: String)
}

public enum TransferState: String, Codable, Sendable {
    case queued
    case discovering
    case waitingForPermission
    case running
    case verifying
    case completed
    case interrupted
    case cancelled
    case failed
}
```

`ResourceReference` is the typed browser/export target and contains, rather than reconstructs, a `RepositoryScope`, `RecordLocator`, or `BlobLocator` when one exists. `BrowserItem` retains a `ResourceReference` and an `AccessClassification`; authorization never dispatches from display strings or an `isPrivate` Boolean.

The remaining canonical names are:

- Browser: `BrowserSource`, `BrowserPath`, `BrowserItem`, `BrowserSession`, `SearchQuery`.
- Load/error: `LoadState`, `BrowserFailure`.
- Public repository: `RepositoryTarget`, `ResolvedRepository`, `RepositoryDescription`, `RepositoryRecordPage`, `RecordOrigin`, `RecordRow`, `PublicRepositoryServing`, `PublicRepositoryService`, `PublicRepositoryStore`, `PublicRecordStore`.
- Resolution: `ResolvedPDSIdentity`, `DIDDocumentPDSResolving`, `DIDDocumentPDSResolver`.
- Spaces and writes: SwanSpaces `SpaceRef`, `RepositoryVersion`, `SpaceProtocolProfile`, `SpaceProtocolMethod`, `SpaceProtocolCapabilities`, `SpaceProtocolCapabilityProviding`, `SpaceRepositoryService`, `SpaceAdministrationService`, `MutationCoordinator`, `BackupPreflightEvidence`, `BackupPreflightProviding`.
- Authentication: `RecordWriteAction`, `SpaceManagementAction`, `LoginIntent`, `AccessContext`, `AccountConnectionStatus`, `AuthenticationIssue`, `AuthorizationScopePlanner`.
- Transfers: `TransferState`, `TransferExecutorRegistry`, `TransferAccountParkingReceipt`, `TransferQueue`, `TransferStore`. `TransferJobDescriptor.requiredAccountDIDs` is a `Set<String>`, and `TransferQueue.markAccountsUnavailable(_:)` returns `TransferAccountParkingReceipt` only after the selected jobs are durably parked and their old execution generations have terminated or been fenced.

## Invariants every plan preserves

- Public reads always use an unauthenticated client created for the resolved target PDS, even when the target belongs to a connected account.
- Space reads and blobs never fall back to public sync endpoints.
- Every generated Petrel response requires both a `200..<300` status and a non-`nil` decoded body when the endpoint defines an output.
- Public caches, Space caches, backup paths, preview paths, and blob-reference indexes are qualified by their complete data-plane identity.
- `BrowserSession` contains stable scalar/domain identifiers, never clients, credentials, or feature services, and one window never mutates another window's navigation state.
- Public writes use the freshest `swapRecord` and `swapCommit` preconditions. The supported Space alpha has no CAS input, so Space mutation uses an immediate comparison, an explicit race warning, one submission, and post-write verification.
- A record action grant and a Space `manage=` grant are different authorities. UI capability checks preserve that distinction.
- Persisted transfer records contain descriptors and security-scoped bookmarks, never OAuth tokens, DPoP keys, Space credentials, clients, or record bodies.
- Remove-from-app parks and cancellation-fences every exact-account transfer before OAuth, credential-manager, cache, or preview cleanup begins.
- No screen, command, menu, URL handler, or focused action exposes repository migration/import, email or handle changes, password or app-password controls, account deactivation, or remote account deletion.

## Integration ownership

The Xcode project uses manually maintained `PBXGroup`, `PBXFileReference`, `PBXBuildFile`, and Sources-phase entries. During implementation, one integration worker owns all edits to `ATProtoDrive.xcodeproj/project.pbxproj`, shared schemes, `ATProtoDrive/ATProtoDriveApp.swift`, and the final root `Browser/ContentBrowserView.swift`. Feature workers add source and test files on disk and hand their exact membership list to that owner.

The integration owner must keep project-file changes in the same sealed change as the source files they make buildable. No worker may report a task complete while its files are absent from the relevant target.

Plan 2 also has one explicit cross-repository prerequisite: Petrel's `SpaceCredentialManager` must accept the same strict authority-host provider used by ATProtoDrive. That Petrel change and its tests are independently sealed before Plan 2's first ATProtoDrive build gate; the app must not route credential exchange through Petrel's legacy fallback resolver.

## Baseline and common verification commands

Create one isolated directory per task or verification run:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-verify.XXXXXX)"
ATD_DERIVED="$VERIFY_ROOT/DerivedData"
```

Unsigned deterministic build and hosted unit tests follow. The full-target `test` command is not an early Plan 1 gate: use Plan 1's explicit safe matrix until Plan 2 Task 1 has isolated Space persistence and Plan 2 Task 4 has isolated account preferences/live OAuth. After both tasks seal, later plans may use this aggregate command while keeping opt-in live tests gated.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ATD_DERIVED" \
  CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ATD_DERIVED" \
  -resultBundlePath "$VERIFY_ROOT/UnitTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests
```

The unsigned build does not prove Keychain, OAuth callback, DPoP, CAB, security-scoped bookmark, or live Space behavior. Plan 4 defines the separate signed runtime gates.

## Task sealing contract

Each task in the linked plans starts with a failing focused test, implements the smallest behavior that makes it pass, reruns the focused and relevant aggregate suites, and checks the diff. When the task is independently green and contains no unrelated user changes:

```bash
jj status
jj diff --summary
jj describe -m "browser: add anonymous repository routing"
jj new
```

The linked task supplies its own exact description; the line above is a concrete format example. `jj new` follows `jj describe` immediately. Git commands are read-only. A content-identical descendant is acceptable when ancestry and tree equality are both verified.

## Final completion gate

The v1 goal is complete only after Plan 4's audit maps every approved-spec acceptance criterion to current-worktree evidence: focused and aggregate tests, an unsigned build, signed runtime proof where credentials or entitlements matter, live anonymous public browsing, separately identified current-alpha Space evidence, two-window/account isolation, transfer relaunch recovery, finished UX screenshots, and an explicit absence audit for prohibited account controls.
