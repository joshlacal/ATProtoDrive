# Public Files continuation

Continue the approved [v1 design](../specs/2026-08-23-atprotodrive-v1-design.md) with a complete public inventory browsing increment, drawing from [Files Tasks 1–3](2026-08-23-atprotodrive-v1-files-backups-transfers.md). This increment does not claim completion of that entire plan.

## Scope and acceptance

1. Anonymous, resolved-PDS blob enumeration with checked response status/body, opaque pagination, deduplication, retained failed-refresh content and explicit retry.
2. Explicit user-started public record reference scan with progress, cancellation, cursor-cycle detection and atomic qualified index replacement. Enumeration and reference completeness are separate; enumeration never establishes payload availability or integrity.
3. Public Files reachable for anonymous repositories and connected accounts, searchable sortable table, qualified selection, and reference/identity inspector. Record references navigate back to their collection.
4. Deterministic offline fixture, meaningful service/store/scanner/presentation tests, app build, runtime screenshot, and repeatable Run action.

## Integration contracts

- Root owns project membership, app injection, ContentBrowserView, MainWindowView, repository navigation and documentation.
- Service worker owns PublicBlobService.swift, RecordInventoryScanner.swift, BlobInventoryStore.swift, BlobReferenceIndex.swift and corresponding tests.
- UI worker owns BlobBrowserView.swift, BlobInspectorView.swift, BlobTableProjection.swift, SearchQuery.swift and presentation tests.
- Build worker owns script/build_and_run.sh and .codex/environments/environment.toml.
- No worker writes VCS history or edits local dependencies; one final integration owner preserves the pre-existing parent changes.

## Review ledger

| Tasks / seam | Check and ruling |
| --- | --- |
| Services / UI | Immutable repository per store; UI consumes snapshot, progress, errors and explicit async methods. Scope changes construct a new store. |
| Scanner / existing index | Stage a complete scope snapshot; reject abnormal exhaustion without publishing partial replacement. |
| Public slice / full Files plan | Space service prerequisite is absent. Ruling: implement only anonymous public inventory, no permissioned routing or payload transport; isolated subset has no Space dependency. |
| Existing scan progress definitions | Full plan has conflicting progress shapes. Ruling: retain existing counters and expose completion separately. |
| Build / baseline | Use installed Xcode and sibling local dependencies; report dependency drift rather than regenerate shared code. |

## Progress

- Baseline: isolated workspace at `../ATProtoDrive-files-20260919`, parent `8cbce785` retaining unfinished blob and verifier work.
- Implemented anonymous blob enumeration, explicit atomic reference scans, searchable/sortable Files table, metadata inspector, reference navigation, account/anonymous destinations, cancellation and stale-request guards.
- Added deterministic offline fixture and the Codex Run action. Runtime testing exposed a constraint-update crash in the native inspector for both old record and new file content; the side-panel workaround is recorded in [the decision log](../../DECISIONS.md).

## Verification — 2026-09-19

- Xcode 27.0, macOS 27.0, arm64; app builds with current sibling Petrel/Swan dependencies and `CODE_SIGNING_ALLOWED=NO`.
- Initial selected matrix: **163 passed, 1 skipped**, 16 suites. Included blob services/store/index, scanner, browser presentation/domain/navigation/races, public repository services/store/fixtures/resolver/sidebar/recents, verifier and write pipeline. The skipped test was the opt-in live smoke.
- Final targeted run after adding cursor-cycle and partial-staging failure tests: **31 passed, 0 skipped**, scanner/navigation/presentation suites. Live anonymous resolution and enumeration returned five identifiers from `bsky.app` at `https://puffball.us-east.host.bsky.network`; this verifies public metadata transport, not file bytes or permissioned access.
- Results retained locally at `/tmp/atprotodrive-files-20260919/public-files-tests.xcresult` and `/tmp/atprotodrive-files-20260919/final-regressions.xcresult`; associated logs are in the same directory. Earlier compile failures remain there and were resolved against current dependency interfaces.
- Built fixture was launched and visually inspected with a screenshot: pagination yields three distinct files; reference scan supplies MIME/size/count; MIME search filters correctly; file details and record links work; Back retains the inventory. Final record inspector reports the completed scan and both inspector surfaces remain running.
- Run script syntax and executable identity across macOS `/tmp` aliases checked. Added lines have no trailing whitespace.
- Legacy interactive OAuth/account-persistence tests were excluded. No account credentials, Space writes, downloads, previews, transfers, or payload integrity claims are part of this increment.

## Remaining v1 work

Canonical Space services and contextual authorization, file payload transport/preview, verified backup packages, durable transfer jobs, and mutation flows remain separate work in the v1 plan. This increment provides a working public file inventory and reference browser.
