## 2026-11-04: iPhone sync recovery and navigation

### Owner's physical iPhone, prod TestFlight build 2611050013

The owner installed the build and reported checks 1 through 4 good: existing account and history, a message from the phone reaching the Mac, live response streaming, and background catch-up followed by another send.

Check 5 (phone network loss and recovery) exposed two bugs. The top "Not synced" banner covered navigation buttons, making Back difficult to tap. After Wi-Fi returned, the connection notice above the composer disappeared immediately, but the top sync banner took about a full minute to clear. Notification checks 6 through 8 and the optional Mac-offline check have not been reported for this build.

### Fix and reproduction

- The banner was an outer safe-area inset around `WorkspaceRootView`, outside its `NavigationSplitView`. An isolated iPhone 17 Pro Simulator preview, using the real shared shell, the real banner view, and an in-memory fixture mirror, reproduced the overlap. With the banner supplied through a view-only environment value and inset inside each navigation column, Back, the title, and the thread menu are fully visible above it. This is a visual layout check; the preview is not a live hub integration.
- Relay connectivity and mirror sync have separate retry loops. `MirrorHost` previously watched only terminal relay stops, so a successful relay connection did not wake mirror sync's backoff (up to 60 seconds). It now nudges the current account's sync when the current relay connects. A nudge cancels a pending backoff, including one whose failure callback is still running. A suspended sync stays parked.
- A recovery pull previously waited up to 25 more seconds for changes on a quiet hub. While a sync error is outstanding it now requests `wait=0`. The banner still clears only after a successful pull has been applied and its cursor saved.
- Three regression tests failed before the fix: nudging during failure reporting, nudging an existing retry wait, and recovering against an unchanged hub. The quiet-hub assertion also checks the requested wait directly, so scheduler load cannot be mistaken for a long-poll delay.

### Automated and Simulator verification

| Check | Result |
| --- | --- |
| `swift build` | Pass |
| `swift test` | Pass: 1,333 tests in 164 suites, 81.612 seconds, after rebasing onto `main` at `bdbe57a` |
| `MirrorSyncTests` | Pass: all 23; the three new recovery cases failed against the original implementation |
| iOS Simulator app build (`B4App-iOS`) | `BUILD SUCCEEDED` |
| `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| `Scripts/docs-index.sh --check`, `git diff --check` | Pass |
| Isolated Simulator layout preview | Original overlap reproduced; revised banner leaves navigation controls fully visible |
| Independent code review | No actionable findings |

The first full-suite attempt found this fresh checkout lacked its `.build/postgres` test binaries, despite an environment override, and the quiet-hub test's three-second wall-clock guard failed under full-suite load. The existing pinned PostgreSQL binaries were copied into this checkout; the quiet-hub test now asserts the request's `wait=0` directly and uses the suite's usual timeout guard. The subsequent complete suite passed. No production hub or account was modified.

The before/after Simulator screenshots are local, gitignored artifacts under `.build/verification/iphone-sync-recovery/`. The temporary preview app was removed from the Simulator after capture.

### Remaining live verification

The fixes are local source changes, not part of installed build 2611050013. Repeat the network-loss test on a build carrying them: while offline, navigate Back to the list and into a thread; restore connectivity and confirm the sync banner clears promptly after a successful sync. The physical iPhone fixes and notification checks remain open.
