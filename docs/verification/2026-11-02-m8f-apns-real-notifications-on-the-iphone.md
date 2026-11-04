## 2026-11-02: M8f APNs, real notifications on the iPhone (D-141 to D-149)

Branch `blove/m8f-apns`, stacked on `blove/m8f-attention`. Plan `docs/superpowers/plans/2026-11-02-m8f-apns.md`. The suites below ran at `1bcb3b6` (the code head; this record is the next commit).

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Swift tests | `swift test` | Pass: 1268 tests in 160 suites. The first full run reported one issue, the timing-sensitive `B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting`, while the hub's `cargo test` was running on the same machine; it passed alone (1.6 s) and with its suite (15 tests) on rerun, and nothing else failed |
| Rust format and lint | `cargo fmt --all -- --check`; `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked` against the throwaway PostgreSQL 17.11 | Pass: 448 tests, 0 failed (`b4hub` 300, `b4hub-core` 31, `b4hub-db` 117), `push` among them (13 in `b4hub`, 28 in `b4hub-db`). `relay::presence_is_sent_when_the_queue_has_room_again`, a timing flake that failed on the base commit in the task reports, passed |
| Infra | `bats Infra/scripts/tests`; `terraform test` in `Infra/modules/hub`; `shellcheck` | Pass when the infra task finished at `7005c60`: 64 bats, 52 terraform tests, shellcheck clean, and with `INCLUDE_APNS_SECRETS=0` the rendered task definition is byte-identical to before. Not rerun for this record |
| Apps | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`; the same for `B4App-macOS -destination 'platform=macOS'` | `BUILD SUCCEEDED` (exit 0) when the iOS task finished, and again after its review fix at `1bcb3b6`. Not rerun for this record |
| After merging main (`ccb3377`) and the final review's fixes (`613159a`) | all of the above, plus `terraform test` in `Infra/bootstrap`, `tflint`, `terraform fmt -check` | Pass: `swift test` 1286 tests in 161 suites; `cargo test` 453 tests (the new `outcome_after_the_read_is_silent` among them), clippy and fmt clean; 64 bats; terraform 9 (bootstrap) and 52 (hub module); tflint, shellcheck (CI's file set) and `terraform fmt` clean; iOS Debug and Release Simulator and macOS builds `BUILD SUCCEEDED`. The merge broke two infra tests, since main's hub template now reads `apple_callback_scheme`; `b973dd9` passes it in the APNs render tests. |

What the new tests show, by the design's requirements:

| Requirement | Tests |
| --- | --- |
| The sender: headers, token, and Apple's answers | `Hub/crates/b4hub/tests/push.rs` against a fake APNs over HTTP/2: `alert_carries_jwt_topic_and_headers` (ES256 `kid`/`iss`/`iat`, `apns-topic`, push type, priority, collapse id), `withdrawal_is_background_priority_5`, `dead_token_is_deleted`, `expired_jwt_is_reminted_once`, `server_error_retries_once_then_drops`, `jwt_reused_within_50_minutes` (fixed clock); the `cli` unit tests `apns_config_names_missing_values` and `bad_key_refuses_to_start` (the variable is named, the key never echoed) |
| Keys, badge, and withdrawal payloads | `b4hub-core` `push::tests::fixture_cases` over `Tests/Fixtures/sync/push.json` (keys, badges, withdrawals; spool and plain payloads), `a_withdrawal_carries_no_alert_sound_or_badge`; Swift `ThreadLinkTests` decodes the same payloads |
| What ends a notification, once | `b4hub-db/tests/push.rs`: `answer_withdraws_once`, `expiry_withdraws`, `read_withdraws_earlier_turns_once`, `withdrawal_reaches_the_reader_too`, `deleting_a_thread_withdraws_its_notifications`; `b4hub/tests/push.rs`: `the_route_delivers_alerts_and_withdrawals`, `spool_writes_withdrawals` |
| The badge, one rule per language | `b4hub-db/tests/push.rs`: `badge_counts_needs_input_and_unread`, `bands_match_the_shared_fixture` (over `Tests/Fixtures/sync/attention.json`); Swift `MirrorNotificationsTests` (`needsYouCount`) |
| One device per token, dead tokens | `token_moves_to_its_new_device`, `delete_token_forgets_the_phone`, `delete_token_spares_a_newer_token`, `save_token_replaces` |
| The push environment | `PushEnvironmentTests` (Simulator, development and production profiles, none, unreadable) |
| The phone backstop's judging | `MirrorNotificationsTests` (a request answered or expired, a deleted thread, a read turn, same-`createdAt` ties by id, an archived thread ending nothing, unknown and malformed keys) |
| The capped wake and the parked sync | `MirrorSyncTests` suspension tests; `MirrorHost` and `AppDelegate` have no unit tests (the app target has no test target): reviewed twice and exercised in the live gate below |

### Live gate 1: the Simulator through APNs sandbox (2026-11-02, branch head `1bcb3b6`)

Setup, isolated from the owner's app: Compose project `b4hub-m8f` on `127.0.0.1:8081` (an image built from `a420d45`; the hub code has not changed since the infra task) with `B4HUB_PUSH_SENDER=apns`, key id `34GWB4MSB5`, team `GJJKL34HCT`, and the `.p8` mounted read-only from `~/.b4app/signing` (never printed; the hub logged `push sender` with `sender=apns` at start). The Debug build (local flavour) ran on the Simulator "M8f iPhone 17 Pro" (iOS 26.5, Xcode 26.6), signed in to that hub. The Mac was the scripted `macos` device (`macsim.py`: approve, answer, read), as in the M8f gate after the sign-in merge. Times come from the hub's log and the app's subsystem log.

| Exit item | Result |
| --- | --- |
| Token | Pass. The app registered `sandbox` from `PushEnvironment` (the compile-time Simulator) and an 80-byte token (a `push_tokens` row of 160 hex characters; not printed). |
| App in the background, a fixture approval notifies within five seconds, through Apple | Pass. The hub logged `APNs accepted` for kind `alert`, key `request:<id>`, status 200, with an `apns-id`, 0.19 s after it accepted the Mac's push. The banner "M8f approval check" / "Waiting for your approval" showed and the icon badge read 1 (the payload's badge). |
| Answering on the Mac | Hub side passes. APNs accepted the "Replied" alert (turn key, 200) and the withdrawal (`background`, key `request:<id>`, 200) within 40 ms of each other. |
| The withdrawal removes the notification | Not on the Simulator, as designed (D-148). SpringBoard logged "Content-available push notifications are only supported on-device for iOS, watchOS, and tvOS" for both the alert's `content-available` and the withdrawal (`pushType Background`, priority 5), so Apple's push cannot wake a Simulator app and the approval stayed in Notification Center while the app was in the background. |
| The backstop clears it on the next foreground sync (the design's fallback) | Pass. On bringing the app to the foreground it logged "removed 1 notifications that have ended" 1.6 to 2.5 s later: exactly the resolved request's notification (SpringBoard "Removing index ... request:r-t-gate-approval-3"), and it set the badge. |
| Reading a "Replied" removes it | Pass. APNs accepted a withdrawal for `turn:<id>` (200). With the app in the foreground the backstop removed the "Replied" 21 ms after the read reached the hub; with the app in the background it was removed 1 s after the next foreground. |
| The badge matches the list | Pass. 1 (one thread with a pending request), 2 (plus an unread reply), back to 1 after the reply was read; the remaining 1 is a request left pending by an earlier gate run, so that thread still needs input. |
| Notifications delivered before the slice | As expected, three notifications from the M8f spool carry no key (pre-slice payloads) and stayed: no rule can judge them (D-142). |

Screenshots (kept with the session; not committed): the approval with badge 1, the "Replied" with badge 1, the Simulator not waking, the final badge, and Notification Center at the end.

### Not exercised, and blocked

- The iPhone gate (live gate 2): passed 2026-11-03 (see that entry). It covers what the Simulator cannot: a withdrawal push waking the app on a device, a `production` token from a TestFlight build and `api.push.apple.com`, a tap on the lock screen, Low Power Mode, and the badge on a real icon.
- `api.push.apple.com` (production) and a 410/400 from the real Apple (dead-token deletion is fixture-tested against a fake APNs only); a provider-token expiry in the field (re-mint is fixture-tested with a fixed clock).
- The >1000-change catch-up case (D-146) and an overtaken suspend's owed reconcile (D-147), both parked and unreproduced.
- The hosted hubs: nothing applied to either AWS account.
