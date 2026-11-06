# Widget Background Catch-up Implementation Plan

> Execute inline using the executing-plans workflow, with test-first changes and independent review.

**Goal:** Finish background catch-up before parking the mirror so later-page new threads can reach the widget.

**Architecture:** Keep the account-owned sync loop and App Group mirror. Replace first-batch completion with a bounded, generation-aware end-of-feed operation on MirrorSync and coalesce host wakes.

**Tech Stack:** Swift concurrency, SQLite mirror, Swift Testing, UIKit background notifications, WidgetKit.

- [x] Confirm existing mirror-sync baseline; preserve physical evidence and use a branch from current main.
- [x] In `Tests/WorkspaceMirrorTests/MirrorSyncRefreshTests.swift`, use a gated hub and file-backed mirror to prove a fresh approval beyond the first page is visible through `MirrorGlance` before a refresh completes and the caller parks sync. Establish executable red failure with the current first-batch behavior.
- [x] Extend `Sources/WorkspaceMirror/MirrorSync.swift`: register bounded refresh waiters; cancel an in-flight long poll; mark a fresh cycle; drain `more` pages immediately; finish only after the final page's batch is published; clean up waiters on timeout/cancellation/stop.
- [x] Cover empty feeds, pre-existing pulls, snapshot recovery, failure/timeout, cancellation and overlapping requests. Run `swift test --filter MirrorSync` and inspect outcomes.
- [x] Add and test a Foundation-only `MirrorRefreshCoordinator` with generation-aware repeats across late cleanup/park arrivals and an overall deadline. In `Apps/iOS/B4App/MirrorHost.swift`, coalesce background refresh work through it and await sync catch-up in place of batch waiters while retaining ordered resume/suspend and the existing time limits. Add safe background/timeline diagnostics in `AppDelegate.swift` and `Apps/iOSWidget/AttentionWidget.swift`.
- [x] Update the decision and verification logs, milestone and compatibility notes; keep physical H failure distinct from the fixture fix and I/H passes.
- [x] Run `swift build`, `swift test`, strict recursive Swift format lint, both native app builds, docs-index and diff checks. Request independent code review and resolve findings.
- [x] Open PR with a fresh decision number; wait for all required CI checks. Merge on green as authorized; fetch the exact merge commit and verify a clean release tree.
- [x] Run production `Scripts/upload-ios.sh` with a new UTC build number using the existing protected signing helper. Verify Apple reports VALID and IN_BETA_TESTING, then provide the owner the build and fresh-widget retest steps.
