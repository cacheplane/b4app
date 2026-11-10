# macOS Recovery Smoke Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exercise archived-session recovery through the shipped macOS UI and real isolated coordinator in CI.

**Architecture:** XCUITest launches a test-only fixture host and UI app as separate processes. The host owns an ephemeral PostgreSQL cluster and real coordinator; the app mounts `WorkspaceRootView` and connects over its explicit fixture socket. The existing fake provider refuses resume, so UI error handling follows production commands and events.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest/XCUITest, XcodeGen, PostgreSQL fixture infrastructure, shell runner, GitHub Actions.

## Task 1: Build the isolated fixture boundary

Files: create `Tests/macOSSmoke/project.yml`, `Tests/macOSSmoke/Host/main.swift`, `Tests/macOSSmoke/Harness/SmokeApp.swift`, and `Tests/macOSSmoke/UITests/RecoverySmokeTests.swift`.

- [ ] Write the journey test first: launch a fresh host, open the seeded chat, assert initial draft and cached transcript, click Send once, assert the archived recovery card.
- [ ] Host uses `EphemeralPostgres.paths`, a seeded `AccountRegistry`, `MemorySecretStore`, and `Coordinator.start`. Seed a connection to the existing fake executable and a thread with native id `thr_archived`; expose only socket configuration and fixture ids in a scratch manifest. Handle SIGTERM by closing coordinator before normal process exit.
- [ ] Harness requires an explicit fixture socket, uses `InMemoryPreferences`, and mounts the real `WorkspaceRootView` at the same minimum size as the shipping app. Graceful quit persists the draft. Missing configuration displays a fixture setup error and never starts a normal coordinator.
- [ ] UI runner launches host from the build products, waits for its ready manifest with a deadline, launches harness, and reads thread/draft via `WorkspaceClient` + `UnixSocketTransport`. Register teardown immediately after host launch.
- [ ] Generate with `xcodegen generate --spec Tests/macOSSmoke/project.yml --project .build/macOSSmoke`; run targeted XCUITest, fix build/setup errors until the actual interaction executes.

## Task 2: Assert the recovery contract and rendering

Files: modify journey test; create `Tests/macOSSmoke/UITests/RecoveryAssertions.swift` and `Tests/macOSSmoke/Harness/RecoveryReference.swift`; modify only accessibility identifiers in `Sources/WorkspaceUI/ThreadErrorNotice.swift`.

- [ ] Assert primary message/Details identifiers; run and observe missing-element failure before adding identifiers.
- [ ] Add stable identifiers to primary recovery message, Details, diagnostics, and Dismiss; retain production behavior.
- [ ] Expand/collapse/re-expand Details, assert one notice and absent continuity banner, action and Dismiss alignment, diagnostics cap, and visible composer.
- [ ] Render an unconstrained reference in the fixture harness using the same public LLA font and primary text's measured content width. Compare rendered danger-text line extent with the captured real notice, not just accessibility text. Keep reference presentation outside the recovery screenshot and restore the workspace before further interaction.
- [ ] Assert one failed terminal turn without native id and draft equality using protocol reads; invoke Check again and repeat state assertions.
- [ ] Quit UI gracefully, relaunch against the existing host, select thread, assert draft loaded and turn count unchanged.
- [ ] Run four variants: 900×600 and 1200×800, each light and dark. Attach window screenshots, accessibility and state diagnostics, including failure teardown.
- [ ] Negative control: save production files to a temporary backup, temporarily remove message and controls layout priorities, run the constrained expanded test, verify failure specifically identifies clipped text; restore files even if the command fails. Run positive suite again.

## Task 3: Runner and CI

Files: create `Scripts/test-macos-smoke.sh`, `Tests/macOSSmoke/README.md`; modify `.github/workflows/ci.yml`, `README.md`, `docs/milestones.md`; create a dated verification record.

- [ ] Follow `test-ios-layout.sh` conventions: generate project, serial macOS test invocation, configurable results/derived-data paths, forwarded xcodebuild arguments, and summary validation requiring passed nonzero tests.
- [ ] Add independent CI job with Xcode/XcodeGen setup, SwiftPM cache, pinned PostgreSQL fetch and macOS smoke invocation. Always upload result bundles; add shell runner to lint.
- [ ] Document command, fixture boundary, requirements, assertions and remaining packaged/live gates. Record actual positive and negative test evidence, plus any local UI automation permission prerequisite.
- [ ] Run focused smoke suite, existing recovery suites, `swift build`, `swift test`, strict formatting, shell lint, `Scripts/docs-index.sh --check`, and `git diff --check`.
- [ ] Review final changes and commit passing implementation. Allocate a material decision number only when opening a PR if a new decision is needed; this change otherwise implements D-190's verification.
