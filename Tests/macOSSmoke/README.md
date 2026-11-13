# macOS recovery smoke tests

Run `./Scripts/test-macos-smoke.sh` on an Apple Silicon Mac with Xcode 26, XcodeGen, Node 24 or newer, and an active desktop session. Xcode's UI test runner must have permission to automate applications. The script installs the locked real-runtime test package, fetches the repository's pinned PostgreSQL binaries when missing, generates a separate test project, and runs XCUITest serially. Failed and zero-test runs exit unsuccessfully.

The harness mounts the shipped `WorkspaceRootView` and connects over the real client/socket to a separate fixture host running the real coordinator. The archived-session journeys use the existing fake runtime, while the B4 journeys use the real runtime with a simulated model. The fixture host seeds its own account and database; fake-runtime cases also seed cached history and a draft. Every journey has a fresh private `/tmp/b4smk-*` root; the runner closes its own host at teardown. The installed app, owner account, Keychain and LaunchAgents are outside this suite.

The four archived-session journeys cover compact (900×600) and desktop (1200×600 locally, 1000×600 in CI) content sizes in light and dark appearance. CI explicitly selects the second width to fit its 1024-point virtual display; both exact dimensions and full-window screen containment are asserted. They open the chat through the sidebar, send once, expand/collapse/re-expand Details, check the visible recovery text against a freshly rendered unconstrained reference, check notice count and action alignment, invoke Check again and Dismiss, and relaunch the UI to verify the persisted draft. Protocol reads verify one failed terminal attempt, no native turn id and retained cached history. The fake runtime's request log independently rejects any native `turn/start`.

A fifth test verifies that closing the runner's ownership pipe stops the fixture host without sending a signal. The same EOF mechanism handles a runner crash that skips teardown. The runner and UI app enable SwiftNIO strict lifecycle checks; client shutdown must finish its scoped reader before closing the event loop. The host retains the coordinator’s existing bounded account-shutdown order.

The reference uses the actual message width, the same LLA font and appearance, and a pixel-to-point conversion. The assertion examines rendered danger-text extent, because the accessibility label can contain complete instructions even when the visible text is truncated. Existing component compression tests cover smaller pane proposals as well.

Results and attachments are in `.build/macOSSmoke/Results-*.xcresult`. CI retains the result bundle, including screenshots, accessibility trees, persisted thread snapshots and fixture logs. Customize results and build storage with `B4APP_SMOKE_RESULTS` and `B4APP_SMOKE_DERIVED_DATA`. Extra arguments pass to `xcodebuild`, for example:

```sh
./Scripts/test-macos-smoke.sh \
  -only-testing:WorkspaceSmokeTests/RecoverySmokeTests/testCompactLightRecovery
```

`PaletteSmokeTests` drives the command palette and the composer's `/` list with real keys over the same fixture (the fake Codex): Find, Commands, thread actions, Rename, the completions and their picks, and where the cursor is afterwards. It sends no turn; the fake runtime's request log rejects any `turn/start`. Two more of its tests cover the palette's panel and the title bar's command centre: that the button is centred in the window and the palette opens over it, that the panel drags by its header and footer and snaps home, and, from screen pixels, that its shadow follows the card with nothing left behind.

This is fixture UI/coordinator integration coverage. Signed installation, embedded helper discovery, LaunchAgent registration and real-provider compatibility remain separate opt-in gates.

Both default widths use the supported minimum 600-point content height to exercise compression. CI sets `B4APP_SMOKE_DESKTOP_WIDTH=1000`; the local default remains 1200. The suite never changes display settings. On a larger desktop, also run the 800-point variant with:

```sh
./Scripts/test-macos-smoke.sh B4APP_SMOKE_DESKTOP_HEIGHT=800
```

To reproduce the CI width locally:

```sh
./Scripts/test-macos-smoke.sh B4APP_SMOKE_DESKTOP_WIDTH=1000
```

Two additional real-B4 journeys run compact/light and desktop/dark through the same shipped UI and isolated coordinator. A test-owned Node supervisor launches the published B4 CLI with aimock model fixtures. They observe partial streaming, a real tool step, stopped-endpoint failure with preserved draft/history and full Details text, Check again without automatic resend, deliberate same-thread continuation, and UI relaunch. Provider and tool journals verify four model requests and exactly one tool execution across the journey. Each deliberate app attempt has one user item; the failed draft reaches the native runtime only on the final Send.

The Node supervisor uses an ownership pipe plus atomic operation-id manifests. EOF or SIGTERM closes its B4 and aimock listeners, including during startup; its synthetic evidence is attached to the Xcode result before cleanup. This covers an attached local B4 endpoint, with the model simulated. Managed-server settings interactions and real-model behavior remain separate gates.
