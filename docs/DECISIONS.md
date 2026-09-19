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
