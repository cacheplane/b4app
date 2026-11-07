# Recovery text compression implementation plan

> **For agentic workers:** Use the existing approved thread-recovery design and execute the steps inline. Request independent plan and code review before merging.

**Goal:** Keep the recovery instructions readable when Details is expanded in a constrained macOS thread view.

**Architecture:** Preserve the existing single notice, bounded diagnostic scroll region, and aligned action row. Protect the message within the card and prioritize the controls container where it competes with the flexible transcript. Use that same container in the regression; avoid unbounded intrinsic heights or a new scrolling notice.

**Tech Stack:** SwiftUI, AppKit hosting/layout inspection, Swift Testing.

## Task 1: Reproduce the installed layout

Files: `Tests/WorkspaceUITests/RecoveryNoticeTests.swift` (or a focused companion file).

- [x] Host the production notice in a constrained vertical layout with expanded Details, using the archived-response shape and widths matching the live view.
- [x] Measure the rendered primary message, including a multiline reference; make the regression fail when it is reduced to one truncated line.
- [x] Run the regression against unchanged production code and confirm the expected failure.

## Task 2: Correct height allocation

Files: `Sources/WorkspaceUI/ThreadErrorNotice.swift`, `Sources/WorkspaceUI/ThreadsView.swift`.

- [x] Apply the smallest layout change that gives primary instructions their required height before flexible diagnostics consume the remaining space.
- [x] Keep diagnostics selectable and capped at the existing token. Keep recovery and Dismiss controls together and preserve bounded split-view minimum sizing.
- [x] Run the new regression plus existing notice, remediation, and detail-minimum-size tests; inspect expanded/collapsed narrow and normal fixture renders.
- [x] Explicitly mount an expanded recovery notice in minimum-size checks, including an arbitrary long fallback primary message, since existing detail variants do not include this notice.

## Task 3: Verify and integrate

Files: `docs/verification/2026-11-06-recovery-text-compression.md`, `docs/milestones.md`.

- [x] Run source build/tests, strict Swift formatting, whitespace and docs checks; distinguish fixture results from installed-app observations.
- [x] Request independent review and resolve important findings.
- [ ] Open a PR with the concrete defect and verification evidence; merge automatically only after required CI passes, as authorized by the owner.

The owner approved the recovery presentation earlier and requested this targeted correction after live verification showed the expanded card truncating its primary sentence. No runtime submission or account behavior changes are planned.
