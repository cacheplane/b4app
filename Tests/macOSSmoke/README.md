# macOS recovery smoke tests

Run `./Scripts/test-macos-smoke.sh` on an Apple Silicon Mac with Xcode 26, XcodeGen, Node 24 or newer, and an active desktop session. Xcode's UI test runner must have permission to automate applications. The script installs the locked real-runtime test package, fetches the repository's pinned PostgreSQL binaries when missing, generates a separate test project, and runs XCUITest serially. Failed and zero-test runs exit unsuccessfully.

The harness mounts the shipped `WorkspaceRootView` and connects over the real client/socket to a separate fixture host running the real coordinator. The fake-runtime journeys use the existing fake Codex; the B4 journey uses the real runtime with a simulated model. Every journey has a fresh private `/tmp/b4smk-*` root, and the runner closes its own host at teardown. The installed app, owner account, Keychain and LaunchAgents are outside this suite.

Five tests (D-244):

| Test | What it drives |
| --- | --- |
| `RecoverySmokeTests.testDesktopDarkRecovery` | An archived session at the desktop size in dark appearance: open through the sidebar, send once, Details, the recovery text against a rendered reference, Check again and Dismiss, relaunch to the persisted draft; protocol reads confirm one failed attempt and no native `turn/start` |
| `B4RuntimeSmokeTests.testDesktopDarkB4Recovery` | The real B4 runtime with aimock: partial streaming, a real tool step, a stopped endpoint's failure with draft and history kept, Check again without resend, continuing the same thread, and relaunch; journals confirm four model requests and one tool execution |
| `PaletteSmokeTests.testPaletteAndSlashByKeyboard` | The command palette and the composer's `/` list by real keys: Find, Commands, thread actions, Rename, completions and the cursor afterwards |
| `ReadingSmokeTests.testALongThreadShowsEarlierRowsOnRequest` | A thread longer than the transcript's window opens at its end; "Show earlier" draws the rest and the reader stays in place |
| `FixtureLifetimeTests.testHostExitsWhenItsOwnerPipeCloses` | Closing the runner's ownership pipe stops the fixture host without a signal |

The desktop size is 1200×600 locally and 1000×600 in CI (`B4APP_SMOKE_DESKTOP_WIDTH=1000`), to fit CI's 1024-point virtual display. Smaller panes are covered by the package's `RecoveryCompressionTests` and `DetailMinimumSizeTests`.

The harness never opens a window smaller than the app's minimum (900×600, `LLA.Metrics.minimumWindow`): a smaller `SMOKE_WIDTH` or `SMOKE_HEIGHT` is raised to it, with a line on standard error, since holding the window below the minimum made AppKit throw.

Results and attachments are in `.build/macOSSmoke/Results-*.xcresult`, with screenshots, accessibility trees and fixture logs. `B4APP_SMOKE_RESULTS` and `B4APP_SMOKE_DERIVED_DATA` move them. Extra arguments pass to `xcodebuild`:

```sh
./Scripts/test-macos-smoke.sh \
  -only-testing:WorkspaceSmokeTests/RecoverySmokeTests/testDesktopDarkRecovery
```

This is fixture UI/coordinator integration coverage. Signed installation, embedded helper discovery, LaunchAgent registration and real-provider compatibility remain separate opt-in gates.
