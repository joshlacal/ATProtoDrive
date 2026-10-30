# ATProtoDrive: October 29 Spaces alpha compatibility

ATProtoDrive is a local macOS client that creates, browses and manages AT Protocol Spaces through Petrel's generated types and Swan's archive verification. The October 29, 2026 alpha (atproto `5d88b414`) retires `com.atproto.simplespace`: space creation and deletion move to `com.atproto.space`, member-list methods move to `com.atproto.memberspace`, and `createSpace` takes a single `policy` union instead of separate read, write and app-access policies. This change updates the app's existing callers to those names and shapes. It adds no new Spaces features. It builds on the October 22 consumer work in [spaces-release-20261023.md](spaces-release-20261023.md); decisions are logged in [DECISIONS.md](DECISIONS.md).

## Changes

- `createSpace` and `deleteSpace` call `com.atproto.space.*`. The "Member List" option sends a memberspace policy with no flags, and "Public" sends memberspace with `publicRead` and `publicWrite`. App access stays open because `allowedApps` is omitted.
- `listMembers`, `putMember` and `removeMember` call `com.atproto.memberspace.*`. Their inputs and outputs are unchanged.
- A `PolicyMismatch` answer from `listMembers` (an own space governed by a personalspace or managedspace policy) leaves the member list empty and still shows the space's repositories.
- Credential refusals: Petrel's space credential manager already maps the new `SpaceNotFound` refusal to an authorization refusal, so the app's branching is unchanged. The detail view's headline now reads "not found, or you do not have access".

Not applicable here: serving `checkUserAccess`, reading another owner's `getSpace`, keeping a synchronized copy, and repository-host duties. The app does none of these.

## Verification

The full ATProtoDrive test suite was run on macOS (October 30, 2026) against the regenerated sibling Petrel and the sibling Swan: 249 tests in 22 suites passed, and the two live tests were skipped. New or rewritten cases cover the memberspace policy mapping and its wire `$type`, `PolicyMismatch` tolerance (typed and generic) including a load that keeps its repositories, and a `SpaceNotFound` credential refusal classified as an authorization refusal. No live server, account or app-level Spaces flow was exercised.
