## 2026-11-10: No-folder starts

A Codex or Claude thread starting with no folder (D-203), from the Mac, the phone and the CLI. Commits c0468de (store), f78737d (coordinator and CLI), 9b63294 (hub routing and the relay wire), dabe720 (interface). Every gate below ran on this branch (`blove/no-folder-starts`) one at a time, with nothing else building or testing in this checkout.

### Gates

- `swift build`: `Build complete!`.
- `swift test`: `Test run with 1517 tests in 189 suites passed after 142.103 seconds.` Exit 0, no failing test and no recorded issue in the log. The two flaky symptoms the interface task saw while app builds ran at the same time (`AppleSignInTests.appleSheetSaysItHasNoWindow` once, eight `MirrorSyncTests` timeouts) did not appear on this quiet run, so there was nothing to rerun.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean, exit 0.
- Hub, from `Hub/`: `source <(./scripts/test-db.sh) && cargo test --workspace --locked`: 29 test binaries, 515 tests passed, 0 failed; then `./scripts/test-db.sh --stop` stopped the cluster.
- `cargo fmt --all -- --check`: clean, exit 0.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings.
- `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'`: `** BUILD SUCCEEDED **`.
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`: `** BUILD SUCCEEDED **`.
- `Scripts/docs-index.sh --check`: `191 decisions and 109 verification records are well formed` (rerun after these two files were added: 192 decisions and 110 verification records, well formed). `Scripts/docs-index.sh --next` printed `D-203`.

### What the tests cover

- Store: the `appFolders` table, the folder root per flavour and under `B4APP_DATA_DIR`, and the backup archive (`AppFolderStoreTests`, `PlatformTests`, `DatabaseTests`).
- Coordinator (`NoFolderStartTests`, `EnvironmentServiceTests`, `ThreadNewCommandTests`): the folder name and mode, the whole-id fallback with an existing folder left alone, a gone folder made again at its path, no environment from the insert or `backfill()`, the start table (no environment and no folder from any device makes a folder; a folder from another device with no environment is `environment_missing`; a B4 start is unchanged), `folder_gone` on `turn.send`, and `--no-folder` / `--cwd` in the CLI.
- Hub and wire: `thread.start` with no `environmentId` routes by `deviceId` (`Hub/crates/b4hub/tests/relay.rs`), and `relay.json` is read by `RelayWireTests` and the hub's fixture test.
- Interface (`NewThreadDraftTests`, `AttentionModelTests`, `ThreadListTests`, `WorkspaceModelTests`): the default place, the phone's primary-Mac rule and blocked reasons, what a start sends from each platform, the remembered environment, the "No folder" group and filter, and the `folder_gone` words. This is all fixture and unit tests; the phone path was only fixture-tested.

### Hand check

Not done. Setup: a scratch data directory and runtime directory under `$TMPDIR`, `B4APP_FLAVOR=local`, `codex` on `PATH` replaced by a shim to `Tests/CodexAdapterTests/Fixtures/fake-codex.py`, the debug `agent-workspace` and the coordinator it spawned. `doctor --json` answered `"ok" : true`, but `connection add --kind codex --name Codex` answered `error [signed_out]: Nobody is signed in. Sign in from the Agent Workspace app.` A coordinator started outside the app has no account, so no thread could be made, and I did not sign in or call a hub to get around that. So none of these were checked by hand: the folder under `<dataDir>/projects`, the thread reading "No folder", a restart leaving it without an environment, and Send after deleting the folder showing the folder-gone words. I stopped the coordinator I started (pid 2932) and removed the scratch directory; I did not touch the real data directories or the installed apps.

### Not checked

- The Mac app on screen (the "No folder" toggle, the default place, the sidebar group, the folder-gone message).
- The phone or the Simulator (the primary-Mac rule, the blocked reasons, a start relayed through a hub).
- A start against a real Codex or Claude runtime, or a hosted hub.
These are left to the controller's on-screen check.

### Deviations from the plan

- The app folder is made before the runtime's session is created (the runtime starts in it), not immediately before the thread row is inserted. Every refusing check still runs first, and a failure up to the insert removes the folder only while it is empty, with its row.
- From another device, a start with an unknown connection and no environment answers `connection_missing` (it was `environment_missing`).
- The composer keeps a hand-picked "No folder" through a refresh; on the phone a no-folder thread's owner, and the not-confirmed lookup, fall back to the Mac the start named (`deviceId`).
- The sidebar group and the phone filter formerly titled "Other" are now "No folder", and also hold threads whose environment is not known.

### Follow-ups

- No test covers the rollback when session creation fails after the folder is made.
- Two concurrent starts with one new thread id can leave a thread whose empty folder was removed.
- The new `relay.json` `thread.start` entry is checked as raw JSON in Swift rather than decoded as `ThreadStart.Params` (the existing entries lack `threadId`).
- On the Mac, "No folder" with no ready connection still says "Choose a folder to start in."
- A phone with no primary Mac shows "No folder" with Send off and no reason.
- The place menu draws a leading divider when there are no environments.
