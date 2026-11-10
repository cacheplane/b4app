## 2026-11-09: Real B4 workspace smoke promotion

This follows the successful real-runtime/model-fixture trial in PR #166, merged at `fa194c490cb246eda0ea1ac5c4e23a6951d0e21a` after all seven CI checks passed. The user authorized continuing into workspace UI coverage and fixes exposed by that trial.

### Boundary and coverage

The shipped workspace SwiftUI runs against a real isolated coordinator/PostgreSQL host and the published B4 0.15.8 runtime. aimock 1.47.0 supplies the model API. Two added journeys exercise compact/light and desktop/dark: visible partial text with Stop and a running turn, real tool execution, stopped-endpoint failure with one notice/full recovery text/aligned buttons, saved draft and cached history, Check again without sending, deliberate same-thread continuation, and UI relaunch. The four archived-session journeys and owner-pipe lifetime check remain in the default suite.

The Node owner controls only its own B4/aimock children. EOF/SIGTERM cleanup, startup cancellation, stop/start on the same endpoint, request/tool journals and retained diagnostics have integration coverage. Swift teardown attaches coordinator thread/draft state even when a UI assertion fails, then independently closes the client, host and runtime. No owner's app data, credentials, projects, servers or display settings are changed. This is fixture integration, not paid-model, managed-server Settings or signed-installation evidence.

### Product defects exposed

A private native-app run reproduced a refused B4 send clearing both the composer and stored draft while its turn was terminal, submission `prepared`, with no native turn id or model request. The local send handler restored only archived or unresolved attempts. A failing model regression observed empty composer and empty persisted save for both response/event states. The fix restores failed-command input within the existing account, selected/open-thread, deletion and newer-text guards. Tests cover both event orders and newer typing; restoration never resends.

A second private run confirmed the draft fix, full expanded recovery message, one actionable notice and aligned buttons. Stopping B4 left three provider requests and one real tool invocation. Check again after restart preserved the draft and sent nothing; a deliberate Send completed the same native conversation with four model requests and one tool invocation. It also exposed duplicated cached messages: streaming ids (`turn-N:mM`) differ from canonical checkpoint ids, and locally stored user items initially have no native id.

The history fix adds optional native turn identity to snapshot items. B4 tags message groups at HumanMessage boundaries, matching the published runtime's turn reconstruction and the adapter's existing ordinal. The merge first honors all exact native ids, then matches same role/type/nonempty text only within one unambiguous terminal acknowledged native turn. It preserves app row/turn identities and live payloads while adopting canonical checkpoint ids. Prepared/unknown/running/ambiguous turns receive no fallback, and tagged items cannot fall through to global text matching. Already-duplicated caches are not automatically deleted or rewritten.

A final private native-app run after the history fix observed live partial text plus Stop and an independently running coordinator turn. After the tool and stopped-endpoint refusal, expanded recovery text remained complete with one notice and aligned actions. Check again retained exactly six cached items with their original app ids and turn links, adopted canonical checkpoint ids, preserved the saved draft, and left the provider journal at three requests and one tool invocation. The deliberate continuation completed the same native thread and moved the journal to four requests, still one tool invocation. The fixture shut down its owned app/coordinator/B4/model processes; this manual compact/light run does not substitute for the automated CI matrix or relaunch assertions.

### Local verification

- The locked Node package passed all 13 runtime/SSE/owner tests in 25.376 seconds in an independent run.
- Native `build-for-testing` passed after the real-runtime host, owner driver, UI journeys and shared assertions were added.
- Draft regression failed before the fix; all 21 focused model recovery/send tests passed afterward.
- Final clean Swift verification passed all 1,478 tests in 185 suites in 117.095 seconds, including both product fixes and identity safeguards. The earlier pre-history suite also passed 1,475 tests.
- Final `swift build` passed in 10.69 seconds. Strict Swift formatting, actionlint, shellcheck, docs-index and whitespace checks passed.
- The first two local XCUITest runs failed before any test began: the UI runner timed out enabling automation mode. One overlapped another worktree's UI run. Developer mode was observed disabled; no global security setting was changed. These failures are not counted as passing UI evidence. A third run after that competing runner ended built successfully and failed at the same automation-mode initialization, before any journey executed. Clean CI must supply UI execution evidence.
- The storage regression reproduced duplicate rows before the history fix. All 19 targeted history/translation tests in three suites passed in 80.101 seconds, including seven identity rejection scenarios. An incremental full-suite run after the public snapshot layout changed reported inconsistent fields in an unrelated adapter test and exited unsuccessfully; the final clean build/test run above resolved that stale-artifact failure. Swift cleanup also removed the downloaded PostgreSQL fixture; the first clean attempt failed for missing binaries, which were restored from the pinned archive before the passing final run.

### CI gate

PR #167 first ran all seven macOS cases in [CI run 42777543347](https://github.com/cacheplane/b4app/actions/runs/42777543347). The five existing cases passed; both new B4 cases failed at the initial partial-text lookup because macOS exposed static text in `value` while the test searched only `label`. Retained coordinator state and provider journals confirmed a successful single streaming turn; screenshots and AX trees exposed the selector mismatch. The lookup now accepts either field, and the streaming proof rejects a full answer in either field while still requiring hittability, transcript containment and an independently running turn. A native build passed for this correction.

The same first head passed runtime integration (13 checks), full package tests, native app builds, Hub tests and lint. Corrected-head smoke and all mandatory CI checks remain required before merge; no failed UI run is treated as successful coverage.
