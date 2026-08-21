# ATProtoDrive End-to-End Interop Smoke Checklist

This checklist provides a manual, step-by-step verification script for human execution against live ATProto PDS environments (e.g. `swan.place` and the Bluesky permissioned data spaces alpha PDS).

---

## Preamble & Environment Notice

> **⚠️ Alpha PDS Wipe & Re-vendoring Notice:**
> The Bluesky Spaces Alpha PDS is updated and reset weekly on Thursdays. If schema or lexicon breaking changes occur upstream:
> 1. Run `Petrel/Scripts/vendor-space-lexicons.sh <sha>` using the latest `permissioned-data` branch commit from `bluesky-social/atproto`.
> 2. Run `Petrel/Scripts/regenerate-generated.sh` in the Petrel directory.
> 3. Verify tests compile and pass with `xcodebuild test -project ATProtoDrive/ATProtoDrive.xcodeproj -scheme ATProtoDrive -destination 'platform=macOS'`.

### Prerequisites
- macOS 15+ Sequoia workstation.
- Built `ATProtoDrive.app` (or running from Xcode with scheme `ATProtoDrive`).
- Two live ATProto accounts:
  - **Account A (Swan PDS):** e.g. `alice.swan.place` (CAB authentication via `https://cab.swan.place`).
  - **Account B (Bluesky Alpha PDS / bsky.social):** e.g. `bob.test` (Public client authentication via `https://cab.swan.place/public-client-metadata.json`).
- Network access to `https://cab.swan.place` and target PDS hosts.

---

## Part 0: Live OAuth Login & Callback Routing (Controller Deferred Checks)

### Step 0.1: Login Account A (swan.place via CAB)
1. Launch `ATProtoDrive.app`.
2. Observe empty state: "No Accounts" with description "Add an ATProto account to browse Spaces."
3. Click the **"Add Account"** button in the sidebar or empty state.
4. Enter Account A handle (e.g. `alice.swan.place`) and click **"Log In"** (or press Return).
5. Default browser opens to the authorization consent page on `swan.place`.
6. Authorize the application requesting scope `atproto space:*?authority=*`.
7. Browser redirects to `blue.catbird.atprotodrive:/callback?...`.
8. Observe ATProtoDrive handles the callback, dismisses the sheet, and displays Account A in the sidebar with handle and DID.
- **Expected Observation:** Account A appears under the "Spaces" sidebar section; no error banners.
- **Result:** Pass [ ] / Fail [ ]

### Step 0.2: Login Account B (bsky-lineage via Public Client Fallback)
1. Click the **"+" (Add Account)** button in the sidebar toolbar.
2. Enter Account B handle (e.g. `bob.bsky.social` or alpha PDS handle) and click **"Log In"**.
3. App attempts CAB flow, detects native client rejection, automatically falls back to Public OAuth client (`https://cab.swan.place/public-client-metadata.json`), and opens browser authorization URL.
4. Complete authorization in browser.
5. Browser redirects to `blue.catbird.atprotodrive:/callback?...`.
6. Observe ATProtoDrive routes callback via state parameter matching and adds Account B to sidebar.
- **Expected Observation:** Both Account A and Account B are visible in the sidebar simultaneously.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 1: Swan Account Creates S1, Adds Alpha Account, Cross-PDS Read & Verify

### Step 1.1: Create Space S1 on Account A
1. In the sidebar, locate Account A header and click the **"+" (New Space)** icon.
2. In the "New Space" sheet:
   - Space Type: `space.swan.drive`
   - Space Key (skey): `drive-s1`
   - Policy: Select **"Member List Policy"**
3. Click **"Create Space"**.
- **Expected Observation:** Sheet dismisses; sidebar updates to show `drive-s1` under Account A marked with blue icon. Selecting `drive-s1` shows Space Details with header "Owned Space", skey `drive-s1`, and authority matching Account A DID.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.2: Add Account B as Member to S1
1. In the Space Detail view for `drive-s1`, scroll to the **"Members"** section.
2. Click **"Add Member…"**.
3. In the "Add Member" sheet, enter Account B's handle (e.g. `bob.bsky.social`) or DID.
4. Click **"Add Member"**.
- **Expected Observation:** Sheet dismisses; Account B's DID appears in the Members list under `drive-s1`.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.3: Account A Creates Record in S1
1. In the Space Detail toolbar for `drive-s1`, click **"New Record"**.
2. In the Record Editor sheet:
   - Collection: `space.swan.drive.file`
   - Record Key (rkey): `doc-1`
   - JSON Value: `{"title": "Hello from Swan", "createdAt": "2026-08-21T12:00:00Z"}`
3. Click **"Format JSON"** and verify formatting.
4. Click **"Save Record"**.
- **Expected Observation:** Record is saved. In Space Detail, Account A's repo entry shows under "Writer Repositories". Selecting Account A's repo navigates to Record Table displaying `doc-1`.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.4: Account B Discovers S1 and Reads Records Cross-PDS
1. In the sidebar under Account B, perform a pull-to-refresh or trigger reload.
2. Verify `drive-s1` appears in Account B's spaces list with a purple icon and "Shared" badge.
3. Click `drive-s1` under Account B.
- **Expected Observation:** Space Detail shows "Shared Space", authority DID of Account A, and lists Account A's writer repo.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.5: Account B Verifies Account A's Repo (SwanSpaces CAR + LtHash)
1. In Account B's view of `drive-s1`, locate Account A's repo row under "Writer Repositories".
2. Click the **"Verify"** button next to Account A's repo entry.
3. Observe progress spinner while CAR is fetched via `SpaceCredentialManager` and verified via `SwanSpaces`.
- **Expected Observation:** Green badge **"Verified (1 record)"** appears next to the repo entry.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 2: Alpha Account Creates S2, Adds Swan Account, Cross-PDS Read & Verify

### Step 2.1: Create Space S2 on Account B
1. In the sidebar under Account B, click the **"+" (New Space)** icon.
2. In the sheet:
   - Space Type: `space.swan.drive`
   - Space Key: `alpha-s2`
   - Policy: **"Member List Policy"**
3. Click **"Create Space"**.
- **Expected Observation:** `alpha-s2` appears under Account B as an Owned Space.
- **Result:** Pass [ ] / Fail [ ]

### Step 2.2: Account B Adds Account A to S2
1. In Space Detail for `alpha-s2`, click **"Add Member…"** in Members section.
2. Enter Account A handle/DID and submit.
- **Expected Observation:** Account A DID appears in the Members list.
- **Result:** Pass [ ] / Fail [ ]

### Step 2.3: Account B Writes Record to S2
1. In Space Detail for `alpha-s2`, click **"New Record"**.
2. Enter Collection `space.swan.drive.file`, rkey `alpha-doc`, JSON `{"text": "Alpha PDS payload"}`.
3. Click **"Save Record"**.
- **Expected Observation:** Record saved; Account B's repo entry appears under Writer Repositories.
- **Result:** Pass [ ] / Fail [ ]

### Step 2.4: Account A Reads Cross-PDS from Alpha Space S2 & Verifies
1. In sidebar under Account A, refresh spaces.
2. Click `alpha-s2` (marked Shared).
3. Click **"Verify"** on Account B's writer repo.
- **Expected Observation:** Space credentials exchanged across PDS; CAR verified; green **"Verified"** badge displayed.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 3: Side-by-Side Live Collaboration & Manual Refresh

### Step 3.1: Account A Writes Second Record to Shared Space S1
1. Select `drive-s1` under Account A.
2. Click **"New Record"** → Collection `space.swan.drive.file`, rkey `doc-2`, value `{"title": "Second record"}`.
3. Click **"Save Record"**.
- **Expected Observation:** Record `doc-2` appears in Account A's record table.
- **Result:** Pass [ ] / Fail [ ]

### Step 3.2: Account B Refreshes Shared Space S1 View
1. Select `drive-s1` under Account B.
2. Select Account A's repo row.
3. Trigger manual refresh (Cmd+R or pull-to-refresh).
- **Expected Observation:** Record table updates immediately to display both `doc-1` and `doc-2`. Selecting `doc-2` displays its JSON in the inspector pane.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 4: Delete Space & Tombstone UI Propagation

### Step 4.1: Account A Deletes Space S1
1. Select `drive-s1` under Account A.
2. In the Space Detail header, click the `…` menu (or right-click `drive-s1` in sidebar).
3. Select **"Delete Space…"**.
4. Confirm deletion in the confirmation dialog.
- **Expected Observation:** Space `drive-s1` is removed from Account A's sidebar; detail view resets to empty selection state.
- **Result:** Pass [ ] / Fail [ ]

### Step 4.2: Account B Observes Tombstone State
1. Under Account B, select the previously cached `drive-s1` row (or refresh Account B spaces).
2. Detail view attempts credential renewal/repo reload against the space authority.
- **Expected Observation:** SpaceDetailView renders the Tombstone UI: "Space Deleted" with trash icon and description "This space has been deleted by its authority." No crash or uncaught error.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 5: Interactive Blob Upload, QuickLook & NSSavePanel Download (Controller Live Check)

### Step 5.1: Upload Blob Attachment in Record Editor
1. Under Account B, open `alpha-s2` and click **"New Record"**.
2. In Record Editor, set Collection to `space.swan.drive.file` and rkey to `blob-doc`.
3. Click **"Upload Blob & Insert Reference…"**.
4. In the open panel, choose any image or text file (e.g. a sample `.png` or `.txt`).
5. Observe blob uploads via XRPC `com.atproto.repo.uploadBlob` and inserts canonical `$type: "blob"` JSON reference at the cursor position.
6. Click **"Save Record"**.
- **Expected Observation:** Record saved; Record Inspector displays "Blob References (1)" with CID, MIME type, and size.
- **Result:** Pass [ ] / Fail [ ]

### Step 5.2: Blob QuickLook Preview
1. In Record Inspector, click the **"QuickLook"** button next to the blob entry (or right-click → "QuickLook Blob").
- **Expected Observation:** Native macOS QuickLook preview window displays the blob contents.
- **Result:** Pass [ ] / Fail [ ]

### Step 5.3: Interactive NSSavePanel Download (Security-Scoped Powerbox)
1. In Record Inspector, click the **"Download…"** button next to the blob entry (or right-click → "Download Blob…").
2. In the native macOS `NSSavePanel`, navigate to an arbitrary folder outside the sandbox (e.g. `~/Downloads` or `~/Desktop`).
3. Click **"Save"**.
- **Expected Observation:** File is saved to the chosen path with proper extension. Verify file size and contents match the uploaded original.
- **Result:** Pass [ ] / Fail [ ]

---

## Smoke Test Summary

| Checklist Section | Status | Notes |
|---|---|---|
| Part 0: Live OAuth (CAB + Public Client) | [ ] PASS / [ ] FAIL | |
| Scenario 1: Swan → Alpha Cross-PDS Read & Verify | [ ] PASS / [ ] FAIL | |
| Scenario 2: Alpha → Swan Cross-PDS Read & Verify | [ ] PASS / [ ] FAIL | |
| Scenario 3: Shared Space Side-by-Side Refresh | [ ] PASS / [ ] FAIL | |
| Scenario 4: Delete Space & Tombstone UI | [ ] PASS / [ ] FAIL | |
| Scenario 5: Blob Upload, QuickLook & NSSavePanel | [ ] PASS / [ ] FAIL | |

**Tester Name:** ________________________  
**Date Executed:** ________________________  
**Build Commit SHA:** ____________________  
