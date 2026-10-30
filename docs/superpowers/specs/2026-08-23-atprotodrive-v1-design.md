# ATProtoDrive v1 Design

**Status:** Approved for implementation

**Product:** ATProtoDrive for macOS

**Implementation direction:** Native Finder-like browser with separate public and permissioned data planes

## 1. Summary

ATProtoDrive v1 turns the existing ATProto Spaces explorer into a general-purpose macOS PDS data manager. It lets people browse public repositories without signing in, connect multiple accounts, inspect and safely mutate records they own, browse public and permissioned blobs, work with ATProto Spaces, create verified local backups, and monitor transfers.

The app uses a familiar macOS source-list, content-table, and optional-inspector layout. Public repositories and permissioned Spaces share presentation conventions but retain separate protocol services, authentication, cache namespaces, repository semantics, and verification paths.

Account administration is intentionally narrow. V1 shows account and server status, reconnects when authorization or contextual write reconsent is required, and removes an account from ATProtoDrive. It does not import or migrate repositories, change handles or email addresses, manage app passwords, deactivate accounts, or delete remote accounts.

## 2. Problem

The current application is a capable ATProto Spaces test client, but its account → Space → writer repository → record navigation and nested inspector make routine browsing difficult. It has no first-class public-repository browser, public blob inventory, backup workflow, transfer center, or unified macOS interaction model.

AT Protocol data also differs from a filesystem in important ways:

- Public records and referenced blobs are public.
- Spaces are access-controlled, experimental repositories, not encrypted folders.
- Blobs have no intrinsic filename, directory, move, rename, or independent lifetime.
- A repository CAR excludes blob payloads.
- There is no generic API that enumerates every form of private application state.

The product must feel like a cloud drive without pretending these protocol limitations do not exist.

## 3. Goals

V1 must:

1. Browse any public ATProto repository by handle or DID without authentication.
2. Enumerate all collections currently reported by `com.atproto.repo.describeRepo`, paginate all records in a selected collection, and inspect exact record values and protocol identifiers.
3. Connect multiple accounts and browse each account's own public repository, public blobs, discoverable Space repositories, manually opened Spaces, supported private application state, backups, activity, and server status.
4. Keep public and permissioned repositories visibly and technically separate.
5. Inventory referenced public and Space blobs, correlate blobs with referring records, preview and download their bytes, and attach uploaded blobs through a durable record reference.
6. Safely create, update, and delete records owned by the connected account in both its public repository and its own writer repositories inside Spaces.
7. Manage declarations, policies, and members for Spaces owned by the connected account with separate administration grants and confirmations.
8. Create complete, inspectable, and verifiable local backups composed of record archives plus blob payloads.
9. Persist transfer history and support cancellation, retry, component-level resumption, and reveal-in-Finder.
10. Expose account/server status, reconnect (including contextual permission reconsent), and remove-from-app only.
11. Provide native macOS pointer, keyboard, menu, toolbar, search, table, inspector, Quick Look, and drag-to-Finder behavior.

## 4. Non-goals

V1 does not:

- Import or restore a repository or backup into a PDS.
- Migrate an account or repository between PDS hosts.
- Change a handle, email address, password, or app password.
- Deactivate or delete an ATProto account.
- Enumerate or revoke every provider-side OAuth session.
- Expose remote account deletion through hidden menus, URL handlers, or command routing.
- Present Space data as end-to-end encrypted or confidential from participating PDSes and applications.
- Claim to discover every Space a user can read. `listSpaces` does not enumerate read-only memberships.
- Emulate a mounted filesystem or add a File Provider extension.
- Invent authoritative filenames, folders, modification dates, or version history where the protocol supplies none.
- Implement a new drive-specific ATProto Lexicon in v1.

## 5. Protocol and trust boundaries

### 5.1 Public repositories

Public repository browsing uses the standard public APIs:

- `com.atproto.repo.describeRepo`
- `com.atproto.repo.listRecords`
- `com.atproto.repo.getRecord`
- `com.atproto.sync.getRepo`
- `com.atproto.sync.listBlobs`
- `com.atproto.sync.getBlob`

Public reads do not require an account session. Mutations use `com.atproto.repo.createRecord`, `putRecord`, `deleteRecord`, and, for single-repository batches, `applyWrites`.

Opening a public repository resolves the handle when supplied, then resolves and validates the resulting DID document directly. PDS discovery uses the document's `AtprotoPersonalDataServer` service independently of `alsoKnownAs`, so a valid DID with no advertised handle remains browseable. The returned `describeRepo` DID and DID-document ID must match the resolved identity before any records are shown. ATProtoDrive accepts `did:plc` and hostname-level `did:web`; it rejects path-form `did:web`, non-development port forms, and PDS service endpoints containing user information, a path prefix, query, or fragment.

### 5.2 ATProto Spaces

Space browsing and mutation use `com.atproto.space.*` and, for member lists, `com.atproto.memberspace.*`. A Space is an authorization and synchronization boundary containing one permissioned repository per writer. The app labels this section **Spaces — Experimental** and displays its access policy without describing the content as encrypted.

A Space record is identified by the full permissioned URI `at://{spaceDid}/space/{spaceType}/{skey}/{authorDid}/{collection}/{rkey}`. The app derives and validates that URI through `SpaceRef`; it never substitutes the public-repository form rooted at the writer DID.

Authority routing validates the exact authority DID document and an exact `#atproto_space_host` service with the supported profile's service type and an origin-only HTTPS endpoint. ATProtoDrive fails closed instead of falling back to `#atproto_pds` when the dedicated authority service is absent or malformed. Credential exchange and ordinary authority requests use the same validated host provider.

`listSpaces` supplies only Spaces in which the user holds a writer repository. Known, readable Spaces that are not discoverable remain accessible through **Open Space by URI**, bookmarks, and recents. Whole-Space browsing requires a valid Space credential and writer enumeration; without that capability, the UI clearly falls back to the authenticated user's own Space repository.

Spaces are version-aware. Unsupported-method and protocol-profile mismatches disable the affected actions without weakening public browsing.

### 5.3 Private application state

AT Protocol does not define a generic private-record enumeration API. V1 therefore provides a capability-gated **Private App State** section with named providers rather than a misleading private-repository abstraction. The initial provider reads Bluesky preferences when the connected account and service support `app.bsky.actor.getPreferences`.

Private application state is read-only in v1 because mutation semantics are provider-specific and cannot share the repository CRUD safety contract. This named, capability-gated surface is the v1 interpretation of the approved requirement to browse supported private data; it does not expand the account-administration surface.

### 5.4 Access classification

Every fetched, cached, previewed, exported, and logged item carries a typed access classification:

- `publicRepository(did)`
- `permissionedSpace(spaceURI, writerDID)`
- `privateAppState(provider, accountDID)`
- `localBackup(backupID, originalAccessClass)`

Public and permissioned record caches, blob caches, temporary previews, and backup paths never share an unqualified key. An `isPrivate` Boolean is not sufficient.

## 6. Information architecture

### 6.1 Window structure

The main `WindowGroup` uses a two-column `NavigationSplitView` and an optional trailing `.inspector`:

1. **Source sidebar** — accounts and stable product destinations.
2. **Content browser** — sortable table, outline, gallery, or status surface appropriate to the selected source.
3. **Inspector** — selection-specific preview and protocol details, shown only when requested.

This replaces the existing permanent account → Space → repository → record columns and the nested `HSplitView` inspector.

Selection and navigation history are window-scoped. Account sessions and transfer services are app-scoped. Each window can browse a different account or repository without overwriting another window's selection.

### 6.2 Sidebar

Each connected account has a compact source-list group containing:

- Overview
- Public Records
- Public Blobs
- Spaces — Experimental
- Private App State
- Backups
- Activity
- Server & Account

Global utility rows provide:

- Open Public Repository
- Open Space by URI
- Add Account

Rows use native source-list density: one icon, one title, and at most one secondary line. Counts and detailed metadata belong in content or inspector surfaces.

### 6.3 Content browser

The center pane preserves a consistent browser grammar:

- Breadcrumbs describe the selected account, data plane, Space, writer, and collection.
- Tables support stable selection, column sorting, resizing, keyboard navigation, contextual menus, and multi-selection where operations are safe.
- Search lives in the toolbar and supports text plus tokens for source, account, Space, owner, collection, record/blob, MIME type, and transfer state.
- Empty, loading, stale, unsupported, and failed states are distinct.
- Pagination is automatic as the user scrolls and remains available through an explicit **Load More** action for accessibility and recovery.

### 6.4 Inspector and Quick Look

The inspector prioritizes a friendly summary, then exposes:

- Preview
- Identity and location
- Access classification
- Blob references and referring records
- Integrity and verification state
- Raw JSON
- Exact URI, CID, DID, collection, record key, PDS endpoint, Space URI, and revision

Quick Look supports downloaded images, video, audio, PDFs, text, and other system-supported formats. The app never renders untrusted HTML or SVG in an executable web view.

## 7. Application architecture

### 7.1 State ownership

- `AccountStore` remains the app-wide owner of account sessions, OAuth state, and account-local service construction.
- `BrowserSession` is a window-scoped `@Observable` model for source selection, browser path, selected items, history, inspector visibility, sort order, filters, and search.
- `TransferQueue` is an app-scoped actor with a read-only observable projection for UI.
- Feature stores own remote loading state and call services through narrow interfaces.

### 7.2 Separate data-plane services

The implementation introduces concrete services rather than one repository service with mode flags:

- `PublicRepositoryService`
- `PublicBlobService`
- `SpaceRepositoryService`
- `SpaceBlobService`
- `PrivateStateService`
- `BackupService`
- `TransferQueue`
- `AccountStatusService`
- `MutationCoordinator`

Public and Space services may share low-level DID resolution, XRPC transport, byte streaming, hashing, formatting, and transfer primitives. They do not share authorization decisions, URI construction, repository verification, or cache namespaces.

### 7.3 Presentation projection

Services return typed domain values. A presentation-only `BrowserItem` projection provides common table concerns such as title, subtitle, icon, kind, sort values, and selection identity. Every `BrowserItem` retains a typed source reference, so actions dispatch to the correct concrete service without downcasting or checking an `isPrivate` flag.

### 7.4 Local persistence

V1 avoids a new database dependency:

- Account credentials stay in Petrel's existing secure storage.
- Window selection uses `@SceneStorage` where practical.
- User display preferences use `@AppStorage`.
- Bookmarks, recents, transfer metadata, and activity history use versioned JSON files in Application Support, written atomically.
- Security-scoped bookmarks preserve user-selected backup destinations across relaunch.
- Remote record and blob indexes are memory-resident and reloadable. Durable offline content lives in explicit backups, not an implicit shadow database.

## 8. Records

### 8.1 Public browsing

Opening a handle or DID resolves a stable DID and its current PDS. `describeRepo` supplies the collection inventory. Each collection is paginated independently with opaque cursors. The loader keeps request parameters stable, detects repeated cursors, tolerates empty pages with cursors, and deduplicates records by URI and CID.

The table shows a friendly type label, record key, URI, CID, and any useful timestamp contained in the record. A record-supplied timestamp is labeled by its field name and is never implied to be a repository modification time.

### 8.2 Space browsing

For a selected Space, the browser shows:

- Space overview and policy
- My Records
- Whole Space, when the credential permits it
- Writer repositories
- Collections and records
- Members and management actions, when the connected account is authorized
- Space blobs and backup actions

Unknown collections remain fully browseable. Declared Space collections improve labels and previews but do not filter the repository.

### 8.3 Editing

The generic record editor has a schema-aware preview when a known Lexicon is available and a raw JSON editor for all records. It preserves unknown keys, `$type`, `$link`, `$bytes`, and blob references. Validation is enabled by default. Any bypass of known validation is an expert action with a separate warning and is not remembered as a preference.

Only the connected user's public repository and the connected user's own writer repository in a Space are writable. Foreign public repositories and other Space writers remain read-only.

## 9. Blobs

### 9.1 Inventory and reference index

Public and Space blob services enumerate CIDs through their respective APIs. Permissioned blobs always use the authenticated `com.atproto.space.listBlobs` and `com.atproto.space.getBlob` path; the app never falls back to a public sync endpoint for Space content. The app recursively scans current record values for blob references and builds a reverse index from CID to referring records. A complete reverse index requires walking every collection and record page in the selected repository scope. Until that background scan finishes, the UI displays indexed progress and labels reference counts as incomplete.

The blob browser displays:

- Derived label or CID fallback
- MIME type and declared size when present
- Data plane and owner
- Number and identity of referring records
- Availability and verification status

Derived filenames and extensions are marked as conveniences, not protocol metadata.

### 9.2 Preview and download

Blob bytes stream to a data-plane-qualified temporary path. Downloads use an `NSSavePanel`, atomic final writes, security-scoped access, and a stable suggested filename. Quick Look and drag-to-Finder export copies; they do not mutate the repository.

### 9.3 Upload and attachment

There is no standalone durable upload operation. **Attach File** runs this staged flow:

1. Validate advertised upload limits and local file access.
2. Upload the bytes and receive a blob reference.
3. Insert or replace the reference in a record draft.
4. Commit through the public compare-and-swap path or the explicitly warned Space-alpha preflight path defined below.
5. Refetch the record and blob to verify reachability.

If the record write is confirmed to have failed after upload, Activity reports a temporary unreferenced upload and offers retrying the record step. If submission has an uncertain remote outcome, Activity does not call the blob unreferenced or resubmit blindly: it first refetches the record and reconciles the exact JSON Pointer, original CID, and uploaded blob reference. The app does not claim that it rolled the upload back.

There is no generic **Delete Blob** action. Users remove an attachment by updating or deleting referring records after seeing every known reference and consequence.

## 10. Safe mutation model

### 10.1 Permission escalation

Public browsing is anonymous. Connecting an account requests only the base and read capabilities required for status and Space browsing. Write commands show their required capability and start a deliberate OAuth reconsent flow when invoked. Reconsent is part of the selected write flow, not an independent account-administration destination.

Generic public record management requires the appropriate repository grant; arbitrary attachment upload requires a blob grant; Space record creation, update, and deletion require their matching `space:` record-action grants. Space creation, policy changes, membership changes, and deletion require separate `manage=` administration grants. The app never substitutes the broader administration grant for a record-action grant. Granted capabilities are visible in Server & Account.

### 10.2 Update pipeline

Every update shares this preparation:

1. Refetch the current record and repository revision.
2. Preserve the original value and CID.
3. Validate the edited value.
4. Show the exact destination and a human-readable diff.
5. Recheck the remote value immediately before submission.
6. Submit once, then refetch and verify the committed value and CID.

Public repository updates use `swapRecord` and `swapCommit`. A stale public precondition produces a conflict UI containing the original, edited, and current remote values.

The current Spaces alpha update and delete schemas do not expose compare-and-swap inputs. For Space records, the app refetches the exact record and the writer-host `com.atproto.space.getLatestCommit` signed revision/hash immediately before submission. That comparison aborts a write when a change is already observable, but the read-only latest-commit endpoint cannot close the race with an external writer between comparison and submission. The confirmation UI states this limitation; Space deletes require **Back Up First**. If a future supported Space profile adds conditional mutation, the service uses it and removes the warning for that profile.

The app never silently overwrites an already detected change or automatically retries a non-idempotent mutation after an uncertain outcome.

### 10.3 Create and delete

Create validates the collection NSID, record key, `$type`, and repository ownership. Generated record keys are clearly identified before submission.

Delete refetches the record, shows the URI and CID, and lists affected blob references. A public delete uses the freshest available conflict precondition and offers **Back Up First**. A Space delete requires **Back Up First**, repeats the non-atomic alpha warning, and performs the immediate preflight comparison described above. A deleted public record is described as effectively permanent; the UI does not imply retained remote history.

Space deletion, member removal, record deletion, and removing an account from ATProtoDrive use separate actions, grants, and confirmation language. Space deletion explains that conforming syncers are expected to discard synchronized copies, but deletion does not erase writer-owned Space repository data, exports, backups, or copies retained by nonconforming applications. **Back Up First** evidence for whole-Space deletion is bound to the fully paginated authority claim, each observed writer revision/hash, the manifest digest, and a freshness window; stale or mismatched evidence cannot authorize deletion. Successful deletion purges the app's active Space credential, record cache, blob cache, and temporary previews while preserving explicit local backups.

### 10.4 Batch operations

`applyWrites` is used only when all writes target one repository and one data plane. Public batches use a commit precondition. Current-alpha Space batches remain atomic within the target Space repository but lack an external conflict precondition, so they receive the same preflight limitation and warning as individual Space writes. Cross-repository or public-to-Space copies become separately visible transfer jobs. The UI never describes them as atomic moves.

Writes are serialized per repository. Reads and downloads may run concurrently within bounded limits.

## 11. Backups

### 11.1 Backup package

A backup is a user-selected directory package with this logical structure:

```text
<name>.atprotodrivebackup/
  manifest.json
  records-index.json
  public/
    repo.car
    blobs/<cid>
  spaces/<space-digest>/<writer-did-digest>/
    repo.car
    blobs/<cid>
```

Only relevant branches are present. Public and Space content are never mixed in one unqualified directory. Directory components use filesystem-safe digests; the manifest retains the canonical Space URI and writer DID.

`manifest.json` includes:

- Format version
- Creation and completion timestamps
- Source account, DID, handle, PDS, and protocol profile
- Data-plane and Space identifiers
- Repository revisions and record/blob counts
- Component paths, byte counts, content hashes, and verification results
- Complete, incomplete, or failed state

`records-index.json` is a readable browsing index and does not replace the CAR as the canonical repository archive.

### 11.2 Creation and verification

Backup creation writes to a temporary sibling package, records progress component by component, verifies every written hash, and atomically renames the package only after a complete manifest is durable. An interrupted package remains explicitly incomplete and can resume at the component boundary; already verified components are skipped.

For each repository, the CAR revision defines the record snapshot. Blob references are derived from that CAR snapshot and every referenced blob is then fetched and hashed. This avoids calling a concurrent `listBlobs` result an exact match for an earlier CAR revision.

A whole-Space backup is not globally atomic across multiple PDS hosts. It fully paginates the authority-claimed writer set and records that claim plus each writer's independently observed revision and fetch time. It is **complete relative to that authority-claimed writer set** only when every claimed writer and referenced blob succeeds. The manifest and completion UI repeat that qualification because the authority's writer claim can be stale; completeness does not imply an authoritative membership list or a single cross-host instant. A user may instead choose an explicitly labeled single-writer Space backup.

CAR verification and blob hashing are independent stages. A CAR without blobs is never labeled a complete backup.

### 11.3 Supported local actions

V1 can create, browse, Quick Look, verify, reveal, and move a backup package to Trash. It cannot restore, import, or migrate the package into a PDS.

## 12. Transfers and Activity

`TransferQueue` persists jobs and their latest state in Application Support. Job kinds include:

- Blob download
- Blob attachment upload
- Repository export
- Full backup
- Backup verification
- Cross-source copy

States include queued, discovering, waiting for permission, running, verifying, completed, interrupted, cancelled, and failed. Each job records source, destination, stage, bytes where known, component progress, retry count, timestamps, and a redacted error.

On launch, jobs that were running become interrupted and resumable. Resumption occurs at safe component boundaries. Individual blob downloads may restart from byte zero when the endpoint does not support a validated ranged resume. Backup jobs reuse components whose stored hashes still match.

Cancellation stops future work, preserves completed backup components when useful, and never rolls back a confirmed remote write. Activity explains any partial remote outcome.

A cross-source record copy is allowed only between writable repositories owned by connected accounts. It snapshots the source record, transfers referenced blobs as required, preserves ordinary AT URI links without rewriting them, validates the destination collection, and asks before replacing a conflicting record key. Copying Space data into a public repository requires an explicit irreversible-disclosure confirmation. Copying public data into a Space does not imply that the public source became private. The destination create and any later source delete are separate jobs; v1 never labels that sequence an atomic move.

## 13. Account and server controls

Server & Account displays:

- Handle and DID
- Resolved PDS endpoint and server DID
- Repository/session status
- OAuth mode and granted capabilities
- Last successful status check
- Advertised blob upload limit
- Spaces availability or unsupported state

It exposes only:

- **Reconnect** — repeats OAuth while preserving local sources and backups. A write that needs additional permission invokes this same reconnect/reconsent mechanism contextually.
- **Remove from ATProtoDrive** — attempts logout or token revocation, removes local credentials and account caches, and preserves backups by default.

Remove-from-app does not deactivate the account, delete repository data, delete Spaces, or imply that every provider session was revoked.

## 14. Error handling and observability

Typed error states include:

- Offline or transport failure
- Rate limited, including retry timing when advertised
- Reconnect or reconsent required
- Authorization refused
- Unsupported Spaces or protocol profile
- Repository, record, or blob not found
- Space tombstone or deleted Space
- Stale mutation conflict
- Missing referenced blob
- CAR, commit, or content-hash verification failure
- Local storage or security-scoped bookmark failure

An error never converts a previously loaded collection into an empty successful state. The app keeps last-known data visible with a stale/error banner and exposes retry or reconnect where appropriate.

Automatic retry is limited to idempotent reads, discovery, and downloads. Mutations require a fresh precondition and user intent after uncertain outcomes.

Normal logs include operation identifiers, endpoint classes, status codes, timing, and redacted protocol errors. They exclude OAuth tokens, Space credentials, record bodies, blob bytes, and private provider state.

## 15. Keyboard, menu, and drag behavior

The app provides discoverable toolbar and menu equivalents for:

- Open Repository
- Open Space
- Refresh
- New Record
- Edit Record
- Delete Record
- Attach File
- Download
- Quick Look
- Back Up
- Toggle Inspector
- Focus Search

Context menus mirror applicable actions. Destructive actions are never gesture-only.

Drag-to-Finder exports a copy through a file promise. Internal cross-source drag defaults to copy. Because a protocol-level move would be create-plus-delete across repositories, v1 does not offer an atomic move affordance.

## 16. Testing strategy

### 16.1 Unit and service tests

Tests cover:

- Handle/DID/PDS resolution and public anonymous client routing
- Collection discovery and per-collection pagination
- Opaque cursor handling, repeated-cursor termination, and URI/CID deduplication
- Public versus Space endpoint, credential, URI, and cache selection
- Space blob requests never falling back to public sync endpoints
- Capability-gated private-state reading and absence of private-state mutation
- Recursive blob-reference extraction and reverse indexing
- Upload-then-reference success and partial failure
- JSON preservation and validation
- Public mutation diffs and atomic conflict preconditions
- Space mutation preflight, detected-change aborts, non-atomic warning, and post-write verification
- No blind mutation retry
- Separation of Space record-action grants from Space administration grants
- Space policy, member, and deletion authorization and confirmation behavior
- Backup manifest encoding, path isolation, atomic completion, hashes, and interrupted resume
- Qualified whole-Space completeness against the fully paginated authority-claimed writer set
- Transfer persistence, cancellation, retry, component resumption, reveal, and relaunch recovery
- Cross-source access-transition warnings and non-atomic copy behavior
- Independent session, cache, and selection routing for multiple connected accounts
- Account reconnect and remove-from-app behavior
- Absence of high-risk account actions from command routing

URL-protocol fakes verify request methods, parameters, authorization, DPoP routing, pagination, status handling, and response decoding. Existing CAR fixtures continue to verify public and Space repository integrity paths.

### 16.2 UI and runtime tests

Runtime verification covers:

- Native sidebar selection and stable per-window navigation
- Sortable table columns, search, breadcrumbs, and selection retention
- Inspector presentation and raw/friendly record views
- Quick Look and drag-to-Finder copy
- Contextual reconsent, public conflicts, Space alpha race warnings, confirmations, unsupported, stale, empty, and failed states
- Space creation, policy, membership, and deletion flows
- Activity progress, cancellation, retry, component resumption, reveal-in-Finder, and relaunch restoration
- Two simultaneous account groups with independent navigation and data
- Account status, reconnect, and remove-from-app

The app must build and test on the macOS target, launch successfully, render the redesigned surfaces, and be inspected through screenshots. Live public-repository browsing is verified against a current public PDS. Live Spaces evidence is reported separately from mocked and fixture evidence; Swift compilation or generated-client availability is not accepted as proof of current alpha interoperability.

## 17. Acceptance criteria

ATProtoDrive v1 is complete only when all of the following are demonstrated in the current worktree:

1. A user can open a public repository by handle or DID without signing in, browse every reported collection and paginated record, inspect raw JSON and identifiers, and recover visibly from failures.
2. Two connected accounts can independently browse their own public repositories, public blobs, supported private application state, discoverable Space repositories, and manually opened readable Spaces without selection, authorization, or cache crossover.
3. Blob browsers show references and metadata, Quick Look and download work, and attachment upload becomes successful only after the referring record is committed and verified.
4. Owned public records support create, update, and delete with contextual reconsent, validation, diff preview, atomic conflict protection, and post-write verification. Owned Space records support the same operations with a last-moment preflight, explicit current-alpha race warning, required pre-delete backup, and post-write verification. Foreign repositories remain read-only.
5. A backup contains verified CAR archives, blob payloads, a readable record index, and a complete manifest. Whole-Space completeness is qualified against the fully paginated authority-claimed writer set. Interrupted work resumes safely and a CAR-only export is not called complete.
6. Activity persists across relaunch, accurately represents queued, running, partial, completed, cancelled, and failed work, and demonstrates cancel, retry, component resumption, and reveal-in-Finder.
7. An authorized owner can create a Space, change its supported policy, manage members, and delete it through separate administration grants and confirmations, with active cache and credential cleanup after deletion.
8. Cross-source record copy transfers required blobs, warns on access-class changes, and never presents create-plus-delete as an atomic move.
9. Server & Account shows current status and supports reconnect, contextual permission reconsent, and remove-from-app while every prohibited high-risk account-administration action remains absent.
10. Unit and service tests pass, the macOS app builds and launches, the primary flows are navigated in the running app, and screenshots demonstrate the finished UX.

## 18. References

- [ATProto Spaces alpha announcement](https://atproto.com/blog/atproto-spaces-alpha)
- [Proposal 0016: Permissioned Data](https://github.com/bluesky-social/proposals/blob/main/0016-permissioned-data/README.md)
- [AT Protocol OAuth specification](https://atproto.com/specs/oauth)
- [AT Protocol permission specification](https://atproto.com/specs/permission)
- [AT Protocol repository specification](https://atproto.com/specs/repository)
- [AT Protocol blob specification](https://atproto.com/specs/blob)
