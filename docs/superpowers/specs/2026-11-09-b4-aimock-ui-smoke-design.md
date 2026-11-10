# Real B4 workspace UI smoke coverage

The owner authorized continuing the successful real B4/aimock trial through UI coverage, pull request and merge on green without another approval pause. The trial's four runtime cases and fragmented-SSE check passed locally, and its dedicated CI job passed in PR #166. That PR must merge green before this follow-up merges.

## Boundary and architecture

Drive the shipped `WorkspaceRootView` through the existing macOS XCUITest harness and its real isolated coordinator/PostgreSQL host. Add a real B4 fixture mode alongside the existing archived fake-runtime mode. The test-owned Node fixture runs the same published B4 CLI and aimock used by the trial; the coordinator connects to it as an attached local B4 endpoint. This verifies attached-runtime recovery, not the managed-server settings UI or a paid provider.

A small Node fixture executable owns B4 and aimock. Its stdin pipe is the ownership boundary: EOF closes both servers even if XCTest crashes. JSON-line commands `stop`, `start` and `snapshot` operate only on that fixture. Each response is an atomic manifest under the private `/tmp/b4smk-*` root, containing the matching operation id, state, endpoint and synthetic journal/tool evidence. Invalid commands fail explicitly. SIGTERM also drains and closes the fixture. Logs and journals are preserved before temporary state is removed.

The Swift UI test fixture starts this owner before the real coordinator, then launches the unchanged workspace UI app against the coordinator's socket. The host validates the private manifest and loopback B4 endpoint, creates a real native thread via `ThreadCreate`, and seeds only the initial draft. It does not inject transcript/error/turn state. The old fake-runtime journey stays available and retains its assertions.

## UI journey

Run one compact/light and one wider/dark variant using the existing exact content-size and screen-containment checks. CI's second width remains 1000; local default remains 1200. Model responses are explicit JSON fixtures. A UI-specific streaming fixture deliberately emits slowly enough to observe pending UI state; tests wait on observable state with deadlines, never on settling sleeps.

1. Select the real B4 chat in the sidebar. Click Send once on its initial streaming draft. Observe a partial visible answer and Stop while the coordinator still reports a running turn, then require completed output and a single successful terminal turn.
2. Type/send the tool scenario through the composer. Require the rendered real tool step, final answer, one actual tool invocation and two provider requests for that tool round. No duplicate user input or assistant answer may appear.
3. Type the restart draft and wait until the coordinator has saved it. Stop the test-owned B4 process while leaving its native state intact. Click Send once, observe one actionable failure notice, preserved draft and readable prior transcript, full recovery text through Details expansion, and aligned action/Dismiss controls. The failure must not reach the model provider.
4. Start the same B4 project on the same endpoint. Click Check again in the UI. Require recovery without an automatic send or tool replay, with the same native thread and saved draft. Click Send deliberately; require the expected continuation, successful terminal state and cleared draft.
5. Gracefully relaunch the UI against the same coordinator and require the conversation/history/native identity to remain consistent. Attach screenshots, accessibility state, coordinator thread data and Node fixture evidence.

Protocol reads and journals supplement actual UI input; they do not bypass Send, Details, Check again, or draft editing. Every positive turn needs explicit successful terminal status. Offline failure must stay visibly failed rather than be counted as successful recovery.

## Ownership, CI and limits

The Node owner gets an environment allowlist and private fixture paths. It inherits no provider credentials or owner projects. Add a Node integration check that closes its ownership pipe and verifies both listeners and the B4 child disappear normally with retained artifacts. Swift teardown independently closes the app, coordinator and Node owner even after an assertion failure; it removes the outer root only after owned processes stop.

Install the locked Node package and select Node 24 in the macOS smoke job; pass the executable and fixture-package paths through test-only build settings. No Node dependency is embedded in the shipping app or shared SwiftUI module. Keep the separate fast runtime CI job and all existing smoke tests. Full Swift/package/native/iOS and updated smoke CI must pass at the reviewed head before merge. Record local failures or environmental limits honestly.

Live-model compatibility, signed installation and managed-server settings interactions remain separate gates. This suite claims real UI/coordinator/attached-B4 integration with a simulated model.
