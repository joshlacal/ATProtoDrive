# Decisions

## 2026-09-19 · ATProtoDrive · Public Files continuation

Chose: a complete public file inventory browsing increment, using the existing qualified blob index (provisional). The public browser is implemented; canonical Space services and contextual authorization are not. Anonymous public enumeration and record scans can be completed independently without changing those authorities. Payload previews/downloads, backups, durable transfers and Spaces remain separate increments.

Reversible until: integration of this continuation. Override by: redirecting the next increment to the Space service prerequisite in the v1 plan.

Reference scans are explicit, cancellable actions because large public repositories can require many paginated requests. Listing files remains immediately useful and does not imply a complete reference scan or verified payload bytes.

## 2026-09-19 · ATProtoDrive · Current Petrel compatibility

Chose: update legacy Space helper call sites to the currently required split read/write policy fields and `putMember` input. The old member policy applies to both fields; adding a legacy full member sets both read and write. This restores compilation against the sibling dependency while the root Space surface remains read-only. No permissioned requests were made to validate this compatibility mapping.

The resolved package file is refreshed from the current sibling packages: obsolete CryptoSwift, JOSESwift and swift-zlib pins disappear, and zstd 1.5.7 is added. No existing retained dependency version is upgraded. Reversible until integration; override by reverting this consumer compatibility change and pinning a compatible dependency checkout.

The existing recovery index also adopts Swan's current canonical path ordering and individual-entry consumption API. Shared CIDs remain distinct record paths, and out-of-order consumption is rejected. Current SignedCommit initializer ordering is reconciled in test consumers. Verifier and write-pipeline regressions pass; this does not qualify a live Space workflow.

## 2026-09-19 · ATProtoDrive · Inspector layout

Chose: place the existing inspector content in a fixed-width side panel beside the navigation split view (provisional). On the current macOS/Xcode 27 runtime, opening the native SwiftUI inspector repeatedly terminated the app with an AppKit constraint-update exception for both record and file details. Fixing the native inspector width did not resolve it. The ordinary side panel preserves the toolbar toggle and selection while remaining stable during the same fixture interactions.

Reversible until integration. Override by restoring the native inspector after its window constraint behavior is verified on the target runtime. This is a local runtime workaround, not a claim about all macOS versions.

## 2026-10-30 · ATProtoDrive · October 29 Spaces alpha compatibility

Chose: map the two existing create-space options onto the memberspace policy (provisional). "Member List" becomes `com.atproto.memberspace.policy` with no flags set, and "Public" becomes memberspace with `publicRead: true` and `publicWrite: true`. `allowedApps` is omitted, which matches the old open app access. This is the exact conversion the October 29 proposal gives for the old member-list and public policies, so a space created by the app grants the same access as before. Rejected: offering personalspace or managedspace creation, or exposing the new publish flags (feature work the compatibility request rules out). This supersedes the split read/write mapping in the 2026-09-19 compatibility entry.

Chose: treat `PolicyMismatch` from `com.atproto.memberspace.listMembers` as "member list not readable", like an unimplemented method (provisional). An own space governed by a personalspace or managedspace policy then still loads its repositories with no member list, instead of failing the whole detail load. Both the typed Petrel error and the generic XRPC error are recognised. Rejected: deciding from the space type before calling listMembers (the app cannot read a non-owner policy, and the server is the authority on which policy applies).

Chose: reword the compiled detail view's access-denied line to "not found, or you do not have access" (provisional). Under October 29 a refused user receives `SpaceNotFound`, which Petrel already reports as an authorization refusal described as "not found or not authorized". `UserNotAuthorized`, `AppNotAuthorized` and `NotAuthorized` are still handled. Rejected: leaving "You no longer have access", which asserts prior membership the error no longer implies.

Reversible until: integration of `claude/spaces-oct29-20261030`. Override by: reverting that bookmark's ATProtoDrive commit.

## 2026-11-12 · ATProtoDrive · November 12 Spaces alpha compatibility

Chose: keep the existing repository list as a current-writer view. `com.atproto.space.listWriters` now returns `repoWrite` and `repoRemoved` entries; the app maps `repoWrite` and skips `repoRemoved` and unknown variants. ATProtoDrive does not maintain a synchronized local copy, so there is no retained repository state to delete or hide separately.

Chose: preserve suspension and transient failures rather than treating them as deletion. `RepoTakendown` and `RepoDeactivated` display as suspended, `UpstreamFailure` as temporary, and only `SpaceDeleted` invalidates the cached credential. Petrel owns the new HPKE-export and RFC 9421 MAC flow.

Reversible until: integration of `claude/spaces-nov12-20261112`. Override by: introducing explicit removed-writer history only as separate product work.

## 2026-11-20 · ATProtoDrive · Wire interactive Spaces workspace and Open Space by URI into root browser

Chose: replace the read-only `LegacySpacesCompatibilityView` route in `ContentBrowserView` with `SpacesBrowserView` (provisional), keeping `LegacySpacesCompatibilityProjection` compiling for existing sidebar tests, and wire `.global(.openSpace)` to `OpenSpaceDestinationView`. `SpacesBrowserView` connects the already-migrated November 12 Spaces models and views (`SpaceListModel`, `SpaceDetailView`, `RecordTableView`, `RecordInspectorView`, `CreateSpaceSheet`, `OpenSpaceSheet`, `MemberEditor`, `RecordEditorSheet`), adds `com.atproto.personalspace.policy` creation and `com.atproto.space.getSpace` policy summaries for owned Spaces, and preserves an OAuth "Browse My Records" fallback when whole-Space credential sync is refused (such as `AppNotAuthorized` on an app-restricted Space) while the account has its own `repoRev` in `listSpaces`.

Rejected: leaving the Spaces tab on the dead four-line read-only disclosure stub until the full multi-plan mutation/backup-gate coordinator from Plan 2 is written from scratch, because all November 12 Space CRUD/read/STAR-verification views were already implemented and unit-tested in the repo but unreachable from `ContentBrowserView`.

Reversible until: merge of `agy/atprotodrive-spaces-20261120` or replacement by the full Plan 2 Space coordinator. Override by: reverting the `ContentBrowserView` route back to `LegacySpacesCompatibilityView` or replacing `SpacesBrowserView` when Plan 2 lands.
