# ATProtoDrive: November 12 Spaces alpha compatibility

ATProtoDrive now targets the November 12, 2026 Spaces alpha at atproto `d4def6e9`, through the old-line Petrel Spaces backport `db6c3ccb` and Swan `f240becd`. This is a compatibility-only update; it adds no Spaces features.

## Changes

- Space creation and listing use the renamed `space` fields. Member mutations send one-element `putMembers` and `removeMembers` batches.
- Repository discovery uses `com.atproto.space.listWriters`. The existing repository view shows only current `repoWrite` entries; it skips `repoRemoved` and unknown entries because they are not current writers.
- `AccountNotAuthorized` remains an access refusal. `RepoTakendown` and `RepoDeactivated` are shown as suspended, without deleting persisted space state. `UpstreamFailure` is shown as temporary, and `InvalidSpaceMac` as a response-verification failure.
- Petrel owns HPKE export, RFC 9421 MAC requests and response verification. ATProtoDrive passes verified bytes to the new `SpaceSTAR.verify(archive:space:repo:maximumArchiveBytes:)` shape and no longer supplies MAC material.
- Test STAR fixtures use the November 5 `0x01` pair marker and `0x00` terminator. The large-archive transport fixture answers Petrel's new `Accept-Signature` request rather than using the removed commit-MAC helper.

`listRecords` no longer accepts `reverse`. ATProtoDrive did not request reverse order for Space records and applies its existing local table sort, so no ordering change was needed. Swan's public `SwanSpaces` recovery and CAR APIs used by `RepoVerifier` did not change; Swan's STAR framing and space-meta `repoRev` changes are internal to the dependency and forced no ATProtoDrive source edit.

## Verification

Run the full macOS suite with:

```bash
ATD_DERIVED_DATA="$PWD/../../_build/ATProtoDrive" xcodebuild test \
  -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -destination 'platform=macOS' \
  -derivedDataPath "$ATD_DERIVED_DATA" \
  -only-testing:ATProtoDriveTests
```

The compatibility run passed all 249 tests in 22 suites. The two opt-in live tests skipped in the offline run.
