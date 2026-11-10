## 2026-11-09: Real B4 workspace smoke promotion

This follows the successful real-runtime/model-fixture trial in PR #166, merged at `fa194c490cb246eda0ea1ac5c4e23a6951d0e21a` after all seven CI checks passed. The user authorized continuing into workspace UI coverage and fixes exposed by that trial.

### Boundary and coverage

The shipped workspace SwiftUI runs against a real isolated coordinator/PostgreSQL host and the published B4 0.15.8 runtime. aimock 1.47.0 supplies the model API. Two added journeys exercise compact/light and desktop/dark: visible partial text with Stop and a running turn, real tool execution, stopped-endpoint failure with one notice/full recovery text/aligned buttons, saved draft and cached history, Check again without sending, deliberate same-thread continuation, and UI relaunch. The four archived-session journeys and owner-pipe lifetime check remain in the default suite.

The Node owner controls only its own B4/aimock children. EOF/SIGTERM cleanup, startup cancellation, stop/start on the same endpoint, request/tool journals and retained diagnostics have integration coverage. Swift teardown attaches coordinator thread/draft state even when a UI assertion fails, then independently closes the client, host and runtime. No owner's app data, credentials, projects, servers or display settings are changed. This is fixture integration, not paid-model, managed-server Settings or signed-installation evidence.

### Product defects exposed

A private native-app run reproduced a refused B4 send clearing both the composer and stored draft while its turn was terminal, submission `prepared`, with no native turn id or model request. The local send handler restored only archived or unresolved attempts. A failing model regression observed empty composer and empty persisted save for both response/event states. The fix restores failed-command input within the existing account, selected/open-thread, deletion and newer-text guards. Tests cover both event orders and newer typing; restoration never resends.

A second private run confirmed the draft fix, full expanded recovery message, one actionable notice and aligned buttons. Stopping B4 left three provider requests and one real tool invocation. Check again after restart preserved the draft and sent nothing; a deliberate Send completed the same native conversation with four model requests and one tool invocation. It also exposed duplicated cached messages: streaming ids (`turn-N:mM`) differ from canonical checkpoint ids, and locally stored user items initially have no native id.

The history fix adds optional native turn identity to snapshot items. B4 tags message groups at HumanMessage boundaries, matching the published runtime's turn reconstruction and the adapter's existing ordinal. The merge first honors all exact native ids, then matches same role/type/nonempty text only within one unambiguous terminal acknowledged native turn. It preserves app row/turn identities and live payloads while adopting canonical checkpoint ids. Prepared/unknown/running/ambiguous turns receive no fallback, and tagged items cannot fall through to global text matching. Already-duplicated caches are not automatically deleted or rewritten.

### Local verification

- The locked Node package passed all 13 runtime/SSE/owner tests in 25.376 seconds in an independent run.
- Native `build-for-testing` passed after the real-runtime host, owner driver, UI journeys and shared assertions were added.
- Draft regression failed before the fix; all 21 focused model recovery/send tests passed afterward.
- Full Swift verification passed 1,475 tests in 185 suites in 93.273 seconds before the later history-identity change. A fresh full run is required for that change.
- `swift build` passed in 16.60 seconds before the history change. Strict formatting passed at that point.
- The first two local XCUITest runs failed before any test began: the UI runner timed out enabling automation mode. One overlapped another worktree's UI run. Developer mode was observed disabled; no global security setting was changed. These failures are not counted as passing UI evidence. A third run after that competing runner ended built successfully and failed at the same automation-mode initialization, before any journey executed. Clean CI must supply UI execution evidence.
- The storage regression reproduced duplicate rows before the history fix. All 19 targeted history/translation tests in three suites passed in 80.101 seconds, including seven identity rejection scenarios. An incremental full-suite run after the public snapshot layout changed reported inconsistent fields in an unrelated adapter test and exited unsuccessfully; all Swift artifacts are being rebuilt from clean state before repeating the full gate.

### CI gate

The follow-up PR must pass the dedicated B4 runtime job, full Swift package tests, native builds, iOS navigation/banner checks, all seven macOS smoke cases, Hub tests, and workflow/docs lint at its reviewed head before merge. Results and any corrections will be recorded here.
