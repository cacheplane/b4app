## 2026-11-01: M8b organisation (fixture gates; live gate pending)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6), run from the worktree `feat/m8b-organisation` at `2cedd55` (the head of Tasks 1 to 12) before this documentation commit. **Only the fixture gates are recorded here. The live gate (the owner's packaged app, the Compose hub, and the Simulator) has not been run, and nothing below is a live result.** The owner's running Agent Workspace app, its LaunchAgent, `~/Library/Application Support/b4app`, and the Compose stack were not touched.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 517 tests in 89 suites in 36.4 s (324 tests at the end of M8a). The first full run reported 1 issue in 517 tests: `MirrorSyncTests.offlineEditsWaitAndDrainWhenTheHubReturns` (`MirrorSyncTests.swift:185`, `lastError == nil`), a timing flake under load (the PR #19 class, a 10 s wait). `swift test --filter MirrorSyncTests` alone passed (13 tests), and a second full run passed with no issues |
| Project | `./Scripts/generate-project.sh` | `B4App.xcodeproj` regenerated from `project.yml` |
| macOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Rust format | `cd Hub && eval "$(./scripts/test-db.sh)" && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked`, then `./scripts/test-db.sh --stop` | Pass: 117 tests against a real PostgreSQL 17.11 (77 at the end of M8a): `b4hub` 51 (unit 22, `changes` 14, `enroll` 10, `health` 5), `b4hub-core` 19, `b4hub-db` 47 (unit 3, `changes` 34, `migrate` 7, `rls` 3) |
| CI | the Swift package job, the apps job, and the Ubuntu `hub` job | Recorded in the PR for `feat/m8b-organisation`, not here |

### Exit items the fixtures cover

| M8b exit item (design) | Fixture evidence | Not covered by fixtures |
| --- | --- | --- |
| 1. Sidebar and phone list in attention order; an approval moves its thread to the top within one poll; answering it moves it to unread; opening it on the phone makes it quiet on both | `Tests/Fixtures/sync/attention.json` run against the coordinator's store (`ActivityQueryTests`), the mirror's store (`MirrorActivityTests`), `Attention` (`AttentionTests`), and the model (`AttentionModelTests`, `ThreadListTests`); `markRead` and its guard in `ProjectServiceTests` | The timing within one poll, and both screens, against the real stack |
| 2. A phone rename, pin, archive, project rename, and draft show on the Mac, and the reverse | Hub: `phone_title_edit_applies_and_later_mac_edit_wins`, `a_phone_may_insert_a_draft_and_clear_it`; Mac: `HubPullTests`, `RemoteApplyTests`; phone: `MirrorWritesTests`, `outboxIsPushedThenPulledBack` | The same through the Compose hub with the owner's joined app |
| 3. Convergence: both devices rename one thread and edit one draft while the hub is down, the Mac later; both converge on the Mac's values, and on the phone's with the clocks reversed | The shared `conflicts.json` (`conflictFixtureMergesToTheExpectedValues`, both orders, in the Swift suites; the Rust suite decodes the same file), `stale_phone_edit_loses`, `offlineEditsWaitAndDrainWhenTheHubReturns` | The live run with `docker compose stop hub` |
| 4. A cursor below a pruned horizon resyncs from `/v1/snapshot` without losing an outbox row | `stale_cursor_gets_resync_and_snapshot_restores`, `a_pruned_cursor_resyncs_through_the_snapshot_over_http`, `staleCursorResyncsFromSnapshotWithoutLosingLocalRows`, `resyncUsesTheSnapshot`, `snapshotKeepsTheOutbox`, `aSnapshotClockNewerThanAnUnsentEditWins` | A prune of the real hub |
| 5. A phone change to a Mac-only column is refused; no hub row holds a secret, path, or pid | `phone_cannot_write_mac_only_columns`, `connection_secrets_are_scrubbed_even_if_sent` | A look at the real hub's tables after the live run |
| 6. `cargo test`, `swift test`, and both app builds pass | Above, locally | CI |

### Live gate: run 2026-11-01 (see "M8b live gate" above; the table below is the procedure as planned)

To be run only after the owner's go-ahead, because it rebuilds the owner's packaged app and migrates the owner's real local store (to `0004`) and the Compose hub's volume (to `0003`); both migrations are hard to reverse. First: `agent-workspace db backup` and a `pg_dump` of the hub volume. Then rebuild the hub image and bring the stack up from the branch's `Hub/` (`/readyz` must show `"migrations":"current"`), `./Scripts/package.sh`, quit the app, `agent-workspace coordinator restart`, reopen, and run the three items below in the iPhone 17 Pro Simulator with a fixture approval (or a real Codex command approval), recording each with timings. Fill this table in; leave a row `not run` until it is.

| Exit item | Procedure | Result |
| --- | --- | --- |
| 1. Attention order on both devices | Open the Mac sidebar (Pinned and per-project sections) and the phone's list with the project filter. Start a fixture turn that opens an approval: the thread must move to the top on both within one poll interval. Answer it on the Mac: it moves to unread. Open it on the phone: it becomes quiet on both | not run |
| 2. Phone and Mac edits show on the other | Rename a thread on the phone, pin one, archive one, rename a project, and type a draft: each shows on the Mac within one poll interval. Then do the reverse | not run |
| 3. Live convergence | `docker compose stop hub`; rename the same thread and edit the same draft on both devices, the Mac's edit later; `docker compose start hub`; both must show the Mac's values (and, with the phone's edit later, the phone's) | not run |

Also record for the live run: `agent-workspace hub status` shows `unsynced 0`; `agent-workspace coordinator status` shows a pid started after the restart; a screenshot of the Simulator list and the Mac sidebar; and that the owner's app, once restored from `main`, is rebuilt with the same dev loop.
