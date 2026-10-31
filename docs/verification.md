# Verification record

Gate results and unresolved checks, newest first. Each entry names what was exercised, how, and what remains open. Live checks are only those run on the target Mac against real runtimes.

## 2026-10-31: M2 Claude Code conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), Claude Code 2.1.282 at `~/.local/bin/claude`, **signed out** (`claude auth status --json` → `loggedIn: false`) for the whole session.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 145 tests in 30 suites (21 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live Claude (opt-in) | `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive` | **Not run**: requires `claude auth login` first |

New fixture coverage: `ClaudeTurnTracker` (streamed turn in order, `result success` with `is_error` → failed with `auth_required`, interrupt → cancelled by flag and by `terminal_reason`, tool_use paired with its tool_result, permission and question requests with safe payloads and synthetic question ids, elicitation marked unanswerable, `control_cancel_request`, session state, `apiKeySource` conflict, process exit ending the turn and scoping the disconnect, transcript snapshots); `ClaudeSession` and `ClaudeAdapter` against `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (inspect and login URL capture, session + streamed turn, permission allowed then stale, permission denied with a failed tool result, question answers passed through by question text, elicitation auto-declined, hang + interrupt → cancelled, crash → failed turn + thread-scoped disconnect + resume on the next send with a new generation, failed result error code, `--resume` of a known session and `native_session_missing` for an unknown one, `loadSession` from the transcript file); `SessionService` over the socket (a Claude conversation beside a Codex thread with both connections listed, a Claude tool permission answered exactly once through `request.respond`, a Claude crash leaving the Codex request pending and both connections `ready`).

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| Protocol shapes while signed out | Raw `claude` launch with the adapter's argv, `initialize` + one `user` message on stdin | Recorded in `docs/research/2026-10-30-claude-cli-stream-protocol.md`: hooks before the handshake, `command_lifecycle`, `system/init` with `apiKeySource: none`, replayed user frame, synthetic `assistant` error, `result success` with `is_error: true`. `--resume` of an unknown id → `result error_during_execution`, exit 1. |
| Claude connection registration | `agent-workspace connection add --kind claude` (scratch directories) | Pass, honest: `ready / auth_required`, version 2.1.282, message "Not signed in. Run `claude auth login` or use Sign in from the Connections screen." Exit 0. |
| Thread creation while signed out | `agent-workspace thread new --connection claude --cwd <dir>` | Refused with `auth_required`, exit 1. No process was left behind. |
| Codex unaffected | `connection add --kind codex` in the same coordinator | `ready / authenticated` beside the Claude row. |

### Not exercised (open gates)

- Any Claude inference: streaming, a real `can_use_tool`, `AskUserQuestion`, the `result` after `interrupt`, and resume with `--resume`. Sign in with `claude auth login`, then run the live test; it prints the reply, the interrupt outcome, and the resume answer.
- `claude auth login` through the app or CLI (it opens the owner's browser; not triggered unattended).
- Interactive use of the macOS window (screen-recording permission declined).

## 2026-10-30: M1 Codex conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), codex-cli 0.166.0 from the Homebrew cask, signed in with ChatGPT.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 124 tests in 26 suites (37 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live Codex (opt-in) | `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` | Pass in 9.7 s: handshake, account, thread, "pong" turn, interrupt → cancelled, reopen with history |

New fixture coverage: `StreamingProcess` (echo, terminate, stderr tail, write after exit, missing executable); Codex event translation for a streamed turn, interrupted and failed turns with mapped error codes, approval requests with a safe payload, every server request method's kind and decline body, account notifications, thread status, history snapshots; `CodexAppServer` and `CodexAdapter` against `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (handshake and account, streamed turn, approval answered with the user's decision then stale on a second answer, unsupported permissions request declined automatically, user question answers passed through, `thread/resume` before `turn/start` and `native_session_missing`, interrupt → cancelled, process exit mid-turn then restart on the next send, failed turn error code); storage upsert by native item id with stable sequence, active-turn lookup, request expiry per connection, snapshot replacement keeping live items; protocol mutation flags for the nine new methods; `SessionService` over the real socket (whole conversation with user and assistant items persisted, second turn refused while one is active, retry with the same `operationId` returning the same turn, approval answered exactly once, runtime exit leaving the turn `reconciling` with submission `unknown` and refusing dispatch, failed dispatch keeping the user message, pending requests expiring and turns reconciling across a coordinator restart).

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| Codex connection registration | `agent-workspace connection add --kind codex` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` | Pass. Found `/opt/homebrew/bin/codex` 0.166.0, `account/read` reported the ChatGPT account (`promax`), connection stored `ready / authenticated`, capabilities recorded. Exit 0. |
| New thread in a directory | `agent-workspace thread new --connection codex --cwd <dir> --title "Live check"` | Pass. `thread/start` returned native id `01a18f32-…`; the thread row carries the account email as `nativeScope`. |
| Real streamed turn | `agent-workspace turn send <id> Reply with exactly the single word: pong` | Pass in 3.5 s. Deltas streamed to the terminal, `[turn completed]`, exit 0. |
| Tool turn | `turn send <id> Read README.txt …` | Pass in 4.9 s. Codex ran `/bin/zsh -lc 'cat README.txt'` (shown as a tool card with its output), then answered with the file contents. No approval was requested under the user's Codex configuration, so the approval path was not exercised live. |
| Stop | `turn send … Count slowly from 1 to 3000 …` in the background, `turn interrupt <id>` after 6 s | Pass. The in-flight numbers drained, `[turn cancelled]`, exit 130; `thread show` lists the turn with a `reasoning` item and no assistant text. |
| Reopen the same native thread | `CodexLive` test: dispose the adapter, create a new one, `loadSession` | Pass. `thread/resume` + `thread/turns/list` returned the earlier user message and the "pong" reply. |
| macOS app hosts the coordinator during a live turn | Built `Agent Workspace.app` launched from the command line with the scratch directories; `agent-workspace doctor`, `thread list`, `turn send <id> … pong2` | Pass. The lock carried the app's pid (4700), the CLI reused it, the second turn completed through the app-hosted coordinator, and `thread show` listed both turns. |
| Conversation UI rendering | `ImageRenderer` of `TranscriptRow`, `RuntimeRequestList`, `ComposerView`, and `TurnStatusBadge` with representative items (throwaway test, not committed) | Pass. User bubble, Markdown assistant text, collapsed command card with status, live streaming text, "Turn stopped." note, "Waiting for you" badge, approval card with Allow once / Allow for session / Deny, question card, composer with Stop and a disabled Send while a turn is active. `ScrollView`, `TextEditor`, and `Picker` do not render through `ImageRenderer` and were checked by build only. |

### Not exercised (open gates)

- A real approval or user-question request from Codex. The coordinator, adapter, CLI, and UI paths are fixture-tested end to end; trigger one live by asking Codex to run a command outside its sandbox policy.
- Interactive use of the macOS window (screen-recording permission declined). The window was not clicked through; the shared SwiftUI code built for both platforms and rendered in isolation.
- `account/login/completed` from a signed-out state (the Mac stayed signed in).
- Mac sleep/wake with an app-server running; the minimal packaged Finder launch (M6).

## 2026-10-30: M0 baseline and Swift application shell (initial PR)

Target: MacBook Pro (Apple Silicon), macOS 26.5, Xcode 26.6, Swift 6.3.3, iPhone 17 Pro simulator (iOS 26.5).

### Automated (run locally; CI runs the same on `macos-26`)

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass (11 targets) |
| Tests | `swift test` | Pass: 87 tests in 19 suites |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

Fixture coverage the spec calls out as easy to break: envelope and method validation (mutations require `operationId`, unknown methods, wrong version, non-object params), event cursor gaps and epoch changes, bounded replay returning `snapshot_required`, singleton lock (held lock reported without removal, release and reacquire), NDJSON and JSON-RPC framing across arbitrary chunk boundaries, SSE parsing across every chunk size with parked, failed, cancelled, snapshot-only, and reattach outcomes, CRLF split across chunks, Claude auth-mode conflict detection, Claude stream-json frame encoding and decoding (initialize, user, can_use_tool allow and deny, AskUserQuestion answer, system init, result), B4 HTTPS enforcement and offline mapping through a `URLProtocol` stub, native-id uniqueness per connection and scope, runtime request single transition, command runner timeout and missing executable.

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| CLI starts the coordinator and reports diagnostics | `.build/debug/agent-workspace doctor --json` with `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` pointed at scratch directories | Pass. The CLI spawned `b4app-coordinator` from beside itself, the lock and socket were created with mode 0600 in a 0700 directory, the database opened in WAL mode. Exit 0. A second `doctor` reused the same coordinator pid. |
| CLI not-implemented commands | `agent-workspace server start research --json` | Pass. JSON error `not_implemented` with the milestone, exit 3. |
| Claude Code inspection | Through coordinator diagnostics | Found `~/.local/bin/claude` 2.1.282 through PATH. Earlier in the day the adapter reported `ready / authenticated` (claude.ai pro); by the time of the final run `claude auth status --json` itself reported logged out and the adapter reported `auth_required`, which is the honest result. No credential files were read. |
| Claude stream-json handshake | `claude` launched with the SDK's argv, one `initialize` control request on stdin, then EOF | Pass with no inference: one `control_response` frame, exit 0. Recorded in `docs/research/2026-10-30-claude-cli-stream-protocol.md`. |
| Codex inspection | Through coordinator diagnostics | `missing_executable` with install guidance (the CLI is not installed). Expected; not a pass of the Codex integration. |
| macOS app hosts the coordinator and shares it with the CLI | Built app launched from the command line with no coordinator running | Pass. The lock file carried the app's pid; `agent-workspace doctor` returned the same pid and `ready` runtime rows while the app was running. |
| Stale lock and socket files after an unclean exit | App killed with SIGTERM, then `doctor` | Pass. The next coordinator took the freed `flock`, replaced the socket file, and served the CLI. |
| iOS app renders the shell | Installed and launched on the iPhone 17 Pro simulator with `simctl`; screenshot captured with `simctl io` | Pass. Sidebar with Threads, Connections, Local servers, Diagnostics, the thread list, search, and the status "Coordinator unavailable: iOS cannot reach the Mac coordinator yet". A first build was letterboxed because XcodeGen overwrote the Info.plist; fixed by moving the keys into `project.yml`. |

### Not exercised (open gates)

- A screenshot of the macOS window could not be captured (screen-recording permission declined), so the macOS layout was verified only through the socket and the shared SwiftUI code that rendered on iOS.
- Packaging, Finder launch, LaunchAgent registration, signing, notarization. M6.
- Codex app-server handshake, sign-in, any turn. Blocked on installing the Codex CLI.
- Claude sessions beyond the handshake, permission bridge, interrupt. M2.
- B4 thread operations and managed server supervision. Blocked on selecting a trusted local project. M3 and M4.
- Keychain writes through `KeychainSecretStore`. The memory store was used in tests; the Keychain store is wired but untested live.
