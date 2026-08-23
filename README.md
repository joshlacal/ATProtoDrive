# ATProtoDrive

ATProtoDrive is a native macOS file-browser-style explorer for ATProto permissioned data spaces (`com.atproto.space.*` and `com.atproto.simplespace.*`), announced in the [ATProto Spaces Alpha](https://atproto.com/blog/atproto-spaces-alpha).

Built with SwiftUI on top of [Petrel](https://github.com/joshlacal/Petrel) (Swift ATProto SDK) and SwanSpaces (Swift PDS & Space CAR verifier), ATProtoDrive allows multi-account browsing, space management, record CRUD, blob inspection, and repository cryptographic verification.

---

## Features

- **Multi-Account Sidebar:** Sign in to multiple ATProto accounts simultaneously (e.g. `swan.place` and Bluesky alpha PDS) with side-by-side space browsing.
- **Space Management:** Create spaces with member-list or public write policies; open spaces by URI reference (`at://authority/space/type/skey`).
- **Member Management:** Add and remove authorized writer members on owned spaces.
- **Record Table & Inspector:** Browse writer repos and records; inspect canonical `at://` URIs, CIDs, pretty-printed JSON records, and blob attachments.
- **Record CRUD & Blob Upload:** Create, edit, and delete space records; upload blobs directly into records with automatic JSON reference insertion.
- **Blob Actions:** QuickLook previews, copy CID/URI, and native `NSSavePanel` file downloads.
- **Cryptographic Repo Verification:** Verify space writer repositories against author signing keys (P-256 and secp256k1) and streaming CAR LtHash commitments using `SwanSpaces`.

---

## Prerequisites

- **macOS 15.0+** (Sequoia)
- **Xcode 16.0+**
- Local path dependencies: `../Petrel` and `../swan` (included in repository monorepo root)

---

## Building and Running

### Xcode
Open `ATProtoDrive.xcodeproj` in Xcode, select the `ATProtoDrive` scheme with the **My Mac** destination, and press **Cmd+R** to build and run.

### Command Line
```bash
# Build app
xcodebuild -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -destination 'platform=macOS' build

# Run unit and integration tests
xcodebuild test -project ATProtoDrive.xcodeproj \
  -scheme ATProtoDrive \
  -destination 'platform=macOS' -only-testing:ATProtoDriveTests
```

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

- **Architecture & Design Specification:** `docs/superpowers/specs/2026-08-23-atprotodrive-v1-design.md`
- **Implementation Plan Index:** `docs/superpowers/plans/2026-08-23-atprotodrive-v1.md`
- **Manual E2E Smoke Checklist:** `Scripts/e2e-smoke.md`
- **ATProto Proposal 0016:** [Permissioned Data Spaces](https://github.com/bluesky-social/proposals/blob/main/0016-permissioned-data/README.md)
