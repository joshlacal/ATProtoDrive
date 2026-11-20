# ATProtoDrive

ATProtoDrive is a native macOS browser for AT Protocol repositories, records and files. Open a public repository by handle or DID without signing in, or connect an account. Public reads use the repository's resolved PDS anonymously.

## Available now

- **Public Records:** collection browsing, paginated record tables, search, sorting and a JSON inspector.
- **Public Files:** paginated blob inventory for opened repositories and connected accounts, file-type and CID search, sorting and a metadata inspector.
- **Reference scans:** an explicit, cancellable scan of every public collection and record page, showing each reference's record URI and JSON Pointer. File enumeration and reference-scan completion are reported separately. File type and size come from record declarations; listed files have not been downloaded or hash-verified.
- **Browser navigation:** per-window Records / Public Files destinations, back/forward history and qualified selection.
- **Spaces:** full November 12 alpha Space workspace — list owned and shared Spaces, open a Space by `at://` URI, create personal/member-list/public Spaces, inspect Space policies (`getSpace`), list writers (`listWriters`), manage members (`memberspace`), browse/create/edit/delete records, download/QuickLook Space blobs, and verify writer STAR archives.

File previews/downloads for public repositories, verified backup packages, and durable transfer jobs remain planned work. See the [v1 plan index](docs/superpowers/plans/2026-08-23-atprotodrive-v1.md) and [Public Files continuation](docs/superpowers/plans/2026-09-19-public-files-continuation.md).

## Prerequisites

- **macOS 15.0+** (Sequoia)
- **Xcode 16.0+**
- Local path dependencies: sibling checkouts of [Petrel](https://github.com/joshlacal/Petrel) at `../Petrel` and [Swan](https://github.com/joshlacal/Swan) at `../Swan`. They are not part of this repository; clone them next to it at the revisions below.

### Dependency revisions

The Xcode project references Petrel and Swan as local packages (`XCLocalSwiftPackageReference`), so neither the project nor `Package.resolved` pins their revisions. Check out these revisions before building; they are the ones the current test run used:

| Dependency | Path | Revision |
|---|---|---|
| Petrel | `../Petrel` | `c694ea48b23f6f9f2cacf173499e06866fb298c5` |
| Swan | `../Swan` | `83b9d3ca2564f8751e35dc0abba8357541ab0210` |

Swan's own `Package.swift` uses `../Petrel` when present and otherwise falls back to Petrel revision `59a07d03…` from GitHub. When either dependency moves, update this table in the same change.

---

## Building and Running

### Xcode
Open `ATProtoDrive.xcodeproj` in Xcode, select the `ATProtoDrive` scheme with the **My Mac** destination, and press **Cmd+R** to build and run.

### Codex Run / Command Line

The Codex Run action uses the same script as a local terminal:

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify

# Offline sample repository; no account restore or live network services
ATD_CODE_SIGNING_ALLOWED=NO ./script/build_and_run.sh --fixture --verify
```

In the sample repository, choose **Public Files**, load the next page and select **Scan References** to populate file metadata and record links. This fixture validates presentation and navigation, not a live server or payload integrity. Build output defaults to `.build/DerivedData`; override it with `ATD_DERIVED_DATA` if needed.

Direct Xcode commands:

```bash
# Build app
xcodebuild -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -destination 'platform=macOS' build

# Run the offline Public Files regression suites
xcodebuild test -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -destination 'platform=macOS' \
  -only-testing:ATProtoDriveTests/BlobServiceTests \
  -only-testing:ATProtoDriveTests/BlobInventoryStoreTests \
  -only-testing:ATProtoDriveTests/BlobReferenceIndexTests \
  -only-testing:ATProtoDriveTests/RecordInventoryScannerTests \
  -only-testing:ATProtoDriveTests/PublicBrowserPresentationTests \
  -only-testing:ATProtoDriveTests/PublicFilesNavigationTests \
  -only-testing:ATProtoDriveTests/PublicFilesNavigationRaceTests
```

The live public enumeration smoke test is opt-in: prefix the test command with `TEST_RUNNER_ATPROTODRIVE_LIVE_PUBLIC_SMOKE=1`. It only resolves `bsky.app` and lists up to five public blob identifiers. The legacy `AccountStoreTests` suite contains interactive OAuth and account-persistence tests; it is deliberately excluded from the offline command.

---

## Authentication & CAB Dependency

ATProtoDrive uses OAuth 2.0 with DPoP for all account sessions:
- **CAB Server (`https://atprotodrive.catbird.blue`):** Serves client metadata and JWKS assertions for Client Assertion Backend authentication (`AuthMode.cab`).
- **OAuth Redirect Scheme:** Uses `blue.catbird.atprotodrive:/callback` (ATProto specification requires the private-use URI scheme to match the client_id FQDN reversed).
- **Dual Client Metadata:**
  - Confidential Client Metadata: `https://atprotodrive.catbird.blue/oauth-client-metadata.json`
  - Public Client Metadata: `https://atprotodrive.catbird.blue/public-client-metadata.json`

### Why Two Metadata Documents Exist
Bluesky-lineage PDS implementations reject `private_key_jwt` client assertions from native application clients (requiring client authentication method `none`). In contrast, `swan.place` and CAB-aware PDSes accept confidential CAB authentication.

`AccountStore` automatically manages this interoperability:
1. Attempts `AuthMode.cab` first via `https://atprotodrive.catbird.blue/oauth-client-metadata.json`.
2. If the PDS rejects native client metadata, automatically falls back to `AuthMode.publicOAuth` with `https://atprotodrive.catbird.blue/public-client-metadata.json`.
3. Persists the negotiated auth mode per account for seamless token refresh.

---

## Upstream Alpha PDS & Lexicon Re-vendoring

The Bluesky permissioned data spaces alpha is under active development. The hosted alpha PDS is wiped and updated weekly on Thursdays.

The app currently targets the November 12, 2026 alpha (`d4def6e9`) through Petrel 2.0 and Swan at the revisions listed under [Dependency revisions](#dependency-revisions). See [the November 12 compatibility note](docs/spaces-release-20261112.md).

If upstream lexicons change on the `permissioned-data` branch of `bluesky-social/atproto`:
```bash
# 1. Resolve and validate the current permissioned-data commit SHA.
# Record this value in the vendoring change so regeneration remains reproducible.
ATPROTO_PERMISSIONED_DATA_SHA="$(
  git ls-remote https://github.com/bluesky-social/atproto.git \
    refs/heads/permissioned-data | awk 'NR == 1 { print $1 }'
)"
test "${#ATPROTO_PERMISSIONED_DATA_SHA}" -eq 40

# 2. Vendor updated space lexicons into Petrel using the resolved commit SHA
cd ../Petrel
./Scripts/vendor-space-lexicons.sh "$ATPROTO_PERMISSIONED_DATA_SHA"

# 3. Regenerate Swift lexicon types
./Scripts/regenerate-generated.sh

# 4. Verify ATProtoDrive build & test suite
cd ../ATProtoDrive
xcodebuild test -project ATProtoDrive.xcodeproj -scheme ATProtoDrive -destination 'platform=macOS' -only-testing:ATProtoDriveTests
```

---

## Documentation & References

- **Spaces November 12 compatibility:** `docs/spaces-release-20261112.md`
- **Architecture & Design Specification:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`
- **Implementation Plan Index:** `docs/superpowers/plans/2026-08-23-atprotodrive-v1.md`
- **Manual E2E Smoke Checklist:** `Scripts/e2e-smoke.md`
- **ATProto Proposal 0016:** [Permissioned Data Spaces](https://github.com/bluesky-social/proposals/blob/main/0016-permissioned-data/README.md)

---

## License

ATProtoDrive is dual-licensed under either of

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option (`MIT OR Apache-2.0`). Unless you explicitly state otherwise, any contribution you intentionally submit for inclusion in this project, as defined in the Apache-2.0 license, is dual-licensed as above, without any additional terms or conditions.

To report a security vulnerability, see [SECURITY.md](SECURITY.md).
