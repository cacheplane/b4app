## 2026-10-31: M8a read-only mirror

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6), Docker 27.4.0 for the hub image and Compose, the iPhone 17 Pro Simulator (iOS 26.5) for the phone. The owner's running Agent Workspace app, its LaunchAgent, and `~/Library/Application Support/b4app` were left alone; the live gate ran a scratch debug coordinator on scratch `B4APP_DATA_DIR` and `B4APP_RUNTIME_DIR`. **The agent in the live gate was the fixture `fake-codex.py`. The sync path (coordinator, hub, PostgreSQL, iOS mirror) was real end to end; the inference was not, and, at the time of this gate, the owner's packaged app had not joined a hub; the evening entry below covers the join with a real Codex turn.**

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Rust format | `cd Hub && source <(./scripts/test-db.sh) && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked` (then `./scripts/test-db.sh --stop`) | Pass: 77 tests against a real PostgreSQL 17.11: `b4hub` 43 (unit 20, `changes` 8, `enroll` 10, `health` 5), `b4hub-core` 12, `b4hub-db` 22 (unit 3, `changes` 10, `migrate` 6, `rls` 3) |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 324 tests in 74 suites (262 before M8a; 319 before the final-review fixes) |
| macOS app | `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Pass |
| iOS app | the same with `-scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| CI | the `hub` job (Ubuntu, `postgres:17` service) | Recorded in the draft PR cacheplane/b4app#17 (base `design/m8-hub`), not here: the controller observed all three checks (the Swift package job, the apps job, which runs both app builds, and the Ubuntu `hub` job) green at commit a6d9a2a (end of Task 6) and partially green on later heads; later heads, including the docs commit, were still pending when this was written. The final head's result is in the PR |
| Image | `docker build` of `Hub/Dockerfile` on the build Mac, `linux/arm64` | Builds; runs as uid 10001; `docker compose ps` showed `hub` healthy after about 11 s (Task 5) |

### Live on this Mac (Task 9 gate)

| Step | How | Result |
| --- | --- | --- |
| Hub up | `docker compose build` and `up -d` in `Hub/` with a `Hub/.env` holding two random passwords; `curl localhost:8080/readyz` | db healthy, `migrate` exited 0, hub serving: `{"migrations":"current","minClientProtocol":1,"ok":true}` |
| Seed and codes | `docker compose run --rm migrate seed --org cacheplane … --user blove …`, then `migrate enroll --user blove` once per device | Org and user seeded; each code printed once and spent once |
| Scratch coordinator | `agent-workspace doctor --json` with scratch directories spawned `.build/debug/b4app-coordinator`; `connection add --kind codex --path Tests/CodexAdapterTests/Fixtures/fake-codex.py` | `ready`, `authenticated`, 0.166.0 (the fixture's version string) |
| Mac join | the code piped on stdin to `agent-workspace hub join http://localhost:8080` | Joined as `blove@cacheplane`; it never appeared as an argument; `hub status` then showed 0 unsynced |
| Thread and turn on the Mac | `thread new --connection "Fixture Codex" --title "First Codex thread"`; `turn send` | `[turn completed]`, reply "Hello from fake Codex."; `hub status` back to 0 unsynced |
| Phone enrolls | Simulator build signed ad hoc by Xcode; Connect screen with `http://localhost:8080`, an eight-character code, device name "iPhone 17 Pro" | Switched to the shell; the list showed "First Codex thread" without a refresh (`docs/screenshots/ios-mirror-list.png`) |
| Transcript | opened the thread; then quit and relaunched the app | The user message and the reply showed; after relaunch the stored link resumed the pull loop and the list showed at once |
| Live turn | `turn send` on the Mac while the thread was open on the phone | The second user message and its reply were on screen 1.4 s after the Mac's turn completed (`docs/screenshots/ios-mirror-thread.png`); the first screenshot taken already showed them |
| Live new thread | `thread new --title "Second Codex thread"` while the list was open | On the phone within 1.6 s |
| What the hub holds | `psql` in the Compose database | `connections`: `authReference` NULL, `target` empty, `localServerId` NULL, and the hub has no `localServers` table; `changes` count 35, all from the `macos` device; the Mac's `db status` also 35 and the phone's `syncState` cursor 35 |
| URL refusal, Mac | `agent-workspace hub join http://192.168.1.10:8080` | `protocol_invalid`, "The hub URL must use https (http is allowed only for localhost)."; exit 4; the existing link untouched |
| URL refusal, phone | the same URL typed on the Connect screen | The same message inline, the code kept, no request made, nothing from 192.168.x in the hub log |
| Secret boundary | the Simulator's unified log for the app (5,797 lines) and `docker compose logs hub` searched for each code and for `Bearer` | 0 matches; the Mac's code was only ever on stdin; the store holds a `secret:` reference, never the token |
| Teardown | `coordinator stop`, `docker compose down -v`, scratch directories, `Hub/.env`, and code files removed, app uninstalled from the Simulator | The owner's coordinator (pid 11944) was never touched |

Three things the gate found and Task 9 fixed in the same commit: an unsigned Simulator build cannot use the data-protection Keychain (`Keychain error -34018`), and a failure after enrollment (the Keychain put or the link save) had spent the code and left an unrevoked device, so `MirrorHost.connect` now removes the secret and revokes the new device with the token it still holds. The same cleanup was confirmed against an unsigned build (the device row showed `revoked_at` and no tokens). Tapping a thread on an iPhone did nothing in the shared shell (the collapsed split view's sidebar was buttons, not navigation links); `WorkspaceRootView` now binds the compact column.

### Review Focus items that only the live gate exercises

- **URL refusal on the Connect screen.** `HubURLTests` covers the rule; the Simulator run showed the screen refusing before any request (no screenshot of that step was kept).
- **The Simulator end to end** (hub, enrollment, push, mirror, live update): there is no other way to exercise it; it passed with the fixture agent as recorded above.

### Live on this Mac: the packaged app joined, with a real Codex turn (2026-10-31, evening)

| Step | How | Result |
| --- | --- | --- |
| Packaged app on this branch | `./Scripts/package.sh`, the running app quit, `dist/Agent Workspace.app` replaced, `agent-workspace coordinator restart` | Coordinator pid 76419 on the new bundle; `db status` shows `0001_init, 0002_changes, 0003_hub`, so the live store migrated in place (18 change rows kept) |
| Hub | Compose stack from `Hub/` with a local `.env`; `seed` and two `enroll` codes through the `migrate` service | `/readyz` current; org `cacheplane`, user `blove` |
| Mac join | `agent-workspace hub join http://localhost:8080 --name "Brian's MacBook Pro"` with the code on stdin | `hub status`: device enrolled, `unsynced 0`, first push 2026-11-01T01:52:39Z |
| Phone enrol | The iOS build on the booted iPhone 17 Pro Simulator, Connect screen, URL default and the second code | List showed the real `First Codex thread` (connection `Codex`) within one poll of the Mac's push; before the Mac joined the list was honestly empty |
| Real Codex turn | In the Mac app, opened the thread and sent `Reply with exactly one word: synced` (clicked Send; a plain Return in the composer inserts a newline through accessibility) | Codex answered `synced`; the Mac transcript, the phone's transcript, and `hub status` (`unsynced 0`, 39 changes on the hub) agreed within seconds |
| Hub rows | `psql` in the Compose database | `connections`: `authReference` NULL, `target` empty, `localServerId` NULL, `nativeScope` the account email (no `/`, so not hashed); `devices`: two active; `threads.context` is the thread's working directory `/Users/blove/repos/b4app` (owner's call pending) |
| Mac click-through | Threads, Connections (both runtimes `ready`, signed in), Local servers (`research` registered, stopped), Diagnostics (coordinator, runtimes, database path) | All four surfaces render and respond; the shared-shell change for iPhone has no visible effect on the Mac |
| Phone Send | Typed into the composer and tapped Send | Refused inline with `Writing from this device arrives in M8b; sending turns through the hub in M8c.` (`unsupported_capability`) |
| Phone Diagnostics | Diagnostics row | Sync section: hub URL, device `iPhone 17 Pro`, cursor 39, last sync time, unreadable rows 0 |

Found and fixed during this run: the iOS app died with `SIGTRAP` about two seconds after a relaunch and once during use. The crash reports show `LLA.Dynamic.color`'s dynamic colour provider being resolved by UIKit off the main thread (scene snapshot) while the closure was main-actor isolated by the module's default isolation. `LLA.Dynamic`, `LLA.Palette`, and the hex colour initialisers are now `nonisolated`; `ThemeTests.dynamicColorsResolveOffTheMainActor` resolves every palette colour from a detached task, and the nonisolated `Palette` makes a main-actor `Dynamic` a compile error. The rebuilt app survived relaunch and the Diagnostics screen.

### Not exercised (open gates)

- Real Claude or B4 threads through a hub (only the real Codex thread above); a second Mac.
- `hub leave`, the `database.restore` refusal while joined, uploaded history surviving a device revoke, the 1 MiB payload truncation, and the 401 suspension: `fixture-tested` only, never run live. The one revoke seen live was the Keychain-failure cleanup.
- A hub behind TLS, a `linux/amd64` image, any deployment other than the Mac's Compose, and a restore of a hub from a PostgreSQL backup.
- Rate limiting, byte-limited pull pages, and pruning (`resync_required` for a real stale cursor; M8a answers it for a negative cursor only, fixture-tested and never seen live): not built.

### Known limitations

- Disconnecting the phone is deleting the app; the hub device stays unrevoked (there is no Disconnect control to call the hub's revoke).
- The phone's thread header shows the Mac's working directory from `threads.context`. It is a project path, not an executable path, and it crosses the wire; the owner decides whether `threads.context` should sync.
- The shell shows Mac wording on the phone ("Coordinator connected"). When the last pull failed (hub down, token revoked, hub wiped) a one-line banner above the shell says "Not synced since <time>: <error>" and hides after the next successful pull (`MirrorSyncTests` covers the status callback; the banner was built for both app targets but not seen in the Simulator). A healthy phone still cannot tell that the Mac is asleep or offline: its pulls succeed and simply bring nothing, until M8c adds presence.
- New turns and runtime requests mirrored while a thread is open appear when it is reopened; only display items, threads, and connections are published live.
- No rate limit on `/v1/enroll`; `/v1/changes` pages have no byte limit; a value over 2 MiB in any column other than `displayItems.payload` and `runtimeRequests.payload` (both truncated over 1 MiB) would block the Mac's queue with a permanent 413, visible only in `hub status`.
- `linux/amd64` is unverified.

### Found during M8a, fixed separately

`database.restore` (M7) failed with `invalid input syntax for type json` on any archive whose change log held an `update` with a scalar jsonb value, because `Export.swift` wrote a jsonb scalar string bare and the restore reinserted it as raw text; `exportAndRestoreRoundTrip` missed it because its seed had no updates. Fixed on `main` by PR #18 (archive version 2, see the entry above).
