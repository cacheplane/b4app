# macOS recovery smoke tests

## Approved direction

Automate the recovery interaction verified manually after PR #147. The owner requested a larger design, then directed us to continue with it. This is fixture-based macOS UI and coordinator integration coverage, not live-provider or signed-package verification.

## Boundary and isolation

An XcodeGen project under `Tests/macOSSmoke` builds a fixture host executable, a SwiftUI harness app, and an XCUITest bundle. The runner owns the host independently of the UI app. The host starts the real coordinator with a fresh ephemeral PostgreSQL database, memory secrets, short private temporary socket path, and the existing fake archived-session executable. The harness mounts the shipped `WorkspaceRootView` and connects to that explicit socket using the shipped transport. There is no alternate implementation of the recovery notice or composer and no injected UI error state.

Each journey owns a unique scratch root and database. Setup seeds an active fixture account, a connection to the fake runtime, one thread mapped to `thr_archived`, cached history, and a saved draft. UI preferences are in memory, making the database the sole source of the draft after relaunch. The test runner reads thread/draft state using normal coordinator commands. No owner data, installed app, Keychain, login items, external provider, or hub is used. Missing fixture configuration fails closed rather than resolving production paths. Host teardown is explicit, bounded, and restricted to the process the runner launched; its normal exit stops its test database cluster.

## Journeys

Four variants cover normal and minimum supported macOS window sizes (1200×600 and 900×600 content), light and dark appearance. Each variant starts from fresh state, selects the seeded chat through the sidebar, clicks Send exactly once, and waits for the archived refusal. It expands, collapses, and re-expands Details. It checks the recovery display, invokes Check again while still archived, and gracefully closes/relaunches the UI against the same host. The thread remains selected by an explicit sidebar click after relaunch; selection persistence is outside this contract.

Assertions: exactly one terminal failed turn, no native turn id, cached transcript retained, draft unchanged in composer and storage, exactly one active error notice, no redundant continuity notice, bounded visible diagnostics, full recovery instructions rendered, aligned action/Dismiss controls without overlap, and visible usable composer. Check again creates no additional turn. Relaunch reads the saved draft without seeding again. Notice persistence across app relaunch is not required.

## Rendering contract

Accessibility values cannot prove visible text: the original truncated label exposed its full value. Add stable accessibility identifiers to the primary message, Details and Dismiss; scope the diagnostics scroll view to its notice because the native disclosure propagates its own identifier to its contents. Give the notice explicit accessibility containment so its identifier describes one card. Compare danger-text rendered vertical extent in the real window with an unconstrained reference rendered by the same SwiftUI font, content width, appearance and scale. The reference belongs only to test support, not the shipped app. Frame/visibility assertions catch clipping outside the window. Keep the existing component compression tests for the smaller pane proposals. Verify the new regression's sensitivity once by temporarily disabling the two layout priorities from PR #147 and observing its truncation assertion fail, then restore the exact production source.

## Execution and artifacts

`Scripts/test-macos-smoke.sh` generates the test project, runs the suite serially with `xcodebuild test`, writes an `.xcresult`, and rejects failed or zero-test summaries. A separate macOS CI job fetches the pinned PostgreSQL binaries and runs that command. Attach screenshots, accessibility trees, fixture diagnostics, and state summaries to the result bundle, including on assertion failure. Wait for observable state with deadlines; no blind settling sleeps or automatic retries masking failures. Bounded polling is permitted for external-process readiness and normal protocol reads.

## Follow-on scope

Signed package installation, embedded helper discovery, LaunchAgent registration, real-provider authentication/compatibility and inference remain opt-in later gates. B4 restart and reconnect can become separate fixture journeys after this foundation is proved.

## Implementation finding

Actual pointer input exposed a decorative composer border intercepting Send clicks even though accessibility reported the button enabled and hittable. The minimal correction makes that border noninteractive. The smoke test requires the single click to reach the runtime, then verifies no native turn starts after the archived refusal. It also clicks Dismiss and verifies notice removal without losing the draft.

Running multiple journeys exposed a socket lifetime race: scoped channel cleanup could outlive its event loop. The client transport reader now finishes before its group shuts down, and all concurrent or later closers await the same cleanup task. The runner and UI app enable SwiftNIO strict checks; the coordinator’s existing bounded account-shutdown order is preserved. A fixture ownership pipe makes runner loss trigger normal host shutdown, and a separate lifecycle test verifies EOF without a signal.
