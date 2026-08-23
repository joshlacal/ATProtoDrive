# ATProtoDrive v1 Account Controls and Final Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish ATProtoDrive v1 with exact-DID account status, contextual OAuth reconnect/reconsent, safe remove-from-app behavior, read-only supported private app state, deterministic macOS UI automation, and requirement-by-requirement runtime acceptance evidence.

**Architecture:** `AccountStore` remains the app-scoped authority for account sessions and OAuth state, but delegates target validation, identifier resolution, fresh-client construction, restoration, callback completion, and local-authorization cleanup to injected collaborators. Requested scopes and reported grants remain distinct: persisted requests preserve reconnect continuity but never prove current authorization. Account status and private-state snapshots are keyed by exact DID (and provider where applicable), so one account can never overwrite another account's stale state. A debug-only `AppDependencies.fixture(_:)` graph supplies the same browser/service interfaces as production while fail-fast network and Keychain sentinels make accidental external I/O observable to XCUITest; signed OAuth/Keychain and live evidence remain separate gates.

**Tech Stack:** Swift 6, SwiftUI and Observation on macOS 15, AppKit/Quick Look integration supplied by Plans 1-3, Petrel OAuth/XRPC, SwanSpaces `SpaceRef`, Swift Testing for unit/service tests, XCTest/XCUITest for UI automation, Xcode 16 project and shared scheme, jj for version control.

**Spec:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`

**Dependencies:** Execute after `2026-08-23-atprotodrive-v1-public-browser.md`, `2026-08-23-atprotodrive-v1-spaces-crud.md`, and `2026-08-23-atprotodrive-v1-files-backups-transfers.md`. This plan consumes, without renaming, `AccessClassification`, `ResourceReference`, `RepositoryScope`, `RecordLocator`, `BlobLocator`, `BrowserSource`, `BrowserPath`, `BrowserItem`, `BrowserSession`, `LoadState`, `BrowserFailure`, `RepositoryTarget`, `ResolvedRepository`, `RepositoryDescription`, `RepositoryRecordPage`, `RecordOrigin`, `RecordRow`, `PublicRepositoryServing`, `PublicRepositoryService`, `PublicRepositoryStore`, `PublicRecordStore`, `SpaceRepositoryService`, `SpaceAdministrationService`, `MutationCoordinator`, `TransferQueue`, `TransferStore`, `RecordWriteAction`, `SpaceManagementAction`, `LoginIntent`, `AccessContext` (including `.spaceRead(space:)`), `AccountConnectionStatus`, `AuthenticationIssue`, and `AuthorizationScopePlanner`; it uses `SpaceRef` from SwanSpaces. Plan 4 adds only the audience-qualified private-RPC case to the canonical `AccessContext` declaration.

## Global Constraints

- Support macOS 15.0 and Swift 6.0; do not add a database or third-party UI dependency.
- Keep account sessions, services, status, and transfers app-scoped; keep `BrowserSession` selection, path, search, sort, history, and inspector state window-scoped.
- Resolve every authenticated operation from the explicit account DID. Never use `activeAccount`, `activeAccountID`, the first account, or a public-read client as a fallback.
- Keep anonymous public reads on `PublicRepositoryService`; an account connection is never required for public browsing.
- Treat Petrel's empty `getGrantedScopes(for:)` result as unknown for gateway/legacy or untracked sessions, not as proof of no permission. Show raw scopes and do not locally infer wildcard authorization.
- Retain the exact previously requested scopes when Petrel reports grants as unknown, but never display or evaluate those requested scopes as reported grants. Requested, reported, and capability-evaluation state are separate fields.
- Build a fresh Petrel `ATProtoClient` with a fresh `OAuthConfig(scope:)` for each reconnect/reconsent request; `OAuthConfig.scope` is immutable.
- Validate every raw OAuth target before client creation. SwanCore's `scopeNeeded` formatters do not validate target NSIDs, record keys, MIME types, or RPC audiences; use `SwanCore.AtprotoSyntax`, `SwanCore.ConcreteMime`, and `SpaceRef` first and fail without calling the OAuth driver.
- Separate Space record `action=` grants from Space administration `manage=` grants. Never let an administration grant satisfy record CRUD.
- `Server & Account` may expose only **Reconnect** and **Remove from ATProtoDrive**. Contextual reconsent is launched from the blocked operation, not as a third administration control.
- Do not add migration, restore/import, email, handle, password, app-password, deactivation, account deletion, provider-session enumeration, or hidden command/URL equivalents.
- `Remove from ATProtoDrive` must state that remote account data, Spaces, memberships, and explicit backups remain unchanged; do not swallow local cleanup failures.
- Private App State is named, capability-gated, and read-only. V1 supports `app.bsky.actor.getPreferences` and exposes no provider mutation protocol.
- Debug fixture mode is compiled only under `#if DEBUG`, disables Keychain/network access, derives its state directory from a caller-provided safe token inside the app's Application Support container, and cannot be activated in Release.
- The Xcode project uses manual groups and build phases. Give one integration worker exclusive ownership of `ATProtoDrive.xcodeproj/project.pbxproj` while adding all Plan 4 files and targets.
- `CODE_SIGNING_ALLOWED=NO` proves compilation and deterministic non-authenticated UI only. Keychain continuity, OAuth callbacks, reconnect, and live authenticated status require a normally signed development build and separate evidence.
- Each task ends by sealing only its reviewed paths with jj and immediately creating a fresh child via `jj new`; Git remains read-only.

---

## File Map

### Account and status production files

- Modify `ATProtoDrive/Accounts/AuthenticationModels.swift` — consume Plan 2's `LoginIntent`, `AccessContext` (including `.spaceRead(space:)`), `RecordWriteAction`, `SpaceManagementAction`, `AccountConnectionStatus`, and `AuthenticationIssue`; add only the audience-qualified private-RPC context.
- Modify `ATProtoDrive/Accounts/AuthorizationScopePlanner.swift` — extend Plan 2's SwanCore-backed canonical scope construction without introducing a parallel planner.
- Create `ATProtoDrive/Accounts/OAuthFlowDriver.swift` — Petrel client creation, CAB-to-public fallback, callback completion, and restoration seams.
- Create `ATProtoDrive/Accounts/AuthorizationTargetValidator.swift` — pre-OAuth NSID, record-key, concrete-MIME, Space, and RPC service-target validation.
- Create `ATProtoDrive/Accounts/AccountMetadataStore.swift` — injectable account-list metadata persistence backed by a named UserDefaults suite; Petrel remains the credential store.
- Modify `ATProtoDrive/Accounts/AccountStore.swift` — pending intent tracking, exact-DID completion, visible authentication issues, reconnect/reconsent, injected persistence/cleanup, and remove-from-app.
- Modify `ATProtoDrive/Accounts/AddAccountView.swift` — start `.add` intent and present failures through the shared issue surface.
- Create `ATProtoDrive/Accounts/AccountStatusModels.swift` — exact status snapshot and repository/session/Spaces state types.
- Create `ATProtoDrive/Accounts/AccountStatusService.swift` — Petrel transport adapter and exact-DID status aggregation.
- Create `ATProtoDrive/Accounts/AccountStatusStore.swift` — `LoadState<AccountStatusSnapshot>` projection retaining stale status.
- Create `ATProtoDrive/Accounts/SpacesAvailabilityProbe.swift` — exact-account alpha endpoint probe with typed unsupported/401/403/transport mapping.
- Create `ATProtoDrive/Accounts/AccountControlCatalog.swift` — closed two-action control catalog shared by the view and commands.
- Create `ATProtoDrive/Accounts/ServerAccountView.swift` — status presentation, reconnect, and remove confirmation.
- Create `ATProtoDrive/Accounts/AccountLocalDataCleaner.swift` — account-qualified transient cache, preview, recents, and Space credential cleanup that never touches backups.
- Create `ATProtoDrive/Accounts/AccountRemovalTombstone.swift` — durable idempotent removal progress and retry evidence.

### Private state production files

- Create `ATProtoDrive/PrivateState/PrivateStateModels.swift` — provider descriptor, availability, and immutable JSON document.
- Create `ATProtoDrive/PrivateState/PrivateStateService.swift` — read-only provider protocol and exact-account registry.
- Create `ATProtoDrive/PrivateState/BlueskyPreferencesService.swift` — `app.bsky.actor.getPreferences` adapter preserving unexpected union values.
- Create `ATProtoDrive/PrivateState/PrivateStateStore.swift` — stale-preserving observable load state.
- Create `ATProtoDrive/PrivateState/PrivateStateView.swift` — provider list, capability state, friendly summary, and raw JSON.

### Integration, fixture, and accessibility files

- Modify `ATProtoDrive/ATProtoDriveApp.swift` — app-scoped dependencies, callback delivery without `try?`, fixture selection, and commands.
- Modify `ATProtoDrive/Browser/ContentBrowserView.swift` — route `.account(did:destination:.serverAndAccount)` and `.account(did:destination:.privateAppState)` using the source's explicit account DID.
- Modify `ATProtoDrive/Browser/DriveSidebarView.swift` — show account connection status without turning it into navigation authority.
- Modify `ATProtoDrive/Browser/BrowserCommands.swift` — use the closed control catalog and omit prohibited actions.
- Modify `ATProtoDrive/Browser/BrowserSession.swift` — redirect only windows whose typed source requires a removed DID.
- Consume Plan 3 `ATProtoDrive/Transfers/TransferModels.swift` and `ATProtoDrive/Transfers/TransferQueue.swift` unchanged — its persisted `requiredAccountDIDs`, `TransferAccountParkingReceipt`, and cancellation-fenced `markAccountsUnavailable(_:)` are the account-removal handoff.
- Create `ATProtoDrive/Support/AccessibilityIdentifiers.swift` — stable identifiers for sidebar, tables, search, inspector, errors, Activity, account controls, and fixtures.
- Create `ATProtoDrive/Testing/DebugFixtureScenario.swift` — debug-only launch parsing.
- Create `ATProtoDrive/Testing/DebugFixtureRuntime.swift` — deterministic two-account/service/transfer data with network and Keychain traps.
- Create `ATProtoDrive/Testing/DebugOAuthCallbackReceiptRecorder.swift` — DEBUG-only redacted receipt proving which signed executable and PID handled a live callback.

### Tests and verification artifacts

- Modify `ATProtoDriveTests/AccountStoreTests.swift` — new intent/callback/removal behavior and environment-gated live OAuth test.
- Modify `ATProtoDriveTests/AuthorizationScopePlannerTests.swift`.
- Create `ATProtoDriveTests/AccountStatusServiceTests.swift`.
- Create `ATProtoDriveTests/AccountStatusStoreTests.swift`.
- Create `ATProtoDriveTests/SpacesAvailabilityProbeTests.swift`.
- Create `ATProtoDriveTests/PrivateStateServiceTests.swift`.
- Create `ATProtoDriveTests/AccountControlCatalogTests.swift`.
- Create `ATProtoDriveTests/AccountPlanTestSupport.swift` — injected OAuth/status/private-state doubles and exact account/snapshot fixtures used by Tasks 2-5.
- Create `ATProtoDriveTests/IsolatedTestEnvironment.swift`.
- Create `ATProtoDriveTests/AppDependenciesTests.swift`.
- Modify `ATProtoDriveTests/BrowserSessionTests.swift`.
- Modify `ATProtoDriveTests/TransferPersistenceTests.swift`.
- Modify `ATProtoDriveTests/TransferQueueTests.swift`.
- Modify `ATProtoDriveTests/BackupManifestTests.swift`.
- Modify `ATProtoDriveTests/AtomicPackageWriterTests.swift`.
- Modify `ATProtoDriveTests/SecurityScopedBookmarkStoreTests.swift`.
- Modify `ATProtoDriveTests/BackupServiceTests.swift`.
- Modify `ATProtoDriveTests/BackupCatalogTests.swift`.
- Modify `ATProtoDriveTests/RepoVerifierTests.swift` — unique temporary directory and cleanup.
- Create `ATProtoDriveUITests/ATProtoDriveUITests.swift`.
- Create `ATProtoDriveUITests/ATProtoDriveUIAssertions.swift`.
- Modify `ATProtoDrive.xcodeproj/project.pbxproj` — add Plan 4 app/unit sources plus the UI-testing target, dependency, product, configurations, and manual source membership.
- Modify `ATProtoDrive.xcodeproj/xcshareddata/xcschemes/ATProtoDrive.xcscheme` — add `ATProtoDriveUITests` as a testable.
- Create `docs/superpowers/verification/2026-08-23-atprotodrive-v1-acceptance.md` — current-worktree evidence matrix and requirement audit.

---

### Task 1: Verify Plan 2 whole-Space authorization and add private RPC

**Files:**
- Modify: `ATProtoDrive/Accounts/AuthenticationModels.swift`
- Modify: `ATProtoDrive/Accounts/AuthorizationScopePlanner.swift`
- Create: `ATProtoDrive/Accounts/AuthorizationTargetValidator.swift`
- Modify: `ATProtoDriveTests/AuthorizationScopePlannerTests.swift`

**Interfaces:**
- Consumes: Plan 2's exact `RecordWriteAction`, `SpaceManagementAction`, `AccessContext.publicRecord`, `.blobUpload`, `.spaceRecord`, `.spaceRead`, `.createSpace`, `.manageSpace`, `LoginIntent`, `AccountConnectionStatus`, `AuthenticationIssue`, and SwanCore-backed `AuthorizationScopePlanner`.
- Produces: only the `AccessContext.privateAppState(method:serviceDID:)` addition, its canonical `AuthorizationScopePlanner.requiredScope(for:)` arm, `authorizationScope(previouslyRequested:reportedGranted:adding:)`, and `AuthorizationTargetValidator.validate(context:recordKey:)`. The `.spaceRead(space:)` case and its whole-Space scope arm remain Plan 2 outputs under verification here; this plan does not introduce a second action enum or scope planner.

- [ ] **Step 1: Add failing exact-scope tests to the existing planner suite**

```swift
import SwanSpaces
import Testing
@testable import ATProtoDrive

@Test("base connection allows discovery and own writer reads without write or manage")
func baseConnectionIsReadSelf() throws {
    let scope = try AuthorizationScopePlanner().baseScope
    #expect(scope == "atproto space:*?authority=*&skey=*&action=read_self")
    #expect(!scope.contains("action=create"))
    #expect(!scope.contains("manage="))
}

@Test("specific-Space read can be exchanged for a whole-Space credential")
func wholeSpaceRead() throws {
    let space = try SpaceRef(
        uriString: "at://did:plc:alice/space/app.example.drive/team"
    )
    let permission = try AuthorizationScopePlanner().requiredScope(
        for: .spaceRead(space: space)
    )

    #expect(permission == "space:app.example.drive?authority=did:plc:alice&skey=team&action=read")
    #expect(try permission != AuthorizationScopePlanner().baseScope)
    #expect(!permission.contains("collection="))
    #expect(!permission.contains("manage="))
}

@Test("private provider RPC scope carries the exact service audience")
func privateProviderAudience() throws {
    let permission = try AuthorizationScopePlanner().requiredScope(
        for: .privateAppState(
            method: "app.bsky.actor.getPreferences",
            serviceDID: "did:web:api.bsky.app#bsky_appview"
        )
    )

    #expect(permission == "rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23bsky_appview")
}

@Test("existing record and administration cases remain disjoint")
func existingCasesRemainDisjoint() throws {
    let space = try SpaceRef(
        uriString: "at://did:plc:alice/space/app.example.drive/team"
    )
    let record = try AuthorizationScopePlanner().requiredScope(for: .spaceRecord(
        space: space,
        collection: "app.example.file",
        action: .update
    ))
    let administration = try AuthorizationScopePlanner().requiredScope(for: .manageSpace(
        space: space,
        action: .update
    ))

    #expect(record.contains("action=update"))
    #expect(!record.contains("manage="))
    #expect(administration.contains("manage=update"))
    #expect(!administration.contains("collection="))
}

@Test("reconsent retains requested scopes when reported grants are unknown")
func retainedScopes() throws {
    let result = try AuthorizationScopePlanner().authorizationScope(
        previouslyRequested: "atproto repo:app.example.note?action=create",
        reportedGranted: [],
        adding: .blobUpload(mimeType: "application/pdf")
    )
    #expect(result == "atproto blob:application/pdf repo:app.example.note?action=create space:*?authority=*&skey=*&action=read_self")
}

@Test("OAuth targets are validated before scope formatting")
func rawTargetsFailClosed() throws {
    let validator = AuthorizationTargetValidator()
    let validSpace = try SpaceRef(
        uriString: "at://did:plc:alice/space/app.example.drive/team"
    )

    #expect(throws: AuthorizationTargetError.invalidCollectionNSID) {
        try validator.validate(
            context: .publicRecord(collection: "not an nsid", action: .update),
            recordKey: "note1"
        )
    }
    #expect(throws: AuthorizationTargetError.invalidRecordKey) {
        try validator.validate(
            context: .spaceRecord(
                space: validSpace,
                collection: "app.example.note",
                action: .delete
            ),
            recordKey: "../note"
        )
    }
    #expect(throws: AuthorizationTargetError.missingRecordKey) {
        try validator.validate(
            context: .publicRecord(collection: "app.example.note", action: .update),
            recordKey: nil
        )
    }
    #expect(throws: AuthorizationTargetError.invalidConcreteMIME) {
        try validator.validate(context: .blobUpload(mimeType: "image/*"), recordKey: nil)
    }
    #expect(throws: AuthorizationTargetError.invalidRPCMethod) {
        try validator.validate(
            context: .privateAppState(
                method: "not-an-nsid",
                serviceDID: "did:web:api.bsky.app#bsky_appview"
            ),
            recordKey: nil
        )
    }
    #expect(throws: AuthorizationTargetError.invalidRPCServiceDID) {
        try validator.validate(
            context: .privateAppState(
                method: "app.bsky.actor.getPreferences",
                serviceDID: "did:web:api.bsky.app"
            ),
            recordKey: nil
        )
    }
}
```

- [ ] **Step 2: Run the existing authorization suite and verify the two new cases are missing**

Run:

```bash
PLAN4_DERIVED="$(mktemp -d /tmp/atprotodrive-plan4-task1.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
  test -only-testing:ATProtoDriveTests/AuthorizationScopePlannerTests
```

Expected: FAIL because `AccessContext.privateAppState`, `AuthorizationTargetValidator`, and `authorizationScope(previouslyRequested:reportedGranted:adding:)` are absent. Plan 2's `.spaceRead(space:)` test must already compile and pass; stop and repair the Plan 2 dependency if it does not.

- [ ] **Step 3: Add only private app state to the canonical enum and planner**

Swift enum cases cannot be added in an extension. Modify the canonical `AccessContext` declaration in `AuthenticationModels.swift` itself, preserve every Plan 2 case including `.spaceRead(space:)` unchanged, and add only the final private-app-state case shown here:

```swift
public enum AccessContext: Hashable, Sendable {
    case publicRecord(collection: String, action: RecordWriteAction)
    case blobUpload(mimeType: String)
    case spaceRead(space: SpaceRef)
    case spaceRecord(space: SpaceRef, collection: String, action: RecordWriteAction)
    case createSpace(spaceType: String, requestedSKey: String?)
    case manageSpace(space: SpaceRef, action: SpaceManagementAction)
    case privateAppState(method: String, serviceDID: String)
}
```

Do not reimplement or move Plan 2's `.spaceRead` arm. Extend the canonical `AuthorizationScopePlanner.requiredScope(for:)` switch only with the private-RPC arm, using the SwanCore formatter rather than an interpolated query string:

```swift
case let .privateAppState(method, serviceDID):
    return try SwanCore.RpcPermission.scopeNeeded(for: .init(
        lxm: method,
        aud: serviceDID
    ))
```

Add this union operation to the same planner. `previouslyRequested` is continuity metadata, `reportedGranted` is the provider's current report, and callers must keep the latter's known/unknown bit separately:

```swift
public func authorizationScope(
    previouslyRequested: String,
    reportedGranted: Set<String>,
    adding context: AccessContext?
) throws -> String {
    var scopes = Set(previouslyRequested.split(whereSeparator: \.isWhitespace).map(String.init))
    scopes.formUnion(reportedGranted)
    scopes.formUnion(try baseScope.split(separator: " ").map(String.init))
    if let context {
        scopes.insert(try requiredScope(for: context))
    }
    scopes.remove("atproto")
    return (["atproto"] + scopes.sorted()).joined(separator: " ")
}
```

Retain Plan 2's base scope of `atproto space:*?authority=*&skey=*&action=read_self`. Verify that its `.spaceRead` remains contextual to **Whole Space** and exchanges only the exact Space credential; Plan 4 neither adds nor broadens that case.

`scopeNeeded` is a canonical formatter, not target validation. Add this explicit OAuth-boundary guard:

```swift
public enum AuthorizationTargetError: Error, Equatable, Sendable {
    case invalidCollectionNSID
    case missingRecordKey
    case invalidRecordKey
    case invalidConcreteMIME
    case invalidSpace
    case invalidSpaceType
    case invalidSpaceKey
    case invalidRPCMethod
    case invalidRPCServiceDID
}

public struct AuthorizationTargetValidator: Sendable {
    public func validate(context: AccessContext, recordKey: String?) throws {
        switch context {
        case let .publicRecord(collection, action):
            try validateRecord(collection: collection, action: action, recordKey: recordKey)
        case let .spaceRecord(space, collection, action):
            guard SwanCore.AtprotoSyntax.isValidNSID(space.spaceType),
                  SwanCore.AtprotoSyntax.isValidDID(space.spaceDID),
                  SwanCore.AtprotoSyntax.isValidRecordKey(space.skey) else {
                throw AuthorizationTargetError.invalidSpace
            }
            try validateRecord(collection: collection, action: action, recordKey: recordKey)
        case let .spaceRead(space), let .manageSpace(space, _):
            guard SwanCore.AtprotoSyntax.isValidNSID(space.spaceType),
                  SwanCore.AtprotoSyntax.isValidDID(space.spaceDID),
                  SwanCore.AtprotoSyntax.isValidRecordKey(space.skey) else {
                throw AuthorizationTargetError.invalidSpace
            }
        case let .createSpace(spaceType, requestedSKey):
            guard SwanCore.AtprotoSyntax.isValidNSID(spaceType) else {
                throw AuthorizationTargetError.invalidSpaceType
            }
            if let requestedSKey,
               !SwanCore.AtprotoSyntax.isValidRecordKey(requestedSKey) {
                throw AuthorizationTargetError.invalidSpaceKey
            }
        case let .blobUpload(mimeType):
            guard SwanCore.ConcreteMime(mimeType) != nil else {
                throw AuthorizationTargetError.invalidConcreteMIME
            }
        case let .privateAppState(method, serviceDID):
            guard SwanCore.AtprotoSyntax.isValidNSID(method) else {
                throw AuthorizationTargetError.invalidRPCMethod
            }
            guard SwanCore.AtprotoSyntax.isValidAtprotoDIDRefAbsolute(serviceDID) else {
                throw AuthorizationTargetError.invalidRPCServiceDID
            }
        }
    }

    private func validateRecord(
        collection: String,
        action: RecordWriteAction,
        recordKey: String?
    ) throws {
        guard SwanCore.AtprotoSyntax.isValidNSID(collection) else {
            throw AuthorizationTargetError.invalidCollectionNSID
        }
        if action != .create, recordKey == nil {
            throw AuthorizationTargetError.missingRecordKey
        }
        if let recordKey, !SwanCore.AtprotoSyntax.isValidRecordKey(recordKey) {
            throw AuthorizationTargetError.invalidRecordKey
        }
    }
}
```

The mutation coordinator passes the exact locator key for update/delete and the user-supplied optional key for create into `reconsent`. `AccountStore` calls this validator before identifier resolution or OAuth client creation. `.privateAppState` receives the exact account/provider service DID including its service fragment; only after the guard succeeds does SwanCore percent-encode it. Do not infer wildcard coverage from either raw reported grants or persisted requested scopes.

- [ ] **Step 4: Rerun authorization and mutation regression tests**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:ATProtoDriveTests/AuthorizationScopePlannerTests \
  -only-testing:ATProtoDriveTests/MutationCoordinatorTests \
  -only-testing:ATProtoDriveTests/SpaceAdministrationServiceTests
```

Expected: PASS; public record, Space record, create-Space, manage-Space, and blob cases retain their Plan 2 names and semantics.

- [ ] **Step 5: Seal Task 1 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "feat: define contextual OAuth access scopes"
jj new
```

---

### Task 2: Refactor OAuth flow and AccountStore around intent and exact DID

**Files:**
- Create: `ATProtoDrive/Accounts/OAuthFlowDriver.swift`
- Create: `ATProtoDrive/Accounts/AccountMetadataStore.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Modify: `ATProtoDrive/Accounts/AddAccountView.swift`
- Modify: `ATProtoDrive/ATProtoDriveApp.swift`
- Modify: `ATProtoDriveTests/AccountStoreTests.swift`
- Create: `ATProtoDriveTests/AccountPlanTestSupport.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Plan 2's `LoginIntent`, `AccountConnectionStatus`, `AuthenticationIssue`, exact `AccessContext` cases, and Task 1's extended planner and validator.
- Produces: value-only `PersistedAccountMetadata`, versioned `AccountMetadataEnvelope`, injected `OAuthFlowDriver` with resolve/start/complete/restore/local-cleanup operations, `AccountStore.Account.requestedScope`, `restoreOnce()`, `beginLogin(handle:intent:)`, `reconnect(accountDID:)`, `reconsent(accountDID:context:recordKey:)`, nonthrowing `handleCallback(_:)`, and `dismissAuthenticationIssue()`. Pending logins carry intent, requested scope, exact expected DID, and their own Petrel client.

- [ ] **Step 1: Replace broad-scope assertions with failing exact-identifier, retained-scope, restore, migration, and callback-isolation tests**

```swift
@MainActor
@Suite("Account OAuth intent routing")
struct AccountOAuthIntentTests {
    @Test("reconsent pins identifier and expected DID and retains requested scope")
    func reconsentUsesExactDID() async throws {
        let aliceClient = await ATProtoClient(baseURL: URL(string: "https://alice-pds.example")!)
        let harness = OAuthFlowDriverHarness(client: aliceClient, grantedScopes: [])
        let metadata = InMemoryAccountMetadataStore()
        let store = AccountStore(oauthDriver: harness.driver, metadataStore: metadata)
        store.installAccountForTesting(
            did: "did:plc:alice",
            handle: "alice.example",
            client: aliceClient,
            authMode: .publicOAuth,
            requestedScope: "atproto repo:app.example.note?action=create space:*?authority=*&skey=*&action=read_self"
        )

        _ = try await store.reconsent(
            accountDID: "did:plc:alice",
            context: .publicRecord(collection: "app.example.note", action: .update),
            recordKey: "note1"
        )

        let request = try #require(await harness.requests.last)
        #expect(request.identifier == "did:plc:alice")
        #expect(request.expectedDID == "did:plc:alice")
        #expect(request.namespace == AccountStore.namespace(for: "did:plc:alice"))
        #expect(request.scope.contains("repo:app.example.note?action=create"))
        #expect(request.scope.contains("repo:app.example.note?action=update"))
        #expect(await harness.resolveInputs == [])
    }

    @Test("reconnect also uses DID as the OAuth identifier")
    func reconnectPinsIdentifier() async throws {
        let aliceClient = await ATProtoClient(baseURL: URL(string: "https://alice-pds.example")!)
        let harness = OAuthFlowDriverHarness(client: aliceClient)
        let store = AccountStore(
            oauthDriver: harness.driver,
            metadataStore: InMemoryAccountMetadataStore()
        )
        store.installAccountForTesting(
            did: "did:plc:alice", handle: "old-handle.example",
            client: aliceClient, authMode: .publicOAuth,
            requestedScope: try AuthorizationScopePlanner().baseScope
        )

        _ = try await store.reconnect(accountDID: "did:plc:alice")

        let request = try #require(await harness.requests.last)
        #expect(request.identifier == "did:plc:alice")
        #expect(request.expectedDID == "did:plc:alice")
        #expect(request.requestedHandle == "old-handle.example")
    }

    @Test("callback failure consumes only its state and preserves both accounts")
    func callbackFailureIsVisible() async throws {
        let aliceClient = await ATProtoClient(baseURL: URL(string: "https://alice-pds.example")!)
        let bobClient = await ATProtoClient(baseURL: URL(string: "https://bob-pds.example")!)
        let harness = OAuthFlowDriverHarness(client: aliceClient, outcome: .invalidCallback)
        let store = AccountStore(
            oauthDriver: harness.driver,
            metadataStore: InMemoryAccountMetadataStore()
        )
        store.installAccountForTesting(
            did: "did:plc:alice", handle: "alice.example", client: aliceClient,
            authMode: .publicOAuth, requestedScope: "atproto repo:app.example.note?action=create"
        )
        store.installAccountForTesting(
            did: "did:plc:bob", handle: "bob.example", client: bobClient,
            authMode: .cab, requestedScope: "atproto"
        )
        store.registerPendingFlowForTesting(
            state: "alice-state",
            client: aliceClient,
            expectedDID: "did:plc:alice",
            intent: .reconnect(accountDID: "did:plc:alice"),
            requestedScope: try AuthorizationScopePlanner().baseScope
        )
        store.registerPendingFlowForTesting(
            state: "bob-state", client: bobClient, expectedDID: "did:plc:bob",
            intent: .reconnect(accountDID: "did:plc:bob"), requestedScope: "atproto"
        )

        await store.handleCallback(
            URL(string: "blue.catbird.atprotodrive:/callback?state=alice-state&code=bad")!
        )

        #expect(store.authenticationIssue?.title == "Couldn’t reconnect account")
        #expect(store.authenticationIssue?.accountDID == "did:plc:alice")
        #expect(store.account(for: "did:plc:alice")?.client === aliceClient)
        #expect(store.account(for: "did:plc:alice")?.requestedScope.contains("action=create") == true)
        #expect(store.account(for: "did:plc:bob")?.client === bobClient)
        #expect(!store.hasPendingFlowForTesting(state: "alice-state"))
        #expect(store.hasPendingFlowForTesting(state: "bob-state"))
        #expect(await harness.discardedStates == ["alice-state"])
    }

    @Test("a callback for a different DID cannot replace Alice or Bob")
    func callbackDIDMismatch() async throws {
        let aliceClient = await ATProtoClient(baseURL: URL(string: "https://alice-pds.example")!)
        let bobClient = await ATProtoClient(baseURL: URL(string: "https://bob-pds.example")!)
        let harness = OAuthFlowDriverHarness(
            client: aliceClient,
            outcome: .completed(.init(
                did: "did:plc:bob",
                handle: "bob.example",
                pdsURL: URL(string: "https://bob-pds.example")!
            ))
        )
        let store = AccountStore(
            oauthDriver: harness.driver,
            metadataStore: InMemoryAccountMetadataStore()
        )
        store.installAccountForTesting(
            did: "did:plc:alice", handle: "alice.example", client: aliceClient,
            authMode: .publicOAuth, requestedScope: "atproto repo:app.example.note?action=update"
        )
        store.installAccountForTesting(
            did: "did:plc:bob", handle: "bob.example", client: bobClient,
            authMode: .cab, requestedScope: "atproto"
        )
        store.registerPendingFlowForTesting(
            state: "alice-state",
            client: aliceClient,
            expectedDID: "did:plc:alice",
            intent: .reconnect(accountDID: "did:plc:alice"),
            requestedScope: try AuthorizationScopePlanner().baseScope
        )
        store.registerPendingFlowForTesting(
            state: "unrelated-state", client: bobClient, expectedDID: "did:plc:bob",
            intent: .reconnect(accountDID: "did:plc:bob"), requestedScope: "atproto"
        )

        await store.handleCallback(
            URL(string: "blue.catbird.atprotodrive:/callback?state=alice-state&code=ok")!
        )

        #expect(store.account(for: "did:plc:alice")?.client === aliceClient)
        #expect(store.account(for: "did:plc:bob")?.client === bobClient)
        #expect(store.account(for: "did:plc:alice")?.requestedScope.contains("action=update") == true)
        #expect(!store.hasPendingFlowForTesting(state: "alice-state"))
        #expect(store.hasPendingFlowForTesting(state: "unrelated-state"))
        #expect(await harness.discardedStates == ["alice-state"])
        #expect(store.authenticationIssue?.message.contains("different account") == true)
    }

    @Test("legacy metadata is migrated to the narrow base scope before restore")
    func metadataMigration() async throws {
        let metadata = InMemoryAccountMetadataStore(
            legacy: [.init(id: "did:plc:alice", handle: "alice.example", authMode: .publicOAuth)]
        )
        let client = await ATProtoClient(baseURL: URL(string: "https://alice-pds.example")!)
        let harness = OAuthFlowDriverHarness(client: client)
        let store = AccountStore(oauthDriver: harness.driver, metadataStore: metadata)

        await store.restoreOnce()

        let migrated = try #require(metadata.savedEnvelope?.accounts.first)
        #expect(migrated.id == "did:plc:alice")
        #expect(migrated.requestedScope == try AuthorizationScopePlanner().baseScope)
        #expect(await harness.restoredMetadata.first?.requestedScope == migrated.requestedScope)
    }

    @Test("invalid raw target reaches neither resolver nor client factory")
    func invalidTargetStopsBeforeOAuth() async throws {
        let client = await ATProtoClient(baseURL: URL(string: "https://alice-pds.example")!)
        let harness = OAuthFlowDriverHarness(client: client)
        let store = AccountStore(
            oauthDriver: harness.driver,
            metadataStore: InMemoryAccountMetadataStore()
        )
        store.installAccountForTesting(
            did: "did:plc:alice", handle: "alice.example", client: client,
            authMode: .publicOAuth, requestedScope: "atproto"
        )

        await #expect(throws: AuthorizationTargetError.invalidConcreteMIME) {
            _ = try await store.reconsent(
                accountDID: "did:plc:alice",
                context: .blobUpload(mimeType: "image/*")
            )
        }
        #expect(await harness.resolveInputs.isEmpty)
        #expect(await harness.requests.isEmpty)
    }
}
```

Create the test harness with concrete closure coverage rather than a network fake. It records resolve/start/restore/local-cleanup independently, so fixture tests prove `AccountStore` never constructs a Petrel client itself:

```swift
actor OAuthFlowDriverHarness {
    enum Outcome: Sendable {
        case completed(CompletedOAuthFlow)
        case invalidCallback
    }

    enum HarnessError: Error { case invalidCallback }

    private let client: ATProtoClient
    private let outcome: Outcome
    private let reportedGrantedScopes: Set<String>
    private let cleanupReceipt: OAuthCleanupReceipt
    private(set) var requests: [OAuthFlowRequest] = []
    private(set) var resolveInputs: [String] = []
    private(set) var restoredMetadata: [PersistedAccountMetadata] = []
    private(set) var discardedStates: [String] = []
    private(set) var cleanupDIDs: [String] = []

    init(
        client: ATProtoClient,
        outcome: Outcome? = nil,
        grantedScopes: Set<String> = ["atproto"],
        cleanupReceipt: OAuthCleanupReceipt = .init(
            localCredentialStateRemoved: true,
            providerRevocationConfirmed: nil
        )
    ) {
        self.client = client
        self.reportedGrantedScopes = grantedScopes
        self.cleanupReceipt = cleanupReceipt
        self.outcome = outcome ?? .completed(.init(
            did: "did:plc:alice",
            handle: "alice.example",
            pdsURL: URL(string: "https://alice-pds.example")!
        ))
    }

    nonisolated var driver: OAuthFlowDriver {
        OAuthFlowDriver(
            resolve: { identifier in try await self.resolve(identifier) },
            start: { request in try await self.start(request) },
            complete: { started, callback in
                try await self.complete(started: started, callback: callback)
            },
            restore: { metadata in try await self.restore(metadata) },
            reportedGrantedScopes: { did in await self.grantedScopes(did) },
            discardPendingAuthorization: { started in
                try await self.discard(started)
            },
            removeLocalAuthorization: { account in try await self.cleanup(account) }
        )
    }

    private func resolve(_ identifier: String) throws -> ResolvedLoginIdentifier {
        resolveInputs.append(identifier)
        return .init(
            input: identifier, did: "did:plc:alice", handle: "alice.example",
            pdsURL: URL(string: "https://alice-pds.example")!
        )
    }

    private func start(_ request: OAuthFlowRequest) throws -> StartedOAuthFlow {
        requests.append(request)
        return StartedOAuthFlow(
            client: client,
            authorizationURL: URL(string: "https://auth.example/authorize")!,
            state: "state",
            authMode: .publicOAuth
        )
    }

    private func complete(
        started: StartedOAuthFlow,
        callback: URL
    ) throws -> CompletedOAuthFlow {
        switch outcome {
        case let .completed(completion): return completion
        case .invalidCallback: throw HarnessError.invalidCallback
        }
    }

    private func restore(_ metadata: PersistedAccountMetadata) throws -> RestoredOAuthAccount? {
        restoredMetadata.append(metadata)
        return nil
    }

    private func grantedScopes(_ did: String) -> Set<String> {
        reportedGrantedScopes
    }

    private func discard(_ started: StartedOAuthFlow) throws {
        discardedStates.append(started.state)
    }

    private func cleanup(_ account: AccountStore.Account) throws -> OAuthCleanupReceipt {
        cleanupDIDs.append(account.id)
        return cleanupReceipt
    }
}

extension OAuthFlowDriverHarness {
    static func cleanupAlwaysSucceeds() async -> OAuthFlowDriverHarness {
        let client = await ATProtoClient(
            baseURL: URL(string: "atproto-fixture://oauth-cleanup")!
        )
        return OAuthFlowDriverHarness(client: client)
    }

    static func partialCleanup(
        _ receipt: OAuthCleanupReceipt
    ) async -> OAuthFlowDriverHarness {
        let client = await ATProtoClient(
            baseURL: URL(string: "atproto-fixture://oauth-cleanup")!
        )
        return OAuthFlowDriverHarness(client: client, cleanupReceipt: receipt)
    }
}

enum AccountPlanFixtureError: Error { case unexpectedOAuth(String) }

extension OAuthFlowDriver {
    /// Offline default for tests that exercise no OAuth operation.
    static func fixture() -> Self {
        .init(
            resolve: { _ in throw AccountPlanFixtureError.unexpectedOAuth("resolve") },
            start: { _ in throw AccountPlanFixtureError.unexpectedOAuth("start") },
            complete: { _, _ in throw AccountPlanFixtureError.unexpectedOAuth("callback") },
            restore: { _ in nil },
            reportedGrantedScopes: { _ in [] },
            discardPendingAuthorization: { _ in },
            removeLocalAuthorization: { _ in
                .init(localCredentialStateRemoved: true, providerRevocationConfirmed: nil)
            }
        )
    }
}

@MainActor
final class InMemoryAccountMetadataStore: AccountMetadataStoring {
    private(set) var savedEnvelope: AccountMetadataEnvelope?
    private let legacy: [LegacyPersistedAccountMetadata]?

    init(
        envelope: AccountMetadataEnvelope? = nil,
        legacy: [LegacyPersistedAccountMetadata]? = nil
    ) {
        self.savedEnvelope = envelope
        self.legacy = legacy
    }

    func load(baseScope: String) throws -> AccountMetadataEnvelope {
        if let savedEnvelope { return savedEnvelope }
        let migrated = AccountMetadataEnvelope(
            formatVersion: 2,
            accounts: (legacy ?? []).map {
                PersistedAccountMetadata(
                    id: $0.id, handle: $0.handle,
                    authMode: $0.authMode, requestedScope: baseScope
                )
            }
        )
        try save(migrated)
        return migrated
    }

    func save(_ envelope: AccountMetadataEnvelope) throws {
        savedEnvelope = envelope
    }
}
```

Under `#if DEBUG`, add only the exact AccountStore test hooks used above: `installAccountForTesting`, `addAccountForTesting`, `registerPendingFlowForTesting`, `hasPendingFlowForTesting(state:)`, and `metadataForTesting()`. `installAccountForTesting` constructs the account's `SpaceCredentialManager` from the supplied client; `registerPendingFlowForTesting` creates the same `PendingLogin` shape as production. None performs persistence, Keychain access, OAuth discovery, or a network call.

- [ ] **Step 2: Run unit tests and verify the new initializer and APIs are absent**

Run:

```bash
PLAN4_DERIVED="$(mktemp -d /tmp/atprotodrive-plan4-task2.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
  test -only-testing:ATProtoDriveTests
```

Expected: FAIL because the expanded OAuth driver, metadata envelope/migration, injected store initializer, requested-scope account field, and reconnect/reconsent APIs do not exist.

- [ ] **Step 3: Add complete OAuth and metadata seams; migrate the exact scope used for every client**

```swift
import Foundation
import Petrel

public struct ResolvedLoginIdentifier: Sendable, Equatable {
    public let input: String
    public let did: String
    public let handle: String
    public let pdsURL: URL
}

public struct OAuthFlowRequest: Sendable, Equatable {
    public let identifier: String
    public let expectedDID: String
    public let requestedHandle: String
    public let namespace: String
    public let scope: String
    public let pdsURL: URL
}

public struct StartedOAuthFlow: Sendable {
    public let client: ATProtoClient
    public let authorizationURL: URL
    public let state: String
    public let authMode: AccountStore.AuthModeType
}

public struct CompletedOAuthFlow: Sendable, Equatable {
    public let did: String
    public let handle: String
    public let pdsURL: URL
}

public struct RestoredOAuthAccount: Sendable {
    public let completion: CompletedOAuthFlow
    public let client: ATProtoClient
    public let authMode: AccountStore.AuthModeType
}

public struct OAuthClientFactory: Sendable {
    public var make: @Sendable (
        _ pdsURL: URL,
        _ namespace: String,
        _ scope: String,
        _ authMode: AccountStore.AuthModeType
    ) async throws -> ATProtoClient
}

public struct OAuthCleanupReceipt: Sendable, Equatable {
    public let localCredentialStateRemoved: Bool
    public let providerRevocationConfirmed: Bool?
}

public struct OAuthFlowDriver: Sendable {
    public var resolve: @Sendable (String) async throws -> ResolvedLoginIdentifier
    public var start: @Sendable (OAuthFlowRequest) async throws -> StartedOAuthFlow
    public var complete: @Sendable (StartedOAuthFlow, URL) async throws -> CompletedOAuthFlow
    public var restore: @Sendable (PersistedAccountMetadata) async throws -> RestoredOAuthAccount?
    public var reportedGrantedScopes: @Sendable (String) async -> Set<String>
    public var discardPendingAuthorization:
        @Sendable (StartedOAuthFlow) async throws -> Void
    public var removeLocalAuthorization:
        @Sendable (AccountStore.Account) async throws -> OAuthCleanupReceipt
}
```

`OAuthFlowDriver.live(clientFactory:)` owns all Petrel construction through the injected factory; `AccountStore` never invokes `ATProtoClient` or `OAuthConfig` initializers. `resolve` uses a disposable anonymous resolver provided by the driver. Every `start` asks the factory for a client built with a new `OAuthConfig(clientId:redirectUri:scope:)`; every `restore` asks it for a client from `metadata.requestedScope` and `AccountStore.namespace(for: metadata.id)`, then requires Petrel's active DID to equal the metadata DID before returning it. `discardPendingAuthorization` logs out and deletes only the namespace/client carried by that failed `StartedOAuthFlow`; callback failure and DID mismatch invoke it before consuming that matching state, and failure to discard is attached to the visible issue without touching any established account. The DEBUG fixture factory calls the external-access sentinel if invoked. Preserve the existing narrow CAB fallback condition: retry with `.publicOAuth` only for `AuthError.nativeClientNoneAuthRequired`. No other CAB error may silently downgrade. `removeLocalAuthorization` calls Petrel logout for an established account, reports whether local credential state was removed, and never hides partial cleanup behind `try?`.

Create metadata here, not in Task 6:

```swift
public struct PersistedAccountMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let handle: String
    public let authMode: AccountStore.AuthModeType
    public let requestedScope: String
}

/// The exact pre-Plan-4 on-disk row. It exists only as a decode/migration input.
struct LegacyPersistedAccountMetadata: Codable, Equatable, Sendable {
    let id: String
    let handle: String
    let authMode: AccountStore.AuthModeType
}

public enum AccountMetadataKeys {
    /// Preserve the shipping key so existing rows can be migrated in place.
    public static let accounts = "blue.catbird.atprotodrive.accounts"
}

public struct AccountMetadataEnvelope: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let accounts: [PersistedAccountMetadata]
}

@MainActor
public protocol AccountMetadataStoring: AnyObject {
    func load(baseScope: String) throws -> AccountMetadataEnvelope
    func save(_ envelope: AccountMetadataEnvelope) throws
}
```

`UserDefaultsAccountMetadataStore.load(baseScope:)` reads only `AccountMetadataKeys.accounts`, first decodes `AccountMetadataEnvelope(formatVersion: 2, ...)`, and rejects unsupported versions. If the bytes decode only as the current legacy `[id, handle, authMode]` array, map every row to `PersistedAccountMetadata(..., requestedScope: baseScope)`, synchronously save version 2 to that same shipping key, and return it. Corrupt bytes throw and surface as an `AuthenticationIssue`; they do not silently erase the account list. Remove the legacy broad constant from production. Add this field to the exact production account declaration and every initializer:

```swift
public struct Account: Identifiable, Sendable {
    public let id: String
    public let handle: String
    public let client: ATProtoClient
    public let credentials: SpaceCredentialManager
    public let authMode: AuthModeType
    public let requestedScope: String
}
```

- [ ] **Step 4: Implement intent APIs and publish callback failures**

Use these exact signatures:

```swift
public func restoreOnce() async
public func beginLogin(handle: String, intent: LoginIntent = .add) async throws -> URL
public func reconnect(accountDID: String) async throws -> URL
public func reconsent(
    accountDID: String,
    context: AccessContext,
    recordKey: String? = nil
) async throws -> URL
public func handleCallback(_ url: URL) async
public func discardPendingAuthorizations() async throws
public func dismissAuthenticationIssue()
```

`restoreOnce()` uses an internal idle/loading/complete guard so opening a second `WindowGroup` scene never launches a second Keychain restore or overwrites the first window's `BrowserSession`. Every window may call it safely.

The pending value must be:

```swift
private struct PendingLogin: Sendable {
    let started: StartedOAuthFlow
    let intent: LoginIntent
    let expectedDID: String
    let requestedHandle: String
    let requestedScope: String
}
```

For `.add`, trim input, call `driver.resolve`, and start with the resolved DID as both `identifier` and `expectedDID`; preserve the resolved handle only for display. For `.reconnect` and `.reconsent`, look up `account(for: accountDID)` and throw an account-not-found issue when absent. Do not resolve its handle: set both `OAuthFlowRequest.identifier` and `expectedDID` to `accountDID`. Before any driver call, `reconsent` invokes `AuthorizationTargetValidator.validate(context:recordKey:)`.

`discardPendingAuthorizations()` snapshots all currently pending flows, calls `driver.discardPendingAuthorization` once for each, and removes a flow from the pending map only after that flow's discard succeeds. It attempts every flow, returns only after all successful discards have completed, and throws one redacted aggregate issue for any failures; it never uses `try?`. `OAuthFlowDriver.live.start` also owns a client created before `StartedOAuthFlow` is returned and must discard that client/namespace if discovery or authorization setup throws, so a failed `beginLogin` cannot strand storage outside the pending map.

Read raw reported grants from `driver.reportedGrantedScopes(accountDID)`, but build the next request with:

```swift
try planner.authorizationScope(
    previouslyRequested: account.requestedScope,
    reportedGranted: reported,
    adding: context
)
```

Persist that exact request string after successful callback; an empty reported set remains `capabilitiesAreKnown == false` elsewhere. Require callback DID equality before replacing that one account. On mismatch, invoke cleanup only on the newly started flow, keep the old account/client/scope, consume only the matching state, and publish the issue. Unknown state, wrong scheme/host/path, duplicate state, and a callback for another pending flow never consume any valid pending flow. Never consult `activeAccount`.

Change app callback delivery to:

```swift
.onOpenURL { url in
    Task { await accountStore.handleCallback(url) }
}
.alert(item: Binding(
    get: { accountStore.authenticationIssue },
    set: { if $0 == nil { accountStore.dismissAuthenticationIssue() } }
)) { issue in
    Alert(
        title: Text(issue.title),
        message: Text(issue.message),
        dismissButton: .default(Text("OK"))
    )
}
```

Remove the current `try? await accountStore.handleCallback(url)`. `AddAccountView` calls `beginLogin(handle:intent:.add)` and leaves callback error presentation to the app-level issue surface.

Callback routing is a closed whitelist. `ApplicationURLHandlerCatalog.handlers` contains only `.oauthCallback`, and `ATProtoDriveApp.onOpenURL` dispatches only through that catalog. Add tests for exactly `blue.catbird.atprotodrive:/callback` with one non-empty `state` and exactly one of `code` or `error`; reject alternate schemes, hosts, paths, fragments, duplicate state values, both result fields, neither result field, and account-management-shaped paths before pending-state lookup.

```swift
public enum ApplicationURLHandler: CaseIterable, Hashable, Sendable {
    case oauthCallback
}

public enum ApplicationURLHandlerCatalog {
    public static let handlers: Set<ApplicationURLHandler> = [.oauthCallback]
}

@Suite("OAuthCallbackRouteTests")
struct OAuthCallbackRouteTests {
    @Test("only the OAuth callback route is accepted")
    func callbackWhitelist() throws {
        #expect(ApplicationURLHandlerCatalog.handlers == [.oauthCallback])
        #expect(try OAuthCallbackRoute.validate(
            URL(string: "blue.catbird.atprotodrive:/callback?state=s1&code=c1")!
        ).state == "s1")
        #expect(try OAuthCallbackRoute.validate(
            URL(string: "blue.catbird.atprotodrive:/callback?state=s2&error=access_denied")!
        ).state == "s2")
        for raw in [
            "other.scheme:/callback?state=s&code=c",
            "blue.catbird.atprotodrive://host/callback?state=s&code=c",
            "blue.catbird.atprotodrive:/remove-account?state=s&code=c",
            "blue.catbird.atprotodrive:/callback?state=a&state=b&code=c",
            "blue.catbird.atprotodrive:/callback?state=s&code=c#fragment",
            "blue.catbird.atprotodrive:/callback?state=s&code=c&error=access_denied",
            "blue.catbird.atprotodrive:/callback?state=s"
        ] {
            #expect(throws: OAuthCallbackRouteError.self) {
                try OAuthCallbackRoute.validate(URL(string: raw)!)
            }
        }
    }
}
```

Delete `activeAccountID`, `activeAccount`, their fallback tests, and every command/view write to them. Account selection belongs to window-local `BrowserSession`; all authenticated services require a DID argument.

- [ ] **Step 5: Rerun unit tests and verify the broad initial scope is gone**

Run the Step 2 command again, then run:

```bash
rg -n 'try\? await accountStore\.handleCallback|manage=create.*manage=delete' \
  ATProtoDrive ATProtoDriveTests
```

Expected: tests PASS; the search returns no production match. The migration fixture contains only the legacy metadata shape, not the former broad write/admin scope. Tests prove restore uses the migrated/requested exact scope, reconnect pins the DID identifier, unknown grants preserve requested scopes without claiming them as granted, invalid raw targets make zero resolver/start calls, and callback failures preserve unrelated accounts and pending flows.

- [ ] **Step 6: Seal Task 2 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "feat: add exact-account OAuth reconnect and reconsent"
jj new
```

---

### Task 3: Build exact-DID account and server status

**Files:**
- Create: `ATProtoDrive/Accounts/AccountStatusModels.swift`
- Create: `ATProtoDrive/Accounts/AccountStatusService.swift`
- Create: `ATProtoDrive/Accounts/AccountStatusStore.swift`
- Create: `ATProtoDrive/Accounts/SpacesAvailabilityProbe.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Create: `ATProtoDriveTests/AccountStatusServiceTests.swift`
- Create: `ATProtoDriveTests/AccountStatusStoreTests.swift`
- Create: `ATProtoDriveTests/SpacesAvailabilityProbeTests.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AccountStore.Account`, `LoadState`, `BrowserFailure`, and Plan 2's exact-account `SpaceRepositoryService.listSpaces(cursor:limit:)` path.
- Produces: `AccountStatusSnapshot`, `SpacesAvailability`, `SpacesAvailabilityProbing.probe(account:)`, typed `AccountAccessFailure`, `AccountStatusServing.fetchStatus(for:)`, DID-keyed `AccountStatusStore.refresh(accountDID:accounts:service:)`, and exact-account `AccountStore.refreshStatus(for:)`/`refreshAllStatuses()` summaries.

- [ ] **Step 1: Write failing exact-DID aggregation and stale-state tests**

```swift
@Test("status rejects a session DID different from the requested account")
func rejectsSessionDIDMismatch() async {
    let account = await AccountPlanTestSupport.aliceAccount()
    let transport = AccountStatusTransportStub(
        activeDID: "did:plc:alice",
        sessionDID: "did:plc:bob"
    )
    let service = AccountStatusService(makeTransport: { _ in transport })

    await #expect(throws: AccountStatusError.sessionDIDMismatch) {
        try await service.fetchStatus(for: account)
    }
    #expect(await transport.requestedGrantedScopeDIDs.isEmpty)
}

@Test("successful aggregation reads grants for the exact requested DID")
func exactGrantedScopeDID() async throws {
    let account = await AccountPlanTestSupport.aliceAccount()
    let transport = AccountStatusTransportStub(
        activeDID: account.id, sessionDID: account.id
    )
    let service = AccountStatusService(makeTransport: { _ in transport })

    let snapshot = try await service.fetchStatus(for: account)

    #expect(snapshot.accountDID == account.id)
    #expect(await transport.requestedGrantedScopeDIDs == [account.id])
}

@Test("status transport preserves typed 401 and 403 failures")
func typedStatusAccessFailures() async {
    let account = await AccountPlanTestSupport.aliceAccount()
    let unauthenticated = AccountStatusService(makeTransport: { _ in
        AccountStatusTransportStub(
            activeDID: account.id, sessionDID: account.id,
            sessionFailure: .unauthenticated(endpoint: "com.atproto.server.getSession")
        )
    })
    let forbiddenContext = AccessContext.publicRecord(
        collection: "app.example.note", action: .update
    )
    let forbidden = AccountStatusService(makeTransport: { _ in
        AccountStatusTransportStub(
            activeDID: account.id, sessionDID: account.id,
            sessionFailure: .insufficientCapability(
                endpoint: "com.atproto.repo.putRecord", context: forbiddenContext
            )
        )
    })

    await #expect(throws: AccountAccessFailure.unauthenticated(
        endpoint: "com.atproto.server.getSession"
    )) { try await unauthenticated.fetchStatus(for: account) }
    await #expect(throws: AccountAccessFailure.insufficientCapability(
        endpoint: "com.atproto.repo.putRecord", context: forbiddenContext
    )) { try await forbidden.fetchStatus(for: account) }
}

@MainActor
@Test("refresh failure preserves the last status snapshot as stale")
func staleSnapshotSurvivesRefreshFailure() async {
    let account = await AccountPlanTestSupport.aliceAccount()
    let service = SequenceAccountStatusService(results: [
        .success(AccountPlanTestSupport.connectedAlice),
        .failure(.offline)
    ])
    let store = AccountStatusStore()
    let accounts = AccountStore(
        oauthDriver: .fixture(), metadataStore: InMemoryAccountMetadataStore()
    )
    accounts.addAccountForTesting(account)

    await store.refresh(accountDID: "did:plc:alice", accounts: accounts, service: service)
    await store.refresh(accountDID: "did:plc:alice", accounts: accounts, service: service)

    guard case let .failed(previous, failure) = store.state(for: "did:plc:alice") else {
        Issue.record("Expected stale failed state")
        return
    }
    #expect(previous == AccountPlanTestSupport.connectedAlice)
    #expect(failure == .offline)
    #expect(store.state(for: "did:plc:alice").isStale)
}

@MainActor
@Test("concurrent account refreshes and failures remain DID isolated")
func twoAccountStatusIsolation() async throws {
    let alice = await AccountPlanTestSupport.aliceAccount()
    let bob = await AccountPlanTestSupport.bobAccount()
    let accounts = AccountStore(
        oauthDriver: .fixture(), metadataStore: InMemoryAccountMetadataStore()
    )
    accounts.addAccountForTesting(alice)
    accounts.addAccountForTesting(bob)
    let service = DIDRoutedStatusService(results: [
        "did:plc:alice": [.success(AccountPlanTestSupport.connectedAlice), .failure(.offline)],
        "did:plc:bob": [.success(AccountPlanTestSupport.connectedBob)]
    ])
    let store = AccountStatusStore()

    async let aliceLoad: Void = store.refresh(
        accountDID: alice.id, accounts: accounts, service: service
    )
    async let bobLoad: Void = store.refresh(
        accountDID: bob.id, accounts: accounts, service: service
    )
    _ = await (aliceLoad, bobLoad)
    await store.refresh(accountDID: alice.id, accounts: accounts, service: service)

    guard case let .failed(previousAlice, _) = store.state(for: alice.id) else {
        Issue.record("Expected Alice stale state")
        return
    }
    #expect(previousAlice?.accountDID == alice.id)
    #expect(store.state(for: bob.id).snapshot?.accountDID == bob.id)
    #expect(store.state(for: bob.id).isStale == false)
}

@MainActor
@Test("401 and contextual 403 update only their exact account")
func accountConnectionFailureIsolation() async throws {
    let accounts = AccountStore(
        oauthDriver: .fixture(), metadataStore: InMemoryAccountMetadataStore()
    )
    accounts.addAccountForTesting(await AccountPlanTestSupport.aliceAccount())
    accounts.addAccountForTesting(await AccountPlanTestSupport.bobAccount())
    let context = AccessContext.publicRecord(
        collection: "app.example.note", action: .update
    )

    accounts.recordAccessFailure(
        accountDID: "did:plc:alice",
        failure: .insufficientCapability(
            endpoint: "com.atproto.repo.putRecord", context: context
        )
    )
    accounts.recordAccessFailure(
        accountDID: "did:plc:bob",
        failure: .unauthenticated(endpoint: "com.atproto.server.getSession")
    )

    guard case let .needsReconsent(actualContext, _) =
        accounts.connectionStatus(for: "did:plc:alice") else {
        Issue.record("Expected Alice to need contextual reconsent")
        return
    }
    #expect(actualContext == context)
    guard case .needsReconnect = accounts.connectionStatus(for: "did:plc:bob") else {
        Issue.record("Expected Bob to need reconnect")
        return
    }
}

@Test("Spaces probe requires a decoded 2xx body and maps failures distinctly")
func spacesProbeMapping() async throws {
    let account = await AccountPlanTestSupport.aliceAccount()
    let spy = SpaceProbeTransportSpy(accountDID: account.id, responses: [
        .response(status: 200, output: nil),
        .response(status: 200, output: .init(profile: "alpha", returnedSpaceCount: 1)),
        .response(status: 404, output: nil),
        .response(status: 401, output: nil),
        .response(status: 403, output: nil),
        .transport("offline")
    ])
    let probe = LiveSpacesAvailabilityProbe(makeTransport: { candidate in
        #expect(candidate.id == account.id)
        return spy
    })

    await #expect(throws: AccountStatusError.invalidResponse(
        endpoint: "com.atproto.space.listSpaces", statusCode: 200
    )) {
        try await probe.probe(account: account)
    }
    #expect(try await probe.probe(account: account) == .available(profile: "alpha"))
    #expect(try await probe.probe(account: account) == .unsupported)
    await #expect(throws: AccountAccessFailure.unauthenticated(
        endpoint: "com.atproto.space.listSpaces"
    )) {
        try await probe.probe(account: account)
    }
    await #expect(throws: AccountAccessFailure.insufficientCapability(
        endpoint: "com.atproto.space.listSpaces", context: nil
    )) {
        try await probe.probe(account: account)
    }
    #expect(try await probe.probe(account: account) == .unavailable("offline"))
    #expect(await spy.requestedAccountDIDs == Array(repeating: account.id, count: 6))
}
```

Append these concrete fixtures to `AccountPlanTestSupport.swift`; the transport's remaining payloads use Alice's DID, active repository revision `3kfixture`, server DID `did:web:pds.example`, no blob limit, raw scopes `["atproto"]`, and `.available(profile: "fixture")` unless an initializer argument overrides them:

```swift
enum AccountPlanTestSupport {
    @MainActor
    static func aliceAccount() async -> AccountStore.Account {
        let client = await ATProtoClient(baseURL: URL(string: "https://pds.example")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client))
        return AccountStore.Account(
            id: "did:plc:alice",
            handle: "alice.example",
            client: client,
            credentials: SpaceCredentialManager(client: client, resolver: resolver),
            authMode: .publicOAuth,
            requestedScope: "atproto space:*?authority=*&skey=*&action=read_self"
        )
    }

    @MainActor
    static func bobAccount() async -> AccountStore.Account {
        let client = await ATProtoClient(baseURL: URL(string: "https://bob-pds.example")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client))
        return AccountStore.Account(
            id: "did:plc:bob", handle: "bob.example", client: client,
            credentials: SpaceCredentialManager(client: client, resolver: resolver),
            authMode: .cab,
            requestedScope: "atproto space:*?authority=*&skey=*&action=read_self"
        )
    }

    static let connectedAlice = AccountStatusSnapshot(
        accountDID: "did:plc:alice",
        handle: "alice.example",
        pdsURL: URL(string: "https://pds.example")!,
        serverDID: "did:web:pds.example",
        session: .connected,
        repository: .active(
            revision: "3kfixture",
            commitCID: "bafyfixture",
            indexedRecords: 2
        ),
        oauthMode: .publicOAuth,
        grantedCapabilities: ["atproto"],
        capabilitiesAreKnown: true,
        lastSuccessfulCheck: Date(timeIntervalSince1970: 1_700_000_000),
        blobUploadLimit: nil,
        spaces: .available(profile: "fixture")
    )

    static let connectedBob = AccountStatusSnapshot(
        accountDID: "did:plc:bob", handle: "bob.example",
        pdsURL: URL(string: "https://bob-pds.example")!,
        serverDID: "did:web:bob-pds.example", session: .connected,
        repository: .active(revision: "3kbob", commitCID: "bafybob", indexedRecords: 1),
        oauthMode: .cab, grantedCapabilities: [], capabilitiesAreKnown: false,
        lastSuccessfulCheck: Date(timeIntervalSince1970: 1_700_000_000),
        blobUploadLimit: nil, spaces: .unsupported
    )
}

actor SequenceAccountStatusService: AccountStatusServing {
    private var results: [Result<AccountStatusSnapshot, BrowserFailure>]
    init(results: [Result<AccountStatusSnapshot, BrowserFailure>]) {
        self.results = results
    }
    func fetchStatus(for account: AccountStore.Account) async throws -> AccountStatusSnapshot {
        try results.removeFirst().get()
    }
}

actor DIDRoutedStatusService: AccountStatusServing {
    private var results: [String: [Result<AccountStatusSnapshot, BrowserFailure>]]
    init(results: [String: [Result<AccountStatusSnapshot, BrowserFailure>]]) {
        self.results = results
    }
    func fetchStatus(for account: AccountStore.Account) async throws -> AccountStatusSnapshot {
        guard var queue = results[account.id], !queue.isEmpty else {
            throw BrowserFailure.transport("No scripted status for \(account.id)")
        }
        let result = queue.removeFirst()
        results[account.id] = queue
        return try result.get()
    }
}

enum SpaceProbeResponse: Sendable {
    case response(status: Int, output: SpacesProbePayload?)
    case transport(String)
}

actor SpaceProbeTransportSpy: SpaceAvailabilityTransporting {
    let accountDID: String
    var responses: [SpaceProbeResponse]
    private(set) var requestedAccountDIDs: [String] = []

    init(accountDID: String, responses: [SpaceProbeResponse]) {
        self.accountDID = accountDID
        self.responses = responses
    }

    func listSpaces(
        accountDID: String,
        cursor: String?,
        limit: Int
    ) async throws -> SpacesProbeResponseEnvelope {
        requestedAccountDIDs.append(accountDID)
        guard accountDID == self.accountDID, cursor == nil, limit == 1 else {
            throw BrowserFailure.authorizationRefused
        }
        switch responses.removeFirst() {
        case let .response(status, output):
            return .init(responseCode: status, output: output)
        case let .transport(message): throw SpaceAvailabilityTransportError.transport(message)
        }
    }
}
```

Implement the value-domain transport without constructing URLs or touching Petrel:

```swift
actor AccountStatusTransportStub: AccountStatusTransporting {
    let activeDID: String
    let sessionDID: String
    let sessionFailure: AccountAccessFailure?
    private(set) var requestedGrantedScopeDIDs: [String] = []

    init(
        activeDID: String,
        sessionDID: String,
        sessionFailure: AccountAccessFailure? = nil
    ) {
        self.activeDID = activeDID
        self.sessionDID = sessionDID
        self.sessionFailure = sessionFailure
    }

    func activeAccountInfo() async -> (did: String?, handle: String?, pdsURL: URL?) {
        (activeDID, "alice.example", URL(string: "https://pds.example")!)
    }
    func refreshToken() async throws {}
    func session() async throws -> AccountSessionPayload {
        if let sessionFailure { throw sessionFailure }
        return .init(did: sessionDID, handle: "alice.example", active: true, status: nil)
    }
    func repositoryStatus() async throws -> AccountRepositoryPayload {
        .init(
            activated: true,
            validDID: true,
            commitCID: "bafyfixture",
            revision: "3kfixture",
            indexedRecords: 2
        )
    }
    func serverDescription(pdsURL: URL) async throws -> ServerDescriptionPayload {
        .init(serverDID: "did:web:pds.example", blobUploadLimit: nil)
    }
    func grantedScopes(for did: String) async -> Set<String> {
        requestedGrantedScopeDIDs.append(did)
        return ["atproto"]
    }
    func spacesAvailability(account: AccountStore.Account) async throws -> SpacesAvailability {
        .available(profile: "fixture")
    }
}
```

- [ ] **Step 2: Run tests and verify status types are missing**

Run:

```bash
PLAN4_DERIVED="$(mktemp -d /tmp/atprotodrive-plan4-task3.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
  test -only-testing:ATProtoDriveTests
```

Expected: FAIL with missing `AccountStatusService` and `AccountStatusStore`.

- [ ] **Step 3: Implement the complete status snapshot**

```swift
public enum AccountSessionState: Equatable, Sendable {
    case connected
    case needsReconnect(String)
    case degraded(String)
}

public enum AccountRepositoryState: Equatable, Sendable {
    case active(revision: String, commitCID: String, indexedRecords: Int)
    case inactive(status: String?)
    case unavailable(String)
}

public enum SpacesAvailability: Equatable, Sendable {
    case available(profile: String?)
    case unsupported
    case authorizationRequired
    case unavailable(String)
}

public struct AccountStatusSnapshot: Equatable, Sendable {
    public let accountDID: String
    public let handle: String
    public let pdsURL: URL
    public let serverDID: String
    public let session: AccountSessionState
    public let repository: AccountRepositoryState
    public let oauthMode: AccountStore.AuthModeType
    public let grantedCapabilities: Set<String>
    public let capabilitiesAreKnown: Bool
    public let lastSuccessfulCheck: Date
    public let blobUploadLimit: Int?
    public let spaces: SpacesAvailability
}

public struct AccountSessionPayload: Equatable, Sendable {
    public let did: String
    public let handle: String
    public let active: Bool?
    public let status: String?
}

public struct AccountRepositoryPayload: Equatable, Sendable {
    public let activated: Bool
    public let validDID: Bool
    public let commitCID: String
    public let revision: String
    public let indexedRecords: Int
}

public struct ServerDescriptionPayload: Equatable, Sendable {
    public let serverDID: String
    public let blobUploadLimit: Int?
}

public enum AccountStatusError: Error, Equatable, Sendable {
    case activeDIDMismatch
    case sessionDIDMismatch
    case invalidResponse(endpoint: String, statusCode: Int)
}

public enum AccountAccessFailure: Error, Equatable, Sendable {
    case unauthenticated(endpoint: String)
    case insufficientCapability(endpoint: String, context: AccessContext?)
}
```

Define a testable transport that maps Petrel's tuple APIs into non-optional domain payloads:

```swift
public protocol AccountStatusTransporting: Sendable {
    func activeAccountInfo() async -> (did: String?, handle: String?, pdsURL: URL?)
    func refreshToken() async throws
    func session() async throws -> AccountSessionPayload
    func repositoryStatus() async throws -> AccountRepositoryPayload
    func serverDescription(pdsURL: URL) async throws -> ServerDescriptionPayload
    func grantedScopes(for did: String) async -> Set<String>
    func spacesAvailability(account: AccountStore.Account) async throws -> SpacesAvailability
}

public protocol AccountStatusServing: Sendable {
    func fetchStatus(for account: AccountStore.Account) async throws -> AccountStatusSnapshot
}

public protocol SpacesAvailabilityProbing: Sendable {
    func probe(account: AccountStore.Account) async throws -> SpacesAvailability
}

public struct SpacesProbePayload: Equatable, Sendable {
    public let profile: String?
    public let returnedSpaceCount: Int
}

public struct SpacesProbeResponseEnvelope: Equatable, Sendable {
    public let responseCode: Int
    public let output: SpacesProbePayload?
}

public protocol SpaceAvailabilityTransporting: Sendable {
    func listSpaces(
        accountDID: String,
        cursor: String?,
        limit: Int
    ) async throws -> SpacesProbeResponseEnvelope
}

public enum SpaceAvailabilityTransportError: Error, Equatable, Sendable {
    case transport(String)
}

public struct LiveSpacesAvailabilityProbe: SpacesAvailabilityProbing, Sendable {
    public let makeTransport:
        @Sendable (AccountStore.Account) async throws -> any SpaceAvailabilityTransporting

    public func probe(account: AccountStore.Account) async throws -> SpacesAvailability {
        let transport = try await makeTransport(account)
        do {
            let response = try await transport.listSpaces(
                accountDID: account.id, cursor: nil, limit: 1
            )
            switch response.responseCode {
            case 200 ... 299:
                guard let output = response.output else {
                    throw AccountStatusError.invalidResponse(
                        endpoint: "com.atproto.space.listSpaces",
                        statusCode: response.responseCode
                    )
                }
                return .available(profile: output.profile)
            case 401:
                throw AccountAccessFailure.unauthenticated(
                    endpoint: "com.atproto.space.listSpaces"
                )
            case 403:
                throw AccountAccessFailure.insufficientCapability(
                    endpoint: "com.atproto.space.listSpaces", context: nil
                )
            case 404, 405, 501: return .unsupported
            default:
                return .unavailable("HTTP \(response.responseCode)")
            }
        } catch let error as SpaceAvailabilityTransportError {
            guard case let .transport(message) = error else { throw error }
            return .unavailable(message)
        }
    }
}
```

The Petrel adapter must:

1. Read `getActiveAccountInfo()` and require its DID to equal `account.id`.
2. Call `refreshToken()`; `false` means no refresh was needed, not invalid session.
3. Call authenticated `com.atproto.server.getSession()` and `checkAccountStatus()`; require 2xx and non-nil data, and require `getSession.did.didString()` to equal `account.id`. Map HTTP 401/session-expired to `AccountAccessFailure.unauthenticated`; map HTTP 403 to `AccountAccessFailure.insufficientCapability(endpoint:context:nil)` rather than generic transport.
4. Build a separate anonymous `await ATProtoClient(baseURL: pdsURL)` for `com.atproto.server.describeServer()` so server metadata does not depend on broad authenticated routing.
5. Read raw scopes with `getGrantedScopes(for: account.id)`, never `nil`; set `capabilitiesAreKnown` false whenever the set is empty because Petrel documents empty as ambiguous for unknown, untracked, legacy, and gateway-held sessions.
6. Ask `SpacesAvailabilityProbing` with the exact `Account` value. `LiveSpacesAvailabilityProbe` creates the Plan 2 Space service only from that account and performs `listSpaces(cursor:nil, limit:1)`. The Petrel adapter returns `SpacesProbeResponseEnvelope`, setting `output` only when generated `result.data` decoded successfully. A 2xx with nil output throws `.invalidResponse`; a decoded 2xx is `.available(profile:)`; 404/405/501 is `.unsupported`; 401 throws `.unauthenticated`; 403 throws `.insufficientCapability`; transport failure becomes `.unavailable(redactedMessage)`. It never tries another account or a public client.
7. Set `lastSuccessfulCheck` only after all required status fields have passed DID and response validation.

- [ ] **Step 4: Implement a stale-preserving observable store with no fallback account**

```swift
@MainActor
@Observable
public final class AccountStatusStore {
    public private(set) var statesByDID: [String: LoadState<AccountStatusSnapshot>] = [:]

    public func state(for accountDID: String) -> LoadState<AccountStatusSnapshot> {
        statesByDID[accountDID] ?? .idle
    }

    public func refresh(
        accountDID: String,
        accounts: AccountStore,
        service: any AccountStatusServing
    ) async {
        guard let account = accounts.account(for: accountDID) else {
            statesByDID[accountDID] = .failed(
                previous: state(for: accountDID).snapshot,
                failure: .authorizationRefused
            )
            return
        }
        statesByDID[accountDID] = .loading(previous: state(for: accountDID).snapshot)
        do {
            statesByDID[accountDID] = .loaded(try await service.fetchStatus(for: account))
        } catch {
            let failure = (error as? BrowserFailure)
                ?? .transport(String(describing: error))
            statesByDID[accountDID] = .failed(
                previous: state(for: accountDID).snapshot,
                failure: failure
            )
        }
    }
}
```

Inject `any AccountStatusServing` into the live `AccountStore`, retain `connectionStatusByDID: [String: AccountConnectionStatus]`, and expose:

```swift
public func connectionStatus(for accountDID: String) -> AccountConnectionStatus
public func refreshStatus(for accountDID: String) async
public func refreshAllStatuses() async
```

`refreshStatus(for:)` must use `account(for:)`; if absent it stores `.degraded(message: "Account is no longer connected")` only for that DID and returns. Before calling the service it stores `.checking`. A successful snapshot maps to `.connected(grantedScopes: snapshot.grantedCapabilities)`; `.unauthenticated` maps to `.needsReconnect(message:)`; `.insufficientCapability(_, let context?)` maps to `.needsReconsent(context:message:)`; missing-context 403 maps to `.degraded` and the relevant blocked operation supplies its exact context through `recordAccessFailure(accountDID:failure:)`. Other status failures map to `.degraded(message:)`.

The Step 1 `accountConnectionFailureIsolation` test is the required 401/403 projection proof. `refreshAllStatuses()` iterates a captured list of account DIDs and never changes any `BrowserSession` selection.

- [ ] **Step 5: Rerun unit tests**

Run the Step 2 command again.

Expected: PASS for exact requested DID, two-account concurrent isolation, 2xx/nil decoding failure, typed 401 versus 403 classification, raw scope ambiguity, exact-account Spaces probe routing/mapping, and per-DID stale snapshot retention.

- [ ] **Step 6: Seal Task 3 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "feat: add exact-account server status"
jj new
```

---

### Task 4: Add the two-action Server & Account surface and safe removal

**Files:**
- Create: `ATProtoDrive/Accounts/AccountControlCatalog.swift`
- Create: `ATProtoDrive/Accounts/AccountLocalDataCleaner.swift`
- Create: `ATProtoDrive/Accounts/AccountRemovalTombstone.swift`
- Create: `ATProtoDrive/Accounts/ServerAccountView.swift`
- Modify: `ATProtoDrive/Accounts/AccountMetadataStore.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Modify: `ATProtoDrive/Browser/BrowserSession.swift`
- Modify: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Modify: `ATProtoDrive/Browser/DriveSidebarView.swift`
- Modify: `ATProtoDrive/Browser/BrowserCommands.swift`
- Create: `ATProtoDriveTests/AccountControlCatalogTests.swift`
- Modify: `ATProtoDriveTests/AccountStoreTests.swift`
- Modify: `ATProtoDriveTests/BrowserSessionTests.swift`
- Modify: `ATProtoDriveTests/TransferQueueTests.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Tasks 2-3 account APIs/status, `BrowserSource.account(did:destination:.serverAndAccount)`, account-qualified caches/previews/recents from Plans 1-3, and Plan 3's persisted `TransferJobDescriptor.requiredAccountDIDs`, `TransferAccountParkingReceipt`, and cancellation-fenced `TransferQueue.markAccountsUnavailable(_:)`.
- Produces: closed `AccountControlAction`, idempotent `AccountLocalDataCleaning`, durable `AccountRemovalTombstone`, throwing/retryable `removeFromApp(_:)`, exact Plan 3 queue handoff, window-scoped removal redirection, and `ServerAccountView(accountDID:)`.

- [ ] **Step 1: Write failing closed-catalog and removal-partial-failure tests**

```swift
@Suite("Account control catalog")
struct AccountControlCatalogTests {
    @Test("only reconnect and remove-from-app are routable")
    func onlyTwoActions() {
        #expect(Set(AccountControlAction.allCases) == [.reconnect, .removeFromApp])
        #expect(AccountControlCatalog.actions.map(\.title) == [
            "Reconnect",
            "Remove from ATProtoDrive"
        ])
    }
}

@MainActor
@Test("local cleanup failure is visible and does not report successful removal")
func removalFailureIsVisible() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "https://pds.example")!)
    let cleaner = AccountLocalDataCleanerStub(result: .failure(TestFailure.diskFull))
    let queue = try QueueFixture().queue
    let store = AccountStore(
        oauthDriver: .fixture(), metadataStore: InMemoryAccountMetadataStore(),
        localDataCleaner: cleaner, transferQueue: queue
    )
    store.installAccountForTesting(
        did: "did:plc:alice",
        handle: "alice.example",
        client: client,
        authMode: .publicOAuth,
        requestedScope: try AuthorizationScopePlanner().baseScope
    )

    await #expect(throws: AccountRemovalError.self) {
        try await store.removeFromApp("did:plc:alice")
    }

    #expect(store.account(for: "did:plc:alice") != nil)
    #expect(store.authenticationIssue?.message.contains("remote account was not deleted") == true)
    #expect(await cleaner.preservedBackups)
    #expect(store.metadataForTesting().removalTombstones["did:plc:alice"] != nil)
}

@MainActor
@Test("logout success plus cleaner failure resumes idempotently from tombstone")
func removalRetryUsesDurableTombstone() async throws {
    let harness = await OAuthFlowDriverHarness.cleanupAlwaysSucceeds()
    let cleaner = AccountLocalDataCleanerStub(results: [
        .failure(TestFailure.diskFull), .success(())
    ])
    let metadata = InMemoryAccountMetadataStore()
    let store = try await AccountPlanTestSupport.twoAccountStore(
        oauthDriver: harness.driver, metadataStore: metadata,
        localDataCleaner: cleaner
    )

    await #expect(throws: AccountRemovalError.self) {
        try await store.removeFromApp("did:plc:alice")
    }
    #expect(store.account(for: "did:plc:alice") != nil)
    #expect(store.account(for: "did:plc:bob") != nil)

    try await store.removeFromApp("did:plc:alice")

    #expect(store.account(for: "did:plc:alice") == nil)
    #expect(store.account(for: "did:plc:bob") != nil)
    #expect(await harness.cleanupDIDs == ["did:plc:alice"])
    #expect(await cleaner.requestedDIDs == ["did:plc:alice", "did:plc:alice"])
    #expect(try metadata.load(baseScope: "atproto").removalTombstones.isEmpty)
}

@MainActor
@Test("metadata save failure publishes neither removal nor window redirect")
func metadataFailureIsAtomic() async throws {
    // Save 1 seeds the two-account envelope; save 2 is the first tombstone write.
    let metadata = FailingAccountMetadataStore(failOnSaveNumber: 2)
    let harness = await OAuthFlowDriverHarness.cleanupAlwaysSucceeds()
    let cleaner = AccountLocalDataCleanerStub(result: .success(()))
    let events = AccountRemovalEventRecorder()
    let store = try await AccountPlanTestSupport.twoAccountStore(
        oauthDriver: harness.driver, metadataStore: metadata,
        localDataCleaner: cleaner, removalEvents: events.sink
    )

    await #expect(throws: AccountRemovalError.self) {
        try await store.removeFromApp("did:plc:alice")
    }

    #expect(store.account(for: "did:plc:alice") != nil)
    #expect(store.account(for: "did:plc:bob") != nil)
    #expect(await harness.cleanupDIDs.isEmpty)
    #expect(await cleaner.requestedDIDs.isEmpty)
    #expect(await events.removedDIDs.isEmpty)
}

@MainActor
@Test("tombstone save after parking receipt retries without duplicate queue work")
func parkingReceiptPersistenceRetryIsIdempotent() async throws {
    let queueEvents = QueueEventRecorder()
    let queueFixture = try QueueFixture(
        jobs: [.fixtureSpaceDownload(
            id: TransferFixtureSupport.aliceID,
            accountDID: "did:plc:alice"
        )],
        eventRecorder: queueEvents
    )
    var hasFailedSuspensionSave = false
    let metadata = FailingAccountMetadataStore(failWhen: { envelope in
        guard !hasFailedSuspensionSave,
              envelope.removalTombstones["did:plc:alice"]?
                .accountJobsSuspended == true else { return false }
        hasFailedSuspensionSave = true
        return true
    })
    let harness = await OAuthFlowDriverHarness.cleanupAlwaysSucceeds()
    let cleaner = AccountLocalDataCleanerStub(result: .success(()))
    let store = try await AccountPlanTestSupport.twoAccountStore(
        oauthDriver: harness.driver,
        metadataStore: metadata,
        localDataCleaner: cleaner,
        transferQueue: queueFixture.queue
    )

    await #expect(throws: AccountRemovalError.self) {
        try await store.removeFromApp("did:plc:alice")
    }
    #expect(store.account(for: "did:plc:alice") != nil)
    #expect(store.metadataForTesting().removalTombstones["did:plc:alice"]?
        .accountJobsSuspended == false)
    #expect(await queueFixture.queue.state(
        of: TransferFixtureSupport.aliceID
    ) == .waitingForPermission)
    let queueSavesAfterReceipt = await queueFixture.persistence.atomicSaveCount
    let queuePublicationsAfterReceipt = await queueEvents.publicationCount
    let queueCancellationsAfterReceipt = await queueEvents.cancellationRequestCount
    #expect(await harness.cleanupDIDs.isEmpty)
    #expect(await cleaner.requestedDIDs.isEmpty)

    metadata.failWhen = nil
    try await store.removeFromApp("did:plc:alice")

    #expect(await queueFixture.persistence.atomicSaveCount == queueSavesAfterReceipt)
    #expect(await queueEvents.publicationCount == queuePublicationsAfterReceipt)
    #expect(await queueEvents.cancellationRequestCount == queueCancellationsAfterReceipt)
    #expect(await harness.cleanupDIDs == ["did:plc:alice"])
    #expect(await cleaner.requestedDIDs == ["did:plc:alice"])
    #expect(store.account(for: "did:plc:alice") == nil)
    #expect(store.account(for: "did:plc:bob") != nil)
}

@MainActor
@Test("partial Petrel cleanup, final-save failure, and retry remain durable")
func partialAuthorizationAndFinalSaveRetry() async throws {
    let metadata = FailingAccountMetadataStore(
        failWhen: { envelope in !envelope.accounts.contains { $0.id == "did:plc:alice" } }
    )
    let harness = await OAuthFlowDriverHarness.partialCleanup(
        .init(localCredentialStateRemoved: true, providerRevocationConfirmed: false)
    )
    let backups = ExplicitBackupPreservationSpy()
    let events = AccountRemovalEventRecorder()
    let store = try await AccountPlanTestSupport.twoAccountStore(
        oauthDriver: harness.driver, metadataStore: metadata,
        localDataCleaner: backups, removalEvents: events.sink
    )

    await #expect(throws: AccountRemovalError.self) {
        try await store.removeFromApp("did:plc:alice")
    }
    #expect(store.account(for: "did:plc:alice") != nil)
    #expect(store.account(for: "did:plc:bob") != nil)
    #expect(store.metadataForTesting().removalTombstones["did:plc:alice"]?
        .localAuthorizationRemoved == true)
    #expect(await backups.backupURLs == [.fixtureAlice, .fixtureBob])
    #expect(await backups.bookmarksWereMutated == false)
    #expect(await events.removedDIDs.isEmpty)

    metadata.failWhen = nil
    try await store.removeFromApp("did:plc:alice")
    try await store.removeFromApp("did:plc:alice")

    #expect(store.account(for: "did:plc:alice") == nil)
    #expect(store.account(for: "did:plc:bob") != nil)
    #expect(await harness.cleanupDIDs == ["did:plc:alice"])
    #expect(await events.removedDIDs == ["did:plc:alice"])
}

@Test("account removal suspends only jobs that require that DID")
func transferQueueAccountHandoff() async throws {
    let fixture = try QueueFixture(jobs: [
        .fixtureAnonymousPublicDownload(),
        .fixtureSpaceDownload(accountDID: "did:plc:alice"),
        .fixtureSpaceDownload(accountDID: "did:plc:bob")
    ])

    let receipt = try await fixture.queue.markAccountsUnavailable(["did:plc:alice"])

    #expect(await fixture.queue.state(of: TransferFixtureSupport.anonymousID) == .queued)
    #expect(await fixture.queue.state(of: TransferFixtureSupport.aliceID) == .waitingForPermission)
    #expect(await fixture.queue.state(of: TransferFixtureSupport.bobID) == .queued)
    #expect(await fixture.persistence.atomicSaveCount == 1)
    #expect(receipt.accountDIDs == ["did:plc:alice"])
    #expect(receipt.parkedJobIDs == [TransferFixtureSupport.aliceID])
}

@MainActor
@Test("removal fences a running executor before OAuth or cache cleanup")
func removalWaitsForTransferTerminationBarrier() async throws {
    let lateCallbacks = LateCallbackProbe()
    let executor = CancellationFencedBlockingExecutor(
        kind: .blobDownload,
        lateCallbackProbe: lateCallbacks
    )
    let queueFixture = try QueueFixture(
        executorOverride: executor,
        jobs: [.fixtureSpaceDownload(
            id: TransferFixtureSupport.aliceID,
            accountDID: "did:plc:alice"
        )]
    )
    let harness = await OAuthFlowDriverHarness.cleanupAlwaysSucceeds()
    let cleaner = AccountLocalDataCleanerStub(result: .success(()))
    let metadata = InMemoryAccountMetadataStore()
    let store = try await AccountPlanTestSupport.twoAccountStore(
        oauthDriver: harness.driver,
        metadataStore: metadata,
        localDataCleaner: cleaner,
        transferQueue: queueFixture.queue
    )

    await queueFixture.queue.start()
    await executor.waitUntilStarted()
    let removal = Task { try await store.removeFromApp("did:plc:alice") }
    await executor.waitUntilCancellationObserved()

    #expect(await queueFixture.persistence.lastSavedState(
        id: TransferFixtureSupport.aliceID
    ) == .waitingForPermission)
    #expect(await queueFixture.queue.state(
        of: TransferFixtureSupport.aliceID
    ) == .waitingForPermission)
    #expect(await queueFixture.persistence.atomicSaveCount == 1)
    #expect(await harness.cleanupDIDs.isEmpty)
    #expect(await cleaner.requestedDIDs.isEmpty)
    #expect(store.metadataForTesting().removalTombstones["did:plc:alice"]?
        .accountJobsSuspended == false)

    await executor.attemptLateCallbacksThenTerminate()
    try await removal.value

    #expect(await lateCallbacks.events == [
        .reportRejectedAsStale,
        .checkpointRejectedAsStale,
        .executorTerminated
    ])
    #expect(await harness.cleanupDIDs == ["did:plc:alice"])
    #expect(await cleaner.requestedDIDs == ["did:plc:alice"])
    #expect(store.account(for: "did:plc:alice") == nil)
    #expect(store.account(for: "did:plc:bob") != nil)
}

@MainActor
@Test("account removal redirects only a window whose source requires that DID")
func removalRedirectsOnlyOwningWindow() {
    let aliceWindow = BrowserSession()
    let bobWindow = BrowserSession()
    aliceWindow.selectSource(.account(did: "did:plc:alice", destination: .spaces))
    bobWindow.selectSource(.account(did: "did:plc:bob", destination: .serverAndAccount))

    aliceWindow.handleAccountRemoval(.didRemoved("did:plc:alice"))
    bobWindow.handleAccountRemoval(.didRemoved("did:plc:alice"))

    #expect(aliceWindow.selectedSource == .global(.openPublicRepository))
    #expect(bobWindow.selectedSource == .account(
        did: "did:plc:bob", destination: .serverAndAccount
    ))
}
```

Append this deterministic cleaner to `AccountPlanTestSupport.swift`:

```swift
enum TestFailure: Error { case diskFull }

actor AccountLocalDataCleanerStub: AccountLocalDataCleaning {
    var results: [Result<Void, TestFailure>]
    private(set) var requestedDIDs: [String] = []
    private(set) var preservedBackups = true

    init(result: Result<Void, TestFailure>) { self.results = [result] }
    init(results: [Result<Void, TestFailure>]) { self.results = results }

    func removeTransientData(for accountDID: String) async throws {
        requestedDIDs.append(accountDID)
        try results.removeFirst().get()
    }
}

struct NoopAccountLocalDataCleaner: AccountLocalDataCleaning {
    func removeTransientData(for accountDID: String) async throws {}
}

@MainActor
final class FailingAccountMetadataStore: AccountMetadataStoring {
    var failWhen: ((AccountMetadataEnvelope) -> Bool)?
    private var envelope = AccountMetadataEnvelope(
        formatVersion: 3, accounts: [], removalTombstones: [:]
    )

    init(failOnSaveNumber: Int) {
        var remaining = failOnSaveNumber
        failWhen = { _ in
            remaining -= 1
            return remaining == 0
        }
    }

    init(failWhen: @escaping (AccountMetadataEnvelope) -> Bool) {
        self.failWhen = failWhen
    }

    func load(baseScope: String) throws -> AccountMetadataEnvelope { envelope }
    func save(_ candidate: AccountMetadataEnvelope) throws {
        if failWhen?(candidate) == true { throw TestFailure.diskFull }
        envelope = candidate
    }
}

actor AccountRemovalEventRecorder {
    private(set) var removedDIDs: [String] = []
    nonisolated var sink: @Sendable (AccountRemovalEvent) async -> Void {
        { event in await self.record(event) }
    }
    private func record(_ event: AccountRemovalEvent) {
        guard case let .didRemoved(did) = event else { return }
        removedDIDs.append(did)
    }
}

actor ExplicitBackupPreservationSpy: AccountLocalDataCleaning {
    private(set) var backupURLs: [URL] = [.fixtureAlice, .fixtureBob]
    private(set) var bookmarksWereMutated = false
    func removeTransientData(for accountDID: String) async throws {
        // Intentionally only records transient cleanup; backup arrays are not touched.
    }
}

extension URL {
    static let fixtureAlice = URL(fileURLWithPath: "/fixture/alice.atprotodrivebackup")
    static let fixtureBob = URL(fileURLWithPath: "/fixture/bob.atprotodrivebackup")
}

extension AccountPlanTestSupport {
    @MainActor
    static func twoAccountStore(
        oauthDriver: OAuthFlowDriver? = nil,
        metadataStore: any AccountMetadataStoring,
        localDataCleaner: any AccountLocalDataCleaning = NoopAccountLocalDataCleaner(),
        transferQueue: TransferQueue? = nil,
        removalEvents: @escaping @Sendable (AccountRemovalEvent) async -> Void = { _ in }
    ) async throws -> AccountStore {
        let driver: OAuthFlowDriver
        if let oauthDriver {
            driver = oauthDriver
        } else {
            driver = (await OAuthFlowDriverHarness.cleanupAlwaysSucceeds()).driver
        }
        let queue: TransferQueue
        if let transferQueue {
            queue = transferQueue
        } else {
            queue = try QueueFixture().queue
        }
        let alice = await aliceAccount()
        let bob = await bobAccount()
        try metadataStore.save(.init(
            formatVersion: 3,
            accounts: [alice, bob].map {
                .init(
                    id: $0.id, handle: $0.handle,
                    authMode: $0.authMode, requestedScope: $0.requestedScope
                )
            },
            removalTombstones: [:]
        ))
        let store = AccountStore(
            oauthDriver: driver, metadataStore: metadataStore,
            localDataCleaner: localDataCleaner,
            transferQueue: queue, removalEventSink: removalEvents
        )
        store.addAccountForTesting(alice)
        store.addAccountForTesting(bob)
        return store
    }
}
```

- [ ] **Step 2: Run unit tests and verify failure**

Run:

```bash
PLAN4_DERIVED="$(mktemp -d /tmp/atprotodrive-plan4-task4.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
  test -only-testing:ATProtoDriveTests
```

Expected: FAIL because the catalog and throwing removal contract do not exist.

- [ ] **Step 3: Implement the closed catalog and account-qualified cleaner**

```swift
public enum AccountControlAction: String, CaseIterable, Hashable, Sendable {
    case reconnect
    case removeFromApp
}

public enum AccountControlRole: String, Equatable, Sendable {
    case standard
    case destructive
}

public struct AccountControlDescriptor: Identifiable, Equatable, Sendable {
    public let action: AccountControlAction
    public let title: String
    public let role: AccountControlRole
    public var id: AccountControlAction { action }
}

public enum AccountControlCatalog {
    public static let actions = [
        AccountControlDescriptor(
            action: .reconnect,
            title: "Reconnect",
            role: .standard
        ),
        AccountControlDescriptor(
            action: .removeFromApp,
            title: "Remove from ATProtoDrive",
            role: .destructive
        )
    ]
}

public protocol AccountLocalDataCleaning: Sendable {
    /// Idempotent: missing account-qualified artifacts are success.
    func removeTransientData(for accountDID: String) async throws
}

public enum AccountRemovalStep: String, Equatable, Sendable {
    case transferJobs
    case localAuthorization
    case transientData
    case accountMetadata
}

public enum AccountRemovalEvent: Equatable, Sendable {
    case didRemoved(String)
}

public struct AccountRemovalError: Error, Equatable, Sendable {
    public let failedSteps: [AccountRemovalStep]
    public let message: String
}

public struct AccountRemovalTombstone: Codable, Equatable, Sendable {
    public let accountDID: String
    public var localAuthorizationRemoved: Bool
    public var transientDataRemoved: Bool
    public var accountJobsSuspended: Bool
    public var lastFailure: String?
    public let startedAt: Date
}

public struct AccountMetadataEnvelope: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let accounts: [PersistedAccountMetadata]
    public let removalTombstones: [String: AccountRemovalTombstone]

    public init(
        formatVersion: Int,
        accounts: [PersistedAccountMetadata],
        removalTombstones: [String: AccountRemovalTombstone] = [:]
    ) {
        self.formatVersion = formatVersion
        self.accounts = accounts
        self.removalTombstones = removalTombstones
    }
}
```

Replace Task 2's version-2 declaration with the version-3 declaration above; do not leave two production types. Its custom `Codable` initializer accepts format 2 with a missing tombstone field as `[:]`, rewrites it as format 3, and rejects other versions. `lastFailure` stores only a fixed `AccountRemovalStep.rawValue` plus a redacted error category—never a provider body, token, path, or raw error description. The live cleaner clears only account-qualified public/Space record caches, blob caches, Space credential-manager instances, temporary previews, source recents/bookmarks, status snapshots, and private-state snapshots. It is idempotent and treats already-missing qualified artifacts as success. It must not delete `.atprotodrivebackup` packages, their parent-directory security-scoped bookmarks, transfer history, or another account's cache.

Consume Plan 3's exact queue contract without adding a competing API:

```swift
public actor TransferQueue {
    public func markAccountsUnavailable(
        _ accountDIDs: Set<String>
    ) async throws -> TransferAccountParkingReceipt
}
```

Plan 3 owns `public let requiredAccountDIDs: Set<String>` on its existing full `TransferJobDescriptor` definition, memberwise initializer, fixtures, and Codable round trip. Task 4 verifies and consumes it; do not duplicate, rename, or abbreviate that struct here.

Anonymous public reads/downloads/backups use an empty set. Authenticated public writes, Space jobs, private-state reads, and destination writes contain the exact DID(s) they need. `markAccountsUnavailable(Set([accountDID]))` invalidates the selected execution generations, transitions every nonterminal matching job to `.waitingForPermission` with a redacted **Reconnect account to continue** reason, and durably writes the entire changed snapshot set before publishing any of those transitions. It then cancels the captured task handles, awaits every selected executor's actual termination, rejects all late report/checkpoint/completion callbacks through the stale-generation fence, and only then returns `TransferAccountParkingReceipt(accountDIDs:parkedJobIDs:terminationBarrierPassedAt:)`. This is the sole system transition allowed from `.running`/`.verifying` to `.waitingForPermission`; user-driven state transitions remain exactly those from Plan 3. Unrelated and anonymous-public jobs are byte-for-byte unchanged.

- [ ] **Step 4: Replace best-effort removal with all-required local cleanup**

Use this signature:

```swift
public func removeFromApp(_ accountDID: String) async throws
```

Implement removal as a durable, retryable state machine:

1. Look up the exact account; if a tombstone already exists, resume it. Otherwise save an envelope containing a fresh tombstone **before** any external cleanup. If that save fails, publish no in-memory removal and perform no cleanup.
2. When `accountJobsSuspended` is false, make `transferQueue.markAccountsUnavailable(Set([accountDID]))` the **first external operation after the durable tombstone** and await it. Do not invoke OAuth, destroy a client/credential manager, or clear any cache while this call is suspended. Only after its `TransferAccountParkingReceipt` returns—proving matching jobs were durably parked and their executors crossed the termination/generation fence—set `accountJobsSuspended = true` and save that tombstone step. If queue parking or the tombstone-step save fails, stop removal, retain the account/tombstone, and perform no OAuth or transient cleanup; a retry calls the idempotent queue operation again. A resumed tombstone with `accountJobsSuspended == true` may skip the idempotent call because that flag was persisted only after the barrier receipt, and Plan 3 restores those jobs as parked without starting them.
3. If not already receipted, invoke `oauthDriver.removeLocalAuthorization(account)`. Persist its partial/full receipt in the tombstone. A provider-revocation failure is reported, but a receipt that proves local tokens/DPoP state are gone satisfies the local-authorization step; never claim provider-wide revocation.
4. After the termination barrier, run the idempotent transient cleaner even if OAuth cleanup reports a failure. Persist each completed step and accumulate OAuth/cleaner failures; never short-circuit those two post-barrier cleanup attempts or use `try?`.
5. When required local steps are complete, construct an envelope with that account and tombstone removed and save it **before** mutating `accounts` or emitting a removal event. A failed final save leaves the in-memory account plus tombstone available for retry.
6. Only after the final save succeeds remove the in-memory account and emit `AccountRemovalEvent.didRemoved(accountDID)` once. Repeated calls after completion are idempotent success.

On any incomplete step publish an `AuthenticationIssue`, retain the tombstone/account metadata, and throw `AccountRemovalError`. Tests cover initial tombstone-save failure, queue/barrier failure before any secret/cache cleanup, a blocking executor with stale late callbacks, logout success plus cleaner failure and retry, partial Petrel cleanup receipt, final metadata-save failure, repeated completion, and preservation of Bob plus all explicit backups/bookmarks.

Petrel can remove local authorization even when provider-wide revocation is unavailable. Success copy must therefore say **Removed from ATProtoDrive** rather than **Account deleted** or **All sessions revoked**.

- [ ] **Step 5: Build the status view and exact confirmation copy**

`ServerAccountView(accountDID:)` renders handle/DID, PDS endpoint/server DID, repository/session health, OAuth mode, raw granted capabilities or **Not reported by this OAuth mode**, last successful check, blob upload limit, and Spaces availability. Its action area is generated only from `AccountControlCatalog.actions`.

Use this confirmation text verbatim except for handle substitution:

> This removes local authorization, cached records and blobs, Space credentials, and saved sources for @handle from ATProtoDrive. Your PDS account, records, blobs, Spaces, memberships, and backups are not deleted. Your provider may retain other sessions.

`AccountStore` exposes a true multicast `removalEvents() -> AsyncStream<AccountRemovalEvent>` by registering one continuation per subscriber; it removes a continuation on termination and publishes each event to every live window. Each window's `MainWindowView` subscribes for its lifetime and calls `BrowserSession.handleAccountRemoval(_:)`. `BrowserSource.requiredAccountDIDs` is a typed set: account overview, authenticated own-repo write contexts, Spaces, and private state contain the owning DID; anonymous public sources and local backups contain none. Only a session whose current source set contains the removed DID clears its path/selection/history and selects `.global(.openPublicRepository)`. Sessions browsing another DID, anonymous public content, local backups, and Activity remain unchanged. The Step 1 two-window test proves Alice redirects while Bob remains unchanged.

- [ ] **Step 6: Remove forbidden command labels and rerun tests**

Run the Step 2 command, then:

```bash
rg -ni 'migrate account|import repository|change email|change handle|app password|deactivate account|delete account' \
  ATProtoDrive --glob '*.swift'
```

Expected: unit tests PASS; durable removal/tombstone, exact-account transfer handoff, and two-window redirection tests pass. The search returns no action, menu, button, URL route, or command registration. Explanatory non-goal copy may use these terms only in tests or static help, never as actionable controls.

- [ ] **Step 7: Seal Task 4 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "feat: add safe account status controls"
jj new
```

---

### Task 5: Add capability-gated read-only Bluesky preferences

**Files:**
- Create: `ATProtoDrive/PrivateState/PrivateStateModels.swift`
- Create: `ATProtoDrive/PrivateState/PrivateStateService.swift`
- Create: `ATProtoDrive/PrivateState/BlueskyPreferencesService.swift`
- Create: `ATProtoDrive/PrivateState/PrivateStateStore.swift`
- Create: `ATProtoDrive/PrivateState/PrivateStateView.swift`
- Modify: `ATProtoDrive/Browser/ContentBrowserView.swift`
- Create: `ATProtoDriveTests/PrivateStateServiceTests.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AccessClassification.privateAppState(provider:accountDID:)`, `LoadState`, `BrowserFailure`, `AccountStore.account(for:)`, and Task 2 contextual reconsent.
- Produces: `PrivateStateKey(accountDID:providerID:)`, exact `PrivateStateTarget`, known/unknown `PrivateStateAvailability`, read-only `PrivateStateServing.providers(for:)` and `load(providerID:account:)`, and a per-key `PrivateStateStore`; no create, put, update, delete, or generic private-repository API.

- [ ] **Step 1: Write failing exact-account and unexpected-value-preservation tests**

```swift
@Suite("Private App State")
struct PrivateStateServiceTests {
    @Test("Bluesky preferences remain exact-account and preserve unknown JSON")
    func preferencesPreserveUnknownValues() async throws {
        let account = await AccountPlanTestSupport.aliceAccount()
        let raw = Data(#"[{"$type":"app.example.futurePref","enabled":true}]"#.utf8)
        let transport = PreferencesTransportStub(
            expectedDID: "did:plc:alice",
            responseCode: 200,
            encodedPreferences: raw
        )
        let service = BlueskyPreferencesService(transport: transport)

        let document = try await service.load(account: account)

        #expect(document.accountDID == "did:plc:alice")
        #expect(document.access == .privateAppState(
            provider: "app.bsky.actor.getPreferences",
            accountDID: "did:plc:alice"
        ))
        #expect(document.rawJSON == raw)
        #expect(await transport.requestedDIDs == ["did:plc:alice"])
    }

    @Test("2xx with nil decoded output is a protocol failure")
    func nilOutputFails() async {
        let account = await AccountPlanTestSupport.aliceAccount()
        let service = BlueskyPreferencesService(
            transport: PreferencesTransportStub(responseCode: 200, encodedPreferences: nil)
        )
        await #expect(throws: PrivateStateError.invalidResponse) {
            try await service.load(account: account)
        }
    }

    @Test("empty reported grants remain unknown and do not offer reconsent yet")
    func unknownCapabilitiesRequireProbe() async throws {
        let account = await AccountPlanTestSupport.aliceAccount()
        let service = BlueskyPreferencesService(transport: PreferencesTransportStub(
            expectedDID: account.id,
            serviceDID: "did:web:api.bsky.app#bsky_appview",
            reportedScopes: [],
            responseCode: 200,
            encodedPreferences: Data("[]".utf8)
        ))

        let provider = try #require(await service.providers(for: account).first)
        guard case let .unknownNeedsProbe(context) = provider.availability else {
            Issue.record("Expected unknown capability state")
            return
        }
        #expect(context == .privateAppState(
            method: "app.bsky.actor.getPreferences",
            serviceDID: "did:web:api.bsky.app#bsky_appview"
        ))
    }

    @Test("SwanCore evaluates exact RPC method and audience")
    func exactAudienceEvaluation() async throws {
        let account = await AccountPlanTestSupport.aliceAccount()
        let exact = "rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23bsky_appview"
        let wrongAudience = "rpc:app.bsky.actor.getPreferences?aud=did:web:other.example%23appview"

        let available = BlueskyPreferencesService(transport: PreferencesTransportStub(
            expectedDID: account.id,
            serviceDID: "did:web:api.bsky.app#bsky_appview",
            reportedScopes: [exact], responseCode: 200,
            encodedPreferences: Data("[]".utf8)
        ))
        let blocked = BlueskyPreferencesService(transport: PreferencesTransportStub(
            expectedDID: account.id,
            serviceDID: "did:web:api.bsky.app#bsky_appview",
            reportedScopes: [wrongAudience], responseCode: 403,
            encodedPreferences: nil
        ))

        #expect(await available.providers(for: account).first?.availability == .available)
        guard case .needsReconsent = await blocked.providers(for: account).first?.availability else {
            Issue.record("Expected exact-audience reconsent")
            return
        }
    }

    @Test("invalid service target and authentication failure never become reconsent")
    func invalidTargetAnd401FailClosed() async throws {
        let account = await AccountPlanTestSupport.aliceAccount()
        let invalid = BlueskyPreferencesService(transport: PreferencesTransportStub(
            expectedDID: account.id, serviceDID: "did:web:api.bsky.app",
            reportedScopes: ["atproto"], responseCode: 200,
            encodedPreferences: Data("[]".utf8)
        ))
        let expired = BlueskyPreferencesService(transport: PreferencesTransportStub(
            expectedDID: account.id,
            serviceDID: "did:web:api.bsky.app#bsky_appview",
            reportedScopes: [], responseCode: 401, encodedPreferences: nil
        ))

        #expect(await invalid.providers(for: account).first?.availability ==
            .unsupported("Invalid Bluesky AppView service target"))
        await #expect(throws: AccountAccessFailure.unauthenticated(
            endpoint: "app.bsky.actor.getPreferences"
        )) {
            try await expired.load(account: account)
        }
    }

    @MainActor
    @Test("private snapshots are isolated by account and provider")
    func perKeyStaleIsolation() async throws {
        let store = PrivateStateStore()
        let alice = await AccountPlanTestSupport.aliceAccount()
        let bob = await AccountPlanTestSupport.bobAccount()
        let aliceKey = PrivateStateKey(
            accountDID: "did:plc:alice", providerID: "app.bsky.actor.getPreferences"
        )
        let bobKey = PrivateStateKey(
            accountDID: "did:plc:bob", providerID: "app.bsky.actor.getPreferences"
        )
        await store.load(
            key: aliceKey, account: alice,
            service: PrivateStateServiceStub(document: .alicePreferences)
        )
        await store.load(
            key: bobKey, account: bob,
            service: PrivateStateServiceStub(document: .bobPreferences)
        )
        await store.load(
            key: aliceKey, account: alice,
            service: PrivateStateServiceStub(error: .offline)
        )

        #expect(store.state(for: aliceKey).isStale)
        #expect(store.state(for: aliceKey).snapshot?.accountDID == "did:plc:alice")
        #expect(store.state(for: bobKey).isStale == false)
        #expect(store.state(for: bobKey).snapshot?.accountDID == "did:plc:bob")
    }
}
```

Append this transport to `AccountPlanTestSupport.swift`:

```swift
actor PreferencesTransportStub: PreferencesTransporting {
    let expectedDID: String?
    let serviceDID: String
    let reportedScopes: Set<String>
    let responseCode: Int
    let encodedPreferences: Data?
    private(set) var requestedDIDs: [String] = []

    init(
        expectedDID: String? = nil,
        serviceDID: String = "did:web:api.bsky.app#bsky_appview",
        reportedScopes: Set<String> = ["atproto"],
        responseCode: Int,
        encodedPreferences: Data?
    ) {
        self.expectedDID = expectedDID
        self.serviceDID = serviceDID
        self.reportedScopes = reportedScopes
        self.responseCode = responseCode
        self.encodedPreferences = encodedPreferences
    }

    func fetch(account: AccountStore.Account) async throws -> PreferencesResponse {
        requestedDIDs.append(account.id)
        if let expectedDID, account.id != expectedDID {
            throw PrivateStateError.accountDIDMismatch
        }
        let count: Int? = encodedPreferences.flatMap { data in
            (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count
        }
        return .init(
            responseCode: responseCode,
            encodedPreferences: encodedPreferences,
            itemCount: count
        )
    }

    func capability(account: AccountStore.Account) async throws -> PrivateStateCapabilityPayload {
        guard expectedDID == nil || expectedDID == account.id else {
            throw PrivateStateError.accountDIDMismatch
        }
        return .init(
            activeAccountDID: account.id,
            bskyAppViewDID: serviceDID,
            reportedScopes: reportedScopes,
            scopesAreKnown: !reportedScopes.isEmpty
        )
    }
}

struct PrivateStateServiceStub: PrivateStateServing {
    let result: Result<PrivateStateDocument, BrowserFailure>

    init(document: PrivateStateDocument) { result = .success(document) }
    init(error: BrowserFailure) { result = .failure(error) }

    func providers(for account: AccountStore.Account) async -> [PrivateStateProviderDescriptor] {
        []
    }

    func load(
        providerID: String,
        account: AccountStore.Account
    ) async throws -> PrivateStateDocument {
        try result.get()
    }
}

extension PrivateStateDocument {
    static let alicePreferences = PrivateStateDocument(
        providerID: "app.bsky.actor.getPreferences", accountDID: "did:plc:alice",
        access: .privateAppState(
            provider: "app.bsky.actor.getPreferences", accountDID: "did:plc:alice"
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        itemCount: 1, rawJSON: Data("[{\"$type\":\"app.example.alice\"}]".utf8)
    )
    static let bobPreferences = PrivateStateDocument(
        providerID: "app.bsky.actor.getPreferences", accountDID: "did:plc:bob",
        access: .privateAppState(
            provider: "app.bsky.actor.getPreferences", accountDID: "did:plc:bob"
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        itemCount: 1, rawJSON: Data("[{\"$type\":\"app.example.bob\"}]".utf8)
    )
}
```

- [ ] **Step 2: Run unit tests and verify failure**

Run:

```bash
PLAN4_DERIVED="$(mktemp -d /tmp/atprotodrive-plan4-task5.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
  test -only-testing:ATProtoDriveTests
```

Expected: FAIL because private-state types and service do not exist.

- [ ] **Step 3: Implement the deliberately read-only domain and service protocol**

```swift
public enum PrivateStateAvailability: Equatable, Sendable {
    case available
    case unknownNeedsProbe(AccessContext)
    case needsReconsent(AccessContext)
    case needsReconnect(String)
    case unsupported(String)
}

public struct PrivateStateKey: Hashable, Codable, Sendable {
    public let accountDID: String
    public let providerID: String
}

public struct PrivateStateTarget: Equatable, Sendable {
    public let providerID: String
    public let method: String
    public let serviceDID: String
}

public struct PrivateStateProviderDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let availability: PrivateStateAvailability
}

public struct PrivateStateDocument: Equatable, Sendable {
    public let providerID: String
    public let accountDID: String
    public let access: AccessClassification
    public let fetchedAt: Date
    public let itemCount: Int
    public let rawJSON: Data
}

public enum PrivateStateError: Error, Equatable, Sendable {
    case unsupportedProvider(String)
    case accountDIDMismatch
    case invalidResponse
}

public struct PreferencesResponse: Equatable, Sendable {
    public let responseCode: Int
    public let encodedPreferences: Data?
    public let itemCount: Int?
}

public struct PrivateStateCapabilityPayload: Equatable, Sendable {
    public let activeAccountDID: String
    public let bskyAppViewDID: String
    public let reportedScopes: Set<String>
    public let scopesAreKnown: Bool
}

public protocol PreferencesTransporting: Sendable {
    func capability(account: AccountStore.Account) async throws -> PrivateStateCapabilityPayload
    func fetch(account: AccountStore.Account) async throws -> PreferencesResponse
}

public protocol PrivateStateServing: Sendable {
    func providers(for account: AccountStore.Account) async -> [PrivateStateProviderDescriptor]
    func load(
        providerID: String,
        account: AccountStore.Account
    ) async throws -> PrivateStateDocument
}
```

For Bluesky preferences, first require `getActiveAccountInfo().did == account.id`, then call `getCurrentAccount()`, require that row's DID again, and read `bskyAppViewDID` from that exact Petrel account. Never use a process-global/default AppView mapping. Validate method and service DID with Task 1 before parsing/evaluating scopes.

If reported scopes are empty/unknown, return `.unknownNeedsProbe(context)`; the UI offers **Check Access**, not **Reconnect** or **Grant Access**. If scopes are known, evaluate the exact tuple with:

```swift
let permissions = SwanCore.SwanScopePermissions(
    rawScopes: payload.reportedScopes,
    subject: account.id
)
let target = SwanCore.RpcPermission.Target(
    lxm: "app.bsky.actor.getPreferences",
    aud: payload.bskyAppViewDID
)
let availability: PrivateStateAvailability = permissions.allowsRPC(target)
    ? .available
    : .needsReconsent(.privateAppState(
        method: target.lxm,
        serviceDID: target.aud
    ))
```

The actual probe/load maps 401 to `.needsReconnect`/`AccountAccessFailure.unauthenticated` and only a 403 with a valid exact target to `.needsReconsent`; malformed method/audience is `.unsupported` and never reaches OAuth. The resulting permission includes the percent-encoded exact `aud`. The absence of mutation requirements is an API boundary, not just a disabled button. Do not add a generic private record list or mutation protocol.

- [ ] **Step 4: Adapt `app.bsky.actor.getPreferences` and build stale-preserving UI**

`PetrelPreferencesTransport.fetch(account:)` verifies `getActiveAccountInfo().did == account.id`, then calls:

```swift
let result = try await account.client.app.bsky.actor.getPreferences(input: .init())
if result.responseCode == 401 {
    throw AccountAccessFailure.unauthenticated(
        endpoint: "app.bsky.actor.getPreferences"
    )
}
if result.responseCode == 403 {
    let target = try await capability(account: account)
    throw AccountAccessFailure.insufficientCapability(
        endpoint: "app.bsky.actor.getPreferences",
        context: .privateAppState(
            method: "app.bsky.actor.getPreferences",
            serviceDID: target.bskyAppViewDID
        )
    )
}
guard (200 ... 299).contains(result.responseCode), let output = result.data else {
    throw PrivateStateError.invalidResponse
}
let rawJSON = try JSONEncoder().encode(output.preferences)
return PreferencesResponse(
    responseCode: result.responseCode,
    encodedPreferences: rawJSON,
    itemCount: output.preferences.items.count
)
```

`PetrelPreferencesTransport.capability(account:)` requires both `getActiveAccountInfo().did` and `getCurrentAccount()?.did` to equal `account.id`, extracts only that row's `bskyAppViewDID`, reads `getGrantedScopes(for: account.id)`, and sets `scopesAreKnown` from non-emptiness. It runs `AuthorizationTargetValidator` against the exact private context before returning.

`BlueskyPreferencesService.load(account:)` calls that transport, independently requires 2xx plus non-nil bytes, and constructs the access-qualified document. Petrel's `PreferencesForUnionArray.unexpected(ATProtocolValueContainer)` preserves future union members; retain the encoded bytes and never normalize unknown fields away.

```swift
@MainActor
@Observable
public final class PrivateStateStore {
    public private(set) var statesByKey:
        [PrivateStateKey: LoadState<PrivateStateDocument>] = [:]

    public func state(for key: PrivateStateKey) -> LoadState<PrivateStateDocument> {
        statesByKey[key] ?? .idle
    }

    public func load(
        key: PrivateStateKey,
        account: AccountStore.Account,
        service: any PrivateStateServing
    ) async {
        guard key.accountDID == account.id else {
            statesByKey[key] = .failed(
                previous: nil, failure: .authorizationRefused
            )
            return
        }
        let previous = state(for: key).snapshot
        statesByKey[key] = .loading(previous: previous)
        do {
            let document = try await service.load(
                providerID: key.providerID, account: account
            )
            guard document.accountDID == key.accountDID,
                  document.providerID == key.providerID else {
                throw PrivateStateError.accountDIDMismatch
            }
            statesByKey[key] = .loaded(document)
        } catch {
            statesByKey[key] = .failed(
                previous: previous,
                failure: (error as? BrowserFailure) ?? .transport(String(describing: error))
            )
        }
    }
}
```

Loading/failing Alice's provider can preserve only Alice's prior document and can never expose Bob's bytes. `PrivateStateView` offers provider selection, **Check Access** for unknown grants, contextual reconsent only after exact 403/known-scope denial, friendly item/type counts, and raw JSON; it has no edit toolbar or mutation context menu.

- [ ] **Step 5: Rerun tests and prove no private-state write route exists**

Run the Step 2 command, then:

```bash
rg -n 'PrivateState.*(create|put|update|delete)|func (create|put|update|delete).*Private' \
  ATProtoDrive --glob '*.swift'
```

Expected: tests PASS for empty/unknown grants, exact/wrong audience, invalid service DID, typed 401/403 behavior, unexpected union preservation, and two-account/provider cache isolation; the search returns no private-state mutation API.

- [ ] **Step 6: Seal Task 5 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "feat: browse read-only private app state"
jj new
```

---

### Task 6: Isolate persistence, temporary files, and live tests

**Files:**
- Create: `ATProtoDriveTests/IsolatedTestEnvironment.swift`
- Modify: `ATProtoDrive/Accounts/AccountMetadataStore.swift`
- Modify: `ATProtoDrive/Accounts/AccountStore.swift`
- Modify: `ATProtoDriveTests/AccountStoreTests.swift`
- Modify: `ATProtoDriveTests/RepoVerifierTests.swift`
- Modify: `ATProtoDriveTests/TransferPersistenceTests.swift`
- Modify: `ATProtoDriveTests/TransferQueueTests.swift`
- Modify: `ATProtoDriveTests/BackupManifestTests.swift`
- Modify: `ATProtoDriveTests/AtomicPackageWriterTests.swift`
- Modify: `ATProtoDriveTests/SecurityScopedBookmarkStoreTests.swift`
- Modify: `ATProtoDriveTests/BackupServiceTests.swift`
- Modify: `ATProtoDriveTests/BackupCatalogTests.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the concrete metadata boundary created in Task 2 and Plan 3 path/persistence initializers.
- Produces: one UUID-qualified defaults suite and filesystem root per test, deterministic offline default test target, and an environment-gated live OAuth test.

- [ ] **Step 1: Add failing isolation tests**

```swift
@MainActor
@Test("two AccountStores use isolated metadata without mutating production defaults")
func accountStoresAndFilesystemAreIsolated() async throws {
    let first = try IsolatedTestEnvironment.make()
    let second = try IsolatedTestEnvironment.make()
    defer { first.remove(); second.remove() }
    let productionDefaults = UserDefaults.standard
    let productionBefore = productionDefaults.data(forKey: AccountMetadataKeys.accounts)
    let firstMetadata = UserDefaultsAccountMetadataStore(
        defaults: first.defaults, key: AccountMetadataKeys.accounts
    )
    let secondMetadata = UserDefaultsAccountMetadataStore(
        defaults: second.defaults, key: AccountMetadataKeys.accounts
    )
    try firstMetadata.save(.fixture(accountDID: "did:plc:alice"))
    try secondMetadata.save(.fixture(accountDID: "did:plc:bob"))
    let firstDriver = OAuthFlowDriver.restoreFixture(did: "did:plc:alice")
    let secondDriver = OAuthFlowDriver.restoreFixture(did: "did:plc:bob")
    let firstStore = AccountStore(oauthDriver: firstDriver, metadataStore: firstMetadata)
    let secondStore = AccountStore(oauthDriver: secondDriver, metadataStore: secondMetadata)

    await firstStore.restoreOnce()
    await secondStore.restoreOnce()
    try Data("one".utf8).write(to: first.root.appendingPathComponent("fixture"))

    #expect(firstStore.accounts.map(\.id) == ["did:plc:alice"])
    #expect(secondStore.accounts.map(\.id) == ["did:plc:bob"])
    #expect(!FileManager.default.fileExists(
        atPath: second.root.appendingPathComponent("fixture").path
    ))
    #expect(productionDefaults.data(forKey: AccountMetadataKeys.accounts) == productionBefore)
}

extension AccountMetadataEnvelope {
    static func fixture(accountDID: String) -> Self {
        .init(formatVersion: 3, accounts: [
            .init(
                id: accountDID, handle: "\(accountDID.split(separator: ":").last!).example",
                authMode: .publicOAuth,
                requestedScope: "atproto space:*?authority=*&skey=*&action=read_self"
            )
        ], removalTombstones: [:])
    }
}

enum OfflineFixtureOAuthError: Error { case unexpectedExternalAccess(String) }

extension OAuthFlowDriver {
    static func restoreFixture(did: String) -> Self {
        .init(
            resolve: { _ in throw OfflineFixtureOAuthError.unexpectedExternalAccess("resolve") },
            start: { _ in throw OfflineFixtureOAuthError.unexpectedExternalAccess("start") },
            complete: { _, _ in throw OfflineFixtureOAuthError.unexpectedExternalAccess("callback") },
            restore: { metadata in
                guard metadata.id == did else { return nil }
                let client = await ATProtoClient(
                    baseURL: URL(string: "atproto-fixture://restore")!
                )
                return RestoredOAuthAccount(
                    completion: .init(
                        did: did, handle: metadata.handle,
                        pdsURL: URL(string: "https://fixture.invalid")!
                    ),
                    client: client, authMode: metadata.authMode
                )
            },
            reportedGrantedScopes: { _ in [] },
            discardPendingAuthorization: { _ in },
            removeLocalAuthorization: { _ in
                .init(localCredentialStateRemoved: true, providerRevocationConfirmed: nil)
            }
        )
    }
}
```

- [ ] **Step 2: Run unit tests and record the current global-state failure**

Run the Task 5 test command with a fresh derived-data directory.

Expected: FAIL because the isolation helper and explicit production/test metadata injection are absent, or because `AccountStore` still reaches `UserDefaults.standard` internally.

- [ ] **Step 3: Implement UUID-qualified test state and inject persistence**

```swift
struct IsolatedTestEnvironment {
    let suiteName: String
    let defaults: UserDefaults
    let root: URL

    static func make() throws -> Self {
        let id = UUID().uuidString
        let suite = "blue.catbird.atprotodrive.tests.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATProtoDriveTests-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Self(suiteName: suite, defaults: defaults, root: root)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
```

Task 2 already owns `PersistedAccountMetadata`, `AccountMetadataEnvelope`, `AccountMetadataStoring`, and `UserDefaultsAccountMetadataStore`. `AccountStore.live()` is the only constructor allowed to inject `UserDefaults.standard`; every other initializer requires an explicit metadata store. `AccountStore` itself contains no reference to `UserDefaults.standard` or fixed path. Give each named backup/transfer/verifier test above a unique subdirectory beneath `environment.root`; replace `/tmp/ATProtoDriveFixtures/space-repo.car` with `environment.root.appendingPathComponent("space-repo.car")` and remove it in `defer`. Snapshot the production defaults value and production Application Support tree metadata before/after the isolation suite; assert they are unchanged rather than writing a sentinel there.

Add this DEBUG-only construction seam for the interactive discovery gate:

```swift
#if DEBUG
public static func liveOAuthDiscoveryTest(
    metadataStore: any AccountMetadataStoring,
    namespacePrefix: String
) -> AccountStore
public func localOAuthStorageNamespacesForTesting(
    prefix: String
) async throws -> [String]
#endif
```

It uses the production resolver, network transport, redirect URI, and `OAuthClientFactory`, but the supplied metadata store and UUID-qualified `namespacePrefix` replace both production persistence identities. `namespace(for:)` must produce only `"\(namespacePrefix).pending.\(flowID)"` for an add flow; it must never use the shipping namespace or `UserDefaults.standard`. The live driver's discard operation deletes the exact test namespace's Petrel/Keychain material. The audit method queries that same local OAuth-storage adapter by prefix and returns namespace names only—never tokens—so the test proves cleanup rather than assuming it. This factory and audit are unavailable in Release and are not used by the app.

- [ ] **Step 4: Gate the interactive live OAuth discovery test**

Change the live test declaration to:

```swift
@Test(
    "live OAuth discovery mints a consent URL",
    .enabled(
        if: ProcessInfo.processInfo.environment["ATPROTO_DRIVE_RUN_LIVE_TESTS"] == "1"
            && !(ProcessInfo.processInfo.environment["ATPROTO_DRIVE_LIVE_HANDLE"]?.isEmpty ?? true),
        "Set both live-test environment variables"
    )
)
func liveOAuthDiscovery() async throws {
    let processEnvironment = ProcessInfo.processInfo.environment
    let handle = try #require(processEnvironment["ATPROTO_DRIVE_LIVE_HANDLE"])
    let isolated = try IsolatedTestEnvironment.make()
    defer { isolated.remove() }
    let namespacePrefix = "blue.catbird.atprotodrive.live-test.\(UUID().uuidString)"
    let metadata = UserDefaultsAccountMetadataStore(
        defaults: isolated.defaults,
        key: AccountMetadataKeys.accounts
    )
    let productionBefore = UserDefaults.standard.data(forKey: AccountMetadataKeys.accounts)
    let store = AccountStore.liveOAuthDiscoveryTest(
        metadataStore: metadata,
        namespacePrefix: namespacePrefix
    )

    var discoveryURL: URL?
    var discoveryFailure: Error?
    do {
        discoveryURL = try await store.beginLogin(handle: handle, intent: .add)
    } catch {
        discoveryFailure = error
    }

    var cleanupFailure: Error?
    do {
        try await store.discardPendingAuthorizations()
    } catch {
        cleanupFailure = error
    }

    #expect(store.pendingAuthorizationCountForTesting == 0)
    #expect(try await store.localOAuthStorageNamespacesForTesting(
        prefix: namespacePrefix
    ).isEmpty)
    #expect(try metadata.load(baseScope: "atproto").accounts.isEmpty)
    #expect(UserDefaults.standard.data(forKey: AccountMetadataKeys.accounts) == productionBefore)

    if let cleanupFailure { throw cleanupFailure }
    if let discoveryFailure { throw discoveryFailure }
    #expect(discoveryURL?.scheme == "https")
}
```

Enable the test only when **both** `ATPROTO_DRIVE_RUN_LIVE_TESTS == "1"` and non-empty `ATPROTO_DRIVE_LIVE_HANDLE` are present; otherwise Swift Testing reports a disabled test with the reason **Set both live-test environment variables**. The normal test gate leaves both unset and makes no OAuth discovery or network request. The test always attempts pending-flow discard after `beginLogin`, gives cleanup failure precedence, verifies the pending map and isolated metadata are empty, and removes its defaults/filesystem environment before returning. A throwing live `start` must already have cleaned a not-yet-pending client as required by Task 2. Task 9 supplies and records the operator-provided target; no personal/default handle exists in source.

- [ ] **Step 5: Run the unit target twice to detect leaked process state**

```bash
PLAN4_DERIVED_A="$(mktemp -d /tmp/atprotodrive-plan4-task6a.XXXXXX)"
PLAN4_DERIVED_B="$(mktemp -d /tmp/atprotodrive-plan4-task6b.XXXXXX)"
for PLAN4_DERIVED in "$PLAN4_DERIVED_A" "$PLAN4_DERIVED_B"; do
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$PLAN4_DERIVED" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:ATProtoDriveTests || exit 1
done
```

Expected: both runs PASS; no browser opens, no Keychain prompt appears, and the test-created defaults suites/directories are removed.

- [ ] **Step 6: Seal Task 6 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "test: isolate account and filesystem state"
jj new
```

---

### Task 7: Add deterministic debug fixtures and stable accessibility IDs

**Files:**
- Create: `ATProtoDrive/Support/AccessibilityIdentifiers.swift`
- Create: `ATProtoDrive/Testing/DebugFixtureScenario.swift`
- Create: `ATProtoDrive/Testing/DebugFixtureRuntime.swift`
- Create: `ATProtoDrive/Testing/DebugOAuthCallbackReceiptRecorder.swift`
- Modify: `ATProtoDrive/ATProtoDriveApp.swift`
- Modify: `ATProtoDrive/Browser/MainWindowView.swift`
- Modify: `ATProtoDrive/Browser/DriveSidebarView.swift`
- Modify: `ATProtoDrive/Browser/BrowserTableShell.swift`
- Modify: `ATProtoDrive/Browser/BrowserInspectorView.swift`
- Modify: `ATProtoDrive/Browser/BrowserToolbar.swift`
- Modify: `ATProtoDrive/Browser/InlineErrorBanner.swift`
- Modify: `ATProtoDrive/Transfers/ActivityView.swift`
- Modify: `ATProtoDrive/Accounts/ServerAccountView.swift`
- Modify: `ATProtoDrive/PrivateState/PrivateStateView.swift`
- Create: `ATProtoDriveTests/AppDependenciesTests.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: all service/store protocols and browser surfaces from Plans 1-3 plus Tasks 1-5.
- Produces: app-root `AppDependencies.live()` and DEBUG-only `AppDependencies.fixture(_:)`, `DebugFixtureScenario`, concrete scripted service/persistence/executor graph, `ExternalAccessSentinel`, and stable `AccessibilityID` values used by Task 8.

- [ ] **Step 1: Add a failing launch-parser unit test**

```swift
@Test("fixture mode requires DEBUG scenario and explicit state root")
func fixtureLaunchParsing() throws {
    let environment = [
        "ATPROTO_DRIVE_FIXTURE": "two-accounts",
        "ATPROTO_DRIVE_STATE_TOKEN": "atd-ui-123",
        "ATPROTO_DRIVE_DISABLE_NETWORK": "1"
    ]
    let launch = try #require(DebugFixtureScenario.parse(environment: environment))
    #expect(launch.scenario == .twoAccounts)
    #expect(launch.stateToken == "atd-ui-123")
    #expect(launch.stateRoot.path.contains("/Library/Application Support/ATProtoDrive/DebugFixtures/atd-ui-123"))
    #expect(launch.disablesNetwork)
    #expect(!launch.reusesExistingState)
}

@MainActor
@Test("fixture root cannot be reused by another scenario")
func fixtureRootScenarioIsolation() throws {
    let applicationSupport = FileManager.default.temporaryDirectory
        .appendingPathComponent("ATProtoDriveFixtureIsolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: applicationSupport, withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let token = "shared-token"
    let first = try #require(DebugFixtureScenario.parse(environment: [
        "ATPROTO_DRIVE_FIXTURE": "two-accounts",
        "ATPROTO_DRIVE_STATE_TOKEN": token,
        "ATPROTO_DRIVE_DISABLE_NETWORK": "1"
    ], applicationSupport: applicationSupport))
    _ = try AppDependencies.fixture(first)
    let wrongScenario = try #require(DebugFixtureScenario.parse(environment: [
        "ATPROTO_DRIVE_FIXTURE": "public-records",
        "ATPROTO_DRIVE_STATE_TOKEN": token,
        "ATPROTO_DRIVE_DISABLE_NETWORK": "1",
        "ATPROTO_DRIVE_REUSE_FIXTURE_ROOT": "1"
    ], applicationSupport: applicationSupport))

    #expect(throws: DebugFixtureError.runtimeReceiptMismatch) {
        _ = try AppDependencies.fixture(wrongScenario)
    }
}
```

- [ ] **Step 2: Run unit tests and verify fixture types are missing**

Run the Task 5 test command with a fresh derived-data directory.

Expected: FAIL with missing `DebugFixtureScenario`.

- [ ] **Step 3: Implement debug-only fixture launch and fail-fast I/O traps**

```swift
#if DEBUG
public enum DebugFixtureName: String, Sendable {
    case twoAccounts = "two-accounts"
    case publicRecords = "public-records"
    case blobsAndQuickLook = "blobs-quicklook"
    case staleAndErrors = "stale-errors"
    case activity = "activity"
    case accountControls = "account-controls"
}

public enum DebugFixtureError: Error, Equatable, Sendable {
    case invalidEnvironment
    case unexpectedExternalAccess(String)
    case unexpectedExistingState
    case runtimeReceiptMismatch
}

public struct DebugFixtureScenario: Sendable {
    public let scenario: DebugFixtureName
    public let stateToken: String
    public let stateRoot: URL
    public let disablesNetwork: Bool
    public let reusesExistingState: Bool

    public static func parse(
        environment: [String: String],
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
    ) throws -> Self? {
        guard let raw = environment["ATPROTO_DRIVE_FIXTURE"] else { return nil }
        let reuseValue = environment["ATPROTO_DRIVE_REUSE_FIXTURE_ROOT"]
        guard let scenario = DebugFixtureName(rawValue: raw),
              let token = environment["ATPROTO_DRIVE_STATE_TOKEN"],
              token.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil,
              environment["ATPROTO_DRIVE_DISABLE_NETWORK"] == "1",
              reuseValue == nil || reuseValue == "1" else {
            throw DebugFixtureError.invalidEnvironment
        }
        let root = applicationSupport
            .appendingPathComponent("ATProtoDrive/DebugFixtures", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        return Self(
            scenario: scenario,
            stateToken: token,
            stateRoot: root,
            disablesNetwork: true,
            reusesExistingState: reuseValue == "1"
        )
    }
}

public struct DebugFixtureRuntimeReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int // exactly 1
    public let scenario: String
    public let stateToken: String
}
#endif
```

The state root is therefore inside the signed app's sandbox container; never accept an arbitrary `/tmp` or absolute path from the test process. The UI test passes only a token and derives the same container path from the app bundle identifier when checking the sentinel. A normal fixture launch requires the derived root not to exist, creates it with mode `0700`, and atomically writes `fixture-runtime.json` containing `DebugFixtureRuntimeReceipt(schemaVersion:1, scenario:scenario.rawValue, stateToken:token)`. Reuse is allowed only with `ATPROTO_DRIVE_REUSE_FIXTURE_ROOT=1` and an exact existing receipt match; otherwise fixture construction throws `unexpectedExistingState` or `runtimeReceiptMismatch` before reading persisted state. This makes cross-scenario reuse impossible while retaining an explicit same-scenario relaunch path for recovery tests.

Define the root dependency graph in `ATProtoDriveApp.swift` and keep scene-local `BrowserSession` outside it:

```swift
public protocol BackupCatalogServing: Sendable {
    func refresh() async -> [BackupCatalogItem]
    func open(_ reference: BackupPackageReference) async throws -> BackupCatalogItem
    func verify(_ reference: BackupPackageReference) async throws -> BackupVerificationReport
    func moveToTrash(_ reference: BackupPackageReference) async throws
}

@MainActor
public struct AppDependencies {
    public let accounts: AccountStore
    public let accountStatus: any AccountStatusServing
    public let privateState: any PrivateStateServing
    public let publicRepositories: any PublicRepositoryServing
    public let publicBlobs: any PublicBlobServing
    public let spaceRepositoryForAccount:
        @Sendable (String) throws -> any SpaceRepositoryServing
    public let spaceBlobsForAccount:
        @Sendable (String) throws -> any SpaceBlobServing
    public let backupCatalog: any BackupCatalogServing
    public let transferQueue: TransferQueue
    public let transferStore: TransferStore

    public static func live() throws -> AppDependencies

    #if DEBUG
    public static func fixture(_ scenario: DebugFixtureScenario) throws -> AppDependencies
    #endif
}
```

`live()` builds production OAuth, Keychain, UserDefaults, services, executors, and persistence once. `fixture(_:)` creates the state root with `0700`, then builds only concrete offline implementations in `DebugFixtureRuntime.swift`: `ScriptedPublicRepositoryService`, `ScriptedPublicBlobService`, `ScriptedSpaceRepositoryService`, `ScriptedSpaceBlobService`, `ScriptedAccountStatusService`, `ScriptedPrivateStateService`, Plan 3's exact `JSONTransferPersistence(directory: scenario.stateRoot.appendingPathComponent("Transfers"))`, `ScriptedTransferExecutorRegistry`, `FixtureBackupCatalog` rooted at `scenario.stateRoot.appendingPathComponent("Backups")`, and app-target `FixtureAccountMetadataStore` rooted at `scenario.stateRoot.appendingPathComponent("Accounts")`. The latter two conform to the same production-facing protocols as their live counterparts and contain no Keychain or standard-defaults code. Scripted calls consume deterministic `FixtureScript` responses keyed by typed locator and return a loud `FixtureScriptError.unscriptedCall(endpoint:key:)` for anything absent.

Fixture account rows are installed through DEBUG-only `AccountStore.installFixtureAccount(summary:runtime:)`. Its runtime uses an **anonymous** `await ATProtoClient(baseURL: URL(string: "atproto-fixture://trap")!)` solely to preserve the Plan 2 `Account` value shape and a resolver that calls the sentinel; it never constructs `OAuthConfig`, opens Keychain, restores Petrel state, or starts OAuth. Every feature view receives the scripted service from `AppDependencies`, not `Account.client`. The fixture OAuth driver has all seven closures (resolve, start, complete, restore, reported grants, pending-flow discard, and established-account cleanup); each external operation trips the sentinel unless the current script explicitly models a reconnect/reconsent result.

Make accidental external access fail XCUITest deterministically:

```swift
public struct ExternalAccessRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let operation: String
    public let processID: Int32
    public let timestamp: Date
}

public final class ExternalAccessSentinel: @unchecked Sendable {
    public let url: URL // <stateRoot>/UNEXPECTED_EXTERNAL_ACCESS.json

    public func trip(kind: String, operation: String) -> Never {
        let record = ExternalAccessRecord(
            kind: kind, operation: operation,
            processID: ProcessInfo.processInfo.processIdentifier,
            timestamp: Date()
        )
        try! AtomicJSONStore.write(record, to: url, permissions: 0o600)
        fatalError("Fixture external access: \(kind):\(operation)")
    }
}
```

Register `FixtureNetworkTrapURLProtocol` for the fixture process and inject `FixtureKeychainTrap` into the OAuth/metadata graph; both call `trip`. In `ATProtoDriveUIAssertions`, `assertNoExternalAccess()` reads the sandbox-safe sentinel after every test action and again in `tearDownWithError`; a present sentinel calls `XCTFail` with its redacted operation. A terminated app with a sentinel is therefore an explicit external-I/O failure, not a generic launch failure.

`DebugFixtureRuntime` provides two accounts with distinct DIDs/PDSes, public collections/records and CRUD conflicts, Space create/policy/member/delete flows, public and Space blobs (including identical CIDs in different access classes), a readable Space and unsupported Space state, private preferences, verified/incomplete backups and resume, every transfer state, cross-source disclosure/partial outcome, drag-to-Finder payloads, stale data plus inline failures, reconnect/reconsent, and removal confirmation. The `blobs-quicklook` script also drives the real Plan 3 UI handoff boundaries: a blob-download job accepts an `NSSavePanel` bookmark and writes CID-verified bytes; attachment upload returns `remoteWriteUnverified` after exactly one upload, then an exact-record reconciliation returns the uploaded CID without re-upload; full-backup creation accepts an `NSSavePanel` package destination, atomically publishes a readable package, verifies it through `BackupVerificationTransferExecutor`, and moves it through `NSWorkspace.recycle`; and the Activity fixture exposes a persisted partial result. Script counters make `attachment.upload-count == 1` an assertion over executor calls, not static label text. Fixture persistence writes only below `scenario.stateRoot`; save/open panel destinations granted by the UI test are the only scoped external files.

Add an `AppDependenciesTests` case that creates a temporary Application Support root, parses every `DebugFixtureName`, constructs `AppDependencies.fixture`, calls every scripted service's first read and transfer snapshot, and asserts: both fixture DIDs remain distinct; no OAuth config or authenticated Petrel client was created; all persistence URLs are descendants of the scenario root after standardized/symlink resolution; and the sentinel file is absent. `AppDependencies.live()` is not called by this test.

The separate DEBUG-only live-callback recorder used by Task 9 is concrete and redacted:

```swift
public struct OAuthCallbackReceipt: Codable, Equatable, Sendable {
    public let processID: Int32
    public let executablePath: String
    public let executableSHA256: String
    public let bundleIdentifier: String
    public let handledAt: Date
    public let route: String       // always "/callback"
    public let stateSHA256: String // never raw state
}

public struct DebugOAuthCallbackReceiptRecorder: Sendable {
    public static func fromEnvironment(
        _ environment: [String: String]
    ) throws -> Self? // accepts ^[A-Za-z0-9-]{1,80}$ only

    public func recordAcceptedCallback(state: String) throws
}
```

It resolves `<Application Support>/ATProtoDrive/Acceptance/<token>/callback.json`, canonicalizes beneath the Acceptance root, hashes the running executable at `Bundle.main.executableURL`, writes mode `0600` through `AtomicJSONStore`, and is invoked only after `OAuthCallbackRoute.validate` accepts the route/state. It stores none of the callback query except the state digest. Release builds contain neither the environment parser nor recorder.

- [ ] **Step 4: Apply stable identifiers at semantic controls**

Use one central enum:

```swift
public enum AccessibilityID {
    public static let sidebar = "browser.sidebar"
    public static let content = "browser.content"
    public static let search = "browser.search"
    public static let inspector = "browser.inspector"
    public static let inspectorToggle = "browser.inspector.toggle"
    public static let loadMore = "browser.load-more"
    public static let staleBanner = "browser.error.stale"
    public static let retry = "browser.error.retry"
    public static let activityTable = "activity.table"
    public static let reconnect = "account.reconnect"
    public static let removeFromApp = "account.remove-from-app"
    public static let removalConfirm = "account.remove.confirm"
    public static let rawJSON = "inspector.raw-json"
    public static let externalAccessFailure = "fixture.external-access-failure"
    public static let windowRootPrefix = "window.root."

    public static func source(_ stableID: String) -> String { "source.\(stableID)" }
    public static func row(_ stableID: String) -> String { "row.\(stableID)" }
    public static func window(_ stableID: String) -> String { windowRootPrefix + stableID }
}
```

Declare constants/functions for every Task 8 literal, grouped exactly as follows:

- Browser/inspector: `browser.sidebar`, `browser.content`, `browser.search`, `browser.inspector`, `browser.inspector.toggle`, `browser.error.stale`, `browser.error.retry`, `column.name`, `column.modified`, `inspector.summary`, `inspector.identifiers`, and `inspector.raw-json`.
- Records/blobs/editor: `record.create`, `record.edit`, `record.delete`, `record.delete.confirm`, `record.conflict`, `record.copy-to`, `conflict.cancel`, `editor.collection`, `editor.record-key`, `editor.raw-json`, `editor.save`, `attachment.add`, `attachment.reconciliation`, `attachment.upload-count`, `blob.quick-look`, `blob.drag-source`, `blob.download`, and `blob.download-only`.
- Spaces: `space.create`, `space.create.name`, `space.create.confirm`, `space.policy`, `space.policy.invite-only`, `space.policy.save`, `space.member.add`, `space.member.did`, `space.member.confirm`, `space.member.remove`, `space.member.remove.confirm`, `space.delete`, `space.delete.confirm`, and `space.non-atomic-warning`.
- Backup/copy/Activity: `backup.create`, `backup.created-row`, `backup.completeness`, `backup.preflight.verified`, `backup.resume`, `backup.verify`, `backup.verification-status`, `backup.reveal`, `backup.trash`, `backup.trash.confirm`, `copy.destination.public`, `copy.disclosure.confirm`, `copy.disclosure.accept`, `copy.partial-outcome`, `activity.cancel`, `activity.retry`, `activity.resume`, `activity.result.verified`, `activity.reveal`, and `transfer.stage`.
- Account/private/fixture: `account.did`, `account.capabilities`, `account.reconnect`, `account.remove-from-app`, `account.remove.confirm`, `account.remove.confirm-button`, `oauth.reconnect.sheet`, `oauth.fixture.reject-callback`, `private-state.read-only`, and `fixture.appearance`.

Source/row IDs use `source(_:)` and `row(_:)` with the stable suffixes shown in Task 8; they never derive from localized labels or row indexes. Production window roots use `BrowserSession.id.uuidString`; fixture mode consumes the ordered safe IDs from `ATPROTO_DRIVE_WINDOW_IDS` so tests can address `window.root.alice` and `window.root.bob`. Children remain descendants of that root. Ensure focusable tables, search, Quick Look source rows, inspector toggle, banners, Activity controls, and both account actions have identifiers.

- [ ] **Step 5: Build the debug fixture app without signing**

```bash
PLAN4_DERIVED="$(mktemp -d /tmp/atprotodrive-plan4-task7.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_DERIVED" \
  PRODUCT_BUNDLE_IDENTIFIER=blue.catbird.atprotodrive.smoke \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. This proves compilation and fixture assembly only; it is not OAuth/Keychain evidence.

- [ ] **Step 6: Seal Task 7 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "test: add deterministic macOS UI fixtures"
jj new
```

---

### Task 8: Create the macOS UI-test target and cover native UX contracts

**Files:**
- Create: `ATProtoDriveUITests/ATProtoDriveUIAssertions.swift`
- Create: `ATProtoDriveUITests/ATProtoDriveUITests.swift`
- Modify: `ATProtoDrive.xcodeproj/project.pbxproj`
- Modify: `ATProtoDrive.xcodeproj/xcshareddata/xcschemes/ATProtoDrive.xcscheme`

**Interfaces:**
- Consumes: Task 7 fixture environment and accessibility IDs; browser, Quick Look, Activity, transfer, and account surfaces from all four plans.
- Produces: `ATProtoDriveUITests` UI-testing bundle linked to the app target and included in the shared scheme's Test action.

- [ ] **Step 1: Write the UI source and prove the target is not wired yet**

Create the two source files containing the Step 3 shell test on disk but do not add their PBX objects or scheme entry yet. Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj \
  -target ATProtoDriveUITests -showBuildSettings
```

Expected: FAIL with **The project named ATProtoDrive does not contain a target named ATProtoDriveUITests**. This is the deliberate red phase; Task 7 already installed the accessibility IDs, so a missing-identifier runtime failure would be contradictory.

- [ ] **Step 2: Add complete signed UI-target and scheme wiring**

In `project.pbxproj`, add a `com.apple.product-type.bundle.ui-testing` target named `ATProtoDriveUITests`, product `ATProtoDriveUITests.xctest`, app target dependency/container proxy, both source build files, and Debug and Release configurations with:

```text
CODE_SIGN_IDENTITY = "Apple Development"
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = 44U2ZPNQPK
ENABLE_TESTING_SEARCH_PATHS = YES
GENERATE_INFOPLIST_FILE = YES
MACOSX_DEPLOYMENT_TARGET = 15.0
PRODUCT_BUNDLE_IDENTIFIER = blue.catbird.atprotodrive.uitests
PRODUCT_NAME = "$(TARGET_NAME)"
SDKROOT = macosx
SWIFT_VERSION = 6.0
TEST_TARGET_NAME = ATProtoDrive
```

Add its group, file references, build files, Sources phase, Frameworks phase, Resources phase, target attributes, product, configuration list, and project target membership. Debug also sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"` and `SWIFT_OPTIMIZATION_LEVEL = "-Onone"`; both configurations inherit the project's runpath/search paths. Add it as an unskipped `TestableReference` in `ATProtoDrive.xcscheme` after `ATProtoDriveTests`. `xcodebuild -showBuildSettings -target ATProtoDriveUITests` must show the exact team, signing style, SDK, product, testing search paths, and `TEST_TARGET_NAME` above.

- [ ] **Step 3: Implement window-scoped UI helpers and make the shell test pass**

```swift
import XCTest

extension XCTestCase {
    func element(in root: XCUIElement, id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func attachScreenshot(named name: String, element: XCUIElement) {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct UITestFixtureReceipt: Codable, Equatable {
    let schemaVersion: Int
    let scenario: String
    let stateToken: String
}

final class ATProtoDriveUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateToken: String!
    private var fixtureRoots: [URL] = []
    private var currentFixture: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        launchFixture("two-accounts", appearance: "light")
    }

    override func tearDownWithError() throws {
        assertNoExternalAccess()
        app?.terminate()
        for root in fixtureRoots {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func launchFixture(_ fixture: String, appearance: String) {
        app?.terminate()
        stateToken = "ui-\(UUID().uuidString)"
        currentFixture = fixture
        let root = fixtureContainerRoot(token: stateToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        fixtureRoots.append(root)
        app = XCUIApplication()
        app.launchEnvironment = fixtureEnvironment(fixture: fixture, appearance: appearance)
        app.launch()
    }

    private func relaunchCurrentFixture(appearance: String) throws {
        app.terminate()
        let root = fixtureContainerRoot(token: stateToken)
        let receiptURL = root.appendingPathComponent("fixture-runtime.json")
        let receipt = try JSONDecoder().decode(
            UITestFixtureReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        XCTAssertEqual(receipt, .init(
            schemaVersion: 1, scenario: currentFixture, stateToken: stateToken
        ))
        app = XCUIApplication()
        var environment = fixtureEnvironment(
            fixture: currentFixture, appearance: appearance
        )
        environment["ATPROTO_DRIVE_REUSE_FIXTURE_ROOT"] = "1"
        app.launchEnvironment = environment
        app.launch()
    }

    private func fixtureEnvironment(
        fixture: String,
        appearance: String
    ) -> [String: String] {
        [
            "ATPROTO_DRIVE_FIXTURE": fixture,
            "ATPROTO_DRIVE_STATE_TOKEN": stateToken,
            "ATPROTO_DRIVE_DISABLE_NETWORK": "1",
            "ATPROTO_DRIVE_WINDOW_WIDTH": "1280",
            "ATPROTO_DRIVE_WINDOW_HEIGHT": "800",
            "ATPROTO_DRIVE_APPEARANCE": appearance,
            "ATPROTO_DRIVE_WINDOW_IDS": "alice,bob"
        ]
    }

    private func windowRoot(_ stableID: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "window.root.\(stableID)").firstMatch
    }

    private func assertNoExternalAccess(file: StaticString = #filePath, line: UInt = #line) {
        for root in fixtureRoots {
            let sentinel = root.appendingPathComponent("UNEXPECTED_EXTERNAL_ACCESS.json")
            if let bytes = try? Data(contentsOf: sentinel), !bytes.isEmpty {
                XCTFail("Fixture attempted external access: \(String(decoding: bytes, as: UTF8.self))",
                        file: file, line: line)
            }
        }
    }

    private func fixtureContainerRoot(token: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/blue.catbird.atprotodrive/Data/Library/Application Support")
            .appendingPathComponent("ATProtoDrive/DebugFixtures", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func waitForValue(
        _ element: XCUIElement,
        _ expected: String,
        timeout: TimeInterval = 10
    ) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    func testFinderLikeShellAndInspector() throws {
        let alice = windowRoot("alice")
        XCTAssertTrue(alice.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.firstMatch.frame.size.width, 1280, accuracy: 2)
        XCTAssertEqual(app.windows.firstMatch.frame.size.height, 800, accuracy: 2)
        XCTAssertTrue(element(in: alice, id: "browser.sidebar").exists)
        XCTAssertTrue(element(in: alice, id: "browser.content").exists)
        XCTAssertEqual(app.windows.count, 1)
        element(in: alice, id: "browser.inspector.toggle").click()
        XCTAssertTrue(element(in: alice, id: "browser.inspector").exists)
        attachScreenshot(named: "finder-like-shell-light-1280x800", element: app.windows.firstMatch)
        assertNoExternalAccess()
    }
}
```

`fixtureContainerRoot(token:)` derives `~/Library/Containers/<built app bundle id>/Data/Library/Application Support/ATProtoDrive/DebugFixtures/<token>` and refuses `..`/symlinks. Task 7 applies `NSApp.appearance` and the first window's content size only in fixture mode; production window behavior is unchanged.

Run the newly wired shell test:

Run:

```bash
PLAN4_VERIFY="$(mktemp -d /tmp/atprotodrive-plan4-task8.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_VERIFY/DerivedData" \
  -resultBundlePath "$PLAN4_VERIFY/UITests.xcresult" \
  test -only-testing:ATProtoDriveUITests
```

Expected: `** TEST SUCCEEDED **`; target dependency/container proxy launches the signed app, the exact 1280×800 light window is captured, and the external-access sentinel remains absent.

This uses the project's normal Apple Development signing because XCUITest runtime injection is not an unsigned-build proof. Fixture mode still traps Keychain/network access, so this step proves deterministic UI runtime only, not OAuth continuity.

- [ ] **Step 4: Add two-window, keyboard, search, Quick Look, inspector, stale error, and Activity tests**

```swift
func testTwoWindowsKeepIndependentBrowserSessions() throws {
    let alice = windowRoot("alice")
    XCTAssertTrue(alice.waitForExistence(timeout: 5))
    app.typeKey("n", modifierFlags: .command)
    let bob = windowRoot("bob")
    XCTAssertTrue(bob.waitForExistence(timeout: 5))

    element(in: alice, id: "source.alice-public").click()
    element(in: alice, id: "browser.search").click()
    element(in: alice, id: "browser.search").typeText("invoice source:public")
    element(in: alice, id: "column.modified").click()
    element(in: alice, id: "row.public-invoice").click()

    element(in: bob, id: "source.bob-spaces").click()
    element(in: bob, id: "browser.search").click()
    element(in: bob, id: "browser.search").typeText("draft source:space")
    element(in: bob, id: "column.name").click()
    element(in: bob, id: "row.space-draft").click()
    element(in: bob, id: "browser.inspector.toggle").click()

    XCTAssertEqual(element(in: alice, id: "browser.search").value as? String,
                   "invoice source:public")
    XCTAssertTrue(element(in: alice, id: "row.public-invoice").isSelected)
    XCTAssertFalse(element(in: alice, id: "browser.inspector").exists)
    XCTAssertEqual(element(in: bob, id: "browser.search").value as? String,
                   "draft source:space")
    XCTAssertTrue(element(in: bob, id: "row.space-draft").isSelected)
    XCTAssertTrue(element(in: bob, id: "browser.inspector").exists)
    attachScreenshot(named: "two-account-two-window-alice", element: app.windows.element(boundBy: 0))
    attachScreenshot(named: "two-account-two-window-bob", element: app.windows.element(boundBy: 1))
    assertNoExternalAccess()
}

func testKeyboardSearchQuickLookInspectorAndStaleRecovery() throws {
    app.terminate()
    launchFixture("stale-errors", appearance: "light")
    let alice = windowRoot("alice")
    XCTAssertTrue(alice.waitForExistence(timeout: 5))
    app.typeKey("f", modifierFlags: .command)
    let search = element(in: alice, id: "browser.search")
    XCTAssertTrue(search.hasKeyboardFocus)
    search.typeText("invoice mime:image/png")
    let table = element(in: alice, id: "browser.content")
    table.typeKey(.downArrow, modifierFlags: [])
    XCTAssertTrue(element(in: alice, id: "row.public-image").isSelected)
    table.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(element(in: alice, id: "browser.inspector").exists)
    table.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(app.windows["Quick Look"].waitForExistence(timeout: 5))
    attachScreenshot(named: "blob-quick-look", element: app.windows["Quick Look"])
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(element(in: alice, id: "row.public-image").isSelected)

    element(in: alice, id: "row.public-html").click()
    XCTAssertTrue(element(in: alice, id: "blob.download-only").exists)
    XCTAssertFalse(element(in: alice, id: "blob.quick-look").exists)
    element(in: alice, id: "browser.inspector.toggle").click()
    let summary = element(in: alice, id: "inspector.summary")
    let raw = element(in: alice, id: "inspector.raw-json")
    XCTAssertTrue(summary.exists)
    XCTAssertTrue(raw.exists)
    XCTAssertLessThan(summary.frame.minY, raw.frame.minY)
    XCTAssertTrue(element(in: alice, id: "inspector.identifiers").value
        as? String == "at://did:plc:alice/app.example.file/invoice · bafyfixture · public")
    attachScreenshot(named: "record-inspector", element: app.windows.firstMatch)

    XCTAssertTrue(element(in: alice, id: "browser.error.stale").exists)
    XCTAssertTrue(element(in: alice, id: "row.public-invoice").exists)
    attachScreenshot(named: "stale-state", element: app.windows.firstMatch)
    element(in: alice, id: "browser.error.retry").click()
    XCTAssertFalse(element(in: alice, id: "browser.error.stale").exists)
    XCTAssertTrue(element(in: alice, id: "row.public-html").isSelected)

    table.typeKey(.tab, modifierFlags: [])
    table.typeKey(.tab, modifierFlags: .shift)
    XCTAssertTrue(table.hasKeyboardFocus)
    assertNoExternalAccess()
}

func testActivityLifecycleAndRelaunchRecovery() throws {
    app.terminate()
    launchFixture("activity", appearance: "light")
    let root = windowRoot("alice")
    element(in: root, id: "source.activity").click()
    let unrelatedBefore = element(in: root, id: "row.transfer-bob").value as? String

    element(in: root, id: "row.transfer-cancellable").click()
    element(in: root, id: "activity.cancel").click()
    XCTAssertEqual(element(in: root, id: "row.transfer-cancellable").value as? String,
                   "Cancelled")
    element(in: root, id: "activity.retry").click()
    XCTAssertEqual(element(in: root, id: "row.transfer-cancellable").value as? String,
                   "Queued")
    element(in: root, id: "row.transfer-interrupted").click()
    element(in: root, id: "activity.resume").click()
    XCTAssertEqual(element(in: root, id: "transfer.stage").value as? String,
                   "Resuming component 2 of 3")
    let resumed = element(in: root, id: "row.transfer-interrupted")
    waitForValue(resumed, "Completed")
    XCTAssertEqual(element(in: root, id: "transfer.stage").value as? String,
                   "Verified 3 of 3 components")
    XCTAssertEqual(element(in: root, id: "activity.result.verified").value as? String,
                   "Verified local result")
    let reveal = element(in: root, id: "activity.reveal")
    XCTAssertTrue(reveal.isEnabled)
    reveal.click()
    XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.finder")
        .windows.firstMatch.waitForExistence(timeout: 5))
    element(in: root, id: "row.transfer-partial").click()
    XCTAssertTrue(element(in: root, id: "copy.partial-outcome").label
        .contains("Blob uploaded; record not created"))
    XCTAssertEqual(element(in: root, id: "row.transfer-bob").value as? String,
                   unrelatedBefore)
    attachScreenshot(named: "activity", element: app.windows.firstMatch)

    app.terminate()
    try relaunchCurrentFixture(appearance: "light")
    let restored = windowRoot("alice")
    element(in: restored, id: "source.activity").click()
    XCTAssertEqual(element(in: restored, id: "row.transfer-interrupted").value as? String,
                   "Completed")
    element(in: restored, id: "row.transfer-interrupted").click()
    XCTAssertEqual(element(in: restored, id: "activity.result.verified").value as? String,
                   "Verified local result")
    XCTAssertTrue(element(in: restored, id: "activity.reveal").isEnabled)
    assertNoExternalAccess()
}
```

- [ ] **Step 5: Add runnable write, Space administration, backup, cross-source, Finder-drag, account, and prohibited-route flows**

Add these complete fixture tests and their helper; every button/sheet identifier is defined in Task 7 and every final state is a scripted durable response, not a label-only mock:

```swift
func testPublicConflictAndSpaceAdministrationFlows() throws {
    app.terminate()
    launchFixture("public-records", appearance: "light")
    let root = windowRoot("alice")
    element(in: root, id: "source.alice-public").click()
    element(in: root, id: "row.public-invoice").click()
    element(in: root, id: "record.edit").click()
    replaceText(
        in: element(in: root, id: "editor.raw-json"),
        with: #"{"$type":"app.example.file","name":"Edited"}"#
    )
    element(in: root, id: "editor.save").click()
    XCTAssertTrue(element(in: root, id: "record.conflict").waitForExistence(timeout: 3))
    XCTAssertTrue(element(in: root, id: "record.conflict").label.contains("changed on the PDS"))
    attachScreenshot(named: "public-write-conflict", element: app.windows.firstMatch)
    element(in: root, id: "conflict.cancel").click()
    element(in: root, id: "record.create").click()
    element(in: root, id: "editor.collection").typeText("app.example.file")
    element(in: root, id: "editor.record-key").typeText("new-invoice")
    replaceText(
        in: element(in: root, id: "editor.raw-json"),
        with: #"{"$type":"app.example.file","name":"New"}"#
    )
    element(in: root, id: "editor.save").click()
    XCTAssertTrue(element(in: root, id: "row.public-new-invoice").exists)
    element(in: root, id: "row.public-new-invoice").click()
    element(in: root, id: "record.delete").click()
    element(in: root, id: "record.delete.confirm").click()
    XCTAssertFalse(element(in: root, id: "row.public-new-invoice").exists)

    element(in: root, id: "source.alice-spaces").click()
    element(in: root, id: "space.create").click()
    element(in: root, id: "space.create.name").typeText("Project Cedar")
    element(in: root, id: "space.create.confirm").click()
    XCTAssertTrue(element(in: root, id: "row.space-project-cedar").exists)
    element(in: root, id: "space.policy").click()
    element(in: root, id: "space.policy.invite-only").click()
    element(in: root, id: "space.policy.save").click()
    element(in: root, id: "space.member.add").click()
    element(in: root, id: "space.member.did").typeText("did:plc:bob")
    element(in: root, id: "space.member.confirm").click()
    XCTAssertTrue(element(in: root, id: "row.member.did-plc-bob").exists)
    element(in: root, id: "space.member.remove").click()
    element(in: root, id: "space.member.remove.confirm").click()
    XCTAssertFalse(element(in: root, id: "row.member.did-plc-bob").exists)

    element(in: root, id: "record.create").click()
    XCTAssertTrue(element(in: root, id: "space.non-atomic-warning").exists)
    element(in: root, id: "editor.collection").typeText("app.example.note")
    element(in: root, id: "editor.record-key").typeText("space-note")
    replaceText(
        in: element(in: root, id: "editor.raw-json"),
        with: #"{"$type":"app.example.note","text":"Space"}"#
    )
    element(in: root, id: "editor.save").click()
    XCTAssertTrue(element(in: root, id: "row.space-note").exists)
    element(in: root, id: "row.space-note").click()
    element(in: root, id: "record.edit").click()
    XCTAssertTrue(element(in: root, id: "space.non-atomic-warning").exists)
    attachScreenshot(named: "space-non-atomic-warning", element: app.windows.firstMatch)
    app.typeKey(.escape, modifierFlags: [])
    element(in: root, id: "row.space-note").click()
    element(in: root, id: "record.delete").click()
    XCTAssertTrue(element(in: root, id: "space.non-atomic-warning").exists)
    element(in: root, id: "record.delete.confirm").click()
    XCTAssertFalse(element(in: root, id: "row.space-note").exists)
    element(in: root, id: "space.delete").click()
    XCTAssertTrue(element(in: root, id: "backup.preflight.verified").exists)
    element(in: root, id: "space.delete.confirm").click()
    XCTAssertFalse(element(in: root, id: "row.space-project-cedar").exists)
    assertNoExternalAccess()
}

func testBlobDownloadAttachmentReconciliationAndBackupLifecycle() throws {
    app.terminate()
    launchFixture("blobs-quicklook", appearance: "light")
    let root = windowRoot("alice")
    let destination = try makeFileWorkflowDirectory()

    element(in: root, id: "source.alice-public-blobs").click()
    element(in: root, id: "row.public-image").click()
    element(in: root, id: "blob.download").click()
    let downloaded = destination.appendingPathComponent("fixture-image.png")
    try acceptSavePanel(destination: downloaded)
    XCTAssertTrue(waitForFile(downloaded))
    XCTAssertGreaterThan(try Data(contentsOf: downloaded).count, 0)

    let attachment = destination.appendingPathComponent("attachment.txt")
    try Data("fixture attachment".utf8).write(to: attachment, options: .atomic)
    element(in: root, id: "source.alice-public").click()
    element(in: root, id: "row.public-invoice").click()
    element(in: root, id: "record.edit").click()
    element(in: root, id: "attachment.add").click()
    try acceptOpenPanel(file: attachment)
    element(in: root, id: "editor.save").click()
    let reconciliation = element(in: root, id: "attachment.reconciliation")
    XCTAssertTrue(reconciliation.waitForExistence(timeout: 3))
    XCTAssertEqual(reconciliation.value as? String,
                   "Write response lost; reconciling exact record")
    waitForValue(reconciliation, "Reconciled: record references uploaded CID")
    XCTAssertEqual(element(in: root, id: "attachment.upload-count").value as? String, "1")

    element(in: root, id: "source.alice-account").click()
    element(in: root, id: "backup.create").click()
    let backup = destination.appendingPathComponent("alice.atprotodrivebackup")
    try acceptSavePanel(destination: backup)
    XCTAssertTrue(waitForFile(backup))
    XCTAssertTrue(element(in: root, id: "backup.created-row").waitForExistence(timeout: 10))
    element(in: root, id: "backup.created-row").click()
    element(in: root, id: "backup.verify").click()
    waitForValue(element(in: root, id: "backup.verification-status"), "Verified")
    element(in: root, id: "backup.trash").click()
    element(in: root, id: "backup.trash.confirm").click()
    XCTAssertTrue(waitForFile(backup, exists: false))

    element(in: root, id: "source.activity").click()
    element(in: root, id: "row.transfer-partial").click()
    XCTAssertTrue(element(in: root, id: "copy.partial-outcome").label
        .contains("Blob uploaded; record not created"))
    attachScreenshot(named: "blob-attachment-backup-lifecycle", element: app.windows.firstMatch)
    assertNoExternalAccess()
}

func testBackupResumeCrossSourceDisclosureAndDragToFinder() throws {
    app.terminate()
    launchFixture("blobs-quicklook", appearance: "light")
    let root = windowRoot("alice")
    element(in: root, id: "source.backups").click()
    element(in: root, id: "row.backup-incomplete").click()
    element(in: root, id: "backup.resume").click()
    XCTAssertEqual(element(in: root, id: "backup.completeness").value as? String,
                   "Complete relative to 2 authority-claimed writers")
    attachScreenshot(named: "backup-browser-resumed", element: app.windows.firstMatch)
    XCTAssertEqual(element(in: root, id: "backup.verification-status").value as? String,
                   "Verified")
    let backupReveal = element(in: root, id: "backup.reveal")
    XCTAssertTrue(backupReveal.isEnabled)
    backupReveal.click()
    XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.finder")
        .windows.firstMatch.waitForExistence(timeout: 5))

    element(in: root, id: "source.alice-spaces").click()
    element(in: root, id: "row.space-private-record").click()
    element(in: root, id: "record.copy-to").click()
    element(in: root, id: "copy.destination.public").click()
    XCTAssertTrue(element(in: root, id: "copy.disclosure.confirm").label
        .contains("becomes public and cannot make the source private"))
    attachScreenshot(named: "cross-source-disclosure", element: app.windows.firstMatch)
    element(in: root, id: "copy.disclosure.accept").click()
    XCTAssertTrue(element(in: root, id: "copy.partial-outcome").label
        .contains("Blob uploaded; destination record failed"))

    element(in: root, id: "source.alice-public-blobs").click()
    let destination = try makeFinderDestination()
    let promisedName = "fixture-image.png"
    try dragToFinder(
        source: element(in: root, id: "blob.drag-source"),
        destination: destination
    )
    let promisedURL = destination.appendingPathComponent(promisedName)
    let predicate = NSPredicate { _, _ in FileManager.default.fileExists(atPath: promisedURL.path) }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    XCTAssertGreaterThan(try Data(contentsOf: promisedURL).count, 0)
    assertNoExternalAccess()
}

func testAccountPrivateStateReconnectCallbackAndRemoval() throws {
    app.terminate()
    launchFixture("account-controls", appearance: "light")
    let alice = windowRoot("alice")
    element(in: alice, id: "source.alice-account").click()
    XCTAssertEqual(element(in: alice, id: "account.did").value as? String, "did:plc:alice")
    XCTAssertEqual(element(in: alice, id: "account.capabilities").value as? String,
                   "Not reported by this OAuth mode")
    attachScreenshot(named: "server-account-status", element: app.windows.firstMatch)

    element(in: alice, id: "account.reconnect").click()
    XCTAssertTrue(element(in: alice, id: "oauth.reconnect.sheet").exists)
    attachScreenshot(named: "reconnect", element: app.windows.firstMatch)
    element(in: alice, id: "oauth.fixture.reject-callback").click()
    XCTAssertTrue(app.alerts["Couldn’t reconnect account"].exists)
    app.alerts.buttons["OK"].click()

    element(in: alice, id: "source.alice-private-state").click()
    XCTAssertTrue(element(in: alice, id: "private-state.read-only").exists)
    XCTAssertTrue(element(in: alice, id: "inspector.raw-json").exists)
    XCTAssertFalse(element(in: alice, id: "record.edit").exists)

    element(in: alice, id: "source.alice-account").click()
    element(in: alice, id: "account.remove-from-app").click()
    let confirmation = element(in: alice, id: "account.remove.confirm")
    XCTAssertTrue(confirmation.label.contains("PDS account, records, blobs, Spaces, memberships, and backups are not deleted"))
    attachScreenshot(named: "remove-from-app-confirmation", element: app.windows.firstMatch)
    element(in: alice, id: "account.remove.confirm-button").click()
    XCTAssertTrue(element(in: alice, id: "source.open-public-repository").isSelected)
    XCTAssertTrue(element(in: alice, id: "source.bob-account").exists)
    element(in: alice, id: "source.backups").click()
    XCTAssertTrue(element(in: alice, id: "row.backup-alice").exists)
    element(in: alice, id: "source.activity").click()
    XCTAssertEqual(element(in: alice, id: "row.transfer-bob").value as? String, "Running")
    assertNoProhibitedControls(in: app)
    assertNoExternalAccess()
}

func testDarkAppearancePrimaryBrowser() throws {
    app.terminate()
    launchFixture("two-accounts", appearance: "dark")
    let root = windowRoot("alice")
    XCTAssertTrue(root.waitForExistence(timeout: 5))
    XCTAssertEqual(app.windows.firstMatch.frame.size.width, 1280, accuracy: 2)
    XCTAssertEqual(app.windows.firstMatch.frame.size.height, 800, accuracy: 2)
    XCTAssertEqual(element(in: root, id: "fixture.appearance").value as? String, "dark")
    attachScreenshot(named: "finder-like-shell-dark-1280x800", element: app.windows.firstMatch)
    assertNoExternalAccess()
}

private func assertNoProhibitedControls(in app: XCUIApplication) {
    for menu in app.menuBars.menuBarItems.allElementsBoundByIndex {
        menu.click()
        for label in [
            "Migrate Account", "Import Repository", "Change Email", "Change Handle",
            "Manage App Passwords", "Deactivate Account", "Delete Account"
        ] {
            XCTAssertFalse(app.menuItems[label].exists, "Unexpected menu route: \(label)")
            XCTAssertFalse(app.buttons[label].exists, "Unexpected button route: \(label)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
```

Use these exact helpers for the Finder promise assertion:

```swift
private func makeFinderDestination() throws -> URL {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("ATProtoDrivePromise-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    finder.activate()
    finder.typeKey("g", modifierFlags: [.command, .shift])
    let goToFolder = finder.sheets.textFields.firstMatch
    XCTAssertTrue(goToFolder.waitForExistence(timeout: 5))
    goToFolder.typeText(destination.path)
    finder.sheets.buttons["Go"].click()
    XCTAssertTrue(finder.windows.firstMatch.waitForExistence(timeout: 5))
    app.activate()
    return destination
}

private func makeFileWorkflowDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ATProtoDriveFileWorkflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
}

private func acceptSavePanel(destination: URL) throws {
    let panel = app.sheets.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    app.typeKey("g", modifierFlags: [.command, .shift])
    let locationSheet = panel.sheets.firstMatch
    let location = locationSheet.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    replaceText(in: location, with: destination.deletingLastPathComponent().path)
    locationSheet.buttons["Go"].click()
    XCTAssertFalse(locationSheet.waitForExistence(timeout: 1))
    let name = panel.textFields.firstMatch
    replaceText(in: name, with: destination.lastPathComponent)
    panel.buttons["Save"].click()
    if app.sheets.buttons["Replace"].waitForExistence(timeout: 1) {
        app.sheets.buttons["Replace"].click()
    }
}

private func acceptOpenPanel(file: URL) throws {
    let panel = app.sheets.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    app.typeKey("g", modifierFlags: [.command, .shift])
    let locationSheet = panel.sheets.firstMatch
    let location = locationSheet.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    replaceText(in: location, with: file.path)
    locationSheet.buttons["Go"].click()
    XCTAssertFalse(locationSheet.waitForExistence(timeout: 1))
    panel.buttons["Open"].click()
}

private func waitForFile(
    _ url: URL,
    exists: Bool = true,
    timeout: TimeInterval = 10
) -> Bool {
    let predicate = NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: url.path) == exists
    }
    return XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
        timeout: timeout
    ) == .completed
}

private func dragToFinder(source: XCUIElement, destination: URL) throws {
    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    XCTAssertTrue(source.exists)
    XCTAssertTrue(finder.windows.firstMatch.exists)
    XCTAssertTrue(finder.windows.firstMatch.title.contains(destination.lastPathComponent))
    source.press(forDuration: 1.0, thenDragTo: finder.windows.firstMatch)
    app.activate()
}
```

The unit suites separately assert the closed command catalog and callback-route whitelist; Task 9's symbol/route scan covers hidden source routes that XCUITest cannot enumerate.

- [ ] **Step 6: Run all unit and UI tests, then export screenshot attachments**

```bash
PLAN4_VERIFY="$(mktemp -d /tmp/atprotodrive-plan4-task8-pass.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_VERIFY/DerivedData" \
  -resultBundlePath "$PLAN4_VERIFY/AllTests.xcresult" \
  test

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun xcresulttool export attachments \
  --path "$PLAN4_VERIFY/AllTests.xcresult" \
  --output-path "$PLAN4_VERIFY/Screenshots"
```

Expected: `** TEST SUCCEEDED **`; attachments include light and dark 1280×800 primary browsers, both isolated windows, record inspector, blob/Quick Look, stale state, Activity, public conflict, Space non-atomic warning, blob/attachment/backup lifecycle, resumed backup browser, cross-source disclosure, status, reconnect, and removal confirmation. The native panels produce a non-empty downloaded blob and an atomic verified backup before Trash; reconciliation proves one attachment upload; the Finder-drag test proves a non-empty promised file at the exact destination. Screen Recording/Accessibility permission failures must be reported as host prerequisites, not silently treated as app failures.

- [ ] **Step 7: Seal Task 8 and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "test: add macOS end-to-end UI acceptance"
jj new
```

---

### Task 9: Run signed/live gates and publish the final requirement audit

**Files:**
- Create: `docs/superpowers/verification/2026-08-23-atprotodrive-v1-acceptance.md`
- Modify: `README.md` only if it lacks links to the approved spec, four implementation plans, and final acceptance report.

**Interfaces:**
- Consumes: the complete v1 app and test targets from all four plans.
- Produces: a dated, current-worktree evidence record that distinguishes static, unsigned build, deterministic runtime, signed OAuth/Keychain, live public PDS, and optional live Spaces proof.

- [ ] **Step 1: Capture the exact current-worktree identity before verification**

```bash
jj status
jj log -r '@ | @-' --no-graph -T 'change_id ++ " " ++ commit_id ++ " " ++ description ++ "\n"'
```

Expected: no unreviewed product changes; record the change and commit IDs in the acceptance report.

- [ ] **Step 2: Run unsigned build/unit gates and the separately signed fixture-UI gate**

```bash
PLAN4_FINAL="$(mktemp -d /tmp/atprotodrive-v1-final.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_FINAL/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_FINAL/DerivedData" \
  -resultBundlePath "$PLAN4_FINAL/UnitTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO test -only-testing:ATProtoDriveTests

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_FINAL/SignedUIDerivedData" \
  -resultBundlePath "$PLAN4_FINAL/UITests.xcresult" \
  test -only-testing:ATProtoDriveUITests
```

Expected: all three commands succeed. Record the first two as unsigned compilation/offline unit evidence. Record the third as normally signed deterministic fixture-UI evidence; its network/Keychain traps mean it is still not live OAuth proof.

- [ ] **Step 3: Launch the exact fixture product and inspect screenshots**

```bash
PLAN4_FIXTURE_TOKEN="manual-$(uuidgen)"
PLAN4_FIXTURE_EXECUTABLE="$PLAN4_FINAL/SignedUIDerivedData/Build/Products/Debug/ATProtoDrive.app/Contents/MacOS/ATProtoDrive"
ATPROTO_DRIVE_FIXTURE=two-accounts \
ATPROTO_DRIVE_STATE_TOKEN="$PLAN4_FIXTURE_TOKEN" \
ATPROTO_DRIVE_DISABLE_NETWORK=1 \
ATPROTO_DRIVE_WINDOW_WIDTH=1280 \
ATPROTO_DRIVE_WINDOW_HEIGHT=800 \
ATPROTO_DRIVE_APPEARANCE=light \
"$PLAN4_FIXTURE_EXECUTABLE" &
```

Normalize the primary window to 1280×800, navigate each approved surface using its accessibility identifier, and inspect the exported light/dark screenshots for truncation, nested-pane regression, stale/error clarity, focus visibility, and destructive-copy wording. Record any Accessibility or Screen Recording host permission separately.

- [ ] **Step 4: Run live anonymous public PDS acceptance**

With no account connected, open a current public handle and a DID. Verify handle→DID→PDS resolution, every `describeRepo` collection, multi-page records, raw JSON/identifiers, public blob inventory/download/Quick Look, repeated-cursor protection, and visible recovery after a deliberately failed refresh. Record target DID, PDS URL, timestamp, observed collection/page counts, and redacted errors; do not record record bodies or blob bytes.

This is a required live gate because public browsing requires no credential and is temporally verifiable.

- [ ] **Step 5: Build normally signed and verify OAuth/Keychain account controls**

```bash
PLAN4_SIGNED="$(mktemp -d /tmp/atprotodrive-v1-signed.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_SIGNED/DerivedData" build

PLAN4_SIGNED_APP="$PLAN4_SIGNED/DerivedData/Build/Products/Debug/ATProtoDrive.app"
PLAN4_SIGNED_EXECUTABLE="$PLAN4_SIGNED_APP/Contents/MacOS/ATProtoDrive"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PLAN4_SIGNED_APP"
/usr/bin/codesign -dv --verbose=4 "$PLAN4_SIGNED_APP" 2> "$PLAN4_SIGNED/codesign.txt"
/usr/bin/codesign -d -r- "$PLAN4_SIGNED_APP" 2> "$PLAN4_SIGNED/designated-requirement.txt"
/usr/bin/codesign -d --entitlements :- "$PLAN4_SIGNED_APP" > "$PLAN4_SIGNED/entitlements.plist"
/usr/bin/shasum -a 256 "$PLAN4_SIGNED_EXECUTABLE" > "$PLAN4_SIGNED/executable.sha256"
/usr/bin/grep -F 'TeamIdentifier=44U2ZPNQPK' "$PLAN4_SIGNED/codesign.txt"
/usr/bin/plutil -extract com.apple.security.app-sandbox raw "$PLAN4_SIGNED/entitlements.plist"
/usr/bin/plutil -extract com.apple.security.network.client raw "$PLAN4_SIGNED/entitlements.plist"

PLAN4_CALLBACK_TOKEN="acceptance-$(uuidgen)"
ATPROTO_DRIVE_CALLBACK_RECEIPT_TOKEN="$PLAN4_CALLBACK_TOKEN" \
  "$PLAN4_SIGNED_EXECUTABLE" &
PLAN4_SIGNED_PID=$!
/bin/ps -p "$PLAN4_SIGNED_PID" -o pid=,command=
/usr/bin/pgrep -fl '/ATProtoDrive.app/Contents/MacOS/ATProtoDrive'
```

Before OAuth, require the `pgrep` output to contain only `PLAN4_SIGNED_PID`; close other running ATProtoDrive copies and repeat the read-only check if needed. Record the executable's absolute path, PID, SHA-256, codesign `Authority`, `TeamIdentifier`, designated identifier, and the entitlements keys (not secrets) in the report. The team must be `44U2ZPNQPK`; App Sandbox, network client, user-selected file access, and the expected keychain access group must be present.

Task 7's DEBUG-only `DebugOAuthCallbackReceiptRecorder` activates only for a syntactically safe token. On accepted callback it atomically writes `~/Library/Containers/blue.catbird.atprotodrive/Data/Library/Application Support/ATProtoDrive/Acceptance/<token>/callback.json` with PID, executable path, executable SHA-256, bundle identifier, timestamp, callback route, and SHA-256 of OAuth state. It never records code, raw state, authorization URL, DPoP material, or tokens. After one rejected and one successful callback, verify the exact receipt with:

```bash
PLAN4_CALLBACK_RECEIPT="$HOME/Library/Containers/blue.catbird.atprotodrive/Data/Library/Application Support/ATProtoDrive/Acceptance/$PLAN4_CALLBACK_TOKEN/callback.json"
/usr/bin/test -s "$PLAN4_CALLBACK_RECEIPT"
test "$(/usr/bin/plutil -extract processID raw -o - "$PLAN4_CALLBACK_RECEIPT")" = "$PLAN4_SIGNED_PID"
test "$(/usr/bin/plutil -extract executablePath raw -o - "$PLAN4_CALLBACK_RECEIPT")" = "$PLAN4_SIGNED_EXECUTABLE"
test "$(/usr/bin/plutil -extract executableSHA256 raw -o - "$PLAN4_CALLBACK_RECEIPT")" = "$(/usr/bin/awk '{print $1}' "$PLAN4_SIGNED/executable.sha256")"
test "$(/usr/bin/plutil -extract bundleIdentifier raw -o - "$PLAN4_CALLBACK_RECEIPT")" = "blue.catbird.atprotodrive"
test "$(/usr/bin/plutil -extract route raw -o - "$PLAN4_CALLBACK_RECEIPT")" = "/callback"
```

All five commands must succeed. This is evidence the callback reached this exact temporary signed build, not another registered copy.

Connect two operator-owned test accounts, quit/relaunch the same executable, and verify Keychain restoration, exact DID/PDS routing, independent status and navigation, reconnect preserving local sources/backups, contextual public-write and Space-grant reconsent, visible rejected callback, and remove-from-app wording/cleanup. Never use the unsigned product as proof for these behaviors. Redact authorization URLs, codes, raw state, DPoP material, tokens, Space credentials, record bodies, and private preferences from the report.

- [ ] **Step 6: Run the explicitly gated live OAuth discovery test**

```bash
PLAN4_LIVE_TESTS="$(mktemp -d /tmp/atprotodrive-live-tests.XXXXXX)"
if [[ -n "$ATPROTO_DRIVE_LIVE_HANDLE" ]]; then
  ATPROTO_DRIVE_RUN_LIVE_TESTS=1 \
  ATPROTO_DRIVE_LIVE_HANDLE="$ATPROTO_DRIVE_LIVE_HANDLE" \
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$PLAN4_LIVE_TESTS" \
    test -only-testing:ATProtoDriveTests/AccountStoreTests/liveOAuthDiscovery
else
  echo 'NOT RUN: ATPROTO_DRIVE_LIVE_HANDLE not supplied'
fi
```

Expected: PASS when discovery is reachable, including assertions that the UUID-qualified pending-flow namespace, isolated metadata, and in-memory pending map are empty after discard. Record the operator-supplied handle (or its DID after resolution), timestamp, and result. If the variable is absent, mark **Not run — ATPROTO_DRIVE_LIVE_HANDLE not supplied**; source contains no default/personal handle. A network/PDS failure is recorded as live-environment evidence and must not be misreported as a deterministic unit-test regression.

- [ ] **Step 7: Record optional live Spaces-alpha interoperability separately**

When a current alpha account and readable Space are available, verify discovery, manual URI open, own writer repository, whole Space where credential authority permits it, Space blobs, one contextual record-action reconsent, one separate administration reconsent, and a single-writer backup. Record protocol profile, Space URI digest, participating writer count, timestamp, and result. If unavailable, mark **Not run — no current alpha authority/account**; generated clients, compilation, mocked requests, and fixture UI are not live-interoperability proof.

- [ ] **Step 8: Complete the requirement-by-requirement matrix**

Create a table with one row for every acceptance criterion 1-10 and these columns:

```text
Requirement | Static/unit evidence | Runtime/UI evidence | Live evidence | Result | Residual limitation
```

Additionally include explicit rows for:

- public versus Space endpoint/credential/cache separation;
- two-account and two-window isolation;
- record/blob/Space/backup/Activity browsing;
- public CAS and Space-alpha non-atomic warning;
- cancel/retry/resume/reveal and relaunch recovery;
- contextual record-action versus administration grants;
- reconnect, callback error, removal preservation, and cleanup failure;
- read-only provider-scoped private state;
- absence of migration/import/email/handle/app-password/deactivate/delete controls;
- keyboard, search, table, inspector, Quick Look, drag-to-Finder, stale/error states, and screenshots.

Use **Pass**, **Fail**, or **Not run**; never use **Pass** when evidence is only compilation or a fixture for a requirement that explicitly needs live behavior.

- [ ] **Step 9: Run the final source and history audit**

```bash
rg -n 'try\? await accountStore\.handleCallback|activeAccountID\b|activeAccount\b' \
  ATProtoDrive --glob '*.swift'
rg -n --pcre2 'accounts\.first\b(?!\s*\(\s*where:)' \
  ATProtoDrive --glob '*.swift'
rg -n --pcre2 \
  '\b(?:func|case|var|let|struct|class|enum)\s+(?:migrateAccount|importRepository|importRepo|changeEmail|changeHandle|manageAppPasswords|createAppPassword|deactivateAccount|deleteAccount|requestAccountDelete)\b' \
  ATProtoDrive --glob '*.swift'
rg -ni --pcre2 \
  '(?:Button|Menu|Command|NavigationLink|Label)\s*\(\s*"[^"]*(?:migrate account|import repository|change email|change handle|app.?password|deactivate account|delete account)|(?:/|route[^\n]{0,40})(?:migrate-account|import-repo(?:sitory)?|change-email|change-handle|app-password|deactivate-account|delete-account)' \
  ATProtoDrive --glob '*.swift'
rg -n 'onOpenURL|CFBundleURLSchemes|BrowserCommands|AccountControlCatalog' \
  ATProtoDrive ATProtoDriveTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ATProtoDrive.xcodeproj -scheme ATProtoDrive \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PLAN4_FINAL/AuditDerivedData" CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:ATProtoDriveTests/AccountControlCatalogTests \
  -only-testing:ATProtoDriveTests/OAuthCallbackRouteTests
jj status
jj diff --summary
```

Expected: the first search has no match; the fallback PCRE excludes safe `accounts.first(where:)` and finds no bare/forced first-account fallback. The separate declaration and UI/route searches catch camel-case hidden APIs and actionable labels/routes without falsely matching the required legacy metadata migration. The route/catalog tests whitelist only `blue.catbird.atprotodrive:/callback` and the two account actions, and enumerate every registered app command/URL handler so an unreviewed route fails the test. The informational route/catalog `rg` output is attached to the audit. Only the acceptance report and intentionally linked README are unsealed.

- [ ] **Step 10: Seal the acceptance report and immediately open a new jj change**

```bash
jj status
jj diff --summary
jj describe -m "docs: record ATProtoDrive v1 acceptance evidence"
jj new
```

---

## Coverage and Handoff

This plan closes the approved design's account/status, OAuth, private-state, deterministic-runtime, UI-automation, and final-evidence requirements. Plans 1-3 remain responsible for their public repository, Space CRUD/administration, blob, backup, transfer, Quick Look, and cross-source implementation details; this plan verifies those surfaces together rather than duplicating their services.

Before declaring the project complete, the executor must confirm:

- all nine tasks are sealed in reviewed jj changes with a fresh empty child after each;
- the normal offline test target performs no live OAuth, Keychain, or fixed-path writes;
- the full macOS app builds and deterministic unit/UI tests pass from fresh derived data;
- the fixture app launches and screenshot attachments demonstrate the finished Finder-like UX;
- anonymous live public browsing passes against a current PDS;
- signed OAuth/Keychain account restoration, reconnect/reconsent, exact-DID status, and removal are observed with two accounts;
- optional live Spaces-alpha evidence is clearly separated from fixture evidence;
- every acceptance criterion has current-worktree evidence and no prohibited account control is reachable through a view, menu, command, URL, or contextual action.

Do not mark v1 complete while a required matrix row is **Fail** or **Not run**. A live Spaces-alpha row may be **Not run** only with the explicit environment reason above and must remain visibly separate from deterministic Space service/UI coverage.
