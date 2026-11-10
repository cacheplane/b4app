# Real B4 UI Smoke Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development for independent Node-owner work and superpowers:executing-plans for the dependent Swift/UI integration. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the macOS smoke suite through real B4 routing, streaming/tool presentation and preserved draft/history during stopped-endpoint recovery.

**Architecture:** A test-only Node owner reuses `Tests/B4Runtime/runtime-fixture.mjs`, communicates over an ownership pipe plus atomic manifests, and owns the real B4/aimock servers. The real coordinator attaches to B4 and the shipped workspace UI handles every user action. Existing fake-runtime recovery cases stay intact.

**Tech Stack:** Existing XCUITest harness, real coordinator/PostgreSQL, Node 24, published B4 0.15.8 and aimock 1.47.0.

## Task 1: Node owner and its integration check

Files: `Tests/B4Runtime/runtime-fixture.mjs`, new `owner.mjs`, new `owner.test.mjs`, `fixtures/responses.json`, `package.json`.

- [x] Write the owner lifetime/control acceptance test before implementing the executable; observe its failure.
- [x] Allow fixture temp/artifact directories under a caller-owned private parent while preserving trial defaults.
- [x] Implement `owner.mjs /tmp/b4smk-*`: atomic `b4-runtime.json` responses with id/state/url/provider requests/tool calls. Accept only `stop`, `start`, `snapshot` commands with nonempty operation ids; EOF and SIGTERM close idempotently and report cleanup failures.
- [x] Add an explicit `smoke-ui-stream` response emitting the existing expected text over several seconds so the UI can observe a pending turn.
- [x] Verify stop/start reuse the endpoint, snapshot reports real journals, and closing stdin stops both listeners and preserves synthetic artifacts. Run the complete locked runtime suite.

## Task 2: Real-B4 mode in the Swift fixture host

Files: `Tests/macOSSmoke/Host/SmokeHost.swift`, new `Host/B4SmokeSeed.swift`, new `UITests/B4RuntimeOwner.swift`, `UITests/SmokeFixture.swift`, `project.yml`, `Scripts/test-macos-smoke.sh`.

- [x] Add a test-only build setting/environment for Node and the runtime-package path; the runner verifies Node 24 and installs the locked package.
- [x] Add Swift Node-owner startup/commands/EOF teardown with deadline polling, operation-id matching and loopback/private-path validation.
- [x] Add host `--b4` mode that validates the manifest, adds an attached B4 connection, creates a real thread and saves `smoke-ui-stream` as draft. Seed no fake B4 history or errors.
- [x] Extend `SmokeFixture` to retain Node ownership, thread id and manifests; preserve the existing fake-mode startup and owner-pipe case. Teardown app/host/runtime independently and retain evidence before root removal.

## Task 3: Actual UI journey and reusable assertions

Files: new `Tests/macOSSmoke/UITests/B4RuntimeSmokeTests.swift`, shared helpers in `RecoveryAssertions.swift` / new `SmokeUIAssertions.swift`, minimally adapt `RecoverySmokeTests.swift`.

- [x] Write the compact/light B4 journey first and run it to expose missing behavior.
- [x] Click streaming Send, observe partial text plus Stop and a running coordinator turn, and require terminal success.
- [x] Type/send the tool prompt, require the actual rendered step and one tool ledger entry, and validate native turn/message identities.
- [x] Type/persist the restart draft, stop B4 through the test owner and click Send. Verify one failure notice, expanded full instructions, aligned controls, retained draft/history and unchanged provider request count.
- [x] Restart B4 on the same endpoint; click Check again without automatic resend, then deliberate Send. Verify same native thread, completed continuation and no duplicate tool/provider requests; relaunch UI and verify history.
- [ ] Add wider/dark variant using the existing CI width override. Capture artifacts and verify the existing five smoke tests still pass.

## Task 4: Review, CI and merge

Files: `.github/workflows/ci.yml`, smoke/runtime READMEs, `docs/compatibility.md`, `docs/milestones.md`, trial plan progress and a new gate record.

- [x] Select pinned Node in the macOS job; keep fixture/runtime dependencies test-only. Record the real-UI/real-runtime/simulated-model boundary and retained artifacts.
- [ ] Run runtime tests, focused Swift checks/build, full package verification when host capacity permits, smoke matrix, native builds, strict format and workflow/docs/whitespace checks.
- [x] Obtain independent spec and code-quality reviews and fix important findings.
- [x] Merge PR #166 only with every CI check green; rebase this follow-up onto its merged main commit without duplicate first-stage changes.
- [ ] Open the second PR, monitor all checks, resolve failures and merge only on green. Preserve the active worktree and report both merged PRs with verified limits.

## Trial-exposed recovery defects

- [x] Reproduce local refused-send draft loss with failing model assertions for composer and persisted save; restore within the existing context/newer-text guards and run focused recovery tests.
- [x] Reproduce canonical B4 checkpoint-id duplication with a failing merge regression; carry optional native turn identity from B4 snapshots and reconcile matching completed live messages within that native turn only.
- [x] Verify repeated identical text in different turns and failed prepared attempts retain distinct app identities, and repeated reconciliation is idempotent.
- [ ] Re-run real UI recovery with canonical history ids, complete all seven smoke cases on clean CI and retain coordinator state even on early failure.
