## 2026-10-31: M5 daily-use behavior and recovery

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3). Fixture runs use the three fake runtimes; the live CLI smoke below ran the built `agent-workspace` and a CLI-spawned coordinator against `fake-codex.py` on scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` with `B4APP_CODEX_REQUEST_TIMEOUT=1`. No screen control was available in this session, so the macOS views were built and model-tested but not clicked.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 240 tests in 54 suites (22 new) in 22 s after a clean build |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass (includes the Quit dialog and the wake observer) |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

New fixture coverage, by acceptance row: A05 organization and drafts across a coordinator restart, the snapshot's active turns, model-level sidebar state, archived visibility, draft debounce and flush (`ThreadOrganizationTests`, `WorkspaceModelTests`); A11/A13 history rebuilt from `thread/turns/list` after the cache is lost, a partial cache merged without duplicating the live user message, a second merge a no-op, `thr_missing` → `missing` with the cache kept and sends refused, an account change (`FAKE_CODEX_EMAIL`) → `identity_changed` and back (`SnapshotMergeTests`, `ContinuityTests`); A12 `swallow` → `submission_unknown`, still unknown after reconcile, resend refused, `turn.abandon` then a `late ack` turn completing once with one native turn (`RecoveryTests`); A18 the directory lock across two Codex threads and a Claude thread (one through a `..` path), a free directory, held through a crash, released by abandon (`RecoveryTests`); A15 an expired login flipping the connection to `auth_required` with `connection.changed`, allowance failures recorded, the remediation table (`FailureTests`, `RemediationTests`); A17 `workspace.activeWork` naming local and remote turns, `stopLocalWork` cancelling the Codex turn and detaching from the attached B4 run, `workspace.reconcile` settling a B4 turn that finished while the coordinator was down with exactly one server-side turn, the clock-gap watcher firing once for a 25 s gap (`LifecycleTests`, `SleepWatcherTests`); A16 header lines and URL parameters masked, a `leak` turn redacted in the event, the thread read, and `doctor` (`LogRedactorTests`, `RedactionTests`).

### Live on this Mac (CLI against the fixture runtime)

| Scenario | How | Result |
| --- | --- | --- |
| Lost acknowledgement | `turn send --no-wait <id> please swallow this` | `error [submission_unknown] Codex did not acknowledge the turn; it may still have started.` exit 1; `thread show` printed `[turn … is reconciling; submission unknown]`. |
| Reconcile stays honest | `thread show --reconcile <id>` | Still `reconciling; submission unknown` (the fixture never started it); nothing was re-sent. |
| No automatic repeat | `turn send <id> hello again` | Refused `protocol_invalid` "A turn is still reconciling on this thread", exit 4. |
| Deliberate recovery | `turn abandon <id>` | `turn … terminal failed (abandoned)`, exit 0; the transcript ends with `[turnAbandoned]` after the user message. |
| Late acknowledgement | `turn send <id> late ack please` | The RPC response was dropped by the fixture; the turn still streamed "Hello from fake Codex." and ended `[turn completed]`, exit 0, one native turn. |
| Organization | `thread update <id> --title "Renamed smoke" --pin`, `--archive`, `thread list`, `thread list --archived`, `--unarchive --unpin` | Pinned and renamed row printed with `[pinned]`; archived thread hidden from `thread list` and shown with `[archived]` by `--archived`; unarchive restored it. |
| Diagnostics | `doctor --json` | `recentErrors` holds `codex:smoke-codex / submission_unknown` and nothing else. |

### Boundary audit (A16)

- `WorkspaceUI` imports only `SwiftUI`, `Observation`, `UniformTypeIdentifiers`, `WorkspaceProtocol`, and `WorkspaceClient` (Package.swift dependencies: `WorkspaceProtocol`, `WorkspaceClient`); no process, socket, file, or Keychain API is reachable from a view or the model.
- The credential value appears in `CredentialAdd.Params.value` on the 0600 socket and in `SecretStore.put` only; the router caches responses by operation id, never params; `connection.list`, `doctor`, and events carry `authReference` and `nativeScope`, never values.
- `print` is used only by the coordinator executable's two startup lines and the CLI; router log lines carry method names, error codes, and messages (messages are redacted at the boundary, D-035).
- `recentErrors`, adapter event messages, failed-turn messages, and `connection.changed` messages pass through `LogRedactor`; the CLI-spawned coordinator's stdout log is bounded by copy-truncate like server logs.

### Open after M5

- The Quit dialog, the continuity banner, the remediation button, the rename alert, the archived section, and the state dots were not driven on screen; `applicationShouldTerminate` is covered by the build and by the coordinator-side tests of what it calls.
- A real Mac sleep across a live turn, a real expired login, and allowance exhaustion were not exercised; the first needs the Mac, the other two are fixture-only by the spec's instruction.
- Everything open after M3 and M4 remains open: the remote HTTPS endpoint, `claude auth login`, removing registrations and changing ports, built artifacts.
