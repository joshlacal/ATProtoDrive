# ATProtoDrive v1 Spaces and Safe CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Space-first test-client flow with a clear content-pane Space browser and add safe, ownership-checked public and Space record CRUD plus owner-only Space administration.

**Architecture:** Plan 1 supplies the Finder-like shell, public read service, shared domain identifiers, and window-scoped browser state. This plan keeps public and permissioned operations in separate concrete services, adds a narrow contextual OAuth scope planner, and routes both through a mutation coordinator that owns validation, diffing, repository write serialization, confirmation, and verification. Public writes use protocol CAS; current Proposal 0016 Space writes use a last-moment comparison, an explicit non-atomic warning, one submission, and post-write verification.

**Tech Stack:** Swift 6, SwiftUI and Observation on macOS 15, Swift Testing, Petrel generated AT Protocol clients plus `SpaceRef`/`SpaceCredentialManager`, SwanCore canonical OAuth scope formatting, Xcode project with manually maintained PBX groups and source phases, jj for all VCS writes.

**Spec:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`

**Dependencies:** Execute `docs/superpowers/plans/2026-08-23-atprotodrive-v1-public-browser.md` first and do not begin this plan until Plan 1's Task 8 seal exists. This is a hard compile-time and ownership dependency, not just a UX dependency: this plan consumes Plan 1's `DIDDocumentFetch`, `DIDDocumentPDSResolver.documentURL(for:allowLocalhostDevelopment:)`, generic `DIDDocumentPDSResolving`/`ResolvedPDSIdentity` for every writer's exact `#atproto_pds`, and the Plan-1-owned `ATProtoDrive/Domain/ResourceReference.swift` plus `ATProtoDrive/Browser/BrowserSession.swift` as follow-on edits. It also consumes `AccessClassification`, `RepositoryScope`, `RecordLocator`, `BlobLocator`, `BrowserSource`, `BrowserPath`, `BrowserItem`, `LoadState`, `BrowserFailure`, `RepositoryTarget`, `ResolvedRepository`, `RepositoryDescription`, `RepositoryRecordPage`, `RecordOrigin`, `RecordRow`, `PublicRepositoryServing`, `PublicRepositoryService`, `PublicRepositoryStore`, and `PublicRecordStore`. It never uses Petrel `SpaceHostResolver` to choose either a writer PDS or a Space authority host. Plan 3 supplies the production `BackupPreflightProviding` implementation and blob/cache cleanup participant; until then, Space-record and whole-Space delete remain fail-closed behind the **Back Up First** gate. This plan is the canonical owner of `RecordWriteAction`, `SpaceManagementAction`, `LoginIntent`, `AccessContext`, `AuthorizationScopePlanner`, `AccountConnectionStatus`, and `AuthenticationIssue`. Plan 4 may add one private-RPC access case and status presentation, but must not rename or introduce parallel auth types.

## Global Constraints

- The deployment target remains macOS 15.0 and the project remains Swift 6 strict-concurrency code.
- Public repository reads and writes use public-repository services only; Space reads and writes use Space services and Space credentials only. Never add a service with an `isPrivate` or `useSpace` mode flag.
- `RepositoryScope` is the operational routing key: `.publicRepository(did:pdsURL:)` or `.permissionedSpace(spaceURI:writerDID:accountDID:)`. `AccessClassification` remains the presentation and persistence classification.
- Every cache, selection, preview, and cleanup key includes account DID plus the qualified repository scope. A CID, writer DID, or Space URI alone is not a sufficient key.
- Current Proposal 0016 has no `listCollections`; derive Space collections by fully paginating `com.atproto.space.listRecords` with no collection filter, or from a verified `com.atproto.space.getRepo` CAR index.
- `listSpaces` lists Spaces in which the caller holds a writer repository; it omits read-only memberships. Preserve **Open Space by URI**, bookmarks, and recents.
- The baseline wildcard Space grant is explicit `action=read_self`: it permits own-repository discovery/listing without granting all-writer reads. Whole-Space credential exchange is a separate contextual reconsent for one exact `SpaceRef` with `action=read` and no collection qualifier.
- Whole-Space mode fully paginates `listRepos` at the authority's `#atproto_space_host`, resolves each writer DID through Plan 1's `DIDDocumentPDSResolving` to its exact `#atproto_pds`, and uses the Space credential for every foreign-writer request. `getSpace` and `listRepos` are authority-host calls; `listRecords`, `getRecord`, `getLatestCommit`, and `getRepo` are writer-PDS calls. If credential exchange or writer enumeration is unavailable, show **My Records only** with a reason.
- Every Space record locator uses the canonical seven-component wire form `at://{spaceDid}/space/{spaceType}/{skey}/{authorDid}/{collection}/{rkey}` produced by `SpaceRef.recordURI(authorDID:collection:recordKey:)`. Never synthesize a Space record URI by string concatenation or use a public-record URI for a permissioned record.
- Space authority resolution is strict and independent from writer-PDS resolution: fetch the exact authority DID document through Plan 1's ATProto DID URL rules, require its exact `id`, exactly one `#atproto_space_host` service of type `AtprotoSpaceHost`, and an origin-only HTTPS endpoint. Missing or malformed dedicated authority service is an error; never fall back to `#atproto_pds`.
- A Petrel generated call succeeds only when the status is 2xx and the required output is non-nil. Treat 2xx plus nil output as a decode failure.
- Record grants use `action=read_self|read|create|update|delete`; Space administration uses the disjoint `manage=create|update|delete` vocabulary. Never use `manage=` to authorize a record operation, and never omit `action=` because omission defaults to broad record access.
- `manage=update` is the one administration grant for `updateSpace`, `addMember`, and `removeMember`; it does not authorize `putRecord` or any other record mutation.
- Only the connected account's public repository and that account's own writer repository in a Space are writable. Ownership is checked before any mutation transport is invoked.
- Public updates and deletes send both `swapRecord` and `swapCommit`; public creates send `swapCommit`. `applyWrites` is allowed only for one public repository and carries `swapCommit`.
- Current Space create/put/delete/applyWrites schemas expose no CAS fields. Refetch immediately before submission, abort if the prepared snapshot changed, state that the comparison is non-atomic, submit once, and refetch to verify. Never auto-retry a mutation with an uncertain outcome.
- Current Proposal 0016 does expose `com.atproto.space.getLatestCommit`. Treat its signed `rev` plus `hash` bytes as the writer repository version, route it to the writer PDS, and use it in every Space preflight and post-write verification. It is not a CAS input.
- Space-record deletion and whole-Space deletion require verified, matching backup evidence from `BackupPreflightProviding`. This plan defines the gate but does not implement backup creation.
- Whole-Space deletion evidence is bound to a fresh, fully paginated authority claim and the complete writer-PDS signed revision/hash observations. Re-enumerate and re-observe immediately before submission; any cursor cycle, missing writer, changed claim/revision/hash, stale preparation, or manifest mismatch aborts before `deleteSpace`.
- Whole-Space deletion explains that compliant syncers should discard synchronized copies but writer-owned repositories, exports, backups, and nonconforming copies can remain. Successful remote deletion purges active credentials, record caches, blob-cache participants, and temporary previews while preserving explicit backups.
- Loading and mutation failures retain the last successful snapshot and present a typed banner. Do not turn an error into a successful empty state.
- The project uses classic `PBXGroup`/`PBXSourcesBuildPhase`. The one cross-plan integration owner named by the plan index is the sole editor of `ATProtoDrive.xcodeproj/project.pbxproj`, shared schemes, `ATProtoDrive/ATProtoDriveApp.swift`, and the root `ATProtoDrive/Browser/ContentBrowserView.swift`. Feature workers create or modify only their owned feature files, then hand the integration owner the exact app/test membership list. The integration owner lands that wiring in the same task change before its build/test gate and seal; no task creates compile-only stubs or edits shared integration files independently.
- For every task whose Files list says **Create**, the feature worker writes the failing test/source seam, then—before that task's first `xcodebuild` red-phase command—hands every newly created app/test path to the cross-plan integration owner. The owner adds only those files to the correct source phase in the same working change. A missing test target membership is not an acceptable red result.
- Do not add account migration, import/restore, handle/email/password/app-password changes, deactivation, remote account deletion, or provider-session enumeration.
- Each task's final VCS step is `jj describe` followed immediately by `jj new`; Git remains read-only.

---

## File Map

### Space data plane

- `ATProtoDrive/Spaces/SpaceModels.swift` — Space summaries, policy/app-access projections, writer/member pages, collection inventory, and read capability state. Move the small domain types currently embedded in `SpaceListModel.swift` and `SpaceDetailModel.swift` here.
- `ATProtoDrive/Spaces/SpaceProtocolCapabilities.swift` — the explicit supported alpha profile, per-method capability state, and fail-closed unsupported-method mapping; there is no implicit fallback to another data plane.
- `ATProtoDrive/Spaces/SpaceAuthorityHostResolver.swift` — strict authority-DID document fetch/validation for the one exact `#atproto_space_host`; it deliberately does not wrap Petrel's fallback resolver.
- `ATProtoDrive/Spaces/SpaceRepositoryService.swift` — Space-only Proposal 0016 reads, separate authority-host/writer-PDS routing, output normalization, record mapping, and collection discovery.
- `ATProtoDrive/Spaces/SpaceRepositoryStore.swift` — account- and scope-qualified load state, pagination, deduplication, My Records/Whole Space projection, and selection preservation.
- `ATProtoDrive/Spaces/SpaceBookmarkStore.swift` — app-scoped, versioned, atomically persisted account-qualified Space bookmarks and recents; tests use memory/temp persistence only.
- `ATProtoDrive/Spaces/OpenSpaceCoordinator.swift` — validates a Space URI, requires an explicit connected account, loads its overview through that account's Space service, then records the successful open.
- `ATProtoDrive/Spaces/OpenSpaceView.swift` — global **Open Space by URI** form, account chooser, validation/error states, and successful window-local route transition.
- `ATProtoDrive/Spaces/SpaceBrowserView.swift` — Space list/overview content surfaces and navigation into writer repositories and collections.
- `ATProtoDrive/Spaces/SpaceRecordTableView.swift` — sortable record table, explicit Load More, stale banner, and mutation command projection.

### Authorization and mutation

- `ATProtoDrive/Accounts/AuthenticationModels.swift` — canonical `RecordWriteAction`, `SpaceManagementAction`, `LoginIntent`, `AccessContext`, `AccountConnectionStatus`, and `AuthenticationIssue` shared with Plan 4.
- `ATProtoDrive/Accounts/AuthorizationScopePlanner.swift` — canonical base/read, public-record, Space-record, and Space-management scopes using SwanCore.
- `ATProtoDrive/Mutation/MutationModels.swift` — mutation snapshots, drafts, preparations, warnings, confirmations, outcomes, conflicts, and partial outcomes; it consumes the action enums from `AuthenticationModels.swift`.
- `ATProtoDrive/Mutation/RecordDocumentCodec.swift` — lossless AT Protocol JSON decode/encode and validation gate.
- `ATProtoDrive/Mutation/RecordDiff.swift` — stable field-oriented and raw JSON diff projection.
- `ATProtoDrive/Mutation/PublicMutationService.swift` — public owner-only CAS create/update/delete and post-write verification.
- `ATProtoDrive/Mutation/SpaceMutationService.swift` — Space owner-repository-only preflight/write/verification with current-alpha limitation.
- `ATProtoDrive/Mutation/MutationCoordinator.swift` — per-repository write serialization, reconsent continuation, and no-blind-retry policy.
- `ATProtoDrive/Mutation/RecordMutationSheet.swift` — schema-aware summary plus raw JSON editor that preserves unknown AT Protocol values.
- `ATProtoDrive/Mutation/MutationConfirmationView.swift` — destination, diff, access, conflict, delete consequences, warnings, and partial-result UI.

### Space administration and deletion gate

- `ATProtoDrive/Spaces/SpaceAdministrationService.swift` — owner-only simple-space create/get/update/member/delete calls.
- `ATProtoDrive/Spaces/SpaceAdministrationStore.swift` — policy/member load and mutation state with last-known snapshot retention.
- `ATProtoDrive/Spaces/SpaceAdministrationView.swift` — create, policy, membership, backup-first, and destructive confirmation UI.
- `ATProtoDrive/Spaces/SpaceDeletionSafety.swift` — `BackupPreflightProviding`, matching evidence validation, active-state cleanup participants, and partial cleanup result.

### Existing files changed

- `ATProtoDrive/Accounts/AccountStore.swift` — intent-aware OAuth clients, pending-login context, contextual reconsent, and surfaced callback failures.
- `ATProtoDrive/Domain/ResourceReference.swift` — Plan 1 owns the declaration; Task 3 adds only the account-qualified `.space(accountDID:spaceURI:)` case and updates its existing exhaustive switches.
- `ATProtoDrive/Browser/BrowserSession.swift` — Plan 1 owns the declaration; Task 3 extends its existing path/selection validation for account-qualified Space overview and repository paths.
- `ATProtoDrive/Browser/ContentBrowserView.swift` — cross-plan integration owner only: routes `.spaces` selections into the Space browser supplied here.
- `ATProtoDrive/Browser/BrowserInspectorView.swift` — displays Space policy, writer, access class, current-alpha warning, and mutation verification state.
- `ATProtoDrive/Browser/BrowserCommands.swift` — exposes only ownership- and capability-eligible create/edit/delete/Space-admin commands.
- `ATProtoDrive/Records/RecordListModel.swift` — shrinks to compatibility projection while reusable codec, mutation, and Space read logic moves to focused files.
- `ATProtoDrive/Records/RecordTableView.swift` — becomes a compatibility wrapper around `SpaceRecordTableView`, then is removed after call sites migrate.
- `ATProtoDrive/Spaces/SpaceListModel.swift`, `SpaceDetailModel.swift`, `SpaceDetailView.swift`, `SidebarView.swift` — retain migration shims only until the content-pane flow is wired, then remove obsolete nested navigation.
- `ATProtoDrive/Write/RecordEditorSheet.swift`, `CreateSpaceSheet.swift`, `MemberEditor.swift` — migrate to the unified safe flows; no direct Petrel call remains in a view.
- `ATProtoDrive/ATProtoDriveApp.swift` — cross-plan integration owner only: injects authorization, mutation, Space-service, backup-gate, and cleanup dependencies.
- `ATProtoDrive.xcodeproj/project.pbxproj` — cross-plan integration owner only: wires each handed-off file and adds the local `SwanCore` product to app and unit-test targets in the task that first needs it.

### Tests

- `ATProtoDriveTests/SpaceRepositoryServiceTests.swift`
- `ATProtoDriveTests/SpaceAuthorityHostResolverTests.swift`
- `ATProtoDriveTests/SpaceTestFixtures.swift`
- `ATProtoDriveTests/SpaceBookmarkStoreTests.swift`
- `ATProtoDriveTests/OpenSpaceCoordinatorTests.swift`
- `ATProtoDriveTests/SpaceRepositoryStoreTests.swift`
- `ATProtoDriveTests/AuthorizationScopePlannerTests.swift`
- `ATProtoDriveTests/RecordDocumentCodecTests.swift`
- `ATProtoDriveTests/MutationTestFixtures.swift`
- `ATProtoDriveTests/PublicMutationServiceTests.swift`
- `ATProtoDriveTests/SpaceMutationServiceTests.swift`
- `ATProtoDriveTests/MutationCoordinatorTests.swift`
- `ATProtoDriveTests/SpaceAdministrationServiceTests.swift`
- `ATProtoDriveTests/SpaceDeletionSafetyTests.swift`
- Existing Space/write tests are updated as their production types move; do not delete assertions merely because the implementation boundary changed.

## Fixed Cross-Task Interfaces

The following signatures are the contract for this plan. Keep them identical across tasks and sibling plans.

```swift
public struct SpaceWriterRepository: Identifiable, Hashable, Sendable {
    public var id: String { did }
    public let did: String
    public let revision: String
    /// Canonical RFC 4648 Base64 of `ComAtprotoSpaceListRepos.Repo.hash.data`.
    public let commitHashBase64: String
}

public enum SpacePolicy: Hashable, Sendable {
    /// Anyone satisfying the Space authority's public-access policy may obtain
    /// read access/a Space credential. This does not grant record write access.
    case publicAccess
    case memberList
    case managingApp(rawJSON: String)
    case unsupported(rawJSON: String)
}

public enum SpaceProtocolMethod: String, Hashable, Sendable {
    case getSpace, listSpaces, listRepos, listRecords, getRecord, getLatestCommit, getRepo
    case createRecord, putRecord, deleteRecord, applyWrites
    case listMembers, createSpace, updateSpace, addMember, removeMember, deleteSpace
}

public extension SpaceProtocolMethod {
    static let allCurrentAlphaMethods: [Self] = [
        .getSpace, .listSpaces, .listRepos, .listRecords, .getRecord, .getLatestCommit, .getRepo,
        .createRecord, .putRecord, .deleteRecord, .applyWrites,
        .listMembers, .createSpace, .updateSpace, .addMember, .removeMember, .deleteSpace
    ]
}

public enum SpaceProtocolProfile: Hashable, Sendable {
    case proposal0016Alpha2026_08
    case unsupported(identifier: String)
}

public struct SpaceProtocolCapabilities: Hashable, Sendable {
    public let profile: SpaceProtocolProfile
    public let supportedMethods: Set<SpaceProtocolMethod>
    public let supportsAggregateRecordListing: Bool

    public static let currentPetrelAlpha = Self(
        profile: .proposal0016Alpha2026_08,
        supportedMethods: Set(SpaceProtocolMethod.allCurrentAlphaMethods),
        supportsAggregateRecordListing: true
    )

    public func supports(_ method: SpaceProtocolMethod) -> Bool {
        supportedMethods.contains(method)
    }
}

public protocol SpaceProtocolCapabilityProviding: Sendable {
    func capabilities(
        accountDID: String,
        space: SpaceRef?,
        serviceHost: URL?
    ) async -> SpaceProtocolCapabilities
    func recordUnsupported(
        _ method: SpaceProtocolMethod,
        accountDID: String,
        space: SpaceRef?,
        serviceHost: URL?
    ) async
}

public protocol SpaceAuthorityHostResolving: Sendable {
    func resolveAuthorityHost(for authorityDID: String) async throws -> URL
}

public actor StrictSpaceAuthorityHostResolver: SpaceAuthorityHostResolving {
    private let fetchDocument: DIDDocumentFetch

    public init(
        fetchDocument: @escaping DIDDocumentFetch = DIDDocumentPDSResolver.liveFetch
    ) {
        self.fetchDocument = fetchDocument
    }

    public func resolveAuthorityHost(for authorityDID: String) async throws -> URL {
        let documentURL = try DIDDocumentPDSResolver.documentURL(
            for: authorityDID,
            allowLocalhostDevelopment: false
        )
        let response = try await fetchDocument(documentURL)
        guard (200...299).contains(response.statusCode), let data = response.data else {
            throw BrowserFailure.invalidDIDDocument(
                "Space authority DID document was unavailable"
            )
        }
        let document: DIDDocument
        do { document = try JSONDecoder().decode(DIDDocument.self, from: data) }
        catch {
            throw BrowserFailure.invalidDIDDocument(
                "Space authority DID document could not be decoded"
            )
        }
        return try Self.validatedAuthorityHost(
            from: document,
            expectedDID: authorityDID
        )
    }

    public static func validatedAuthorityHost(
        from document: DIDDocument,
        expectedDID: String
    ) throws -> URL {
        guard document.id == expectedDID else {
            throw BrowserFailure.identityMismatch(
                expected: expectedDID,
                actual: document.id
            )
        }
        let expectedServiceID = "\(expectedDID)#atproto_space_host"
        let matches = document.service.filter {
            ($0.id == "#atproto_space_host" || $0.id == expectedServiceID)
                && $0.type == "AtprotoSpaceHost"
        }
        guard matches.count == 1 else {
            throw BrowserFailure.invalidDIDDocument(
                "Expected exactly one #atproto_space_host service"
            )
        }
        guard var components = URLComponents(
            string: matches[0].serviceEndpoint
        ), components.scheme?.lowercased() == "https",
           let host = components.host, !host.isEmpty,
           components.user == nil, components.password == nil,
           components.path.isEmpty || components.path == "/",
           components.query == nil, components.fragment == nil
        else {
            throw BrowserFailure.invalidDIDDocument(
                "Space authority endpoint must be an origin-only HTTPS URL"
            )
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        components.path = ""
        guard let origin = components.url else {
            throw BrowserFailure.invalidDIDDocument(
                "Space authority endpoint could not be canonicalized"
            )
        }
        return origin
    }
}

public struct SpaceOverview: Hashable, Sendable {
    public let space: SpaceItem
    public let policy: SpacePolicy
    public let appAccessJSON: String
    public let readCapability: SpaceReadCapability
}

public enum SpaceReadCapability: Hashable, Sendable {
    case myRecordsOnly(reason: String)
    case wholeSpace
}

public struct SpaceRepositorySnapshot: Sendable {
    public var overview: SpaceOverview
    public var writers: [SpaceWriterRepository]
    public var recordsByWriter: [String: [RecordRow]]
    public var collectionInventory: [RepositoryScope: SpaceCollectionInventory]
    public var readCapability: SpaceReadCapability
    public var writerFailures: [String: BrowserFailure]
}

public struct SpaceAdministrationSnapshot: Sendable {
    public var overview: SpaceOverview
    public var memberDIDs: [String]
    public var memberCursor: String?
    public var membersComplete: Bool
    public var warning: SpaceAdministrationWarning?
}

public enum SpaceAdministrationWarning: Hashable, Sendable {
    case memberCursorCycle(cursor: String)
    case partialMembers(message: String)
    case unsupportedProfile(identifier: String)
}

public struct VerifiedSpaceRecordIndex: Sendable {
    public let paths: [String]
    public let repositoryRevision: String
    public let commitHashBase64: String
}

public struct SpacePage: Sendable {
    public let spaces: [SpaceItem]
    public let cursor: String?
}

public struct SpaceWriterPage: Sendable {
    public let writers: [SpaceWriterRepository]
    public let cursor: String?
}

public struct SpaceMemberPage: Sendable {
    public let memberDIDs: [String]
    public let cursor: String?
}

public struct SpaceCollectionInventory: Equatable, Sendable {
    public let collections: [String]
    public let recordsScanned: Int
    public let isComplete: Bool
    public let source: Source
    public enum Source: Equatable, Sendable { case pagedRecords, verifiedCAR }
}

public enum SpaceRecordLocatorError: Error, Hashable, Sendable {
    case malformedComponent(String)
    case wireURIMismatch(expected: String, actual: String)
}

public extension RecordLocator {
    static func spaceRecord(
        space: SpaceRef,
        authorDID: String,
        accountDID: String,
        collection: String,
        recordKey: String,
        cid: String,
        wireURI: String? = nil
    ) throws -> Self {
        let canonicalSpace: SpaceRef
        let canonicalAuthor: String
        let canonicalAccount: String
        let canonicalCollection: String
        let canonicalKey: String
        let canonicalCID: String
        do {
            canonicalSpace = try SpaceRef(uriString: space.uriString())
            canonicalAuthor = try DID(didString: authorDID).didString()
            canonicalAccount = try DID(didString: accountDID).didString()
            canonicalCollection = try NSID(nsidString: collection).nsidString()
            canonicalKey = try RecordKey(keyString: recordKey).value
            canonicalCID = try CID.parse(cid).string
        } catch {
            throw SpaceRecordLocatorError.malformedComponent(
                String(describing: type(of: error))
            )
        }
        let canonicalURI = try canonicalSpace.recordURI(
            authorDID: canonicalAuthor,
            collection: canonicalCollection,
            recordKey: canonicalKey
        ).uriString()
        guard wireURI == nil || wireURI == canonicalURI else {
            throw SpaceRecordLocatorError.wireURIMismatch(
                expected: canonicalURI,
                actual: wireURI ?? ""
            )
        }
        return Self(
            scope: .permissionedSpace(
                spaceURI: canonicalSpace.uriString(),
                writerDID: canonicalAuthor,
                accountDID: canonicalAccount
            ),
            uri: canonicalURI,
            collection: canonicalCollection,
            rkey: canonicalKey,
            cid: canonicalCID
        )
    }
}

public protocol SpaceRepositoryServing: Sendable {
    func capabilities(for space: SpaceRef?) async -> SpaceProtocolCapabilities
    func listSpaces(cursor: String?, limit: Int) async throws -> SpacePage
    func overview(space: SpaceRef) async throws -> SpaceOverview
    func listWriters(space: SpaceRef, cursor: String?, limit: Int) async throws -> SpaceWriterPage
    func listRecords(
        scope: RepositoryScope,
        collection: String?,
        cursor: String?,
        limit: Int,
        reverse: Bool,
        excludeValues: Bool
    ) async throws -> RepositoryRecordPage
    func record(locator: RecordLocator) async throws -> RecordSnapshot
    func repositoryBaseline(scope: RepositoryScope) async throws -> RepositoryBaseline
    func collections(scope: RepositoryScope) async throws -> SpaceCollectionInventory
}

public enum RecordWriteAction: String, Hashable, Sendable { case create, update, delete }
public enum SpaceManagementAction: String, Hashable, Sendable { case create, update, delete }

public enum AccessContext: Hashable, Sendable {
    case publicRecord(collection: String, action: RecordWriteAction)
    case blobUpload(mimeType: String)
    case spaceRecord(space: SpaceRef, collection: String, action: RecordWriteAction)
    case spaceRead(space: SpaceRef)
    case createSpace(spaceType: String, requestedSKey: String?)
    case manageSpace(space: SpaceRef, action: SpaceManagementAction)
}

public enum LoginIntent: Hashable, Sendable {
    case add
    case reconnect(accountDID: String)
    case reconsent(accountDID: String, context: AccessContext)
}

public enum AccountConnectionStatus: Hashable, Sendable {
    case checking
    case connected(grantedScopes: Set<String>)
    case needsReconnect(message: String)
    case needsReconsent(context: AccessContext, message: String)
    case degraded(message: String)
}

public struct AuthenticationIssue: Error, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String
    public let accountDID: String?

    public static func missingAccount(_ did: String) -> Self {
        return .init(
            id: UUID(), title: "Account unavailable",
            message: "No connected account matches \(did).", accountDID: did
        )
    }
}

public enum RepositoryVersion: Hashable, Sendable {
    case publicCommit(cid: String)
    case spaceSignedCommit(revision: String, hashBase64: String)

    public var publicCommitCID: String? {
        guard case let .publicCommit(cid) = self else { return nil }
        return cid
    }

    public func requirePublicCommitCID() throws -> String {
        guard case let .publicCommit(cid) = self else {
            throw MutationError.invalidPreparation("Expected a public commit CID")
        }
        return cid
    }
}

public enum RepositoryBaseline: Hashable, Sendable {
    case absent
    case version(RepositoryVersion)
}

public struct RecordSnapshot: Hashable, Sendable {
    public let locator: RecordLocator
    public let value: ATProtocolValueContainer
    public let canonicalJSON: String
    public let recordCID: String
    public let repositoryVersion: RepositoryVersion
}

public struct RecordDraft: Hashable, Sendable {
    public let scope: RepositoryScope
    public let collection: String
    public let recordKey: String?
    public let value: ATProtocolValueContainer
    public let canonicalJSON: String
    public let validate: Bool
}

public struct MutationPreparation: Sendable {
    public let id: UUID
    public let preparedAt: Date
    public let scope: RepositoryScope
    public let action: RecordWriteAction
    public let draft: RecordDraft?
    public let original: RecordSnapshot?
    public let destinationDescription: String
    public let diff: RecordDiff
    public let warnings: [MutationWarning]
    public let requiredAccess: AccessContext
    public let repositoryBaseline: RepositoryBaseline
    public let backupEvidence: BackupPreflightEvidence?
}

public struct MutationBatchPreparation: Sendable {
    public let id: UUID
    public let preparedAt: Date
    public let scope: RepositoryScope
    public let items: [MutationPreparation]
    public let repositoryBaseline: RepositoryBaseline
    public let warnings: [MutationWarning]
}

public struct RecordDiffEntry: Hashable, Sendable {
    public enum Change: Hashable, Sendable { case added, removed, changed }
    public let jsonPointer: String
    public let change: Change
    public let beforeJSON: String?
    public let afterJSON: String?
}

public struct RecordDiff: Hashable, Sendable {
    public let entries: [RecordDiffEntry]
    public let originalCanonicalJSON: String?
    public let editedCanonicalJSON: String?
}

public enum MutationWarning: Hashable, Sendable {
    case spaceAlphaNonAtomicPreflight
    case publicDeleteMayOrphanBlobs
    case spaceDeleteRequiresBackup
}

public struct MutationPartialOutcome: Hashable, Sendable {
    public let preparationID: UUID
    public let scope: RepositoryScope
    public let message: String
    public let safeNextAction: SafeNextAction
    public enum SafeNextAction: Hashable, Sendable { case refetchNow, retryLocalCleanup }
}

public struct MutationConflict: Error, Hashable, Sendable {
    public let original: RecordSnapshot
    public let editedCanonicalJSON: String
    public let currentRemote: RecordSnapshot?
}

public enum MutationError: Error, Hashable, Sendable {
    case foreignRepositoryReadOnly
    case backupRequired(String)
    case invalidPreparation(String)
    case unsupportedSpaceProfile(String)
    case transport(String)
}

public enum AuthorizationScopeError: Error, Hashable, Sendable {
    case invalidAuthorityDID(String)
    case invalidCollection(String)
    case invalidSpaceType(String)
    case invalidSpaceKey(String)
    case nonConcreteMIMEType(String)
}

public enum MutationOutcome: Sendable {
    case verified(RecordSnapshot?)
    case remoteWriteUnverified(MutationPartialOutcome)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

public struct SpaceDeletionWriterBinding: Hashable, Codable, Sendable {
    public let writerDID: String
    public let authorityRevision: String
    public let authorityHashBase64: String
    public let observedRevision: String
    public let observedHashBase64: String
}

public struct SpaceDeletionAuthoritySnapshot: Hashable, Codable, Sendable {
    public let spaceURI: String
    public let accountDID: String
    public let writers: [SpaceDeletionWriterBinding]
    public let fullyPaginated: Bool
    public let observedAt: Date
    public let bindingDigest: String

    public static func validated(
        space: SpaceRef,
        accountDID: String,
        writers: [SpaceDeletionWriterBinding],
        fullyPaginated: Bool,
        observedAt: Date
    ) throws -> Self
}

public struct BackupPreflightEvidence: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case record(locator: RecordLocator, recordCID: String)
        case space(spaceURI: String, authorityBindingDigest: String)
    }
    public let backupID: UUID
    public let subject: Subject
    public let accountDID: String
    public let completedAt: Date
    public let manifestDigest: String
    public let complete: Bool
    public let verified: Bool
}

public protocol BackupPreflightProviding: Sendable {
    func backUpRecordBeforeDeletion(_ snapshot: RecordSnapshot) async throws -> BackupPreflightEvidence
    func backUpSpaceBeforeDeletion(
        space: SpaceRef,
        accountDID: String,
        authoritySnapshot: SpaceDeletionAuthoritySnapshot
    ) async throws -> BackupPreflightEvidence
}

public enum BackupEvidenceValidationError: Error, Hashable, Sendable {
    case subjectMismatch
    case accountMismatch
    case incompleteOrUnverified
    case missingManifestDigest
    case completionInFuture
    case incompleteAuthorityEnumeration
    case invalidWriterObservation(String)
    case backupPredatesAuthoritySnapshot
    case invalidPreparationTime
    case stalePreparation
}

public enum BackupEvidenceValidator {
    public static let maximumSpacePreparationAge: TimeInterval = 300

    public static func validateRecord(
        _ evidence: BackupPreflightEvidence,
        snapshot: RecordSnapshot,
        accountDID: String,
        now: Date
    ) throws {
        guard evidence.subject == .record(
            locator: snapshot.locator, recordCID: snapshot.recordCID
        ) else { throw BackupEvidenceValidationError.subjectMismatch }
        try validateCommon(evidence, accountDID: accountDID, now: now)
    }

    public static func validateSpace(
        _ evidence: BackupPreflightEvidence,
        space: SpaceRef,
        accountDID: String,
        authoritySnapshot: SpaceDeletionAuthoritySnapshot,
        preparedAt: Date,
        now: Date
    ) throws {
        guard authoritySnapshot.spaceURI == space.uriString(),
              authoritySnapshot.accountDID == accountDID,
              authoritySnapshot.fullyPaginated
        else {
            throw BackupEvidenceValidationError.incompleteAuthorityEnumeration
        }
        guard evidence.subject == .space(
            spaceURI: space.uriString(),
            authorityBindingDigest: authoritySnapshot.bindingDigest
        ) else {
            throw BackupEvidenceValidationError.subjectMismatch
        }
        try validateCommon(evidence, accountDID: accountDID, now: now)
        guard evidence.completedAt >= authoritySnapshot.observedAt else {
            throw BackupEvidenceValidationError.backupPredatesAuthoritySnapshot
        }
        guard preparedAt >= evidence.completedAt, preparedAt <= now else {
            throw BackupEvidenceValidationError.invalidPreparationTime
        }
        guard now.timeIntervalSince(preparedAt) <= maximumSpacePreparationAge else {
            throw BackupEvidenceValidationError.stalePreparation
        }
    }

    private static func validateCommon(
        _ evidence: BackupPreflightEvidence,
        accountDID: String,
        now: Date
    ) throws {
        guard evidence.accountDID == accountDID else {
            throw BackupEvidenceValidationError.accountMismatch
        }
        guard evidence.complete, evidence.verified else {
            throw BackupEvidenceValidationError.incompleteOrUnverified
        }
        let digestParts = evidence.manifestDigest.split(
            separator: ":", omittingEmptySubsequences: false
        )
        guard digestParts.count == 2, digestParts[0] == "sha256",
              digestParts[1].count == 64,
              digestParts[1].unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              )
        else {
            throw BackupEvidenceValidationError.missingManifestDigest
        }
        guard evidence.completedAt <= now else {
            throw BackupEvidenceValidationError.completionInFuture
        }
    }
}
```

`SpaceDeletionAuthoritySnapshot.validated` first requires `fullyPaginated == true`, an exact canonical Space URI and valid account/writer DIDs, no duplicate writer DID, nonempty revision fields without control characters, and canonical nonempty RFC 4648 Base64 for both `authorityHashBase64` and `observedHashBase64` (`Data(base64Encoded:)` succeeds and re-encoding is byte-for-byte equal). It stable-sorts writers by DID and encodes a private version-1 Codable tuple containing the Space URI, account DID, and all five writer fields with `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`; `bindingDigest` is `sha256:` plus the lowercase CryptoKit SHA-256 hex of those bytes. The observation timestamp is freshness metadata and is deliberately not part of the content digest. Custom `Decodable` re-enters `validated`, requires the decoded `bindingDigest` to equal the recomputed value, and throws `DecodingError.dataCorrupted` on any mismatch, making the snapshot safe to persist inside Plan 3 transfer payloads. A claimed writer that returns `RepoNotFound`, a non-Space repository version, or any read failure makes snapshot construction fail; an empty writer set is valid only after a terminal fully paginated authority response.

Both validators require the exact qualified subject and account, `complete && verified`, a syntactically valid `sha256:` manifest digest, and `completedAt <= now`. The record validator compares the complete `RecordLocator` and `recordCID`. The Space validator additionally binds that manifest-bearing evidence to the complete authority snapshot digest, requires the backup to finish no earlier than that observation, and rejects a preparation older than five minutes. Production deletion services always invoke their provider themselves and bind the returned evidence to that one preparation/attempt before validating it again at execution.

The production services call these generated APIs exactly:

```swift
client.com.atproto.space.listSpaces(
    input: .init(type: type, did: did, limit: limit, cursor: cursor)
)
client.com.atproto.space.listRepos(
    input: .init(space: space, limit: limit, cursor: cursor)
)
client.com.atproto.space.listRecords(
    input: .init(
        space: space, repo: writerDID, collection: collection,
        limit: limit, cursor: cursor, reverse: reverse,
        excludeValues: excludeValues
    )
)
client.com.atproto.space.getRecord(
    input: .init(space: space, repo: writerDID, collection: collection, rkey: rkey)
)
client.com.atproto.space.getLatestCommit(
    input: .init(space: space, repo: writerDID)
)
client.com.atproto.space.getRepo(
    input: .init(space: space, repo: writerDID, excludeValues: nil)
)
client.com.atproto.simplespace.getSpace(input: .init(space: space))
client.com.atproto.simplespace.listMembers(
    input: .init(space: space, limit: limit, cursor: cursor)
)
```

`getSpace` and `listRepos` are Space-authority-host methods. `StrictSpaceAuthorityHostResolver` uses Plan 1's `DIDDocumentPDSResolver.documentURL(for:allowLocalhostDevelopment:)` with development disabled so the same ATProto-specific `did:plc`/hostname-level `did:web` rules apply and path-form `did:web`, encoded non-local ports, and localhost are rejected before fetch. It then requires a 2xx/non-nil document, `document.id == authorityDID`, exactly one relative `#atproto_space_host` or fully qualified `${authorityDID}#atproto_space_host` service whose type is exactly `AtprotoSpaceHost`, and an origin-only HTTPS endpoint. A missing, duplicate, wrong-ID, wrong-type, insecure, path-prefixed, credential-bearing, query-bearing, or fragment-bearing service fails closed. It never asks Petrel `SpaceHostResolver` for authority routing and never falls back to `#atproto_pds`. This no-fallback rule is an intentional ATProtoDrive hardening policy for the pinned Petrel/Proposal-0016 profile, not a claim that Proposal 0016 forbids PDS fallback.

For a manually opened or foreign Space, construct `/xrpc/com.atproto.simplespace.getSpace` and `/xrpc/com.atproto.space.listRepos` on that validated authority origin and execute both through `SpaceCredentialManager.get(url:space:)`. The connected account's ordinary client is used only when its resolved service URL is the same authority endpoint and the exact-account OAuth path is deliberately selected. Never send either method to whichever connected-account PDS client is handy. The returned writer set is the authority's claim, not proof that the authority serves those repositories.

Each repository remains authoritative at its writer's own PDS. Inject Plan 1's `any DIDDocumentPDSResolving`, call `resolvePDS(for: writerDID)`, require the resolved identity DID to equal `writerDID`, and construct `/xrpc/com.atproto.space/listRecords|getRecord|getLatestCommit|getRepo` on `ResolvedPDSIdentity.pdsURL`. Route foreign-writer calls through `SpaceCredentialManager.get(url:space:)`; never use `SpaceHostResolver` for this stage because it can prefer `#atproto_space_host`. Map the authority response's `Bytes` value only as `repo.hash.data.base64EncodedString()` and keep that canonical `(revision, commitHashBase64)` claim distinct from the writer-PDS signed-commit observation. Report disagreement/failure per writer. `SpaceRepositoryService` owns both routing stages; the account PDS and `PublicRepositoryService` are never fallbacks.

---

### Task 1: Extract Space domain types and implement paged Proposal 0016 reads

**Files:**
- Create: `ATProtoDrive/Spaces/SpaceModels.swift`
- Create: `ATProtoDrive/Spaces/SpaceProtocolCapabilities.swift`
- Create: `ATProtoDrive/Spaces/SpaceAuthorityHostResolver.swift`
- Create: `ATProtoDrive/Spaces/SpaceRepositoryService.swift`
- Create: `ATProtoDrive/Spaces/SpaceBookmarkStore.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Petrel dependency owner only, modify before this task's app red gate: `../Petrel/Sources/Petrel/Auth/Space/SpaceCredentialManager.swift`
- Petrel dependency owner only, test: `../Petrel/Tests/PetrelTests/Auth/SpaceCredentialManagerTests.swift`
- Create: `ATProtoDrive/Accounts/AuthenticationModels.swift`
- Create: `ATProtoDrive/Mutation/MutationModels.swift`
- Modify: `ATProtoDrive/Spaces/SpaceListModel.swift`
- Modify: `ATProtoDrive/Spaces/SpaceDetailModel.swift`
- Modify: `ATProtoDrive/Records/RecordListModel.swift`
- Cross-plan integration owner only: `ATProtoDrive.xcodeproj/project.pbxproj`
- Create: `ATProtoDriveTests/SpaceRepositoryServiceTests.swift`
- Create: `ATProtoDriveTests/SpaceAuthorityHostResolverTests.swift`
- Create: `ATProtoDriveTests/SpaceTestFixtures.swift`
- Create: `ATProtoDriveTests/SpaceBookmarkStoreTests.swift`
- Modify: `ATProtoDriveTests/SpaceListModelTests.swift`
- Modify: `ATProtoDriveTests/SpaceDetailModelTests.swift`
- Modify: `ATProtoDriveTests/WritePipelineTests.swift`

**Interfaces:**
- Consumes: Plan 1 `RepositoryScope`, `RecordLocator`, `RepositoryRecordPage`, `RecordOrigin`, `RecordRow`, `BrowserFailure`, `DIDDocumentFetch`, `DIDDocumentPDSResolver.documentURL(for:allowLocalhostDevelopment:)`, `DIDDocumentPDSResolving`, and `ResolvedPDSIdentity`; Petrel `ATProtoClient`, `DIDDocument`, `SpaceRef`, and `SpaceCredentialManager`. Petrel `SpaceHostResolver` is explicitly not consumed.
- Produces: `SpaceItem`, `SpaceWriterRepository`, `SpaceOverview`, `SpacePage`, `SpaceWriterPage`, `SpaceMemberPage`, `SpaceCollectionInventory`, `SpaceReadCapability`, `SpaceProtocolCapabilities`, strict `SpaceAuthorityHostResolving`, canonical `RecordLocator.spaceRecord`, versioned `SpaceBookmarkStore`, `SpaceRepositoryServing`, live `SpaceRepositoryService`, and the compile-safe fixed `AuthenticationModels`/`RepositoryVersion`/`RecordSnapshot` declarations consumed before Tasks 4 and 5 add behavior.

- [ ] **Step 1: Move, do not duplicate, the existing domain types and land compile-safe shared contracts.** Move `SpaceItem`, `OpenSpaceError`, `RepoEntry` (renamed to `SpaceWriterRepository` with compatibility `typealias RepoEntry = SpaceWriterRepository`), `SpacePolicyOption`, `MemberError`, and `CreateSpaceError` into `SpaceModels.swift`. Create `AuthenticationModels.swift` with the fixed enums and `MutationModels.swift` with `RepositoryVersion`, `RepositoryBaseline`, and `RecordSnapshot` before declaring `SpaceRepositoryServing.record`. Create `SpaceProtocolCapabilities.swift` with the fixed current profile and unsupported-profile states. Add the fixed `RecordLocator.spaceRecord` factory to `SpaceModels.swift`; this is the only constructor used for Space record locators and mappers. Task 4 later adds planner/reconsent behavior and Task 5 adds document/diff behavior; neither redeclares these types. Preserve existing public initializers so the old tests remain green during migration.

```swift
public typealias RepoEntry = SpaceWriterRepository

extension SpaceWriterRepository {
    public init(did: String, rev: String, hash: String) {
        self.init(did: did, revision: rev, commitHashBase64: hash)
    }
    public var rev: String { revision }
    public var hash: String { commitHashBase64 }
}
```

In this same red/green cycle, replace `SpaceListModel`'s static `UserDefaults.standard` helpers with an injected `SpaceBookmarkStore`. The store persists this exact account-qualified envelope and never stores a client, token, credential, record value, or PDS URL:

```swift
public struct SpaceBookmarkEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(accountDID)|\(spaceURI)" }
    public let accountDID: String
    public let spaceURI: String
    public var isBookmarked: Bool
    public var lastOpenedAt: Date
}

private struct SpaceBookmarkEnvelope: Codable, Sendable {
    let version: Int
    var entries: [SpaceBookmarkEntry]
}

public protocol SpaceBookmarkPersisting: Sendable {
    func load() async throws -> Data?
    func writeAtomically(_ data: Data) async throws
}

public protocol LegacyCustomSpaceImporting: Sendable {
    func loadSpaceURIs(accountDID: String) async throws -> [String]
    func removeImportedSpaceURIs(accountDID: String) async throws
}

public actor SpaceBookmarkStore {
    public init(
        persistence: any SpaceBookmarkPersisting,
        legacyImporter: any LegacyCustomSpaceImporting,
        now: @escaping @Sendable () -> Date
    )
    public func restore() async throws
    public func entries(accountDID: String) -> [SpaceBookmarkEntry]
    public func recordOpened(space: SpaceRef, accountDID: String) async throws
    public func setBookmarked(_ bookmarked: Bool, space: SpaceRef, accountDID: String) async throws
    public func remove(spaceURI: String, accountDID: String) async throws
}
```

`FileSpaceBookmarkPersistence.live()` owns `Application Support/ATProtoDrive/SpaceBookmarks-v1.json`, creates only that parent directory, and writes via `Data.write(options: .atomic)`. The actor accepts only envelope version 1, validates every account DID and `SpaceRef`, stable-deduplicates by `(accountDID, canonical Space URI)`, sorts bookmarked entries first then newest open, and caps non-bookmarked recents at 20 per account. `MemorySpaceBookmarkPersistence` is the only default in tests. A corrupt/unknown-version file is moved beside the original as `SpaceBookmarks-v1.invalid-<UUID>.json` before the store publishes an empty visible state; it is never overwritten silently. A one-shot injected `LegacyCustomSpaceImporting` may read the old per-account `UserDefaults` arrays in production, but tests use an empty memory importer; delete a legacy key only after the versioned file has been atomically written.

- [ ] **Step 2: Add shared Space fixtures and write failing service, locator, resolver, and persistence tests.** Cover paging, 2xx/nil rejection, authority-host writer discovery, writer-PDS record routing, exact canonical Space record mapping, strict authority DID validation, and atomic account-qualified bookmark/recents restore. `SpaceTestFixtures.swift` is the only owner of `.fixtureSpace`, `.fixtureSpaceRef`, `.fixtureOwned`, and `ScriptedSpaceService`; later tests extend that file rather than inventing subtly different IDs. Use an injected `SpaceRepositoryOperations` value whose closures return generated Petrel outputs; assert the service keeps opaque cursors stable and constructs `RecordRow.origin == .space(space:repoDID:)`. Before Step 4, hand the exact Task 1 manifest listed in Step 6 to the cross-plan integration owner and confirm its app/test source-phase membership.

```swift
extension SpaceRef {
    static var fixtureSpaceRef: Self {
        try! Self(uriString: "at://did:plc:owner/space/app.example.drive/main")
    }
}

extension RepositoryScope {
    static let fixtureSpace = Self.permissionedSpace(
        spaceURI: SpaceRef.fixtureSpaceRef.uriString(),
        writerDID: "did:plc:alice",
        accountDID: "did:plc:alice"
    )
}

extension SpaceItem {
    static var fixtureOwned: Self {
        .init(ref: .fixtureSpaceRef, accountDID: "did:plc:owner")
    }
}

extension RecordRow {
    static var fixtureOwned: Self {
        let uri = try! SpaceRef.fixtureSpaceRef.recordURI(
            authorDID: "did:plc:alice",
            collection: "app.example.note",
            recordKey: "one"
        ).uriString()
        return .init(
            uri: uri,
            collection: "app.example.note", rkey: "one",
            cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
            json: #"{"$type":"app.example.note","text":"fixture"}"#,
            origin: .space(space: .fixtureSpaceRef, repoDID: "did:plc:alice")
        )
    }
}

extension ComAtprotoSimplespaceGetSpace.Output {
    static var fixturePublicAccess: Self {
        .init(
            uri: .fixtureSpaceRef,
            policy: .comAtprotoSimplespaceDefsPublicPolicy(.init()),
            appAccess: .comAtprotoSimplespaceDefsOpen(.init())
        )
    }
}
```

```swift
@Test("Space RecordLocator uses the complete canonical wire URI")
func canonicalSpaceRecordLocator() throws {
    let space = SpaceRef.fixtureSpaceRef
    let expected = "at://did:plc:owner/space/app.example.drive/main/did:plc:alice/app.example.note/one"
    let locator = try RecordLocator.spaceRecord(
        space: space,
        authorDID: "did:plc:alice",
        accountDID: "did:plc:viewer",
        collection: "app.example.note",
        recordKey: "one",
        cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
        wireURI: expected
    )
    #expect(locator.uri == expected)
    #expect(locator.collection == "app.example.note")
    #expect(locator.rkey == "one")
    #expect(locator.scope == .permissionedSpace(
        spaceURI: space.uriString(),
        writerDID: "did:plc:alice",
        accountDID: "did:plc:viewer"
    ))
}

@Test("Space RecordLocator rejects malformed components and a mismatched wire URI")
func invalidSpaceRecordLocatorFailsClosed() throws {
    let valid = "at://did:plc:owner/space/app.example.drive/main/did:plc:alice/app.example.note/one"
    for input in [
        ("not-a-did", "did:plc:viewer", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", valid),
        ("did:plc:alice", "not-a-did", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", valid),
        ("did:plc:alice", "did:plc:viewer", "not-an-nsid", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", valid),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "bad/key", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", valid),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "one", "not-a-cid", valid),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", "at://did:plc:alice/app.example.note/one"),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", "at://did:plc:other/space/app.example.drive/main/did:plc:alice/app.example.note/one"),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", "at://did:plc:owner/space/app.example.drive/main/did:plc:bob/app.example.note/one"),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", "at://did:plc:owner/space/app.example.drive/main/did:plc:alice/app.example.other/one"),
        ("did:plc:alice", "did:plc:viewer", "app.example.note", "one", "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", "at://did:plc:owner/space/app.example.drive/main/did:plc:alice/app.example.note/two")
    ] {
        #expect(throws: SpaceRecordLocatorError.self) {
            _ = try RecordLocator.spaceRecord(
                space: .fixtureSpaceRef,
                authorDID: input.0,
                accountDID: input.1,
                collection: input.2,
                recordKey: input.3,
                cid: input.4,
                wireURI: input.5
            )
        }
    }
}
```

Add resolver argument-table tests using `StrictSpaceAuthorityHostResolver(fetchDocument:)`. The accepted row is a 299 response whose document `id` is the requested DID and whose sole service is `id: "#atproto_space_host"`, `type: "AtprotoSpaceHost"`, `serviceEndpoint: "https://SPACE.example:443/"`; assert the returned URL is exactly `https://space.example`. Rejected rows cover 199/300, 2xx nil body, malformed JSON, wrong document ID, a relative or fully qualified service ID for a different DID, wrong service type, duplicate matching services, missing dedicated service with a valid `#atproto_pds`, HTTP/localhost, user information, non-root path, query, and fragment. URL-spy rows assert `did:plc:4hqjfn7m6n5hno3doamuhgef` fetches `https://plc.directory/did:plc:4hqjfn7m6n5hno3doamuhgef`, hostname `did:web:identity.example` fetches `https://identity.example/.well-known/did.json`, and path-form `did:web:identity.example:users:alice` fails before the fetch closure. Every rejected row records zero credential, account-PDS, and public-service calls; a DID document containing only a valid PDS proves there is no authority fallback.

`SpaceBookmarkStoreTests` use `MemorySpaceBookmarkPersistence` and one `FileSpaceBookmarkPersistence` rooted in `FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)`. Pin account-qualified identity for the same Space under Alice and Bob, bookmark/recency order, a 20-recents-per-account cap, deduplication after reopen, version-1 round-trip, unknown-version/corrupt quarantine, failed atomic replacement preserving the previous decodable envelope, and a successful retry. Migrate every `SpaceListModelTests`, `SpaceDetailModelTests`, and `WritePipelineTests` constructor/helper to an injected memory store/importer; after this task, `rg -n "UserDefaults\\.standard|customSpacesKey" ATProtoDriveTests/SpaceListModelTests.swift ATProtoDriveTests/SpaceDetailModelTests.swift ATProtoDriveTests/WritePipelineTests.swift` must return no matches.

The Petrel dependency test adds a `SpaceAuthorityHostProvider` spy and proves credential exchange asks it for exactly `space.spaceDID`, posts only to `<returned-origin>/xrpc/com.atproto.space.getSpaceCredential`, and never invokes the compatibility `SpaceHostResolver`. A provider failure records zero delegation-token and exchange requests. A valid PDS fallback fixture with no dedicated Space host is rejected by ATProtoDrive's strict provider before either request.

```swift
@Suite("Space repository service")
struct SpaceRepositoryServiceTests {
    @Test("foreign writer records use the credential-routed operation")
    func foreignWriterRouting() async throws {
        let space = try SpaceRef(
            uriString: "at://did:plc:owner/space/app.example.drive/main"
        )
        let scope = RepositoryScope.permissionedSpace(
            spaceURI: space.uriString(),
            writerDID: "did:plc:bob",
            accountDID: "did:plc:alice"
        )
        let calls = SpaceOperationRecorder()
        let service = SpaceRepositoryService(
            accountDID: "did:plc:alice",
            operations: .fixture(
                credentialListRecords: { requestedSpace, writer, collection, cursor, _, _, _ in
                    await calls.record(space: requestedSpace, writer: writer, cursor: cursor)
                    return .init(cursor: nil, records: [])
                }
            )
        )

        _ = try await service.listRecords(
            scope: scope, collection: nil, cursor: "opaque%2Bcursor",
            limit: 100, reverse: false, excludeValues: false
        )

        #expect(await calls.writerDIDs == ["did:plc:bob"])
        #expect(await calls.cursors == ["opaque%2Bcursor"])
        #expect(await calls.publicCallCount == 0)
    }

    @Test("successful status without decoded output is a decode failure")
    func successfulNilOutputFails() async {
        let service = SpaceRepositoryService(
            accountDID: "did:plc:alice",
            operations: .fixture(listSpaces: { _, _, _, _ in (200, nil) })
        )
        await #expect(throws: BrowserFailure.self) {
            try await service.listSpaces(cursor: nil, limit: 100)
        }
    }

    @Test("getSpace and listRepos target the authority Space host")
    func writerDiscoveryUsesAuthorityHost() async throws {
        let calls = SpaceOperationRecorder()
        let service = SpaceRepositoryService(
            accountDID: "did:plc:alice",
            operations: .fixture(
                resolveAuthorityHost: { _ in URL(string: "https://space.owner.example")! },
                credentialGetSpace: { url, _ in
                    await calls.recordAuthorityURL(url, cursor: nil)
                    return .fixturePublicAccess
                },
                credentialListRepos: { url, _, cursor, _ in
                    await calls.recordAuthorityURL(url, cursor: cursor)
                    return .init(cursor: nil, repos: [])
                }
            )
        )

        _ = try await service.overview(space: .fixtureSpaceRef)
        _ = try await service.listWriters(
            space: .fixtureSpaceRef, cursor: "next+opaque", limit: 100
        )

        #expect(await calls.authorityHosts == [
            "space.owner.example", "space.owner.example"
        ])
        #expect(await calls.authorityPaths == [
            "/xrpc/com.atproto.simplespace.getSpace",
            "/xrpc/com.atproto.space.listRepos"
        ])
        #expect(await calls.cursors == [nil, "next+opaque"])
        #expect(await calls.accountPDSListReposCount == 0)
    }

    @Test("every Space endpoint uses its exact host, path, and query")
    func exactEndpointRouting() async throws {
        let recorder = CredentialURLRecorder()
        let authorityResolver = RecordingSpaceAuthorityHostResolver(
            resolvedURL: URL(string: "https://space.owner.example")!
        )
        let writerResolver = RecordingDIDDocumentPDSResolver(
            identities: ["did:plc:bob": .init(
                did: "did:plc:bob",
                pdsURL: URL(string: "https://pds.writer.example")!,
                declaredHandle: nil
            )]
        )
        let router = SpaceRepositoryHTTPRouter.fixture(
            authorityResolver: authorityResolver,
            writerPDSResolver: writerResolver,
            accountPDS: URL(string: "https://pds.account.example")!,
            recorder: recorder
        )
        let space = SpaceRef.fixtureSpaceRef

        try await router.getSpace(space: space)
        try await router.listRepos(space: space, limit: 50, cursor: "repos+2")
        try await router.listRecords(
            space: space, repo: "did:plc:bob", collection: "app.example.note",
            limit: 25, cursor: "records+2", reverse: true, excludeValues: true
        )
        try await router.getRecord(
            space: space, repo: "did:plc:bob",
            collection: "app.example.note", rkey: "three"
        )
        try await router.getLatestCommit(space: space, repo: "did:plc:bob")
        try await router.getRepo(
            space: space, repo: "did:plc:bob", excludeValues: false
        )

        #expect(await recorder.observations == [
            .init(host: "space.owner.example", path: "/xrpc/com.atproto.simplespace.getSpace",
                  query: ["space": space.uriString()]),
            .init(host: "space.owner.example", path: "/xrpc/com.atproto.space.listRepos",
                  query: ["space": space.uriString(), "limit": "50", "cursor": "repos+2"]),
            .init(host: "pds.writer.example", path: "/xrpc/com.atproto.space.listRecords",
                  query: ["space": space.uriString(), "repo": "did:plc:bob",
                          "collection": "app.example.note", "limit": "25",
                          "cursor": "records+2", "reverse": "true", "excludeValues": "true"]),
            .init(host: "pds.writer.example", path: "/xrpc/com.atproto.space.getRecord",
                  query: ["space": space.uriString(), "repo": "did:plc:bob",
                          "collection": "app.example.note", "rkey": "three"]),
            .init(host: "pds.writer.example", path: "/xrpc/com.atproto.space.getLatestCommit",
                  query: ["space": space.uriString(), "repo": "did:plc:bob"]),
            .init(host: "pds.writer.example", path: "/xrpc/com.atproto.space.getRepo",
                  query: ["space": space.uriString(), "repo": "did:plc:bob",
                          "excludeValues": "false"])
        ])
        #expect(await authorityResolver.requestedDIDs == [
            "did:plc:owner", "did:plc:owner"
        ])
        #expect(await writerResolver.requestedDIDs == [
            "did:plc:bob", "did:plc:bob", "did:plc:bob", "did:plc:bob"
        ])
        #expect(await recorder.observations.allSatisfy { $0.host != "pds.account.example" })
        #expect(await recorder.publicFallbackCount == 0)
    }
}
```

`CredentialURLRecorder` stores both `URL.percentEncodedQuery` and the parsed one-value query map. Its initializer rejects duplicate query names, and each assertion above additionally compares the parsed map so an opaque `+` remains `+` instead of being converted to a space. `SpaceRepositoryHTTPRouter.fixture` uses the same URL builder and `SpaceCredentialManager.get` closure as the live factory; it is not a separate test-only routing implementation. Add a mismatch case where the writer resolver returns identity DID `did:plc:mallory` for requested `did:plc:bob`; expect an identity error and zero credential/public/account-PDS calls.

- [ ] **Step 3: Land the narrow Petrel credential-host injection before compiling ATProtoDrive.** In `SpaceCredentialManager`, add `public typealias SpaceAuthorityHostProvider = @Sendable (String) async throws -> URL`, store that closure instead of a concrete resolver, and add this designated initializer while retaining the existing `resolver:` initializer only as compatibility sugar for other Petrel clients:

```swift
public init(
    client: ATProtoClient,
    authorityHostProvider: @escaping SpaceAuthorityHostProvider,
    urlSession: URLSession = .shared,
    delegationTokenProvider: DelegationTokenProvider? = nil
)
```

The compatibility initializer delegates with `{ did in try await resolver.resolve(authorityDID: did).spaceHost }`; `exchangeCredential(for:)` calls only `authorityHostProvider(space.spaceDID)` and appends the credential endpoint to that returned origin. Add the Petrel tests described in Step 2, first run `cd ../Petrel && swift test --filter SpaceCredentialManagerTests` to observe the missing-initializer failure, then have the Petrel dependency owner implement the seam and rerun the same command to PASS. In the Petrel repository, seal that dependency with `jj describe -m "auth: inject Space authority host provider"` followed immediately by `jj new`; record the resulting parent revision in Task 1 evidence before continuing. Do not attempt to include the separate Petrel repository in ATProtoDrive's Task 1 `jj describe`. In ATProtoDrive, every `AccountStore` construction/restoration path creates `StrictSpaceAuthorityHostResolver` and passes its `resolveAuthorityHost(for:)` closure to this initializer. No production ATProtoDrive call site uses the compatibility `resolver:` initializer.

- [ ] **Step 4: Run the focused app tests and verify the intended failure.**

Run:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-spaces-task1-red.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceAuthorityHostResolverTests -only-testing:ATProtoDriveTests/SpaceRepositoryServiceTests -only-testing:ATProtoDriveTests/SpaceBookmarkStoreTests
```

Expected: FAIL because `SpaceRepositoryService`, strict authority resolution, the qualified record mapper, and `SpaceBookmarkStore` do not exist.

- [ ] **Step 5: Implement the Space-only service, strict authority resolution, distinct writer routing, capabilities, and the live operation factory.** Normalize every generated tuple through one helper and preserve opaque cursors. `StrictSpaceAuthorityHostResolver` is the only authority resolver for `getSpace`/`listRepos`; it uses Plan 1's DID document fetch/URL rules and never wraps Petrel `SpaceHostResolver`. Pass the same strict resolver behavior to every account's `SpaceCredentialManager.authorityHostProvider`, so credential exchange cannot independently fall back through Petrel's compatibility resolver. The injected Plan 1 `DIDDocumentPDSResolving` resolves the writer `#atproto_pds` for all repository methods, including the connected account's writer. The ordinary account client may execute an own-writer call only after its configured base URL equals that resolved writer PDS; otherwise use the explicit URL route. No mismatch falls back to the account PDS or public service.

```swift
private func requiredOutput<T: Sendable>(
    status: Int,
    output: T?,
    endpoint: String
) throws -> T {
    guard (200...299).contains(status) else {
        throw BrowserFailure.http(endpoint: endpoint, statusCode: status)
    }
    guard let output else {
        throw BrowserFailure.decodeFailure(endpoint: endpoint, statusCode: status)
    }
    return output
}

public func listRecords(
    scope: RepositoryScope,
    collection: String?,
    cursor: String?,
    limit: Int,
    reverse: Bool,
    excludeValues: Bool
) async throws -> RepositoryRecordPage {
    guard case let .permissionedSpace(spaceURI, writerDID, scopedAccountDID) = scope,
          scopedAccountDID == accountDID
    else { throw BrowserFailure.unsupported("Space service received a public or differently scoped repository") }
    let space = try SpaceRef(uriString: spaceURI)
    let output = try await operations.listRecords(
        space, writerDID, collection, cursor, limit, reverse, excludeValues,
        writerDID != accountDID
    )
    return RepositoryRecordPage(
        records: try output.records.map {
            try RecordRow(
                spaceRecord: $0,
                space: space,
                authorDID: writerDID,
                accountDID: accountDID
            )
        },
        cursor: output.cursor
    )
}
```

The throwing list mapper takes the generated list record's typed collection, rkey, and CID (that output has no URI), calls `RecordLocator.spaceRecord(..., wireURI: nil)`, and copies the derived canonical locator fields into the row. The `getRecord` mapper passes the output's supplied `uri.uriString()` as `wireURI` and therefore rejects a public-form URI or a URI naming another Space/writer/collection/key. Both paths reject an invalid CID or malformed component before returning a row. `record(locator:)` also reconstructs `space.recordURI(authorDID:collection:recordKey:)` and requires its string to equal `locator.uri` before issuing `getRecord`; do not use Petrel `ATProtocolURI` equality here because it does not compare every Space path component. Callers cannot smuggle a public or differently scoped URI alongside valid query parameters.

Implement `repositoryBaseline(scope:)` by calling writer-PDS `com.atproto.space.getLatestCommit`. A declared `RepoNotFound` maps to `.absent`; a success maps the signed commit to `.version(.spaceSignedCommit(revision: output.commit.rev.description, hashBase64: output.commit.hash.data.base64EncodedString()))`; every other error remains an error. Do not derive a version from the authority's `listRepos` claim or a CAR filename. `record(locator:)` obtains both the exact record and this signed version, so its `RecordSnapshot.repositoryVersion` is always `.spaceSignedCommit`.

`SpaceProtocolCapabilityStore` starts with `.currentPetrelAlpha` for the checked-in generated profile and keys learned state by exact account DID, canonical Space URI when known, and resolved service host (authority host or writer PDS). A declared `MethodNotFound`/method-specific unsupported response records only that `SpaceProtocolMethod`; a generic record/Space 404 does not. An unknown profile publishes `.unsupported(identifier:)`. Callers then disable the affected action and show a typed warning. They do not try a public endpoint, a legacy endpoint, or a different Space write method. Tests cover aggregate-list unsupported CAR fallback, writer-host-specific `applyWrites` unsupported disabling batch, and an entirely unsupported profile leaving read-only metadata visible.

- [ ] **Step 6: Verify the integration-owner handoff, then run focused plus migrated tests.** The exact new-file manifest already handed off before Step 4 is `Spaces/SpaceModels.swift`, `Spaces/SpaceProtocolCapabilities.swift`, `Spaces/SpaceAuthorityHostResolver.swift`, `Spaces/SpaceRepositoryService.swift`, `Spaces/SpaceBookmarkStore.swift`, `Accounts/AuthenticationModels.swift`, `Mutation/MutationModels.swift`, `SpaceAuthorityHostResolverTests.swift`, `SpaceRepositoryServiceTests.swift`, `SpaceBookmarkStoreTests.swift`, and `SpaceTestFixtures.swift`; the four modified legacy source files and three modified legacy test files were already members. Only the index-designated integration owner edits target membership. Do not create future-task stubs. Confirm every handed-off file appears in the correct source phase before running the gate.

Run:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-spaces-task1-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceAuthorityHostResolverTests -only-testing:ATProtoDriveTests/SpaceRepositoryServiceTests -only-testing:ATProtoDriveTests/SpaceBookmarkStoreTests -only-testing:ATProtoDriveTests/SpaceListModelTests -only-testing:ATProtoDriveTests/SpaceDetailModelTests
```

Expected: PASS; existing Space domain tests compile through the migration alias, no public operation is called by a permissioned scope, and every included test uses memory or UUID-scoped temporary persistence. `AccountStoreTests` remains deliberately excluded until Task 4 injects its preference suite and gates live OAuth.

- [ ] **Step 7: Seal the task in jj and immediately open the next change.**

```bash
jj status
jj diff --summary
jj describe -m "refactor: isolate Space repository reads"
jj new
```

---

### Task 2: Derive collections and fully paginate whole-Space writer repositories

**Files:**
- Modify: `ATProtoDrive/Spaces/SpaceRepositoryService.swift`
- Create: `ATProtoDrive/Spaces/SpaceRepositoryStore.swift`
- Modify: `ATProtoDrive/Verify/RepoVerifier.swift`
- Modify: `ATProtoDriveTests/SpaceRepositoryServiceTests.swift`
- Create: `ATProtoDriveTests/SpaceRepositoryStoreTests.swift`
- Modify: `ATProtoDriveTests/SpaceTestFixtures.swift`
- Modify: `ATProtoDriveTests/RepoVerifierTests.swift`

**Interfaces:**
- Consumes: Task 1 `SpaceRepositoryServing`, `SpaceProtocolCapabilities`, and compile-safe `AccessContext.spaceRead`; Plan 1 `LoadState`, `BrowserFailure`, `RepositoryScope`, `RepositoryRecordPage`; existing verified SwanSpaces CAR pipeline.
- Produces: `SpaceRepositoryStore`, complete writer pagination, collection discovery with `.pagedRecords` or `.verifiedCAR`, stable deduplication, and explicit My Records fallback.

- [ ] **Step 1: Write failing tests for the conditions that an eager one-page loader misses.** Cover an empty record page with a cursor, a repeated cursor, duplicate URI/CID rows, a second writer page, collection derivation with unknown NSIDs, and failure of whole-Space discovery while My Records remains usable.

```swift
@MainActor
@Test("collection scan follows empty pages and terminates a repeated cursor")
func collectionScanIsCompleteAndCycleSafe() async throws {
    let service = ScriptedSpaceService(recordPages: [
        nil: .init(records: [], cursor: "two"),
        "two": .init(records: [
            .fixture(
                uri: try! SpaceRef.fixtureSpaceRef.recordURI(
                    authorDID: "did:plc:alice",
                    collection: "app.example.alpha",
                    recordKey: "one"
                ).uriString(),
                collection: "app.example.alpha",
                rkey: "one",
                cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
            ),
            .fixture(
                uri: try! SpaceRef.fixtureSpaceRef.recordURI(
                    authorDID: "did:plc:alice",
                    collection: "app.example.beta",
                    recordKey: "two"
                ).uriString(),
                collection: "app.example.beta",
                rkey: "two",
                cid: "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
            )
        ], cursor: "two")
    ])
    let store = SpaceRepositoryStore(service: service)

    await store.loadCollections(scope: .fixtureSpace)

    #expect(store.collectionInventory?.collections == [
        "app.example.alpha", "app.example.beta"
    ])
    #expect(store.collectionInventory?.isComplete == false)
    #expect(await service.requestedRecordCursors == [nil, "two"])
}

@MainActor
@Test("whole Space failure preserves My Records")
func wholeSpaceFailureFallsBack() async {
    let store = SpaceRepositoryStore(service: ScriptedSpaceService(
        writerFailure: .authorizationRefused,
        ownPage: .init(records: [.fixtureOwned], cursor: nil)
    ))
    await store.load(space: .fixtureSpaceRef, accountDID: "did:plc:alice")
    let snapshot = try! #require(store.loadState.snapshot)
    guard case let .myRecordsOnly(reason) = snapshot.readCapability else {
        Issue.record("Expected My Records fallback")
        return
    }
    #expect(!reason.isEmpty)
    #expect(snapshot.recordsByWriter["did:plc:alice"]?.count == 1)
}
```

A repeated cursor is cycle-safe but not a complete enumeration: preserve the rows already received, set `isComplete == false`, and surface a typed warning. Only a terminal nil/empty cursor after all pages may set `isComplete == true` or enable Whole Space.

- [ ] **Step 2: Run the store suite to confirm failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceRepositoryStoreTests
```

Expected: FAIL because the store, scan state, and cycle-safe pagination do not exist.

- [ ] **Step 3: Implement first-page plus append pagination and last-snapshot retention.** The store uses a request identity containing account DID, Space URI, writer DID, collection, reverse flag, and search/filter state. Ignore completions whose identity no longer matches the active request.

```swift
private enum SpacePagePosition: Equatable, Sendable {
    case notStarted
    case next(String)
    case finished

    var cursor: String? {
        if case let .next(value) = self { return value }
        return nil
    }
}

private struct SpaceRecordPageKey: Hashable, Sendable {
    let scope: RepositoryScope
    let collection: String?
    let reverse: Bool
    let excludeValues: Bool
}

@MainActor @Observable
public final class SpaceRepositoryStore {
    public private(set) var loadState: LoadState<SpaceRepositorySnapshot> = .idle
    private var recordPositions: [SpaceRecordPageKey: SpacePagePosition] = [:]

    public func appendRecords(scope: RepositoryScope, collection: String?) async {
        guard case let .permissionedSpace(_, writerDID, _) = scope else {
            let previous = loadState.snapshot
            loadState = .failed(
                previous: previous,
                failure: .unsupported("Space store received a public repository scope")
            )
            return
        }
        let key = SpaceRecordPageKey(
            scope: scope, collection: collection,
            reverse: false, excludeValues: false
        )
        let position = recordPositions[key] ?? .notStarted
        guard position != .finished, let previous = loadState.snapshot else { return }
        loadState = .loading(previous: previous)
        do {
            let page = try await service.listRecords(
                scope: scope, collection: collection, cursor: position.cursor,
                limit: 100, reverse: false, excludeValues: false
            )
            var updated = previous
            updated.recordsByWriter[writerDID] = deduplicated(
                (previous.recordsByWriter[writerDID] ?? []) + page.records
            )
            recordPositions[key] = nextPosition(
                page.cursor, after: position.cursor
            )
            loadState = .loaded(updated)
        } catch let failure as BrowserFailure {
            loadState = .failed(previous: previous, failure: failure)
        } catch {
            loadState = .failed(
                previous: previous,
                failure: .transport(error.localizedDescription)
            )
        }
    }
}
```

The store mutates only a local copy and publishes a new value; it never mutates a prior snapshot after publishing it.

- [ ] **Step 4: Implement collection derivation without inventing `listCollections`.** Ask Task 1's `SpaceProtocolCapabilityProviding` for the exact account/Space/writer-PDS capability snapshot. When `supportsAggregateRecordListing` is true, paginate `listRecords(collection:nil, excludeValues:true)`. When that one capability is explicitly unsupported and `.getRepo` is supported, fetch writer-PDS `getRepo`, verify the CAR with the writer's signing key, and collect the collection prefix from each verified DRISL path. An unknown/unsupported profile or missing `getRepo` capability does not guess: it returns a typed incomplete inventory and disables the action. Do not parse unverified paths.

```swift
public func collections(scope: RepositoryScope) async throws -> SpaceCollectionInventory {
    do {
        return try await collectionsFromRecordPages(scope: scope)
    } catch let failure as BrowserFailure {
        guard case .unsupported = failure else { throw failure }
        let verified = try await operations.verifiedCARIndex(scope)
        var seen = Set<String>()
        let stableCollections = verified.paths.compactMap { path -> String? in
            guard let first = path.split(separator: "/", maxSplits: 1).first else {
                return nil
            }
            let collection = String(first)
            return seen.insert(collection).inserted ? collection : nil
        }
        return SpaceCollectionInventory(
            collections: stableCollections.sorted(),
            recordsScanned: verified.paths.count,
            isComplete: true,
            source: .verifiedCAR
        )
    }
}
```

- [ ] **Step 5: Fully paginate the authority-claimed writer set before Whole Space is marked available.** The first `listRepos` page and every continuation use the authority's resolved Space host and `SpaceCredentialManager`, as asserted by Task 1's spy. Resolve each returned writer DID through `DIDDocumentPDSResolving` at read time. Convert each required Petrel `Bytes` hash to canonical RFC 4648 Base64 exactly once as `repo.hash.data.base64EncodedString()`, and keep the authority claim (`revision`, `commitHashBase64`) separate from each writer PDS's signed-commit observation; a missing writer yields a visible per-writer failure rather than silently shrinking the set. A repeated writer cursor or failed page leaves `readCapability == .myRecordsOnly(reason:)`, not `.wholeSpace`.

The baseline OAuth grant can load the connected account's own writer repo and `listSpaces` through `action=read_self`. To keep this task compile-safe before Task 4, initialize the store with `wholeSpaceAuthorization: @Sendable (String, SpaceRef) async -> Bool`, whose production default returns `false`. Before credential exchange or `listRepos`, query it for the exact account DID and Space and require the already-declared `.spaceRead(space:)` contextual access. If absent, publish **My Records only — Whole Space access has not been granted** and offer **Request Whole Space Access**; never try credential exchange under the baseline. Task 4 replaces only this injected closure with `AccountStore` scope evaluation/reconsent and does not alter Task 2's pagination types.

- [ ] **Step 6: Run service, store, and CAR verification suites.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceRepositoryServiceTests -only-testing:ATProtoDriveTests/SpaceRepositoryStoreTests -only-testing:ATProtoDriveTests/RepoVerifierTests
```

Expected: PASS, including repeated-cursor termination and verified-CAR fallback.

- [ ] **Step 7: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: paginate Space writers and collections"
jj new
```

---

### Task 3: Put Spaces in the Finder-like content pane

**Files:**
- Create: `ATProtoDrive/Spaces/SpaceBrowserView.swift`
- Create: `ATProtoDrive/Spaces/SpaceRecordTableView.swift`
- Create: `ATProtoDrive/Spaces/OpenSpaceCoordinator.swift`
- Create: `ATProtoDrive/Spaces/OpenSpaceView.swift`
- Modify after Plan 1 seals: `ATProtoDrive/Domain/ResourceReference.swift`
- Modify after Plan 1 seals: `ATProtoDrive/Browser/BrowserSession.swift`
- Modify: `ATProtoDrive/Browser/BrowserModels.swift`
- Cross-plan integration owner only: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Modify: `ATProtoDrive/Spaces/SpaceDetailView.swift`
- Modify: `ATProtoDrive/Records/RecordTableView.swift`
- Modify to an inert compatibility wrapper: `ATProtoDrive/Write/OpenSpaceSheet.swift`
- Modify: `ATProtoDriveTests/BrowserDomainTests.swift`
- Modify: `ATProtoDriveTests/SpaceRepositoryStoreTests.swift`
- Create: `ATProtoDriveTests/OpenSpaceCoordinatorTests.swift`
- Modify: `ATProtoDriveTests/SpaceBookmarkStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 `SpaceBookmarkStore`; Task 2 `SpaceRepositoryStore`; Plan 1's already-declared `ResourceReference`, `BrowserSession`, `BrowserPath`, `BrowserItem`, `BrowserSource.global(.openSpace)`, and shell toolbar/search/inspector primitives.
- Produces: the one new account-qualified `ResourceReference.space(accountDID:spaceURI:)` case in Plan 1's declaration, extended window-local Space selection/routing, `OpenSpaceCoordinator`, global **Open Space by URI** account choice, a center-pane Space browser, writer/collection breadcrumbs, sortable Space record table, stable selection, explicit Load More, and inspector projections. It produces no mutation transport.

- [ ] **Step 1: Add failing account-qualified path, selection, open, and action-eligibility tests.** Keep view decisions in a testable `SpaceBrowserProjection` rather than inspecting SwiftUI internals. Add these tests to Plan 1's existing `BrowserDomainTests` instead of creating a parallel browser-session suite:

```swift
@MainActor
@Test("Space overview identity and selection are account qualified")
func spaceOverviewSelectionIsAccountQualified() throws {
    let uri = "at://did:plc:owner/space/app.example.drive/main"
    let alice = ResourceReference.space(accountDID: "did:plc:alice", spaceURI: uri)
    let bob = ResourceReference.space(accountDID: "did:plc:bob", spaceURI: uri)
    #expect(alice.stableID != bob.stableID)

    let session = BrowserSession()
    let source = BrowserSource.account(did: "did:plc:alice", destination: .spaces)
    session.selectSource(source)
    session.navigate(to: BrowserPath(source: source, components: [alice]))
    #expect(session.replaceSelection(with: [alice]))
    #expect(session.primarySelection == alice)

    let priorIDs = session.selectedItemIDs
    #expect(session.replaceSelection(with: [bob]) == false)
    #expect(session.selectedItemIDs == priorIDs)
    #expect(session.primarySelection == alice)

    session.selectSource(.account(did: "did:plc:bob", destination: .spaces))
    #expect(session.path == nil)
    #expect(session.selectedReferences.isEmpty)
}

@Test("foreign writer selection remains read only")
func foreignWriterProjection() throws {
    let scope = RepositoryScope.permissionedSpace(
        spaceURI: "at://did:plc:owner/space/app.example.drive/main",
        writerDID: "did:plc:bob",
        accountDID: "did:plc:alice"
    )
    let projection = SpaceBrowserProjection(
        accountDID: "did:plc:alice",
        path: BrowserPath(
            source: .account(did: "did:plc:alice", destination: .spaces),
            components: [
                .space(
                    accountDID: "did:plc:alice",
                    spaceURI: "at://did:plc:owner/space/app.example.drive/main"
                ),
                .repository(scope),
                .collection(scope: scope, collection: "app.example.note")
            ]
        )
    )
    #expect(projection.canCreateRecord == false)
    #expect(projection.canEditRecord == false)
    #expect(projection.breadcrumbs.map(\.title) == [
        "Spaces — Experimental", "main", "did:plc:bob", "app.example.note"
    ])
}
```

Do **not** redeclare `ResourceReference` in `BrowserModels.swift`, `SpaceModels.swift`, or a new file. Edit Plan 1's declaration in `ATProtoDrive/Domain/ResourceReference.swift` by inserting exactly this case and arm into the existing enum/switch:

```swift
case space(accountDID: String, spaceURI: String)

// Existing stableID switch:
case let .space(accountDID, spaceURI):
    "space|\(accountDID)|\(spaceURI)"
```

`BrowserPath` remains Plan 1's struct with `source` plus `components`; do not add parallel `.spaceOverview` or `.spaceRecords` path cases. A pure `SpaceBrowserDestination.init(path:)` interprets zero components as root, `.space` as overview, and `.space` + `.repository` + optional `.collection` as records. Reject a path whose source account does not match the account DID carried in `.space` and every `RepositoryScope`. Update Plan 1's existing exhaustive `ResourceReference` stable-ID, path-scope, selection-eligibility, pruning, and inspector switches in place. For a `.space` selection, `BrowserSession.replaceSelection` accepts it only when the current source is `.account(did: sameAccount, destination: .spaces)` and the path's first component is that exact `.space`; repository/collection/record/blob selection continues to require its complete matching scope. `rg -n "switch .*ResourceReference|case \\.repository|case \\.collection|case \\.record|case \\.blob" ATProtoDrive/Domain ATProtoDrive/Browser` is the exhaustive-switch audit; every production switch is reviewed for `.space` before the gate.

Add coordinator tests with two connected accounts and the same URI. A call without account DID returns `.accountChoiceRequired([alice, bob])` and makes zero network/persistence calls. Choosing Bob resolves only Bob's service; choosing Alice resolves only Alice's. Malformed URI/account DID, an unconnected DID, and failed overview make zero durable writes. A successful overview performs exactly `overview -> atomic write`, returns an account-qualified reference, deduplicates a repeated open, and survives store reinitialization. A simulated atomic-write failure returns an error and does not navigate. No test or production path reads `activeAccount` or chooses the first account when two are present.

- [ ] **Step 2: Run the focused test and verify failure.**

Run:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-spaces-task3-red.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/BrowserDomainTests -only-testing:ATProtoDriveTests/OpenSpaceCoordinatorTests -only-testing:ATProtoDriveTests/SpaceBookmarkStoreTests -only-testing:ATProtoDriveTests/SpaceRepositoryStoreTests
```

Expected: FAIL because the follow-on Space case/session validation, open coordinator, global route projection, and browser projection do not exist.

- [ ] **Step 3: Extend Plan 1's owned resource and session files, then implement account-qualified opening.** Modify `ResourceReference.swift` and `BrowserSession.swift` directly; do not shadow either type. Add a throwing `BrowserSession.openSpace(accountDID:spaceURI:)` that validates `DID` and `SpaceRef` first, selects `.account(did: accountDID, destination: .spaces)`, and navigates to a path whose sole component is the account-qualified `.space`. Validation happens before session mutation. Source changes clear prior path/history/selection through the existing `selectSource`; the new account/Space path never inherits another account's overview, record selection, or history.

Implement these exact open contracts in `OpenSpaceCoordinator.swift`:

```swift
public struct SpaceAccountChoice: Identifiable, Hashable, Sendable {
    public var id: String { did }
    public let did: String
    public let displayName: String
}

public struct OpenedSpace: Hashable, Sendable {
    public let accountDID: String
    public let space: SpaceRef
    public let overview: SpaceOverview
    public var reference: ResourceReference {
        .space(accountDID: accountDID, spaceURI: space.uriString())
    }
}

public enum OpenSpaceCoordinatorError: Error, Hashable, Sendable {
    case emptyURI
    case invalidURI(String)
    case invalidAccountDID(String)
    case accountChoiceRequired([SpaceAccountChoice])
    case accountUnavailable(String)
    case persistenceFailed
}

public actor OpenSpaceCoordinator {
    public typealias AccountProvider = @Sendable () async -> [SpaceAccountChoice]
    public typealias ServiceProvider = @Sendable (String) async -> (any SpaceRepositoryServing)?

    public init(
        accounts: @escaping AccountProvider,
        service: @escaping ServiceProvider,
        history: SpaceBookmarkStore
    )
    public func open(uriString: String, accountDID: String?) async throws -> OpenedSpace
}
```

`open` trims the string, requires one exact account when multiple are connected, parses `SpaceRef`, canonicalizes the chosen DID, looks up only that account's service, calls `overview(space:)`, then awaits `history.recordOpened`. It returns only after the atomic write succeeds. If zero accounts exist, return `.accountChoiceRequired([])` so the view offers **Add Account**; if exactly one exists, the view may explicitly preselect it. Never use an active/first-account fallback inside the coordinator.

- [ ] **Step 4: Wire the global Open Space route and account chooser.** `OpenSpaceView` has a Space URI field, a Picker bound to a DID, and an **Open** button disabled until input and required account choice are present. The cross-plan integration owner adds only the `.global(.openSpace)` arm in `ContentBrowserView`, supplying the app-scoped coordinator and the current window's `BrowserSession`. On success, call `try browserSession.openSpace(accountDID: opened.accountDID, spaceURI: opened.space.uriString())`; on failure retain the form and show typed inline copy. Replace `Write/OpenSpaceSheet.swift` with a deprecated wrapper whose body only constructs `OpenSpaceView` from its injected coordinator/session; it owns no state, network call, account selection, or persistence. Task 11 removes the wrapper after its named legacy callers are migrated. The global sidebar row from Plan 1 remains the single entry point; do not add a second command or sheet-specific persistence path.

- [ ] **Step 5: Implement the content hierarchy.** The Space root merges `listSpaces` with only the selected account's `SpaceBookmarkStore.entries(accountDID:)`; the same URI under another account remains a distinct row and never supplies credentials or state. Opening one replaces the center content with overview cards for Policy, My Records, Whole Space, Writer Repositories, Members, Space Blobs, and Back Up. Unknown collections appear alongside known collections; declarations affect labels only.

```swift
public struct SpaceBrowserView: View {
    @Bindable var browserSession: BrowserSession
    @State var store: SpaceRepositoryStore

    public var body: some View {
        Group {
            switch SpaceBrowserDestination(path: browserSession.path) {
            case let .overview(space):
                SpaceOverviewContent(space: space, store: store)
            case let .records(scope, collection):
                SpaceRecordTableView(
                    scope: scope,
                    collection: collection,
                    store: store
                )
            case .root, .invalid:
                SpaceRootTable(store: store)
            }
        }
        .navigationTitle(store.navigationTitle)
    }
}
```

The overview reads only `store.loadState.snapshot`; `.loading(previous:)` and `.failed(previous:failure:)` keep the same cards and rows on screen. **Request Whole Space Access** is present when `readCapability` is `.myRecordsOnly`, but Task 4 supplies its reconsent action. **Space Blobs** and **Back Up** are dependency cards with Plan 3 unavailable-state copy in this plan; do not implement blob enumeration, transfer, or backup creation here.

- [ ] **Step 6: Implement `SpaceRecordTableView` with `Table`, stable row IDs, and incremental paging.** Show Owner, Collection, Record Key, CID, and record-provided timestamp with its source field name. Every row reference comes from the validated canonical `RecordLocator` produced in Task 1. Add both scroll-triggered loading and a keyboard-reachable **Load More** button. A failure keeps rows visible beneath `InlineErrorBanner`.

- [ ] **Step 7: Move Space details into the optional root inspector.** Show the friendly summary first, then policy, access classification, Space URI, writer DID, PDS endpoint, revision/hash, raw JSON, and the current-alpha badge. Remove the nested `HSplitView` and permanent inspector from `RecordTableView`. Extend the inspector's existing exhaustive `ResourceReference` switch with `.space`; it looks up only the account/URI pair carried by the reference.

- [ ] **Step 8: Verify the handoff, build, and run account-qualified projection/open tests.** Hand `Spaces/OpenSpaceCoordinator.swift`, `Spaces/OpenSpaceView.swift`, `Spaces/SpaceBrowserView.swift`, `Spaces/SpaceRecordTableView.swift`, and `OpenSpaceCoordinatorTests.swift` to the integration owner before this command; all modified Plan 1 files are already target members.

Run:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/atprotodrive-spaces-task3-pass.XXXXXX)"; ATD_DERIVED="$VERIFY_ROOT/DerivedData"; DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/BrowserDomainTests -only-testing:ATProtoDriveTests/OpenSpaceCoordinatorTests -only-testing:ATProtoDriveTests/SpaceBookmarkStoreTests -only-testing:ATProtoDriveTests/SpaceRepositoryStoreTests && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ATD_DERIVED" CODE_SIGNING_ALLOWED=NO build
```

Expected: tests PASS and `** BUILD SUCCEEDED **`; the same Space opened under two accounts has distinct references, persisted entries, service calls, and session state, and no test accesses production preferences or live OAuth.

- [ ] **Step 9: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: browse Spaces in the content pane"
jj new
```

---

### Task 4: Add canonical contextual authorization and reconsent

**Files:**
- Modify: `ATProtoDrive/Accounts/AuthenticationModels.swift`
- Create: `ATProtoDrive/Accounts/AuthorizationScopePlanner.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Modify: `ATProtoDrive/Spaces/SpaceBrowserView.swift`
- Modify: `ATProtoDrive/Spaces/SpaceRepositoryStore.swift`
- Cross-plan integration owner only: `ATProtoDrive/ATProtoDriveApp.swift`
- Create: `ATProtoDriveTests/AuthorizationScopePlannerTests.swift`
- Modify: `ATProtoDriveTests/AccountStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 Space identifiers; Petrel dynamic `OAuthConfig(scope:)`; SwanCore `RepoPermission.scopeNeeded(for:)` and `SpacePermission.scopeNeeded(for:)`.
- Produces: canonical `RecordWriteAction`, `SpaceManagementAction`, `LoginIntent`, `AccessContext`, `AccountConnectionStatus`, `AuthenticationIssue`, `AuthorizationScopePlanner`, injected account-metadata preferences, an opt-in-only live OAuth test, and `AccountStore.beginLogin(handle:intent:)`, `reconsent(accountDID:context:)`, and surfaced callback issues. Plan 4 may add only its private-RPC `AccessContext` case and status presentation; it does not rename these cases or add a parallel planner/model family.

- [ ] **Step 1: Hand authorization membership/dependency wiring to the cross-plan integration owner.** The exact manifest is `Accounts/AuthorizationScopePlanner.swift` and `AuthorizationScopePlannerTests.swift`; the integration owner adds local `SwanCore` to app and unit-test targets, wires the two files, and later applies the `ATProtoDriveApp.swift` callback/dependency changes from this task. `import SwanCore` must then resolve in app and tests. Feature code uses SwanCore to format validated scope targets; it never hand-interpolates permission query parameters.

- [ ] **Step 2: Write failing tests that prove record and administration vocabularies cannot cross.** Also pin the base read scope so omission cannot silently restore Proposal 0016's default create/update/delete actions.

```swift
@Test("Space record update uses action and exact destination")
func spaceRecordUpdateScope() throws {
    let space = try SpaceRef(
        uriString: "at://did:plc:owner/space/app.example.drive/main"
    )
    let scope = try AuthorizationScopePlanner().requiredScope(for: .spaceRecord(
        space: space,
        collection: "app.example.note",
        action: .update
    ))
    #expect(scope == "space:app.example.drive?authority=did:plc:owner&skey=main&collection=app.example.note&action=update")
    #expect(!scope.contains("manage="))
}

@Test("member mutation uses manage update and narrow read_self")
func memberManagementScope() throws {
    let space = try SpaceRef(
        uriString: "at://did:plc:owner/space/app.example.drive/main"
    )
    let scope = try AuthorizationScopePlanner().requiredScope(
        for: .manageSpace(space: space, action: .update)
    )
    #expect(scope == "space:app.example.drive?authority=did:plc:owner&skey=main&action=read_self&manage=update")
    #expect(!scope.contains("collection="))
}

@Test("base Space browse scope states narrow read_self explicitly")
func baseScopeIsOwnRepositoryOnly() throws {
    #expect(try AuthorizationScopePlanner().baseScope ==
        "atproto space:*?authority=*&skey=*&action=read_self")
}

@Test("whole Space read is contextual and destination exact")
func wholeSpaceReadScope() throws {
    let space = try SpaceRef(
        uriString: "at://did:plc:owner/space/app.example.drive/main"
    )
    let scope = try AuthorizationScopePlanner().requiredScope(
        for: .spaceRead(space: space)
    )
    #expect(scope == "space:app.example.drive?authority=did:plc:owner&skey=main&action=read")
    #expect(!scope.contains("collection="))
    #expect(!scope.contains("manage="))
}

@Test("malformed scope targets fail before SwanCore formats them")
func malformedTargetsFailClosed() throws {
    let planner = AuthorizationScopePlanner(accountDID: "did:plc:owner")
    #expect(throws: AuthorizationScopeError.invalidCollection("not an nsid")) {
        try planner.requiredScope(
            for: .publicRecord(collection: "not an nsid", action: .create)
        )
    }
    #expect(throws: AuthorizationScopeError.invalidSpaceType("not-a-type")) {
        try planner.requiredScope(
            for: .createSpace(spaceType: "not-a-type", requestedSKey: "main")
        )
    }
    #expect(throws: AuthorizationScopeError.invalidSpaceKey("bad/key")) {
        try planner.requiredScope(
            for: .createSpace(spaceType: "app.example.drive", requestedSKey: "bad/key")
        )
    }
    #expect(throws: AuthorizationScopeError.invalidAuthorityDID("not-a-did")) {
        try AuthorizationScopePlanner(accountDID: "not-a-did").requiredScope(
            for: .createSpace(spaceType: "app.example.drive", requestedSKey: "main")
        )
    }
    for mime in ["image/*", "*/*", "image", "image/ png", ""] {
        #expect(throws: AuthorizationScopeError.self) {
            try planner.requiredScope(for: .blobUpload(mimeType: mime))
        }
    }
    #expect(try planner.requiredScope(for: .blobUpload(mimeType: "image/png")) ==
        "blob:image/png")
}
```

Before running the red command, make `AccountStoreTests.testLiveLoginSpacesAlpha` opt-in and remove the personal/default handle from source:

```swift
@MainActor
@Test(.enabled(
    if: ProcessInfo.processInfo.environment["ATPROTO_DRIVE_RUN_LIVE_TESTS"] == "1"
        && !(ProcessInfo.processInfo.environment["ATPROTO_DRIVE_LIVE_HANDLE"]?.isEmpty ?? true),
    "Set both live-test environment variables"
))
func testLiveLoginSpacesAlpha() async throws {
    let handle = try #require(
        ProcessInfo.processInfo.environment["ATPROTO_DRIVE_LIVE_HANDLE"]
    )
    let store = AccountStore(preferences: Self.isolatedPreferences())
    _ = try await store.beginLogin(handle: handle, intent: .add)
}
```

`AccountStoreTests.isolatedPreferences()` creates `UserDefaults(suiteName: "ATProtoDriveTests.\(UUID().uuidString)")!` and registers cleanup with `removePersistentDomain(forName:)`; every test in `AccountStoreTests` and every later `WritePipelineTests` account fixture injects such a suite. With both live variables unset, Swift Testing disables this one test before its body and performs no handle resolution, OAuth discovery, Keychain access, or browser launch.

- [ ] **Step 3: Run the focused tests and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/AuthorizationScopePlannerTests -only-testing:ATProtoDriveTests/AccountStoreTests
```

Expected: FAIL because intent-aware authentication and the canonical scope planner do not exist.

- [ ] **Step 4: Validate every dynamic target, then implement exact scope generation through SwanCore.** SwanCore's `scopeNeeded` is a formatter, not this app's trust boundary: before calling it, parse every collection and Space type as `NSID`, parse each concrete Space/requested key as `RecordKey`, reject wildcard or malformed user MIME targets, and require a concrete RFC token/token MIME pair. A management target deliberately emits `action=read_self` plus `manage=`; a record target emits `collection=` plus `action=` and no `manage=`.

```swift
public struct AuthorizationScopePlanner: Sendable {
    private let accountDID: String?

    public init(accountDID: String? = nil) {
        self.accountDID = accountDID
    }

    public var baseScope: String {
        get throws {
            let ownRead = try SwanCore.SpacePermission.scopeNeeded(for: .init(
                type: "*", authority: "*", skey: "*",
                operation: .readSelf(aggregate: true, collection: nil)
            ))
            return "atproto \(ownRead)"
        }
    }

    public func requiredScope(for context: AccessContext) throws -> String {
        switch context {
        case let .publicRecord(collection, action):
            try validateCollection(collection)
            return try SwanCore.RepoPermission.scopeNeeded(for: .init(
                collection: collection, action: action.repoAction
            ))
        case let .spaceRecord(space, collection, action):
            try validateExactSpace(space)
            try validateCollection(collection)
            return try SwanCore.SpacePermission.scopeNeeded(for: .init(
                type: space.spaceType, authority: space.spaceDID, skey: space.skey,
                operation: .write(action.spaceWrite, collection: collection)
            ))
        case let .spaceRead(space):
            try validateExactSpace(space)
            return try SwanCore.SpacePermission.scopeNeeded(for: .init(
                type: space.spaceType, authority: space.spaceDID, skey: space.skey,
                operation: .delegationExchange
            ))
        case let .manageSpace(space, action):
            try validateExactSpace(space)
            return try SwanCore.SpacePermission.scopeNeeded(for: .init(
                type: space.spaceType, authority: space.spaceDID, skey: space.skey,
                operation: .manage(action.spaceManageOperation)
            ))
        case let .createSpace(type, requestedSKey):
            guard let accountDID else { throw AuthenticationIssue.missingAccount("unknown") }
            try validateAuthorityDID(accountDID)
            try validateSpaceType(type)
            if let requestedSKey { try validateSpaceKey(requestedSKey) }
            return try SwanCore.SpacePermission.scopeNeeded(for: .init(
                type: type, authority: accountDID, skey: requestedSKey ?? "*",
                operation: .manage(.create)
            ))
        case let .blobUpload(mimeType):
            try validateConcreteMIMEType(mimeType)
            return try SwanCore.BlobPermission.scopeNeeded(for: .init(mime: mimeType))
        }
    }

    private func validateCollection(_ value: String) throws {
        do { _ = try NSID(nsidString: value) }
        catch { throw AuthorizationScopeError.invalidCollection(value) }
    }

    private func validateAuthorityDID(_ value: String) throws {
        do { _ = try DID(didString: value) }
        catch { throw AuthorizationScopeError.invalidAuthorityDID(value) }
    }

    private func validateSpaceType(_ value: String) throws {
        do { _ = try NSID(nsidString: value) }
        catch { throw AuthorizationScopeError.invalidSpaceType(value) }
    }

    private func validateSpaceKey(_ value: String) throws {
        do { _ = try RecordKey(keyString: value) }
        catch { throw AuthorizationScopeError.invalidSpaceKey(value) }
    }

    private func validateExactSpace(_ space: SpaceRef) throws {
        try validateAuthorityDID(space.spaceDID)
        try validateSpaceType(space.spaceType)
        try validateSpaceKey(space.skey)
    }

    private func validateConcreteMIMEType(_ value: String) throws {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        let token = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        )
        guard pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && !$0.contains("*") }),
              value.unicodeScalars.allSatisfy({ $0 == "/" || token.contains($0) })
        else { throw AuthorizationScopeError.nonConcreteMIMEType(value) }
    }
}

private extension RecordWriteAction {
    var repoAction: SwanCore.RepoAction {
        switch self {
        case .create: .create
        case .update: .update
        case .delete: .delete
        }
    }
    var spaceWrite: SwanCore.SpaceScopeTarget.Operation.RecordWrite {
        switch self {
        case .create: .create
        case .update: .update
        case .delete: .delete
        }
    }
}

private extension SpaceManagementAction {
    var spaceManageOperation: SwanCore.SpaceManageOp {
        switch self {
        case .create: .create
        case .update: .update
        case .delete: .delete
        }
    }
}
```

- [ ] **Step 5: Inject account metadata preferences and make OAuth pending state intent-aware.** Add `private let preferences: UserDefaults` and `public init(preferences: UserDefaults = .standard)` to the `@MainActor` store; replace every direct `UserDefaults.standard` account read/write/remove with this instance. The production app accepts the default, but tests must always pass a UUID-scoped suite. Persist the last requested scope per account. Reconsent builds a new Petrel client with base scope plus the exact requested permission, carries the expected DID, and only replaces the account client after callback DID verification. It never routes through `activeAccount` fallback.

```swift
private struct PendingLogin: Sendable {
    let client: ATProtoClient
    let expectedDID: String
    let requestedHandle: String
    let authMode: AuthModeType
    let stateToken: String
    let intent: LoginIntent
    let requestedScope: String
}

public func reconsent(accountDID: String, context: AccessContext) async throws -> URL {
    guard let account = account(for: accountDID) else {
        throw AuthenticationIssue.missingAccount(accountDID)
    }
    return try await beginLogin(
        handle: account.handle,
        intent: .reconsent(accountDID: accountDID, context: context)
    )
}
```

The requested OAuth string is `baseScope` plus the account's still-required exact grants plus `requiredScope(for: context)`, deduplicated without widening any component. For `.spaceRead`, do not substitute the wildcard baseline: request the exact type, authority, and skey with `action=read`, then exchange the Space credential only after the callback is bound to the expected account DID. Wire the content pane's **Request Whole Space Access** action to this context and resume only the pending load for that exact Space; refusal preserves the My Records snapshot.

- [ ] **Step 6: Remove silent callback loss.** Change `handleCallback(_:)` to catch and publish `AuthenticationIssue`; `ATProtoDriveApp.onOpenURL` awaits it without `try?`. Preserve local accounts and browser sources on a failed reconnect/reconsent.

- [ ] **Step 7: Run focused tests, verify preference isolation, and build.** First require `rg -n "UserDefaults\\.standard" ATProtoDriveTests` to return no matches and `rg -n "josh\\.spaces-alpha|beginLogin with josh" ATProtoDriveTests` to return no matches.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/AuthorizationScopePlannerTests -only-testing:ATProtoDriveTests/AccountStoreTests && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: tests PASS and build succeeds; tests pin exact scope strings and callback failures appear as model state. The live OAuth case is reported disabled with **Set both live-test environment variables** and no deterministic test reads or writes production preferences.

- [ ] **Step 8: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: add contextual ATProto reconsent"
jj new
```

---

### Task 5: Extract lossless record documents, diffs, and mutation contracts

**Files:**
- Modify: `ATProtoDrive/Mutation/MutationModels.swift`
- Create: `ATProtoDrive/Mutation/RecordDocumentCodec.swift`
- Create: `ATProtoDrive/Mutation/RecordDiff.swift`
- Modify: `ATProtoDrive/Records/RecordListModel.swift`
- Create: `ATProtoDriveTests/RecordDocumentCodecTests.swift`
- Modify: `ATProtoDriveTests/MutationTestFixtures.swift`
- Modify: `ATProtoDriveTests/WritePipelineTests.swift`

**Interfaces:**
- Consumes: Task 1's compile-safe `RepositoryVersion`, `RepositoryBaseline`, and `RecordSnapshot`; Plan 1 `RepositoryScope`, `RecordLocator`, `AccessClassification`; Petrel `ATProtocolValueContainer`.
- Produces: the completed fixed `RecordSnapshot`, `RecordDraft`, `MutationPreparation`, `MutationOutcome`, `RecordDiff`, `MutationWarning`, `MutationConflict`, and a codec used identically by public and Space mutation services. Public versions are commit CIDs; Space versions are signed revision/hash pairs and are never stored in the same string field.

- [ ] **Step 1: Write failing losslessness and validation tests.** Pin unknown keys, nested `$link`, `$bytes`, blob shapes, explicit `$type`, injected `$type`, and expert validation bypass defaulting to off for every new sheet.

```swift
@Test("unknown AT Protocol values survive edit preparation")
func preservesUnknownKeysAndLinks() throws {
    let source = #"{"$type":"app.example.note","future":{"$link":"bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"},"raw":{"$bytes":"AQID"},"unknown":7}"#
    let document = try RecordDocumentCodec.decode(
        source,
        expectedCollection: "app.example.note",
        validation: .required
    )
    let encoded = try RecordDocumentCodec.canonicalJSON(document.value)
    #expect(encoded.contains("\"future\""))
    #expect(encoded.contains("\"$link\""))
    #expect(encoded.contains("\"$bytes\""))
    #expect(encoded.contains("\"unknown\""))
}

@Test("public and Space repository versions cannot be confused")
func repositoryVersionsAreTyped() {
    #expect(RecordSnapshot.original.repositoryVersion == .publicCommit(
        cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
    ))
    #expect(RecordSnapshot.originalSpace.repositoryVersion == .spaceSignedCommit(
        revision: "3m4j2abcde2",
        hashBase64: "AQIDBA=="
    ))
}

@Test("mismatched type is rejected before transport")
func rejectsMismatchedType() {
    #expect(throws: RecordDocumentError.self) {
        try RecordDocumentCodec.decode(
            #"{"$type":"app.example.other"}"#,
            expectedCollection: "app.example.note",
            validation: .required
        )
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/RecordDocumentCodecTests
```

Expected: FAIL because the focused codec and mutation contracts do not exist.

- [ ] **Step 3: Move JSON validation out of `RecordListModel`.** Decode through JSONSerialization only to verify an object root and inject a missing `$type`; encode/decode the resulting bytes through `ATProtocolValueContainer`. Preserve the original value in `RecordSnapshot` and never reconstruct a record from UI-friendly fields.

```swift
public enum RecordValidationMode: Hashable, Sendable {
    case required
    case expertBypassConfirmed
}

public static func decode(
    _ json: String,
    expectedCollection: String,
    validation: RecordValidationMode
) throws -> RecordDocument {
    guard var object = try JSONSerialization.jsonObject(
        with: Data(json.utf8)
    ) as? [String: Any] else { throw RecordDocumentError.objectRequired }
    if let type = object["$type"] as? String, type != expectedCollection {
        throw RecordDocumentError.typeMismatch(
            expected: expectedCollection,
            found: type
        )
    }
    object["$type"] = object["$type"] ?? expectedCollection
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return RecordDocument(
        value: try JSONDecoder().decode(ATProtocolValueContainer.self, from: data),
        validation: validation
    )
}
```

- [ ] **Step 4: Implement stable human and raw diffs.** Sort object keys for display only, identify added/removed/changed JSON pointers, and retain original/edited canonical JSON for conflict UI. Arrays are compared by index; no schema-specific mutation is inferred.

- [ ] **Step 5: Fill the shared mutation fixtures with complete values.** `MutationTestFixtures.swift` defines `RecordSnapshot.original`, `.originalSpace`, `.remoteChanged`, `.updated`, `fixturePublic(ownerDID:)`, `RecordLocator.fixtureSpace(writerDID:)`, and `String.editedJSON` with explicit `RecordLocator`, `RepositoryScope`, valid CID, canonical JSON, `ATProtocolValueContainer`, and the correctly typed `.publicCommit(cid:)` or `.spaceSignedCommit(revision:hashBase64:)`. Each `MutationPreparation` fixture supplies `id`, `preparedAt`, `repositoryBaseline`, and `backupEvidence`; batch fixtures construct the fixed `MutationBatchPreparation` rather than passing raw arrays. All later mutation tests consume these exact fixtures; there are no unresolved fixture members.

```swift
extension RecordLocator {
    static func fixtureSpace(writerDID: String = "did:plc:alice") -> Self {
        let space = SpaceRef.fixtureSpaceRef
        let uri = try! space.recordURI(
            authorDID: writerDID,
            collection: "app.example.note",
            recordKey: "one"
        ).uriString()
        return try! .spaceRecord(
            space: space,
            authorDID: writerDID,
            accountDID: "did:plc:alice",
            collection: "app.example.note",
            recordKey: "one",
            cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
            wireURI: uri
        )
    }
}
```

No permissioned fixture may call `RecordLocator.init` directly or use `at://{writerDID}/{collection}/{rkey}`. A source scan for `at://space/` and public-shaped Space fixture URIs must be empty after this task.

- [ ] **Step 6: Keep compatibility wrappers in `RecordListModel` and rerun old write-pipeline tests.** Existing static helpers delegate to `RecordDocumentCodec`; this task must not change network behavior.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/RecordDocumentCodecTests -only-testing:ATProtoDriveTests/WritePipelineTests
```

Expected: PASS; old validation behavior remains and new tests prove lossless unknown-value preservation.

- [ ] **Step 7: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "refactor: extract safe record documents and diffs"
jj new
```

---

### Task 6: Implement public owner-only mutations with atomic conflict protection

**Files:**
- Create: `ATProtoDrive/Mutation/PublicMutationService.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRepositoryService.swift`
- Create: `ATProtoDriveTests/PublicMutationServiceTests.swift`

**Interfaces:**
- Consumes: Task 4 `AccessContext.publicRecord`; Task 5 mutation contracts; Plan 1 `ResolvedRepository` and public service construction.
- Produces: `PublicMutationServing`, live `PublicMutationService`, public create/update/delete preparation and execution, atomic stale-conflict evidence, and verified outcomes.

- [ ] **Step 1: Write failing tests proving both preconditions are sent, exact batch unions are built, and foreign/mixed repositories fail before transport.** The transport fake records generated Petrel inputs. The batch test prepares one create/update/delete in the same public repository, asserts all exact union payload fields plus one `swapCommit`, and separately asserts zero calls for a second repository or Space-scoped item.

```swift
@Test("public update sends swapRecord and swapCommit")
func updateUsesBothCASValues() async throws {
    let transport = PublicMutationTransportSpy(
        snapshots: [.original, .original, .updated]
    )
    let service = PublicMutationService(
        accountDID: "did:plc:alice",
        transport: transport
    )
    let preparation = try await service.prepareUpdate(
        original: .original,
        editedJSON: #"{"$type":"app.example.note","text":"new"}"#
    )
    _ = try await service.execute(preparation)

    let input = try #require(await transport.putInputs.first)
    #expect(input.swapRecord?.description == RecordSnapshot.original.recordCID)
    #expect(input.swapCommit?.description ==
        RecordSnapshot.original.repositoryVersion.publicCommitCID)
}

@Test("foreign public repository never reaches mutation transport")
func foreignRepoIsReadOnly() async {
    let transport = PublicMutationTransportSpy()
    let service = PublicMutationService(
        accountDID: "did:plc:alice",
        transport: transport
    )
    await #expect(throws: MutationError.foreignRepositoryReadOnly) {
        try await service.prepareDelete(snapshot: .fixturePublic(ownerDID: "did:plc:bob"))
    }
    #expect(await transport.writeCount == 0)
}
```

- [ ] **Step 2: Run the focused test and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicMutationServiceTests
```

Expected: FAIL because the public mutation service and transport protocol do not exist.

- [ ] **Step 3: Implement preparation.** Refetch `com.atproto.repo.getRecord` and `com.atproto.sync.getLatestCommit`, preserve original value/CID, validate the draft, calculate the diff, and return the exact destination plus `.publicRecord(collection:action:)` required access.

- [ ] **Step 4: Implement last-moment recheck and generated Petrel inputs.** Abort with `MutationConflict(original:edited:remote:)` if either record CID/value or commit CID changed. Use the generated schemas exactly.

```swift
let input = ComAtprotoRepoPutRecord.Input(
    repo: try ATIdentifier(string: accountDID),
    collection: try NSID(nsidString: draft.collection),
    rkey: try RecordKey(keyString: recordKey),
    validate: draft.validate,
    record: draft.value,
    swapRecord: try CID.parse(current.recordCID),
    swapCommit: try CID.parse(current.repositoryVersion.requirePublicCommitCID())
)
let (status, output) = try await transport.put(input)
let committed = try requiredMutationOutput(
    status: status, output: output, endpoint: ComAtprotoRepoPutRecord.typeIdentifier
)
```

For create, send `swapCommit` and check an explicit record key is absent before submission. For delete, refetch and send the freshest `swapRecord` and `swapCommit`. `requirePublicCommitCID()` throws `MutationError.invalidPreparation` for `.spaceSignedCommit`, so version kinds cannot cross data planes.

For same-repository batches, first reject an empty batch, mixed `RepositoryScope`, mixed account ownership, or more than one repository. Refetch the public commit once and construct the generated union/input exactly; do not leave the transport as an ellipsis:

```swift
let writes: [ComAtprotoRepoApplyWrites.InputWritesUnion] = [
    .comAtprotoRepoApplyWritesCreate(.init(
        collection: try NSID(nsidString: "app.example.note"),
        rkey: try RecordKey(keyString: "new"),
        value: RecordSnapshot.updated.value
    )),
    .comAtprotoRepoApplyWritesUpdate(.init(
        collection: try NSID(nsidString: "app.example.note"),
        rkey: try RecordKey(keyString: "existing"),
        value: RecordSnapshot.updated.value
    )),
    .comAtprotoRepoApplyWritesDelete(.init(
        collection: try NSID(nsidString: "app.example.note"),
        rkey: try RecordKey(keyString: "old")
    ))
]
let batchInput = ComAtprotoRepoApplyWrites.Input(
    repo: try ATIdentifier(string: accountDID),
    validate: true,
    writes: writes,
    swapCommit: try CID.parse(currentVersion.requirePublicCommitCID())
)
let (batchStatus, batchOutput) = try await transport.applyWrites(batchInput)
_ = try requiredMutationOutput(
    status: batchStatus,
    output: batchOutput,
    endpoint: ComAtprotoRepoApplyWrites.typeIdentifier
)
```

The batch test asserts all three exact union cases and fields, one `swapCommit`, one transport call, post-write verification of each target, and zero calls for mixed public repositories or a public/Space mixture.

- [ ] **Step 5: Refetch after the response.** Update/create is `.verified` only when URI, CID, and canonical value match the output/draft. Delete is verified only after `getRecord` returns declared `RecordNotFound`. An `InvalidSwap` response becomes the three-way conflict UI model. A thrown transport error after submission begins becomes `.remoteWriteUnverified`; do not retry.

- [ ] **Step 6: Run the public mutation suite.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/PublicMutationServiceTests
```

Expected: PASS for create, update, delete, exact one-repository `applyWrites`, mixed-scope rejection, stale conflict, explicit-key collision, post-write mismatch, foreign ownership, 2xx/nil, and no blind retry.

- [ ] **Step 7: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: add CAS protected public record mutations"
jj new
```

---

### Task 7: Implement Space owner-repository mutations with current-alpha safety

**Files:**
- Create: `ATProtoDrive/Mutation/SpaceMutationService.swift`
- Modify: `ATProtoDrive/Spaces/SpaceRepositoryService.swift`
- Create: `ATProtoDrive/Spaces/SpaceDeletionSafety.swift`
- Create: `ATProtoDriveTests/SpaceMutationServiceTests.swift`
- Modify: `ATProtoDriveTests/WritePipelineTests.swift`

**Interfaces:**
- Consumes: Task 1 `SpaceRepositoryServing`, writer-PDS `getLatestCommit`, and `SpaceProtocolCapabilities`; Task 4 `AccessContext.spaceRecord`; Task 5 mutation contracts; Plan 3-facing `BackupPreflightProviding` declaration.
- Produces: `SpaceMutationServing`, live `SpaceMutationService`, first-write absent-repository handling, single and batch writes, required non-atomic warning, ownership enforcement, detected-change abort, provider-owned backup gating, single submission, and post-write signed-version verification.

- [ ] **Step 1: Write failing tests for the Space-alpha contract.** Pin the absence of CAS fields, immediate refetch ordering, detected-change abort, own-writer enforcement, required backup evidence for delete, post-write mismatch, and no automatic retry.

```swift
@Test("Space update warns, preflights, submits once, and verifies")
func warnedPreflightAndVerify() async throws {
    let transport = SpaceMutationTransportSpy(
        events: [
            .getRecord(.originalSpace), .getLatestCommit(.originalSpace.repositoryVersion),
            .getRecord(.originalSpace), .getLatestCommit(.originalSpace.repositoryVersion),
            .put(.updated),
            .getRecord(.updated), .getLatestCommit(.updated.repositoryVersion)
        ]
    )
    let service = SpaceMutationService(
        accountDID: "did:plc:alice",
        transport: transport
    )
    let preparation = try await service.prepareUpdate(
        original: .originalSpace,
        editedJSON: #"{"$type":"app.example.note","text":"new"}"#
    )
    #expect(preparation.warnings.contains(.spaceAlphaNonAtomicPreflight))

    let outcome = try await service.execute(preparation)

    #expect(outcome.isVerified)
    #expect(await transport.eventNames == [
        "getRecord", "getLatestCommit",
        "getRecord", "getLatestCommit", "put",
        "getRecord", "getLatestCommit"
    ])
    #expect(await transport.putCount == 1)
}

@Test("detected remote change aborts before Space transport")
func changedRemoteAborts() async throws {
    let transport = SpaceMutationTransportSpy(
        events: [
            .getRecord(.originalSpace), .getLatestCommit(.originalSpace.repositoryVersion),
            .getRecord(.remoteChanged), .getLatestCommit(.remoteChanged.repositoryVersion)
        ]
    )
    let service = SpaceMutationService(
        accountDID: "did:plc:alice",
        transport: transport
    )
    let preparation = try await service.prepareUpdate(
        original: .originalSpace,
        editedJSON: .editedJSON
    )
    await #expect(throws: MutationConflict.self) {
        try await service.execute(preparation)
    }
    #expect(await transport.putCount == 0)
}

@Test("first Space write accepts RepoNotFound and verifies the new repository")
func firstWriteCreatesRepository() async throws {
    let transport = SpaceMutationTransportSpy(events: [
        .getLatestCommitError(.repoNotFound),
        .getRecordError(.recordNotFound),
        .getRecordError(.recordNotFound),
        .getLatestCommitError(.repoNotFound),
        .create(.updated),
        .getRecord(.updated),
        .getLatestCommit(.updated.repositoryVersion)
    ])
    let service = SpaceMutationService(
        accountDID: "did:plc:alice", transport: transport,
        backupProvider: UnavailableBackupPreflightProvider()
    )

    let preparation = try await service.prepareCreate(
        draft: .fixtureSpace(recordKey: "first")
    )
    #expect(preparation.repositoryBaseline == .absent)
    #expect(try await service.execute(preparation).isVerified)
    let input = try #require(await transport.createInputs.first)
    #expect(input.repo.didString() == "did:plc:alice")
    #expect(input.collection.description == "app.example.note")
    #expect(input.rkey?.description == "first")
    #expect(input.validate == true)
    #expect(await transport.createCount == 1)
}

@Test("Space batch uses one non-CAS applyWrites call")
func spaceBatchIsSingleWriterAndSingleSubmission() async throws {
    let transport = SpaceMutationTransportSpy.batchFixture()
    let service = SpaceMutationService(
        accountDID: "did:plc:alice", transport: transport,
        backupProvider: VerifiedBackupPreflightProvider.fixture
    )
    let preparation = try await service.prepareBatch(.fixtureSpaceCreateUpdateDelete)
    let outcome = try await service.executeBatch(preparation)
    #expect(outcome.allSatisfy(\.isVerified))
    #expect(await transport.applyWritesCount == 1)
    #expect(await transport.applyWritesInput?.writes.count == 3)
    #expect(await transport.eventNames == [
        "getLatestCommit", "getRecord", "getRecord", "getRecord",
        "getRecord", "getRecord", "getRecord", "getLatestCommit",
        "applyWrites",
        "getRecord", "getRecord", "getRecord", "getLatestCommit"
    ])
}

@Test("record delete obtains provider evidence and rejects future completion")
func recordDeleteEvidenceIsProviderBound() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = RecordSnapshot.originalSpace
    let evidence = BackupPreflightEvidence(
        backupID: UUID(),
        subject: .record(locator: snapshot.locator, recordCID: snapshot.recordCID),
        accountDID: "did:plc:alice",
        completedAt: now.addingTimeInterval(60),
        manifestDigest: "sha256:" + String(repeating: "a", count: 64),
        complete: true,
        verified: true
    )
    let provider = ScriptedBackupPreflightProvider(recordEvidence: evidence)
    let transport = SpaceMutationTransportSpy()
    let service = SpaceMutationService(
        accountDID: "did:plc:alice", transport: transport,
        backupProvider: provider, clock: FixedClock(now: now)
    )

    await #expect(throws: MutationError.self) {
        try await service.prepareDelete(snapshot: snapshot)
    }
    #expect(await provider.recordRequests == [snapshot])
    #expect(await transport.deleteCount == 0)
}
```

Add companion tests for generated-key create (`input.rkey == nil`, returned URI supplies the key), explicit-key collision (zero writes), foreign/mixed Space scopes (zero writes), batch capability unsupported (zero writes plus typed disabled reason), backup-provider failure (zero delete calls), malformed/mismatched/incomplete evidence, empty manifest digest, future completion time, post-write signed-revision mismatch, and a transport failure after submission (one write, `.remoteWriteUnverified`, no blind retry).

- [ ] **Step 2: Run the focused test and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceMutationServiceTests
```

Expected: FAIL because Space mutation safety is still embedded in the eager model and lacks the preflight contract.

- [ ] **Step 3: Enforce writer ownership before all preparation and execution.** Parse `.permissionedSpace(spaceURI:writerDID:accountDID:)`; require both scoped account DID and writer DID to equal `SpaceMutationService.accountDID`. Other writers remain readable through `SpaceRepositoryService` but cannot produce a preparation.

- [ ] **Step 4: Implement create/update/delete and same-writer batches with the generated current-alpha inputs.** Require the exact method in `SpaceProtocolCapabilities` before preparation. These inputs deliberately have no swap fields.

```swift
let updateInput = ComAtprotoSpacePutRecord.Input(
    space: space,
    repo: try DID(didString: accountDID),
    collection: try NSID(nsidString: draft.collection),
    rkey: try RecordKey(keyString: recordKey),
    validate: draft.validate,
    record: draft.value
)

let createInput = ComAtprotoSpaceCreateRecord.Input(
    space: space,
    repo: try DID(didString: accountDID),
    collection: try NSID(nsidString: draft.collection),
    rkey: try draft.recordKey.map { try RecordKey(keyString: $0) },
    validate: draft.validate,
    record: draft.value
)

let deleteInput = ComAtprotoSpaceDeleteRecord.Input(
    space: space,
    repo: try DID(didString: accountDID),
    collection: try NSID(nsidString: snapshot.locator.collection),
    rkey: try RecordKey(keyString: snapshot.locator.rkey)
)
```

Create preparation first calls writer-PDS `com.atproto.space.getLatestCommit`. A declared `RepoNotFound` is the valid `.absent` baseline for an account that has not written in the Space and may therefore be missing from `listSpaces`; all other failures abort. For an explicit key, call `getRecord` and require declared `RecordNotFound`; for a generated key, leave `rkey` nil and obtain the canonical key only from the successful output URI. Immediately before submission, repeat both checks: an explicit key must still be absent, and an absent repository baseline must still return `RepoNotFound` while a present baseline must exactly match `.spaceSignedCommit(revision:hashBase64:)`. Update/delete also refetch the record and compare CID/canonical value.

For every update/delete and every existing-repository create, the order is `getRecord` as applicable, writer-PDS `com.atproto.space.getLatestCommit`, one write, then `getRecord` and `getLatestCommit`. Compare the signed `rev` plus base64-encoded `hash` before and after; never substitute public `com.atproto.sync.getLatestCommit` or the authority's `listRepos` claim. The warning copy is fixed: **“ATProto Spaces alpha has no atomic conflict precondition. ATProtoDrive checked immediately before writing, but another writer could still change this record before the server commits this request.”**

For a Space batch, validate every entry belongs to the same exact `.permissionedSpace(spaceURI:writerDID:accountDID:)`, both DID fields equal the service account, every required action scope is present, and every delete has provider-issued evidence. Preflight all target records plus one current signed version, then build the generated union/input exactly:

```swift
let writes: [ComAtprotoSpaceApplyWrites.InputWritesUnion] = [
    .comAtprotoSpaceApplyWritesCreate(.init(
        collection: try NSID(nsidString: "app.example.note"),
        rkey: try RecordKey(keyString: "new"),
        value: RecordSnapshot.updated.value
    )),
    .comAtprotoSpaceApplyWritesUpdate(.init(
        collection: try NSID(nsidString: "app.example.note"),
        rkey: try RecordKey(keyString: "existing"),
        value: RecordSnapshot.updated.value
    )),
    .comAtprotoSpaceApplyWritesDelete(.init(
        collection: try NSID(nsidString: "app.example.note"),
        rkey: try RecordKey(keyString: "old")
    ))
]
let input = ComAtprotoSpaceApplyWrites.Input(
    space: space,
    repo: try DID(didString: accountDID),
    validate: true,
    writes: writes
)
let (status, output) = try await transport.applyWrites(input)
_ = try requiredMutationOutput(
    status: status,
    output: output,
    endpoint: ComAtprotoSpaceApplyWrites.typeIdentifier
)
```

Submit that input once, never retry it blindly, then verify every target and a new signed commit. If any item cannot be verified, return per-item `.remoteWriteUnverified` outcomes and require a refetch before another write.

- [ ] **Step 5: Define the Plan 3 backup seam and make the service obtain and bind evidence.** `SpaceDeletionSafety.swift` owns the single `BackupPreflightEvidence`/`BackupPreflightProviding` definitions shown in Fixed Cross-Task Interfaces. Inject one provider into `SpaceMutationService`; callers cannot pass evidence to `prepareDelete` or `execute`. `prepareDelete(snapshot:)` invokes `backupProvider.backUpRecordBeforeDeletion(snapshot)`, validates it privately, and binds it to `MutationPreparation.backupEvidence`. `execute(_:)` validates the bound evidence again before the last-moment network preflight. `UnavailableBackupPreflightProvider` throws the typed message **“Back Up First becomes available when the backup service is installed.”** It is the production default until Plan 3 supplies a verified provider.

The shared `BackupEvidenceValidator.validateRecord` requires exact `subject == .record(locator: snapshot.locator, recordCID: snapshot.recordCID)`, including the locator's complete `RepositoryScope`; exact account DID; `complete && verified`; a lowercase `sha256:` manifest digest with 64 hexadecimal digits; and `completedAt <= clock.now`. Evidence is fresh because every production delete preparation calls the provider for that exact snapshot—there is no caller-supplied evidence overload. A missing or invalid proof throws `MutationError.backupRequired` before any `deleteRecord` or `applyWrites` call.

```swift
public struct UnavailableBackupPreflightProvider: BackupPreflightProviding {
    public init() {}
    public func backUpRecordBeforeDeletion(
        _ snapshot: RecordSnapshot
    ) async throws -> BackupPreflightEvidence {
        throw MutationError.backupRequired(
            "Back Up First becomes available when the backup service is installed."
        )
    }
    public func backUpSpaceBeforeDeletion(
        space: SpaceRef,
        accountDID: String,
        authoritySnapshot: SpaceDeletionAuthoritySnapshot
    ) async throws -> BackupPreflightEvidence {
        throw MutationError.backupRequired(
            "Back Up First becomes available when the backup service is installed."
        )
    }
}
```

- [ ] **Step 6: Implement record plus signed-version post-write verification and uncertain outcomes.** Create/update refetch exact collection/rkey and compare URI/CID/value, then fetch `getLatestCommit` and require a valid `.spaceSignedCommit` different from the prepared present version (or present after an absent baseline). Delete verifies declared record-not-found and a successfully decoded current signed commit. If submission may have reached the server but response or either verification fails, return `.remoteWriteUnverified` with **Refetch Now** as the safe next action; never repeat the write or batch.

- [ ] **Step 7: Keep `RecordListModel` compatibility methods delegating to the service, then run new and old suites.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceMutationServiceTests -only-testing:ATProtoDriveTests/WritePipelineTests
```

Expected: PASS; tests prove there is one Space write at most and zero writes after an observed conflict or missing backup.

- [ ] **Step 8: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: add safe Space record mutations"
jj new
```

---

### Task 8: Coordinate writes and replace direct-write editor UX

**Files:**
- Create: `ATProtoDrive/Mutation/MutationCoordinator.swift`
- Create: `ATProtoDrive/Mutation/RecordMutationSheet.swift`
- Create: `ATProtoDrive/Mutation/MutationConfirmationView.swift`
- Modify: `ATProtoDrive/Write/RecordEditorSheet.swift`
- Modify: `ATProtoDrive/Spaces/SpaceRecordTableView.swift`
- Modify: `ATProtoDrive/PublicRepo/PublicRecordStore.swift`
- Modify: `ATProtoDrive/Browser/BrowserCommands.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Cross-plan integration owner only: `ATProtoDrive/ATProtoDriveApp.swift`
- Create: `ATProtoDriveTests/MutationCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 4, 5, 6, and 7 authorization/mutation services; Plan 1 browser commands and selections.
- Produces: app-scoped `MutationCoordinator`, repository write serialization, contextual reconsent continuation, unified editor/confirmation/conflict/partial-result flow, and command eligibility.

- [ ] **Step 1: Write failing coordinator tests.** Test same-repository serialization, different-repository concurrency, reconsent continuation bound to exact account/destination, cancellation before submission, and uncertain outcome refusing retry.

```swift
@Test("writes serialize per qualified repository")
func serializesSameRepository() async throws {
    let probe = MutationConcurrencyProbe()
    let coordinator = MutationCoordinator()
    async let first: Void = coordinator.withRepositoryWriteLock(scope: .fixtureSpace) {
        try await probe.enterAndHold(id: 1)
    }
    async let second: Void = coordinator.withRepositoryWriteLock(scope: .fixtureSpace) {
        try await probe.enterAndHold(id: 2)
    }
    try await probe.releaseInOrder()
    _ = try await (first, second)
    #expect(await probe.maximumConcurrent == 1)
}

@Test("reconsent resumes only the original account operation")
func reconsentIsDestinationBound() async throws {
    let coordinator = MutationCoordinator()
    let pending = coordinator.pendingOperation(
        accountDID: "did:plc:alice",
        context: .publicRecord(collection: "app.example.note", action: .update),
        preparationID: UUID()
    )
    #expect(pending.acceptsCallback(for: "did:plc:bob") == false)
}

@Test("a cancelled queued writer never runs and does not strand the lock")
func cancelledWaiterIsRemoved() async throws {
    let coordinator = MutationCoordinator()
    let probe = MutationConcurrencyProbe()
    let first = Task {
        try await coordinator.withRepositoryWriteLock(scope: .fixtureSpace) {
            try await probe.enterAndHold(id: 1)
        }
    }
    await probe.waitUntilEntered(id: 1)
    let cancelled = Task {
        try await coordinator.withRepositoryWriteLock(scope: .fixtureSpace) {
            await probe.recordUnexpectedEntry(id: 2)
        }
    }
    await probe.waitUntilQueuedWriters(1)
    cancelled.cancel()
    await probe.release(id: 1)
    _ = try await first.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await coordinator.withRepositoryWriteLock(scope: .fixtureSpace) {
        await probe.recordEntry(id: 3)
    }
    #expect(await probe.enteredIDs == [1, 3])
}
```

- [ ] **Step 2: Run the focused test and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/MutationCoordinatorTests
```

Expected: FAIL because repository locks and resumable exact-intent operations do not exist.

- [ ] **Step 3: Implement repository-qualified serialization.** Keys are the complete `RepositoryScope`; public and Space repositories with the same DID do not share a gate.

```swift
public actor MutationCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var locked = Set<RepositoryScope>()
    private var waiters: [RepositoryScope: [Waiter]] = [:]

    public func withRepositoryWriteLock<T: Sendable>(
        scope: RepositoryScope,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(scope)
        defer { release(scope) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ scope: RepositoryScope) async throws {
        if !locked.contains(scope) {
            locked.insert(scope)
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[scope, default: []].append(.init(
                        id: waiterID, continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, scope: scope) }
        }
    }

    private func cancelWaiter(_ id: UUID, scope: RepositoryScope) {
        guard let index = waiters[scope]?.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters[scope]!.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ scope: RepositoryScope) {
        if !waiters[scope, default: []].isEmpty {
            let waiter = waiters[scope]!.removeFirst()
            waiter.continuation.resume()
        } else {
            locked.remove(scope)
        }
    }
}
```

The waiter ID and removal happen on the actor, so cancellation and release cannot resume the same continuation twice. `Task.checkCancellation()` runs after acquisition with the `defer` already installed; a cancellation racing with handoff releases the acquired gate without running the operation.

- [ ] **Step 4: Build the unified editor.** Show a schema-aware summary when a Lexicon is known and raw JSON for every record. The raw editor is authoritative, keeps unknown keys, displays the destination, defaults validation on, and makes bypass a one-use expert confirmation.

- [ ] **Step 5: Require a separate confirmation after preparation.** Present access class, account, repository/Space/writer, collection/rkey, original CID, current revision, human diff, raw diff, affected known blob references, and required scope. Public delete offers **Back Up First**; Space delete requires successful **Back Up First** before the destructive button appears.

- [ ] **Step 6: Add conflict and partial-outcome surfaces.** Public conflict presents Original, Edited, and Current Remote values with **Discard Draft**, **Copy Draft**, and **Start New Edit from Remote**. Space partial outcome states that the server may have committed, offers **Refetch Now**, and has no automatic Retry Write action.

- [ ] **Step 7: Wire toolbar, menus, and context menus through `BrowserCommands`.** Eligibility requires exact account resolution, ownership, selected record, and service capability. Foreign public and Space-writer records expose copy/download/inspect but no hidden create/edit/delete command route.

- [ ] **Step 8: Run coordinator, mutation, and build checks.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/MutationCoordinatorTests -only-testing:ATProtoDriveTests/PublicMutationServiceTests -only-testing:ATProtoDriveTests/SpaceMutationServiceTests && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: PASS and `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: add confirmed mutation workflow"
jj new
```

---

### Task 9: Implement owner-only Space policy and member administration

**Files:**
- Create: `ATProtoDrive/Spaces/SpaceAdministrationService.swift`
- Create: `ATProtoDrive/Spaces/SpaceAdministrationStore.swift`
- Modify: `ATProtoDrive/Spaces/SpaceModels.swift`
- Modify: `ATProtoDrive/Write/CreateSpaceSheet.swift`
- Modify: `ATProtoDrive/Write/MemberEditor.swift`
- Create: `ATProtoDriveTests/SpaceAdministrationServiceTests.swift`
- Modify: `ATProtoDriveTests/WritePipelineTests.swift`

**Interfaces:**
- Consumes: Task 4 `.createSpace` and `.manageSpace` access contexts; Task 1 Space domain values, `SpaceProtocolCapabilities`, and authority-host `getSpace` route; Petrel simple-space generated types.
- Produces: `SpaceAdministrationServing`, live `SpaceAdministrationService`, `SpaceAdministrationStore`, exact owner checks, accurately named access policy, complete/incomplete member pagination, typed warnings, and verified create/update/member results.

- [ ] **Step 1: Write failing owner/grant/pagination tests.** Create uses `manage=create`; policy and add/remove member use `manage=update`; delete uses `manage=delete`. Test that authority mismatch prevents the transport call.

```swift
@Test("member changes require manage update, never record update")
func memberScopeAndOwnership() async throws {
    let transport = SpaceAdministrationTransportSpy()
    let service = SpaceAdministrationService(
        accountDID: "did:plc:owner",
        transport: transport
    )
    let space = try SpaceRef(
        uriString: "at://did:plc:owner/space/app.example.drive/main"
    )
    let preparation = try service.prepareAddMember(
        space: space,
        memberDID: "did:plc:bob"
    )
    #expect(preparation.requiredAccess == .manageSpace(space: space, action: .update))
    #expect(try AuthorizationScopePlanner().requiredScope(for: preparation.requiredAccess)
        .contains("manage=update"))
}

@Test("foreign authority cannot be administered")
func foreignAuthorityFailsBeforeTransport() async {
    let transport = SpaceAdministrationTransportSpy()
    let service = SpaceAdministrationService(
        accountDID: "did:plc:alice",
        transport: transport
    )
    let foreign = try! SpaceRef(
        uriString: "at://did:plc:owner/space/app.example.drive/main"
    )
    await #expect(throws: SpaceAdministrationError.notAuthority) {
        try await service.updatePolicy(space: foreign, policy: .memberList)
    }
    #expect(await transport.callCount == 0)
}

@Test("member cursor cycle remains visibly incomplete")
@MainActor
func memberCursorCycleIsNotSuccess() async {
    let service = ScriptedAdministrationService(memberPages: [
        nil: .init(memberDIDs: ["did:plc:alice"], cursor: "same"),
        "same": .init(memberDIDs: ["did:plc:bob"], cursor: "same")
    ])
    let store = SpaceAdministrationStore(service: service)
    await store.refresh(space: .fixtureSpaceRef)
    let snapshot = try! #require(store.loadState.snapshot)
    #expect(snapshot.memberDIDs == ["did:plc:alice", "did:plc:bob"])
    #expect(snapshot.membersComplete == false)
    #expect(snapshot.warning == .memberCursorCycle(cursor: "same"))
}
```

- [ ] **Step 2: Run the focused test and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceAdministrationServiceTests
```

Expected: FAIL because the administration service is not separated from views/models.

- [ ] **Step 3: Implement exact Petrel calls and normalize their outputs.**

```swift
let create = ComAtprotoSimplespaceCreateSpace.Input(
    type: try NSID(nsidString: draft.spaceType),
    skey: try draft.recordKey.map { try RecordKey(keyString: $0) },
    policy: draft.policy.createInputUnion,
    appAccess: draft.appAccess.createInputUnion
)
let update = ComAtprotoSimplespaceUpdateSpace.Input(
    space: space,
    policy: policy?.updateInputUnion,
    appAccess: appAccess?.updateInputUnion
)
let add = ComAtprotoSimplespaceAddMember.Input(
    space: space,
    did: try DID(didString: memberDID)
)
```

The live transport uses the generated methods without a generic "admin" endpoint:

```swift
client.com.atproto.simplespace.createSpace(input: create)
client.com.atproto.simplespace.updateSpace(input: update)
client.com.atproto.simplespace.listMembers(
    input: .init(space: space, limit: 100, cursor: cursor)
)
client.com.atproto.simplespace.addMember(input: add)
client.com.atproto.simplespace.removeMember(
    input: .init(space: space, did: try DID(didString: memberDID))
)
client.com.atproto.simplespace.deleteSpace(input: .init(space: space))
```

Use Task 1's authority-host credential route for `getSpace(space:)` after create/update; do not send a manually opened/foreign Space description to the account PDS. After add/remove, fully paginate `listMembers(space:limit:cursor:)` and verify the DID is present/absent. Preserve `.unexpected` union values as raw JSON and disable unsupported edits without disabling browsing. Require the relevant method in `SpaceProtocolCapabilities`; an unsupported profile produces `.unsupportedProfile(identifier:)` and disables only that action, with no legacy or public fallback.

Map the simple-space public policy union to `SpacePolicy.publicAccess`, not “public write.” Replace all existing labels/help text that say members or anyone “can write records” with: **“Anyone allowed by this Space policy may request read access. Record creation and changes still require a separate record action grant.”** Member-list policy copy similarly describes access/credential eligibility rather than write authority.

- [ ] **Step 4: Implement `SpaceAdministrationStore` with canonical generic load state.** Its sole public state is `LoadState<SpaceAdministrationSnapshot>`. Refresh begins with `.loading(previous: loadState.snapshot)`; success publishes `.loaded(snapshot)`; failure publishes `.failed(previous: prior, failure: normalizedFailure)`. A failed refresh therefore leaves prior policy and members visible under a stale banner. Stable-deduplicate DIDs with an insertion-ordered `Set` loop. Only a terminal nil/empty cursor sets `membersComplete = true` and `warning = nil`; a repeated cursor keeps received members, sets `membersComplete = false`, and publishes `.memberCursorCycle(cursor:)`. A page failure with partial members publishes `.partialMembers(message:)`. The UI shows these warnings next to the count and never labels an incomplete list “All Members.”

- [ ] **Step 5: Migrate create/member sheets to stores.** Views collect input and display preparation/confirmation only; they never call `account.client.com.atproto.simplespace` directly. Creating a Space with a server-generated key shows the returned canonical URI before navigation.

- [ ] **Step 6: Run new and migrated write suites.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceAdministrationServiceTests -only-testing:ATProtoDriveTests/WritePipelineTests
```

Expected: PASS for policy union preservation, member pagination, exact management grants, owner rejection, and post-mutation verification.

- [ ] **Step 7: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: add scoped Space administration"
jj new
```

---

### Task 10: Gate destructive Space deletion, clean active state, and finish administration UX

**Files:**
- Modify: `ATProtoDrive/Spaces/SpaceDeletionSafety.swift`
- Create: `ATProtoDrive/Spaces/SpaceAdministrationView.swift`
- Modify: `ATProtoDrive/Spaces/SpaceAdministrationService.swift`
- Modify: `ATProtoDrive/Spaces/SpaceAdministrationStore.swift`
- Modify: `ATProtoDrive/Spaces/SpaceBrowserView.swift`
- Modify: `ATProtoDrive/Spaces/SpaceRepositoryStore.swift`
- Modify: `ATProtoDrive/Spaces/SpaceListModel.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Cross-plan integration owner only: `ATProtoDrive/ATProtoDriveApp.swift`
- Create: `ATProtoDriveTests/SpaceDeletionSafetyTests.swift`
- Modify: `ATProtoDriveTests/SpaceAdministrationServiceTests.swift`
- Modify: `ATProtoDriveTests/SpaceTestFixtures.swift`

**Interfaces:**
- Consumes: Task 9 administration service; Task 2's fully paged authority/writer reads; Task 7 `BackupPreflightProviding`, `BackupPreflightEvidence`, shared validator, and unavailable provider; current `SpaceCredentialManager.invalidate`; Plan 3 later supplies backup and blob/preview cleanup participants.
- Produces: `SpaceDeletionAuthoritySnapshotCollecting`, digest-bound and service-created `SpaceDeletionPreparation`, `SpaceActiveStateCleanup`, `SpaceDeletionResult`, persisted uncertain-submission tombstones and status probing, fail-closed whole-Space delete wiring until Plan 3, and full Space administration UI.

- [ ] **Step 1: Write failing deletion-safety tests.** Prove no remote delete without verified matching evidence, remote delete executes once, cleanup occurs only after 2xx, cleanup failures are reported as partial local outcomes, explicit backups are never cleanup targets, and authority mismatch prevents every call.

```swift
extension SpaceDeletionAuthoritySnapshot {
    static func fixture(observedAt: Date) -> Self {
        try! .validated(
            space: .fixtureSpaceRef,
            accountDID: "did:plc:owner",
            writers: [.init(
                writerDID: "did:plc:alice",
                authorityRevision: "3m4j2authority",
                authorityHashBase64: "BQYHCA==",
                observedRevision: "3m4j2writer",
                observedHashBase64: "AQIDBA=="
            )],
            fullyPaginated: true,
            observedAt: observedAt
        )
    }
}

@Test("Space deletion requires matching verified backup evidence")
func backupEvidenceMustMatch() async throws {
    let transport = SpaceAdministrationTransportSpy()
    let cleanup = SpaceCleanupSpy()
    let space = try SpaceRef(
        uriString: "at://did:plc:owner/space/app.example.drive/main"
    )
    let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = SpaceDeletionAuthoritySnapshot.fixture(observedAt: observedAt)
    let wrong = BackupPreflightEvidence(
        backupID: UUID(),
        subject: .space(
            spaceURI: space.uriString(),
            authorityBindingDigest: "sha256:" + String(repeating: "0", count: 64)
        ),
        accountDID: "did:plc:owner",
        completedAt: observedAt.addingTimeInterval(1),
        manifestDigest: "sha256:" + String(repeating: "a", count: 64),
        complete: true,
        verified: true
    )
    let provider = ScriptedBackupPreflightProvider(spaceEvidence: wrong)
    let service = SpaceAdministrationService(
        accountDID: "did:plc:owner",
        transport: transport,
        cleanup: cleanup,
        backupProvider: provider,
        authoritySnapshots: ScriptedSpaceDeletionAuthoritySnapshotCollector(
            snapshots: [snapshot]
        ),
        clock: FixedClock(now: observedAt.addingTimeInterval(2))
    )

    await #expect(throws: SpaceDeletionError.backupRequired) {
        try await service.prepareSpaceDeletion(space: space)
    }
    #expect(await transport.deleteCount == 0)
    #expect(await cleanup.callCount == 0)
}

@Test("remote success plus cleanup failure is a partial local outcome")
func cleanupFailureDoesNotRepeatRemoteDelete() async throws {
    let transport = SpaceAdministrationTransportSpy(deleteStatus: 200)
    let cleanup = SpaceCleanupSpy(failingParticipant: "preview-cache")
    let space = SpaceRef.fixtureSpaceRef
    let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = SpaceDeletionAuthoritySnapshot.fixture(observedAt: observedAt)
    let evidence = BackupPreflightEvidence(
        backupID: UUID(), subject: .space(
            spaceURI: space.uriString(),
            authorityBindingDigest: snapshot.bindingDigest
        ),
        accountDID: "did:plc:owner",
        completedAt: observedAt.addingTimeInterval(1),
        manifestDigest: "sha256:" + String(repeating: "a", count: 64),
        complete: true, verified: true
    )
    let service = makeService(
        transport, cleanup,
        backupProvider: ScriptedBackupPreflightProvider(spaceEvidence: evidence),
        authoritySnapshots: ScriptedSpaceDeletionAuthoritySnapshotCollector(
            snapshots: [snapshot, snapshot]
        ),
        clock: FixedClock(now: observedAt.addingTimeInterval(2))
    )
    let preparation = try await service.prepareSpaceDeletion(space: space)
    let result = try await service.deleteSpace(preparation)
    #expect(result.remoteOutcome == .confirmedDeleted)
    #expect(result.cleanupFailures == ["preview-cache"])
    #expect(await transport.deleteCount == 1)
}

@Test("transport failure after submission is uncertain and never auto-retried")
func uncertainRemoteOutcomeRequiresProbe() async throws {
    let transport = SpaceAdministrationTransportSpy(
        deleteFailureAfterSubmission: URLError(.networkConnectionLost)
    )
    let service = makeService(
        transport, SpaceCleanupSpy(),
        backupProvider: .verifiedSpaceFixture
    )
    let preparation = try await service.prepareSpaceDeletion(space: .fixtureSpaceRef)
    let first = try await service.deleteSpace(preparation)
    guard case let .uncertain(attemptID, _, _) = first.remoteOutcome else {
        Issue.record("Expected uncertain remote outcome")
        return
    }
    #expect(await transport.deleteCount == 1)
    #expect(await service.pendingAttempt(
        spaceURI: SpaceRef.fixtureSpaceRef.uriString()
    )?.id == attemptID)

    await #expect(throws: SpaceDeletionError.uncertainOutcomeRequiresProbe) {
        try await service.deleteSpace(preparation)
    }
    #expect(await transport.deleteCount == 1)
    let probe = try await service.probeDeletionStatus(space: .fixtureSpaceRef)
    #expect(probe == .presentRequiresFreshPreparation)
    #expect(await transport.deleteCount == 1)
}
```

`makeService`'s fixture default supplies two independently returned snapshots with the same binding digest, so the uncertain-outcome test also exercises last-moment re-enumeration. In the same suite, use an argument table for wrong account DID, `complete == false`, `verified == false`, malformed/whitespace manifest digest, `completedAt > clock.now`, backup completion before `snapshot.observedAt`, incomplete pagination, duplicate/missing writer observations, and a preparation aged 301 seconds; every row must fail before remote deletion and cleanup. Add change rows where the second full snapshot has (a) an added/removed authority writer, (b) a changed authority revision/hash, or (c) a changed observed writer revision/hash; all record two complete enumerations, one provider call, zero delete calls, and `.stalePreparation`. A repeated authority cursor or writer-PDS `RepoNotFound` fails during the first collection and records zero provider calls. Add a pre-submission transport failure row that creates no tombstone and an after-submission row that persists exactly one tombstone.

- [ ] **Step 2: Run the focused tests and verify failure.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceDeletionSafetyTests -only-testing:ATProtoDriveTests/SpaceAdministrationServiceTests
```

Expected: FAIL because deletion has no complete authority-snapshot collector, digest/freshness binding, or cleanup registry yet.

- [ ] **Step 3: Collect the complete authority binding, invoke the provider, and reject stale evidence.** Implement `SpaceDeletionAuthoritySnapshotCollector` over Task 1's service. For the exact Space/account it follows every authority-host `listRepos` cursor to a terminal nil/empty cursor, rejects repeats/failures/duplicate DIDs, and preserves each authority `revision` plus canonical `commitHashBase64`. It then resolves every claimed writer through Plan 1's writer-PDS resolver and calls writer-PDS `getLatestCommit`; only `.spaceSignedCommit(revision:hashBase64:)` is accepted. It builds `SpaceDeletionAuthoritySnapshot.validated(..., fullyPaginated: true, observedAt: clock.now)` only after all writers succeed.

```swift
public protocol SpaceDeletionAuthoritySnapshotCollecting: Sendable {
    func collect(
        space: SpaceRef,
        accountDID: String
    ) async throws -> SpaceDeletionAuthoritySnapshot
}
```

`SpaceAdministrationService.prepareSpaceDeletion(space:)` first collects that snapshot, then calls `backupProvider.backUpSpaceBeforeDeletion(space:accountDID:authoritySnapshot:)`, captures `preparedAt` after provider completion, validates all fields, and returns `SpaceDeletionPreparation`; callers cannot construct it outside the module and there is no evidence/snapshot argument overload. `deleteSpace(_:)` verifies the exact service account/Space, rejects a preparation older than 300 seconds, fully collects a second current snapshot, and requires its `bindingDigest` to equal the prepared snapshot before any delete transport call. It then validates the same bound evidence/preparation again at the current time. A content mismatch, incomplete second enumeration, missing writer, or expiry throws `.stalePreparation`; the user must start a new backup/review, and the service never automatically refreshes evidence or submits deletion.

`UnavailableBackupPreflightProvider` keeps preparation visibly blocked with **“Back Up First becomes available when the backup service is installed.”** Plan 3 replaces only the provider. Its implementation must create a manifest whose verified contents include the canonical Space metadata and every writer repository at the exact observed revision/hash, then return the same `authoritySnapshot.bindingDigest` plus that manifest's SHA-256 digest; it does not redefine evidence or weaken this validator.

- [ ] **Step 4: Implement ordered post-delete cleanup.** Participants are credential, Space recents/bookmarks, record store, blob cache, and temporary preview cache. Explicit backup storage cannot conform to the active-state cleanup protocol. Run all participants, collect failures, and never call `deleteSpace` again because cleanup failed.

```swift
public protocol SpaceActiveStateCleanupParticipating: Sendable {
    var participantID: String { get }
    func purgeActiveState(spaceURI: String, accountDID: String) async throws
}

public enum SpaceDeletionError: Error, Hashable, Sendable {
    case backupRequired
    case notAuthority
    case invalidPreparation
    case stalePreparation
    case uncertainOutcomeRequiresProbe
    case transport(String)
}

public enum SpaceRemoteDeletionOutcome: Hashable, Sendable {
    case confirmedDeleted
    case uncertain(attemptID: UUID, submittedAt: Date, message: String)
}

public enum SpaceDeletionProbeResult: Hashable, Sendable {
    case absentConfirmed
    case presentRequiresFreshPreparation
    case authorizationRequired
    case inconclusive(message: String)
}

public struct SpaceDeletionTransportFailure: Error, Hashable, Sendable {
    public let submissionMayHaveReachedServer: Bool
    public let message: String
}

public struct SpaceDeletionSubmissionTombstone: Hashable, Codable, Sendable {
    public let id: UUID
    public let spaceURI: String
    public let accountDID: String
    public let submittedAt: Date
}

public struct SpaceDeletionPreparation: Hashable, Sendable {
    public let id: UUID
    public let space: SpaceRef
    public let accountDID: String
    public let preparedAt: Date
    public let authoritySnapshot: SpaceDeletionAuthoritySnapshot
    public let backupEvidence: BackupPreflightEvidence

    // Internal: only SpaceAdministrationService may bind provider evidence.
    init(
        id: UUID,
        space: SpaceRef,
        accountDID: String,
        preparedAt: Date,
        authoritySnapshot: SpaceDeletionAuthoritySnapshot,
        backupEvidence: BackupPreflightEvidence
    ) {
        self.id = id
        self.space = space
        self.accountDID = accountDID
        self.preparedAt = preparedAt
        self.authoritySnapshot = authoritySnapshot
        self.backupEvidence = backupEvidence
    }
}

public protocol SpaceDeletionAttemptStoring: Sendable {
    func load(spaceURI: String, accountDID: String) async throws -> SpaceDeletionSubmissionTombstone?
    func save(_ tombstone: SpaceDeletionSubmissionTombstone) async throws
    func remove(spaceURI: String, accountDID: String) async throws
}

public struct SpaceDeletionResult: Hashable, Sendable {
    public let remoteOutcome: SpaceRemoteDeletionOutcome
    public let cleanupFailures: [String]
}
```

The live attempt store uses atomic JSON under Application Support, keyed by exact account DID plus canonical Space URI. Save the tombstone before exposing an uncertain result. A second `prepareSpaceDeletion` or `deleteSpace(_:)` for that key throws `.uncertainOutcomeRequiresProbe` without transport. `probeDeletionStatus` performs authority-host `getSpace`/credential checks only: declared `SpaceNotFound` yields `.absentConfirmed`; a present Space yields `.presentRequiresFreshPreparation`; authorization and transport failures remain distinct. Probing never calls `deleteSpace` and never turns a same-URI present Space into an automatic retry target.

The delete transport wraps failures with `SpaceDeletionTransportFailure`: validation/request-construction failures set `submissionMayHaveReachedServer = false` and may be retried after correction; failures after the request body begins transmission set it to `true` and produce the persisted uncertain outcome. Generic thrown errors are conservatively treated as possibly submitted once transport invocation starts.

- [ ] **Step 5: Build the owner administration view.** It shows current policy and app access, member table, Add/Remove Member, and policy edit only when `space.spaceDID == accountDID`. Each action shows its `manage=` grant before contextual reconsent.

- [ ] **Step 6: Implement the whole-Space deletion sequence and exact confirmation copy.** The first action is **Back Up First** and invokes `prepareSpaceDeletion(space:)`; retain the returned preparation only in the exact account/window review state. After verified evidence, require typing the Space key and show: **“Deleting this Space tells conforming syncers to discard synchronized copies. It does not erase writer-owned Space repository data, exports, backups, or copies retained by nonconforming apps.”** The destructive button names the canonical Space URI and invokes `deleteSpace(_:)` with that same service-created preparation.

- [ ] **Step 7: Present partial and uncertain outcomes accurately.** If remote deletion succeeds and one cleanup participant fails, remove the Space from active browsing, retain its explicit backup, show which local cache failed, and offer **Retry Local Cleanup** only. If transport fails after submission begins, do not run cleanup or mark the Space deleted; show **Deletion outcome unknown**, offer **Check Space Status**, and persist the tombstone across relaunch. If the probe finds a Space at the same URI, the UI may offer **Start a Fresh Deletion Review** only after refetching current metadata, obtaining a new verified backup, and repeating typed confirmation; it never labels that action Retry and never reuses the prior submission. Do not offer **Delete Space Again** in either partial state.

- [ ] **Step 8: Run deletion, administration, and build checks.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/SpaceDeletionSafetyTests -only-testing:ATProtoDriveTests/SpaceAdministrationServiceTests && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: PASS and build succeeds. With the unavailable provider, production delete is visibly blocked rather than bypassing backup; Plan 3's provider conformance enables it without changing the safety sequence.

- [ ] **Step 9: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "feat: gate and clean up Space deletion"
jj new
```

---

### Task 11: Remove legacy nested navigation and perform Spaces/CRUD acceptance

**Files:**
- Cross-plan integration owner only: `ATProtoDrive/ATProtoDriveApp.swift`
- Cross-plan integration owner only: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDrive/Browser/BrowserCommands.swift`
- Modify: `ATProtoDrive/Records/RecordListModel.swift`
- Modify to compatibility wrapper after call-site audit: `ATProtoDrive/Records/RecordTableView.swift`
- Modify to compatibility wrapper after call-site audit: `ATProtoDrive/Spaces/SpaceDetailView.swift`
- Modify to compatibility wrapper after call-site audit: `ATProtoDrive/Spaces/SidebarView.swift`
- Modify to compatibility wrapper after call-site audit: `ATProtoDrive/Write/RecordEditorSheet.swift`
- Modify: `ATProtoDriveTests/RecordListModelTests.swift`
- Modify: `ATProtoDriveTests/RecordListModelPipelineTests.swift`
- Modify: `ATProtoDriveTests/WritePipelineTests.swift`

**Interfaces:**
- Consumes: all prior tasks and Plan 1 shell.
- Produces: one Finder-like Space/record path, no direct mutation from views, no account fallback, no obsolete four-pane UI, and a current-state verification record for the parent v1 plan.

- [ ] **Step 1: Search for forbidden and legacy routes before deleting shims.**

Run:

```bash
rg -n "HSplitView|activeAccount\b|try\? await accountStore\.handleCallback" ATProtoDrive/Browser ATProtoDrive/Spaces ATProtoDrive/Records ATProtoDrive/Write ATProtoDrive/ATProtoDriveApp.swift
rg -n "client\.com\.atproto\.(repo|space|simplespace)\.(create|put|delete|apply|add|remove|update)" ATProtoDrive --glob '*View.swift'
rg -n "client\.com\.atproto\.(repo|space|simplespace)\.(create|put|delete|apply|add|remove|update)" ATProtoDrive/Write --glob '*.swift'
rg -n "deleteAccount|deactivate|updateEmail|updateHandle|appPassword|importRepo" ATProtoDrive ATProtoDriveTests
```

Expected before cleanup: legacy nested split/direct-call matches identify the remaining migration sites; prohibited account-operation matches are absent except negative tests or explanatory copy.

- [ ] **Step 2: Add or update failing negative command-routing tests before cleanup.** Assert foreign repos, unsupported Space profiles, missing reconsent, missing backup evidence, and deleted/tombstoned Spaces expose no mutation command. Assert account deletion/deactivation/import/migration commands are absent.

```swift
@Test("foreign Space writer has no mutation command")
func foreignWriterCommands() {
    let commands = BrowserCommandProjection(
        accountDID: "did:plc:alice",
        selection: .record(.fixtureSpace(writerDID: "did:plc:bob"))
    ).availableCommands
    #expect(!commands.contains(.newRecord))
    #expect(!commands.contains(.editRecord))
    #expect(!commands.contains(.deleteRecord))
}
```

- [ ] **Step 3: Run the focused routing/write tests and verify the red phase.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests/WritePipelineTests -only-testing:ATProtoDriveTests/RecordListModelPipelineTests
```

Expected: FAIL because legacy direct routes and capability-ineligible commands remain reachable before the final migration.

- [ ] **Step 4: Route every Space and record command through the new services/coordinator.** Resolve the account by the `accountDID` embedded in `BrowserSource`/`RepositoryScope`; never fall back to `activeAccount`. Feature workers provide the call-site audit and exact keep/remove manifest. The cross-plan integration owner applies root routing changes and project membership removals in this same task change. A legacy file that remains in a source phase must be a deprecated, inert wrapper with a named compatibility caller; otherwise the integration owner removes its source-phase/file reference after `rg` proves there are no production call sites.

- [ ] **Step 5: Run the full deterministic unit target.** Task 1 already moved all Space bookmark/recents tests to injected memory/temp persistence, and Task 4 already moved account tests to UUID-scoped preference suites plus an explicit live-OAuth environment gate. Verify both live variables are unset before this command; do not add a skip flag that could hide another AccountStore failure.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData -resultBundlePath /tmp/ATProtoDrive-SpacesCRUD-UnitTests.xcresult CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests
```

Expected: `** TEST SUCCEEDED **`; the one live OAuth test is explicitly disabled with **Set both live-test environment variables**, no browser opens, and no test writes a shared UserDefaults key or fixed `/tmp` fixture path.

- [ ] **Step 6: Build and launch the app.**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ATProtoDrive-SpacesCRUD-DerivedData CODE_SIGNING_ALLOWED=NO build
/usr/bin/open -n /tmp/ATProtoDrive-SpacesCRUD-DerivedData/Build/Products/Debug/ATProtoDrive.app
```

Expected: build succeeds and the app opens to the two-column Finder-like shell with an optional trailing inspector, not the legacy nested split view.

- [ ] **Step 7: Navigate deterministic fixture states and capture evidence for the parent plan.** At 1280×800 verify Space root, overview/policy, My Records, Whole Space writer list, collection table, inspector, public diff, public conflict, Space non-atomic warning, missing-backup gate, member management, and partial cleanup banner. Record screenshot paths; Plan 4 converts these flows to UI tests.

- [ ] **Step 8: Run live interoperability separately.** Against a current test account/profile, report each of `listSpaces`, manual Open Space URI, `getSpace`, fully paginated `listRepos`, own records, foreign writer credential routing, create/update/delete record, create/update/member/delete Space as **live**, **mocked**, **fixture**, **unsupported**, or **not run**. Do not treat compilation or generated-client availability as live proof. Do not perform destructive live operations outside designated disposable Space fixtures.

- [ ] **Step 9: Repeat the forbidden-route scan.**

Run:

```bash
rg -n "HSplitView|activeAccount\b|try\? await accountStore\.handleCallback" ATProtoDrive/Browser ATProtoDrive/Spaces ATProtoDrive/Records ATProtoDrive/Write ATProtoDrive/ATProtoDriveApp.swift
rg -n "client\.com\.atproto\.(repo|space|simplespace)\.(create|put|delete|apply|add|remove|update)" ATProtoDrive --glob '*View.swift'
rg -n "client\.com\.atproto\.(repo|space|simplespace)\.(create|put|delete|apply|add|remove|update)" ATProtoDrive/Write --glob '*.swift'
rg -n "deleteAccount|deactivate|updateEmail|updateHandle|appPassword|importRepo" ATProtoDrive ATProtoDriveTests
```

Expected after cleanup: no active browser/view `activeAccount`, silent callback, direct mutation, or nested split match; any remaining prohibited-account strings exist only in negative tests/documentation and are reviewed individually. Direct Petrel calls remain expected inside the concrete public/Space service transports and are not a scan failure.

- [ ] **Step 10: Seal the task.**

```bash
jj status
jj diff --summary
jj describe -m "refactor: complete Finder-like Spaces and safe CRUD"
jj new
```

---

## Coverage Checklist

- [ ] Public and permissioned services remain separate at type, endpoint, authorization, and cache boundaries.
- [ ] `listSpaces` is described as Spaces where the caller holds a writer repo, not reader membership; manual/recent read-only Space access remains available.
- [ ] Global **Open Space by URI** validates `SpaceRef`, requires an explicit account when multiple are connected, routes only that account's service/session, and atomically persists versioned account-qualified bookmarks/recents after a successful overview.
- [ ] Plan 1's `ResourceReference.swift` and `BrowserSession.swift` are extended in place; same-URI Space overview/selection state remains distinct across accounts and all exhaustive switches include `.space`.
- [ ] Space overview loads `getSpace` policy/app-access, and owner administration preserves unknown union values.
- [ ] Whole-Space browsing credential-routes fully paged `listRepos` to the authority's strict exact-ID/type/origin `#atproto_space_host` with no PDS fallback, then routes every repository read to that writer's own `#atproto_pds`.
- [ ] Every permissioned `RecordLocator`, row mapper, and fixture uses `SpaceRef.recordURI(authorDID:collection:recordKey:)` and the full seven-component Space record URI.
- [ ] Collections come from fully paged records or a verified CAR index; no `listCollections` call exists.
- [ ] My Records remains usable when whole-Space credential/writer enumeration is unavailable.
- [ ] Wildcard baseline access is exactly `action=read_self`; whole-Space credential exchange requires contextual `.spaceRead(space:)` with exact type/authority/skey and `action=read`.
- [ ] Record `action=` grants and Space `manage=` grants are generated and tested independently; omission cannot grant default writes.
- [ ] Reconsent is contextual, exact-account-bound, and returns to the selected operation.
- [ ] Public create/update/delete use `swapCommit`; update/delete also use `swapRecord`; conflicts include original, edited, and current remote values.
- [ ] Space create/update/delete enforce own writer DID, immediately preflight, state the non-atomic current-alpha race, submit once, and verify after submission.
- [ ] Space-record delete and whole-Space delete fail closed without matching complete/verified backup evidence; whole-Space proof binds a fresh fully paginated authority claim, every observed writer revision/hash, and the manifest digest, then revalidates the whole set before submission.
- [ ] Create validates collection NSID, optional record key, `$type`, object root, and ownership; generated keys are identified before submission.
- [ ] Raw JSON preserves unknown keys, `$type`, `$link`, `$bytes`, and blob-reference values.
- [ ] Public/Space batch operations reject cross-repository or cross-data-plane inputs; Space batch warning remains non-atomic externally.
- [ ] Writes serialize per complete `RepositoryScope`; independent repositories can progress concurrently.
- [ ] Mutations are never automatically retried after an uncertain outcome; the UI offers refetch and reports partial remote state.
- [ ] Policy/member/create/delete Space operations require owner authority and the correct management verb.
- [ ] Whole-Space delete confirmation explains compliant syncer cleanup and retained writer/export/backup/nonconforming copies.
- [ ] Successful deletion clears active credential/cache/preview state, preserves explicit backups, and reports local cleanup failure without repeating remote deletion.
- [ ] Foreign public repositories and foreign Space writers are read-only in toolbar, menu, context menu, keyboard command, and service layers.
- [ ] Loading failures preserve the last snapshot and expose retry/reconnect/reconsent instead of showing an empty success.
- [ ] Deterministic tests use injected memory/temp Space persistence and UUID-scoped account preferences; live OAuth is disabled unless both explicit environment variables are present.
- [ ] Unit tests pass, macOS build succeeds, the app launches, screenshots cover the redesigned states, and live Spaces evidence is labeled separately.

## Handoff

After this plan passes, execute `docs/superpowers/plans/2026-08-23-atprotodrive-v1-files-backups-transfers.md`. Plan 3 must:

1. Conform its verified backup service to `BackupPreflightProviding`, including `backUpSpaceBeforeDeletion(space:accountDID:authoritySnapshot:)`. Its manifest must cover the canonical Space metadata plus every writer repository at the supplied authority-claim and observed signed revision/hash set, return the exact `authoritySnapshot.bindingDigest` and a verified SHA-256 manifest digest, and enable the two **Back Up First** flows without weakening freshness/evidence matching.
2. Register Space blob-cache and qualified temporary-preview cleanup participants with `SpaceActiveStateCleanup`; it must not register explicit backup storage.
3. Use the same `RepositoryScope`, `RecordLocator`, mutation outcomes, and access-transition warnings for attachment and cross-source-copy jobs.
4. Preserve this plan's no-public-fallback rule for Space blobs and no-blind-retry rule for record commits.

Plan 4 then owns complete account-status presentation, deterministic UI fixtures, accessibility identifiers, UI automation, screenshots, and the final v1 requirement audit. It extends the account models defined here; it does not add prohibited account-administration controls.
