# macOS recovery smoke tests

Run `./Scripts/test-macos-smoke.sh` on an Apple Silicon Mac with Xcode 26, XcodeGen, and an active desktop session. Xcode's UI test runner must have permission to automate applications. The script fetches the repository's pinned PostgreSQL binaries when missing, generates a separate test project, and runs XCUITest serially. Failed and zero-test runs exit unsuccessfully.

The harness mounts the shipped `WorkspaceRootView` and connects over the real client/socket to a separate fixture host running the real coordinator. Current-runtime interactions use the existing deterministic fake Codex. Historical B4 rows are inserted into the host's owned account database as cached facts, without starting a legacy endpoint, Node, a model provider, or the dormant Agent Protocol client. Every journey has a fresh private `/tmp/b4smk-*` root, and the runner closes its own host at teardown. The installed app, owner account, Keychain and LaunchAgents are outside this suite.

Five tests (D-244; the fifth journey is renamed for D-240's historical read-only policy):

| Test | What it drives |
| --- | --- |
| `RecoverySmokeTests.testDesktopDarkRecovery` | An archived session at the desktop size in dark appearance: open through the sidebar, send once, Details, the recovery text against a rendered reference, Check again and Dismiss, relaunch to the persisted draft; protocol reads confirm one failed attempt and no native `turn/start` |
| `HistoricalCacheSmokeTests.testDesktopDarkHistoricalCacheAndCurrentNative` | A genuine current fake-Codex thread: visible held partial deltas, Stop with a cancelled outcome and retained partial, native approval and one completed command item, cache reads and UI relaunch without resend, then an explicit continuation in the same native thread. A separate historical B4 cache stays readable with exact opaque identities, tool/task payloads, pending requests, unknown outcome and editable unsent draft; execution and answer controls must be disabled with a visible historical read-only reason, while Check again remains enabled and reads the historical cache without native execution. Native request journals, local reads and host database snapshots check these facts; the two historical requests have distinct fixed timestamps matching the database's creation-time ordering. |
| `PaletteSmokeTests.testPaletteAndSlashByKeyboard` | The command palette and the composer's `/` list by real keys: Find, Commands, thread actions, Rename, completions and the cursor afterwards |
| `ReadingSmokeTests.testALongThreadShowsEarlierRowsOnRequest` | A thread longer than the transcript's window opens at its end; "Show earlier" draws the rest and the reader stays in place |
| `FixtureLifetimeTests.testHostExitsWhenItsOwnerPipeCloses` | Closing the runner's ownership pipe stops the fixture host without a signal |

The historical tool and task rows demonstrate cached rendering and preservation; their seed does not demonstrate execution. The current partial deliberately waits for Stop and is cancelled; it does not demonstrate natural streaming completion. The default archived-recovery fixture is unchanged and never shares its no-inference oracle with successful current turns.

The obsolete fifth journey attempted to add a historical B4 endpoint and is unreachable under D-240. Its automatic real-runtime startup and Node/npm prerequisite are removed from this suite. Standalone `Tests/B4Runtime` retains the separate real-framework integration with a simulated model, including its own model-request/tool journals; it does not qualify active B4 App integration. Current native/managed CI assertions still need observation, and Agent Protocol execution, real-provider/live HTTP, release and activation remain separate held gates. Source assertions or fixture results do not qualify them.

The desktop size is 1200×600 locally and 1000×600 in CI (`B4APP_SMOKE_DESKTOP_WIDTH=1000`), to fit CI's 1024-point virtual display. Smaller panes are covered by the package's `RecoveryCompressionTests` and `DetailMinimumSizeTests`.

The harness never opens a window smaller than the app's minimum (900×600, `LLA.Metrics.minimumWindow`): a smaller `SMOKE_WIDTH` or `SMOKE_HEIGHT` is raised to it, with a line on standard error, since holding the window below the minimum made AppKit throw.

Results and attachments are in `.build/macOSSmoke/Results-*.xcresult`, with screenshots, accessibility trees, native request journals, persisted coordinator reads, historical database snapshots and fixture logs. Teardown captures state even when an assertion fails, closes the client and ownership pipe, and joins only its owned host with the existing bounds. `B4APP_SMOKE_RESULTS` and `B4APP_SMOKE_DERIVED_DATA` move results. Extra arguments pass to `xcodebuild`:

```sh
./Scripts/test-macos-smoke.sh \
  -only-testing:WorkspaceSmokeTests/RecoverySmokeTests/testDesktopDarkRecovery
```

This is fixture UI/coordinator integration coverage. Signed installation, embedded helper discovery, LaunchAgent registration and real-provider compatibility remain separate opt-in gates.
