# ATProtoDrive consumer compatibility

ATProtoDrive is an additional Swift consumer of Petrel and Swan's archive helpers. Its existing permissioned-data browser needed reconciliation so the shared SDK upgrade did not leave it on the old signed-commit/CAR format. The isolated application now builds, uses the October 22 field names, and verifies foreign record lists through an authenticated complete STAR snapshot. This is consumer integration evidence; a real private-account browser flow has not been qualified.

Governing plan: [Spaces implementation](../../workspace/docs/execution-plans/2026-10-23-spaces-release-implementation.md).

## Changes

- `spaceType`, `repoRev`, and `data` replace obsolete generated call/response fields without recomputing stored digest bytes.
- Live foreign repository verification and record browsing use Petrel's MAC-authenticated credential transport followed by complete STAR identity, canonical record, ordering and digest verification. The record list and commit come from the same snapshot; a tampered trailing record cannot publish a partial list. Both foreign `getRepo` reads accept archives up to Petrel's STAR maximum (128 MiB) instead of the credential transport's 10 MiB default, so a large member repo stays browsable; Petrel still checks the MAC and the archive before returning it (review finding ATPD-1).
- Owner-OAuth reads retain their existing route. Historical CAR verification remains available only for old archive fixtures/offline use.
- Only typed authority deletion or exact HTTP 400 `SpaceDeleted` selects deletion UI. Generic error text and repository-host `SpaceNotFound` no longer imply an authority tombstone.
- Protocol error tests inject the resolver's controlled URLSession, preserving production URL validation. The live user-account consent test now requires explicit `ATPROTODRIVE_RUN_LIVE_OAUTH=1` and no longer prints authorization URLs.

## Verification

The macOS application builds against the isolated updated Petrel and Swan packages. The latest full test run executed 245 tests across 21 suites with two live tests skipped and one timing assertion failure. That failure is the unchanged historical recovery-index performance test: its 500 ms wall-clock limit is sensitive to concurrent build load. A final functional run excluding only that wall-clock assertion passed all 244 selected tests; the isolated assertion then passed in 352 ms on the same final binary. Neither its algorithm nor threshold was altered. The latest foreign snapshot/tampering and protocol-error cases passed. Logs preserve the initial failures and successful focused results in `artifacts/drive/`.

The built application was launched in its existing `public-browser` presentation fixture, with account restoration disabled, and its visible record browser captured in `artifacts/drive/public-browser-fixture.png`. That screenshot demonstrates application launch/rendering only; it does not validate the private archive UI or real OAuth. A later capture attempt after the final record-list change was blocked because the Mac was locked; the saved screenshot is retained with that earlier-build limitation. No production user session was opened or modified.

To finish private UI qualification, launch a signed build, sign in to a disposable October 22-compatible local account, open a Space hosted by a distinct authority/PDS, select another account's repository, verify its archive and browse records. Confirm that tampered archives produce no rows/verified badge, member removal denies fresh reads, and authority deletion exposes removal UI without recreating the Space. Source tests and local host transport evidence must not substitute for that app-level flow.

## Custody

The source starts at `c75a05f8` in a new jj workspace. Canonical ATProtoDrive and unrelated work are unchanged. This repository has no configured remote, so its feature revision is local. Independent source review found no actionable remaining issue in the snapshot/error pipeline. The final source revision is recorded in the integration manifest.
