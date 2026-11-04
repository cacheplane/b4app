## 2026-11-03: Apple's web flow through an https callback (D-160)

Fixture gates only. Nothing deployed; the hosted hubs keep `B4HUB_APPLE_CALLBACK_SCHEME` until a Mac build with this ships.

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| `cargo test --workspace --locked` (throwaway PostgreSQL) | 462 pass. New: `config.rs` `the_web_flow_can_hand_back_to_an_https_url_instead`; `apple.rs` `a_hub_with_a_callback_url_hands_back_there`; `begin_web` now checks every web begin's `callback`; `auth_fixture` checks `httpsCallback` and `callback` |
| `swift format lint --strict`, `swift build` | Pass |
| `swift test` | 1294 tests; 1 failed in the full run, `SessionTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`, which this change does not touch and which passed 3 of 3 alone (it failed the same way in the D-140 run). New: `AccountCommandTests.appleStartsTakeTheHubsHttpsCallbackOnlyOnTheirSite`, `AppleSignInTests.theCallbackBecomesTheSessionsWait`; `AuthWireTests` round-trips both new fields |
| `helm unittest Hub/chart/b4hub`, `helm lint` with the CI values | 57 pass; lint clean; the schema refuses a `callbackUrl` with a query |

Live, 2026-11-03 (passed): see "Apple's web flow through an https callback, live" above.
