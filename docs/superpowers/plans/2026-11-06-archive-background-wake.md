# Archive Background Wake Implementation Plan

> Execute inline with test-first changes and independent document and code review. The owner has authorized the PR, merge on green and production TestFlight release.

**Goal:** Wake the phone after Mac archive/unarchive updates so the App Group mirror and widget can catch up.

**Architecture:** Add a silent refresh message to the existing transaction-owned hub push decision and post-commit sender. Reuse the current iOS end-of-feed refresh; no new account, sync loop or migration.

**Tech Stack:** Rust, SQLx/PostgreSQL, APNs HTTP/2, Swift Testing, WidgetKit.

## 1. Baseline and regression

- [x] Preserve prior device evidence and branch from current main in this isolated worktree.
- [x] Run `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --test push --locked` and confirm the existing push baseline (29 passed).
- [ ] In `Hub/crates/b4hub/tests/push.rs`, add an archive-only route test using the existing recording sender and real test database. Expect one background message after commit for a quiet thread. Run its exact filter and observe the missing-delivery assertion fail before implementation.

## 2. Transaction and delivery

- [ ] In `b4hub-db/src/changes.rs`, collect winning applied update operations for column `threads.archived`, including false. Add refreshes to `PushOutcome` after `push::decide`, inside the same transaction.
- [ ] In `b4hub-db/src/push.rs`, add a token-redacting `Refresh` recipient and a selector reusing `phones` with uploader excluded; omit devices already covered by that batch's alerts or withdrawals.
- [ ] In `b4hub-core/src/push.rs`, add pure refresh and spool payload builders. In `b4hub/src/push.rs`, add `Message::Refresh` and update all message accessors, spool and APNs encoding, background headers/lifetime and the constant collapse id. In `routes/changes.rs`, send refreshes after commit alongside other messages.
- [ ] Run the failing route test again and confirm its expected recipient/message. Add PostgreSQL regression cases for both archive values, bulk coalescing, duplicate sequence, refused/losing writes, unrelated edits, uploader exclusion, session/revocation/user isolation, and alert/withdrawal overlap. Verify payload/spool and fake-APNs background headers in `b4hub/tests/push.rs`.

## 3. Shared contract and phone mirror

- [ ] Add a `refreshes` entry to `Tests/Fixtures/sync/push.json`, test its exact payload in the Rust core fixture test, and extend `Tests/WorkspaceProtocolTests/ThreadLinkTests.swift` to confirm no thread navigation, reason, key or withdrawals. The iOS delegate already refreshes unconditionally; no new handler is required.
- [ ] Exercise a file-backed `MirrorGlance` before and after a synced archive update, proving the archived row disappears. Run `swift test --filter 'ThreadLinkTests|Glance'` and inspect results.

## 4. Verification and documentation

- [ ] Run `swift build`, `swift test`, strict recursive Swift format lint, both native builds, and full `cargo test --workspace --locked`, `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`. Run one cargo test per checkout at a time; stop this worktree's test cluster when done.
- [ ] Update `Hub/API.md`, compatibility, milestones and a new verification record with red/green evidence and explicit pending device retest. Include the existing device-results documents. Allocate a new decision with `Scripts/docs-index.sh --next` when opening the PR; do not edit old decisions. Reserve a fresh chart version for the hub release if the current version is already published.
- [ ] Run `Scripts/docs-index.sh --check` and `git diff --check`. Obtain independent code review; resolve material findings before committing and opening the PR.

## 5. Merge and release

- [ ] Open the PR with the final scope and actual validation, wait for every required CI check, resolve any failures, and merge on green. Verify the exact merge tree and clean release checkout.
- [ ] Wait for the merge's attested hub image and test deployment. Deploy that immutable digest to production with the existing GitHub production workflow and verify readiness; do not bypass environment approval. A manual digest deployment avoids creating an unrelated release if no new chart is needed.
- [ ] Upload a new production TestFlight build with `Scripts/upload-ios.sh` and the existing protected signing helper. If the known local Clang probe I/O adapter is necessary, revalidate the exact installed-SDK query and keep it process-local, preserving compiler output and source/signing configuration.
- [ ] Verify Apple `VALID` and `IN_BETA_TESTING`, report the build and production hub state, and give the owner the archive-from-Mac retest procedure. Do not describe fixture results as a physical-device pass.
