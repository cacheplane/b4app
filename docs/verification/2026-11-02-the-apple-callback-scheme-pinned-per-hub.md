## 2026-11-02: The Apple callback scheme pinned per hub (D-114, D-140)

Fixture gates only, run on the build MacBook Pro from the worktree branch. Nothing was deployed: the hosted hubs pick this up with the next deploy (test on merge, prod with a `hub-v*` release).

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| `cargo test --workspace --locked` (throwaway PostgreSQL) | Pass apart from one relay timing flake. New: `config.rs` `the_web_flow_names_its_one_callback_scheme`; `apple.rs` `web_begin_refuses_another_flavours_scheme`, `the_callback_redirects_to_the_configured_scheme`. Run on a private cluster (port 54341), because another worktree's run on the shared 54329 cluster raced sqlx's setup database (`duplicate key … _sqlx_test_…`). `relay.rs` `presence_is_sent_when_the_queue_has_room_again` failed once, then passed 2 of 3 reruns alone: it waits with sleeps and touches no Apple code. |
| `swift build`, `swift format lint --strict` | Pass |
| `swift test` | 1208 tests: 7 failed in the full run, all timeouts or wall-clock checks (`MirrorSyncTests` ×4, `MirrorRelayTests.presenceBecomesHostPresenceEvents`, `PairLinkTests.aScanDuringASlowLogOutKeepsTheNewAccount`, `PairingTests.pairIsRoutedAndNeverReplayedFromTheOperationCache`, `SessionTests.reconcileSettles…`), while other sessions' builds loaded the Mac (single tests took over 117 s). Rerun alone with `AccountCommandTests`: 58 tests in 8 suites pass, including the new `appleStartsShowTheHubsSchemeRefusal`. No Swift source changed. |
| `bats Infra/scripts/tests/` | 52 pass (`render.bats` and `deploy.bats` check `B4HUB_APPLE_CALLBACK_SCHEME`: `b4app-beta` for test, `b4app` for prod) |
| `terraform test` on `Infra/modules/hub/tests/ecs.tftest.hcl` (mocked provider) | 20 pass |
| `helm unittest Hub/chart/b4hub`, `helm lint` with the CI values | 56 pass; lint clean; the schema refuses a `callbackScheme` off the list |

Open: confirming on `hub.test.b4.run` after the merge's deploy that a web begin with `scheme: "b4app"` is refused and `b4app-beta` is accepted; then the same on `hub.b4.run` after the release, with the schemes swapped.
