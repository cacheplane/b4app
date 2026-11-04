## 2026-10-31: M6 package and accept

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0), no code-signing identity installed. Screen control for the app was declined in this session, so rows that need a person at the window are marked as such; everything else ran from the terminal against the packaged app or the fixtures.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 251 tests in 58 suites (new: `FallbackDirectoryTests` nvm ordering and lock peek, `LauncherTests` bundled-coordinator discovery through a symlinked CLI and the LaunchAgent plist) |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass (LaunchAgent hosting, Coordinator menu, `--remove-agent`) |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Package | `./Scripts/package.sh` | Pass: `dist/Agent Workspace.app` 0.1.0 with `Contents/Helpers/{b4app-coordinator,agent-workspace}` and the LaunchAgent plist; `plutil -lint` OK; `codesign --verify --deep --strict` "valid on disk, satisfies its Designated Requirement" (ad hoc); zip written |

### Live on this Mac (packaged app and bundled CLI)

All against the owner's real data directory (`~/Library/Application Support/b4app`), which the 0.1.0 coordinator opened and migrated to schema v3; no connection, thread, or turn was created. The Mac was left as found: agent unregistered, coordinator stopped.

| Scenario | How | Result |
| --- | --- | --- |
| Finder launch (A01) | `open dist/Agent Workspace.app` (LaunchServices, no shell environment) with no coordinator running | The app registered `com.cacheplane.b4app.coordinator` through `SMAppService` and launchd started `Contents/Helpers/b4app-coordinator` (parent pid 1, `launchctl print` state running, "submitted by smd"); `coordinator status` 10 s later: running, version 0.1.0, launch agent loaded. The coordinator's environment held `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `TMPDIR` and nothing from a shell. |
| Runtime lookup without a shell (A01) | `agent-workspace doctor` (the bundled CLI) against that coordinator | node `ready` v24.20.0 at `~/.nvm/versions/node/v24.20.0/bin/node` (source `fallback`, D-040); codex `ready` 0.166.0 at `/opt/homebrew/bin/codex`; claude `ready`, `auth=required`, 2.1.282 at `~/.local/bin/claude`. |
| Quit with the agent hosting (A17, part) | `tell application id "com.cacheplane.b4app" to quit` | The app exited at once (it owned nothing); the coordinator kept the same pid. |
| Relaunch | `open` again | Connected to the same coordinator (same pid and start time); no second registration. |
| CLI finds the bundled coordinator | `coordinator status` from the bundled CLI before anything ran | `executable: …/dist/Agent Workspace.app/Contents/Helpers/b4app-coordinator` (resolved beside the CLI). |
| Lifecycle commands | `coordinator status`, `doctor` (spawns), `status`, `restart`, `stop`, `status --json` on scratch directories with the debug CLI | A CLI-spawned coordinator reported, restarted to a new pid, stopped by SIGTERM; `status` exits 0 and reports `running: false` afterwards. |
| Removal | `Agent Workspace --remove-agent`, then `launchctl print`, `coordinator stop`, `coordinator status` | "removed com.cacheplane.b4app.coordinator"; launchd no longer knows the label; unregistering ended the coordinator (nothing left to stop); no bundled coordinator process remained. |

Not exercised: an upgrade (a 0.0.0 coordinator was not running when the test started, so the version note and the launchd restart path were not seen live; `coordinator restart` was exercised only against a CLI-spawned coordinator); the Login Items approval prompt (registration from `dist/` was accepted without one on this Mac); the Quit dialog for in-process hosting (needs a window).

### Acceptance matrix (spec 14.2)

| ID | Scenario | Status | Evidence |
| --- | --- | --- | --- |
| A01 | Finder launch | Pass (live) | This section, "Finder launch" |
| A02 | Codex login and use | Pass (live, M1 and M4) | `connection login` browser flow and real turns under the owner's account; the same native thread continued across restarts (M1, M4 records) |
| A03 | Claude login and use | Pass (live, 2026-10-31 after the owner signed in) | Real turn, interrupt as `cancelled`, native resume, transcript rebuild; see "Claude Code live gate" |
| A04 | Shared thread list | Pass (fixtures; live for Codex and both B4 modes; a Codex thread created from the window on screen) | Codex, Claude, managed and attached B4 threads listed with distinct connections and labels (M2, M3, M4 records; `SnapshotTests` render) |
| A05 | Thread organization | Pass (integration) | Rename, pin, title search, archive and unarchive, drafts across a coordinator restart (`ThreadOrganizationTests`, `WorkspaceModelTests`, M5 CLI smoke) |
| A06 | Runtime decisions | Pass (fixtures; one live Codex approval) | Single transition per request, stale generations expire, unsupported kinds declined (M1 to M3); live `item/commandExecution/requestApproval` approved once (M3 record) |
| A07 | Explicit Stop | Pass (fixtures; live B4 cancel) | Interrupt reaches the native turn, outcome confirmed or left `reconciling`, drafts kept (M1 to M4) |
| A08 | B4 managed local | Pass (live) | `research` project under `~/repos/b4app-live-check`: start, real turn, restart continuity, stop (M4 record) |
| A09 | B4 attached local | Pass (live) | Attached `b4 dev` survived coordinator kill and app Quit; cancellation worked (M3, M4 records) |
| A10 | B4 remote | Open: no compatible HTTPS endpoint deployed | HTTPS enforcement and bearer handling fixture-verified (M3) |
| A11 | Stream loss | Pass (fixtures; live B4 reattach) | Reattach finished with one server-side turn; snapshot merge never duplicates input (M3, M5) |
| A12 | Lost acknowledgement | Pass (fault injection) | `swallow` → `submission_unknown`, no repeat, `turn.abandon` releases the lock (M5 record) |
| A13 | App/runtime restart | Pass (integration and Mac) | Index returns, histories rebuilt from `thread/turns/list`, missing sessions and expired requests identified (M5); coordinator restart under a live managed server (M4) |
| A14 | Process ownership | Pass (process integration) | Concurrent starts converge on the lock; pid plus start time plus argv ownership; port conflicts stop nothing (M0, M4) |
| A15 | Auth and usage errors | Pass (fixtures) | Expired login → `auth_required` with a sign-in action; allowance failures surfaced; no billing-mode switch (M2, M5); not forced live by the spec's instruction |
| A16 | Renderer/secret boundaries | Pass (code review and focused checks) | `WorkspaceUI` imports no process, socket, file, or Keychain API (still true with `Theme/`: SwiftUI, CoreText, AppKit/UIKit for dynamic colours only); redaction at the coordinator boundary (M5 audit) |
| A17 | Window/Quit/wake | Partial (live Quit with the agent hosting; the window seen and driven on screen after the layout fix; the Quit dialog for in-process hosting and wake not driven) | This section, "Quit with the agent hosting"; the Quit dialog for in-process hosting and a real sleep remain unclicked |
| A18 | Project concurrency | Pass (integration) | Directory lock across two Codex threads and a Claude thread, held through a crash, released by abandon (`RecoveryTests`) |

### Open after M6

- Developer ID signing and notarisation: no certificate on this Mac (D-039).
- A live Claude inference turn (A03), a remote HTTPS B4 endpoint (A10), and a person at the window for the Quit dialog, the continuity banner, hover and context menus, and a real sleep across a live turn (A17).
- Removing a server registration and changing its port.
