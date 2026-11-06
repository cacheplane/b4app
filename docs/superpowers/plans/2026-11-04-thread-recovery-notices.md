# Thread recovery notices implementation plan

**Goal:** Correct archived-session diagnosis and show a single readable recovery notice with aligned controls.

**Architecture:** Preserve the existing adapter, coordinator continuity, and SwiftUI boundaries. Add a reason to the existing protocol error for archived sessions, and suppress transient notices only when persistent continuity already explains that same failure.

**Tech stack:** Swift, SwiftUI, Swift Testing, Python fixture app-server.

- [x] Add fixture responses and failing adapter tests in `Tests/CodexAdapterTests/{CodexAppServerTests.swift,Fixtures/fake-codex.py}` for archived, truly missing, and unrelated resume errors. Verify no refused resume submits a turn.
- [x] Narrow `Sources/CodexAdapter/CodexAdapter.swift` resume error mapping; preserve native diagnostics and archived recovery instructions. Run adapter regression tests.
- [x] Add failing remediation/presentation policy tests in `Tests/WorkspaceUITests/RemediationTests.swift`. Cover archived recovery, matching continuity deduplication, and unrelated error preservation.
- [x] Update `Sources/WorkspaceUI/{Remediation,ComposerView,ThreadsView}.swift`: one explanation per failure, separate wrapping action row, consistent pill controls, diagnostics behind disclosure when useful.
- [x] Render notices at narrow and normal widths in both appearances, verify minimum window sizing, and correct any wrapping/alignment problems.
- [x] Run `swift build`, `swift test`, strict Swift formatting, and `Scripts/docs-index.sh --check`. Record evidence in `docs/verification/`, update compatibility and milestones, and request code review.
- [x] Cover delayed archived refusals during navigation, deletion, and account changes; restore drafts only in their original context.

The owner approved the design and implementation, then requested installation and continuation of the remaining follow-ups. Complete the review branch and pull request in the existing isolated worktree; merging remains a separate step.
