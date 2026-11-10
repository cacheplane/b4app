# macOS recovery smoke tests

Run `./Scripts/test-macos-smoke.sh` on an Apple Silicon Mac with Xcode 26, XcodeGen, and an active desktop session. Xcode's UI test runner must have permission to automate applications. The script fetches the repository's pinned PostgreSQL binaries when missing, generates a separate test project, and runs XCUITest serially. Failed and zero-test runs exit unsuccessfully.

The harness mounts the shipped `WorkspaceRootView` and connects over the real client/socket to a separate fixture host running the real coordinator. Only the provider is simulated, by the existing archived-session fake runtime. The fixture host seeds its own account, database, cached transcript and draft. Every journey has a fresh private `/tmp/b4smk-*` root; the runner closes its own host at teardown. The installed app, owner account, Keychain and LaunchAgents are outside this suite.

The four journeys cover compact (900×600) and desktop (1200×600) content sizes in light and dark appearance. They open the chat through the sidebar, send once, expand/collapse/re-expand Details, check the visible recovery text against a freshly rendered unconstrained reference, check notice count and action alignment, invoke Check again and Dismiss, and relaunch the UI to verify the persisted draft. Protocol reads verify one failed terminal attempt, no native turn id and retained cached history. The fake runtime's request log independently rejects any native `turn/start`.

A fifth test verifies that closing the runner's ownership pipe stops the fixture host without sending a signal. The same EOF mechanism handles a runner crash that skips teardown. The runner and UI app enable SwiftNIO strict lifecycle checks; client shutdown must finish its scoped reader before closing the event loop. The host retains the coordinator’s existing bounded account-shutdown order.

The reference uses the actual message width, the same LLA font and appearance, and a pixel-to-point conversion. The assertion examines rendered danger-text extent, because the accessibility label can contain complete instructions even when the visible text is truncated. Existing component compression tests cover smaller pane proposals as well.

Results and attachments are in `.build/macOSSmoke/Results-*.xcresult`. CI retains the result bundle, including screenshots, accessibility trees, persisted thread snapshots and fixture logs. Customize results and build storage with `B4APP_SMOKE_RESULTS` and `B4APP_SMOKE_DERIVED_DATA`. Extra arguments pass to `xcodebuild`, for example:

```sh
./Scripts/test-macos-smoke.sh \
  -only-testing:WorkspaceSmokeTests/RecoverySmokeTests/testCompactLightRecovery
```

This is fixture UI/coordinator integration coverage. Signed installation, embedded helper discovery, LaunchAgent registration and real-provider compatibility remain separate opt-in gates.

Both default widths use the supported minimum 600-point content height, so they fit GitHub's virtual desktop and exercise compression at a tighter height. On a larger desktop, also run the 800-point variant with:

```sh
./Scripts/test-macos-smoke.sh B4APP_SMOKE_DESKTOP_HEIGHT=800
```
