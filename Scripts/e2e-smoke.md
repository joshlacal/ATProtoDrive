# ATProtoDrive End-to-End Interop Smoke Checklist

This checklist provides a manual, step-by-step verification script for human execution against live ATProto PDS environments (specifically `swan.place` and the hosted Bluesky permissioned data spaces alpha PDS).

---

## Preamble & Environment Notice

> **⚠️ Alpha PDS Reset & Lexicon Re-vendoring Notice:**
> The Bluesky Spaces Alpha PDS is updated and reset weekly on Thursdays. If schema or lexicon breaking changes occur upstream:
> 1. Resolve the latest commit SHA on the `permissioned-data` branch of `bluesky-social/atproto` (e.g. `git rev-parse HEAD` or via GitHub).
> 2. Run `Petrel/Scripts/vendor-space-lexicons.sh <COMMIT_SHA>` using that explicit commit SHA (never a branch name, preserving the pinned-SHA contract).
> 3. Run `Petrel/Scripts/regenerate-generated.sh` in the Petrel directory.
> 4. Verify the test suite passes with `xcodebuild test -project ATProtoDrive/ATProtoDrive.xcodeproj -scheme ATProtoDrive -destination 'platform=macOS' -only-testing:ATProtoDriveTests`.

### Prerequisites
- macOS 15+ Sequoia workstation with `ATProtoDrive.app` built.
- **Account A (Swan PDS):** e.g. `alice.swan.place` (authenticates via CAB at `https://cab.swan.place`).
- **Account B (Hosted Spaces Alpha PDS):** A test account registered on the hosted Spaces Alpha PDS (e.g. `bob.test` or alpha PDS endpoint).
  *Note:* The hosted Spaces Alpha PDS is an isolated alpha environment; standard production `bsky.social` accounts do not support permissioned data spaces. To obtain an alpha account, follow the instructions in the [ATProto Spaces Alpha Announcement](https://atproto.com/blog/atproto-spaces-alpha) or the BPS account portal to obtain an invite code and connect to the hosted alpha PDS endpoint.
- Network access to `https://cab.swan.place` and both PDS hosts.

---

## Part 0: Live OAuth Login & Persistence

### Step 0.1: Login Account A (swan.place via CAB)
1. Launch `ATProtoDrive.app`.
2. Observe empty state: "No Accounts" with description "Add an ATProto account to browse Spaces."
3. Click the **"Add Account"** button.
4. Enter Account A handle (e.g. `alice.swan.place`) and click **"Log In"** (or press Return).
5. Default browser opens to the authorization consent page on `swan.place`.
6. Inspect the browser URL query string:
   - **Assertion:** URL contains `client_id=https%3A%2F%2Fcab.swan.place%2Foauth-client-metadata.json`.
7. Inspect the browser consent UI:
   - **Assertion:** Consent page displays requested scope `atproto space:*?authority=*` (wildcard authority warning).
8. Authorize the application.
9. Browser redirects to `blue.catbird.atprotodrive:/callback?...`.
10. Observe ATProtoDrive dismisses the sheet and displays Account A under the "Spaces" sidebar section.
- **Result:** Pass [ ] / Fail [ ]

### Step 0.2: Login Account B (Alpha PDS via Public Client Fallback)
1. Click the **"+" (Add Account)** button in the sidebar navigation bar.
2. Enter Account B handle (e.g. `bob.test` on alpha PDS) and click **"Log In"**.
3. Observe app attempts CAB flow, receives native client rejection from the PDS, automatically falls back to Public OAuth client, and opens browser authorization URL.
4. Inspect the browser URL query string:
   - **Assertion:** URL contains `client_id=https%3A%2F%2Fcab.swan.place%2Fpublic-client-metadata.json`.
5. Inspect the browser consent UI:
   - **Assertion:** Consent page displays requested scope `atproto space:*?authority=*`.
6. Complete authorization in browser.
7. Browser redirects to `blue.catbird.atprotodrive:/callback?...`.
8. Observe ATProtoDrive matches OAuth state and displays Account B in the sidebar.
- **Result:** Pass [ ] / Fail [ ]

### Step 0.3: Session Persistence across App Relaunch
1. Quit ATProtoDrive completely (`Cmd+Q`).
2. Relaunch `ATProtoDrive.app`.
3. Inspect sidebar without performing any manual login.
- **Expected Observation:** Both Account A (`alice.swan.place`) and Account B (`bob.test`) are automatically restored from persistence in the sidebar with their respective handles and DIDs.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 1: Swan Account Creates S1, Adds Alpha Account, Cross-PDS Open, Read & Verify

### Step 1.1: Create Space S1 on Account A
1. In the sidebar under Account A, click the **"+"** menu in the section header and select **"New Space…"**.
2. In the "Create New Space" sheet:
   - Space Type: `space.swan.drive`
   - Space Key (skey): `drive-s1`
   - Policy: Select **"Member List Policy"**
3. Click **"Create Space"**.
- **Expected Observation:** Sheet dismisses; `drive-s1` appears under Account A with a blue icon. Selecting `drive-s1` displays Space Details with header "Owned Space", skey `drive-s1`, and authority matching Account A DID.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.2: Add Account B as Member to S1
1. In Space Detail for `drive-s1`, scroll to the **"Members"** section.
2. Click **"Add Member"**.
3. In the "Add Member to Space" sheet, enter Account B's handle or DID.
4. Click **"Add Member"**.
- **Expected Observation:** Sheet dismisses; Account B's DID appears in the Members list.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.3: Account A Creates Record in S1
1. In Space Detail toolbar for `drive-s1`, click **"New Record"**.
2. In Record Editor sheet:
   - Collection: `space.swan.drive.file`
   - Record Key (rkey): `doc-1`
   - JSON Value: `{"title": "Hello from Swan", "createdAt": "2026-08-21T12:00:00Z"}`
3. Click **"Format JSON"** to verify JSON pretty-printing.
4. Click **"Create Record"**.
- **Expected Observation:** Record saved; Account A appears under **"Writer Repos"**. Selecting Account A's repo navigates to Record Table displaying `doc-1`.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.4: Account B Opens Space S1 by Reference
1. In the sidebar under Account B, click the **"+"** menu in the header and select **"Open Space by Reference…"**.
2. In the "Open Space by Reference" sheet, enter the full space URI:
   `at://<ACCOUNT_A_DID>/space/space.swan.drive/drive-s1`
3. Click **"Open Space"**.
- **Expected Observation:** Sheet dismisses; `drive-s1` appears in Account B's spaces list with a purple icon and "Shared" badge. Selecting it displays "Shared Space" with Account A as the Authority.
- **Result:** Pass [ ] / Fail [ ]

### Step 1.5: Account B Reads Cross-PDS and Verifies Account A's Repo
1. Under Account B's view of `drive-s1`, locate Account A's entry under **"Writer Repos"**.
2. Click the **"Verify"** button next to Account A's repo entry.
3. Observe progress spinner while CAR is fetched via `SpaceCredentialManager` and verified via `SwanSpaces`.
- **Expected Observation:** Green badge **"Verified (1 recs)"** appears next to the repo entry.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 2: Alpha Account Creates S2, Adds Swan Account, Cross-PDS Open, Read & Verify

### Step 2.1: Create Space S2 on Account B
1. In the sidebar under Account B, click **"+"** → **"New Space…"**.
2. In the sheet:
   - Space Type: `space.swan.drive`
   - Space Key: `alpha-s2`
   - Policy: **"Member List Policy"**
3. Click **"Create Space"**.
- **Expected Observation:** `alpha-s2` appears under Account B marked as "Owned Space".
- **Result:** Pass [ ] / Fail [ ]

### Step 2.2: Account B Adds Account A to S2
1. In Space Detail for `alpha-s2`, click **"Add Member"**.
2. Enter Account A handle/DID and click **"Add Member"**.
- **Expected Observation:** Account A DID appears in the Members list.
- **Result:** Pass [ ] / Fail [ ]

### Step 2.3: Account B Writes Record to S2
1. In Space Detail for `alpha-s2`, click **"New Record"**.
2. Collection: `space.swan.drive.file`, rkey: `alpha-doc`, JSON: `{"text": "Alpha PDS payload"}`.
3. Click **"Create Record"**.
- **Expected Observation:** Record saved; Account B appears under **"Writer Repos"**.
- **Result:** Pass [ ] / Fail [ ]

### Step 2.4: Account A Opens Space S2 by Reference & Verifies
1. In sidebar under Account A, click **"+"** → **"Open Space by Reference…"**.
2. Enter `at://<ACCOUNT_B_DID>/space/space.swan.drive/alpha-s2` and click **"Open Space"**.
3. Select `alpha-s2` (marked Shared).
4. Under **"Writer Repos"**, click **"Verify"** next to Account B's repo.
- **Expected Observation:** CAR verified via `SwanSpaces`; green badge **"Verified (1 recs)"** appears.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 3: Real Side-by-Side Collaboration via Dual Windows

### Step 3.1: Open Second Window
1. Press **Cmd+N** (or select **File > New Window**).
2. Position Window 1 on the left half of the screen and Window 2 on the right half.
3. In Window 1, select Account A → `drive-s1` → Account A's writer repo.
4. In Window 2, select Account B → `drive-s1` (Shared) → Account A's writer repo.
- **Expected Observation:** Both windows display the records table for `drive-s1` simultaneously side-by-side without crosstalk.
- **Result:** Pass [ ] / Fail [ ]

### Step 3.2: Account A Writes Second Record in Window 1
1. In Window 1 (Account A), click **"New Record"**.
2. Collection: `space.swan.drive.file`, rkey: `doc-2`, JSON: `{"title": "Second record"}`.
3. Click **"Create Record"**.
- **Expected Observation:** Record `doc-2` appears immediately in Window 1's record table.
- **Result:** Pass [ ] / Fail [ ]

### Step 3.3: Account B Manually Refreshes in Window 2
1. In Window 2 (Account B), trigger manual refresh via the view's `.refreshable` gesture (pull/swipe down on the records list view).
- **Expected Observation:** Window 2 reloads records from the space and updates to show both `doc-1` and `doc-2`. Selecting `doc-2` renders its pretty-printed JSON in the inspector pane.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 4: Blob Upload, QuickLook & Interactive NSSavePanel Download

### Step 4.1: Upload Blob in Record Editor
1. Under Account B in `alpha-s2`, click **"New Record"**.
2. Collection: `space.swan.drive.file`, rkey: `blob-doc`.
3. In JSON Editor, enter syntactically valid JSON containing a placeholder for the blob:
   ```json
   {
     "description": "Blob test document",
     "attachment": null
   }
   ```
4. In the JSON Editor, highlight/select the word `null` in `"attachment": null`.
5. Click **"Upload Blob…"**.
6. In the file open sheet, select a sample image or text file (e.g. `sample.png` or `test.txt`).
7. Observe blob uploads via `com.atproto.repo.uploadBlob` and `spliceBlobRef` replaces `null` with the canonical `$type: "blob"` structure.
8. Click **"Create Record"**.
- **Expected Observation:** Record saved; selecting `blob-doc` in the record table displays the record in `RecordInspectorView`.
- **Result:** Pass [ ] / Fail [ ]

### Step 4.2: Inspect Blob References & QuickLook Preview
1. In `RecordInspectorView`, locate the **"Blob References (1)"** section.
2. Verify the section displays the blob **CID** and **MIME type**.
3. Click the **"Quick Look"** (eye) button next to the blob entry (or right-click → "Quick Look").
- **Expected Observation:** Native macOS QuickLook preview window opens and renders the blob contents.
- **Result:** Pass [ ] / Fail [ ]

### Step 4.3: Interactive NSSavePanel Download (Powerbox Security-Scoped Access)
1. In `RecordInspectorView`, click the **"Download…"** (arrow down) button next to the blob entry.
2. In the native macOS `NSSavePanel`, navigate to an external folder outside the app container (e.g. `~/Downloads` or `~/Desktop`).
3. Click **"Save"**.
- **Expected Observation:** File is downloaded and saved to the selected path. Open the file in Finder to verify file size and contents match the uploaded original.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 5: Full Record Lifecycle CRUD (Task 10 Verification)

### Step 5.1: Create Record
1. Under Account A in `drive-s1`, click **"New Record"**.
2. Collection: `space.swan.drive.file`, rkey: `crud-lifecycle`, JSON: `{"step": "created", "version": 1}`.
3. Click **"Create Record"**.
- **Expected Observation:** `crud-lifecycle` appears in the table with initial CID.
- **Result:** Pass [ ] / Fail [ ]

### Step 5.2: Edit Record (PutRecord)
1. Select `crud-lifecycle` in the table.
2. Click the **"Edit Record"** button in the window toolbar.
3. In Record Editor, update JSON to `{"step": "edited", "version": 2}`.
4. Click **"Save Changes"**.
- **Expected Observation:** Table reloads; inspector displays updated JSON and a new CID.
- **Result:** Pass [ ] / Fail [ ]

### Step 5.3: Delete Record
1. Right-click `crud-lifecycle` in the table.
2. Select **"Delete Record"** (no ellipsis).
3. In confirmation dialog, observe destructive confirmation button is labeled **"Delete crud-lifecycle"**.
4. Click **"Delete crud-lifecycle"**.
- **Expected Observation:** Record `crud-lifecycle` is removed from the table and inspector resets to "No Record Selected".
- **Result:** Pass [ ] / Fail [ ]

### Step 5.4: Recreate Record with Same RKey
1. Click **"New Record"**.
2. Collection: `space.swan.drive.file`, rkey: `crud-lifecycle`, JSON: `{"step": "recreated", "version": 3}`.
3. Click **"Create Record"**.
- **Expected Observation:** Record is created successfully under the recycled rkey with a new CID.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 6: Context Menus & Pasteboard Verification (Task 11 Verification)

### Step 6.1: Space Row Context Menu
1. Right-click any space row in the sidebar.
2. Select **"Copy Space Ref"**.
3. Paste into TextEdit or Terminal.
- **Expected Observation:** Clipboard contains exact string `at://{authorityDID}/space/{spaceType}/{skey}`.
- **Result:** Pass [ ] / Fail [ ]

### Step 6.2: Record Row Context Menu
1. Right-click a record row in Record Table:
   - Select **"Copy at:// URI"** → paste into TextEdit → verify clipboard contains `at://{spaceDID}/space/{type}/{skey}/{authorDID}/{collection}/{rkey}`.
   - Select **"Copy CID"** → paste into TextEdit → verify clipboard contains the record CID.
   - Select **"Copy JSON"** → paste into TextEdit → verify clipboard contains formatted JSON.
- **Expected Observation:** All three pasteboard copy actions output accurate values matching the exact menu item labels.
- **Result:** Pass [ ] / Fail [ ]

### Step 6.3: Record Inspector Context Menus
1. In `RecordInspectorView`:
   - Right-click the URI row → select **"Copy at:// URI"** → verify clipboard.
   - Right-click the CID row → select **"Copy CID"** → verify clipboard.
   - Right-click a blob row → select **"Copy CID"** → verify clipboard.
- **Expected Observation:** All inspector context menu copy actions function correctly.
- **Result:** Pass [ ] / Fail [ ]

---

## Scenario 7: Delete Space, Force Credential Renewal & Tombstone UI

### Step 7.1: Account A Deletes Space S1
1. In Window 1 (Account A), select `drive-s1`.
2. In the Space Detail header, click the **"…"** (ellipsis) menu button.
   *(Note: Space deletion is located exclusively in the detail header ellipsis menu, not the sidebar context menu).*
3. Select **"Delete Space…"**.
4. In the confirmation dialog, click **"Delete Space"**.
- **Expected Observation:** Space `drive-s1` is removed from Account A's sidebar and details reset to "No Space Selected".
- **Result:** Pass [ ] / Fail [ ]

### Step 7.2: Force Credential Renewal & Observe Tombstone on Account B
1. Space credentials are cached locally for up to 2 hours. To force credential renewal against the authority:
   - Quit `ATProtoDrive` (`Cmd+Q`) and relaunch, or wait for the credential cache to expire.
2. Under Account B, select the persisted `drive-s1` space.
3. Account B attempts to reload space details and exchange space credentials with `swan.place`.
- **Expected Observation:** Space authority responds with `SpaceDeleted`. `SpaceDetailView` renders the Tombstone UI: **"Space Deleted"** title with trash icon (`trash.slash.fill`) and description "This space has been deleted by its authority." No uncaught exceptions or crashes.
- **Result:** Pass [ ] / Fail [ ]

---

## Smoke Test Summary

| Checklist Section | Status | Notes |
|---|---|---|
| Part 0: Live OAuth & Persistence | [ ] PASS / [ ] FAIL | |
| Scenario 1: Swan → Alpha Cross-PDS Read & Verify | [ ] PASS / [ ] FAIL | |
| Scenario 2: Alpha → Swan Cross-PDS Read & Verify | [ ] PASS / [ ] FAIL | |
| Scenario 3: Real Side-by-Side Dual Windows | [ ] PASS / [ ] FAIL | |
| Scenario 4: Blob Upload, QuickLook & NSSavePanel | [ ] PASS / [ ] FAIL | |
| Scenario 5: Full Record Lifecycle CRUD | [ ] PASS / [ ] FAIL | |
| Scenario 6: Context Menus & Pasteboard Verification | [ ] PASS / [ ] FAIL | |
| Scenario 7: Delete Space & Tombstone UI | [ ] PASS / [ ] FAIL | |

**Tester Name:** ________________________  
**Date:** _______________________________  
**Build Commit SHA:** ____________________  
