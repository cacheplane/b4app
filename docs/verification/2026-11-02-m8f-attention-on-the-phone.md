## 2026-11-02: M8f attention on the phone (D-121 to D-128)

Branch `blove/m8f-attention`, from main at `3f3cc15`. Plan `docs/superpowers/plans/2026-11-02-m8f-attention.md`.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Swift tests | `swift test` | Pass: 1255 tests in 158 suites after merging main at `ddc8db8`; one timing-sensitive Codex test (`reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`) failed once under load and passed alone |
| macOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iOS app and widget | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **`; Debug lists `remote-notification` and `fetch`, Release only `remote-notification` |
| Rust format and lint | `cargo fmt --all -- --check`; `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked` against the throwaway PostgreSQL 17.11 | Pass: 425 tests after merging main at `ddc8db8`, `push` among them (15 in `b4hub-db`, including soft-deleted rows and deleted threads never notifying) |

What the new tests show, by the design's requirements:

| Requirement | Tests |
| --- | --- |
| Which changes notify, the four phrases, the payload | `b4hub-core` `push::tests::fixture_cases` over `Tests/Fixtures/sync/push.json` (every request kind and state, every turn status and outcome, recent and old, titles); Swift `ThreadLinkTests` decodes the same payloads |
| Once per request or turn, other phones only, history does not notify | `b4hub-db/tests/push.rs`: `pending_request_notifies_each_other_phone`, `history_upload_does_not_notify`, `outcome_in_a_later_batch_notifies_once`, `retry_and_later_update_do_not_renotify`, `revoked_or_tokenless_phones_get_nothing`, `other_users_phones_are_not_told`; `rls.rs` isolates `push_tokens` and `notifications_sent` |
| The push-token route and the sender | `b4hub/tests/push.rs`: `push_token_requires_an_ios_device`, `push_token_validates_fields`, `push_token_saves`, `a_pending_request_reaches_the_sender_once`, `spool_writes_a_simulator_file`, `apns_refuses`; `cli` unit test for `B4HUB_PUSH_SENDER` |
| The mirror move and the read-only open | `MirrorLocationTests` (moves all three files, keeps both when the group has one, falls back without a group, undoes a partial move); `MirrorGlanceTests` (read-only open refuses writes and leaves an unmigrated file unchanged, reads beside an open writer) |
| The widget's timeline provider | `MirrorGlanceTests`: top three in attention order with project names, unlinked and missing-file glances, staleness at exactly five minutes, entry and reload dates |
| Opening a thread from a tap or a row | `ThreadOpenRequestTests` (cold launch opens after connect, events apply while the open is outstanding, latest request wins, survives an unavailable link) |
| Pausing before suspension | `MirrorSyncTests` suspension tests (no hub traffic while suspended, a long-poll cancelled promptly, a push in flight finishes first, a queued edit pushed after resume, stop while suspended) |

### After merging main's sign-in (PR #49 and through PR #52)

The App Group, URL scheme, and widget became per flavour (D-125); the account owns the sync, so the host suspends it through `MirrorAccount.suspendSync()` (D-127); a hub deletion of an account removes its `push_tokens` and `notifications_sent` rows, and only phones holding a session token are told.

| Check | Result |
| --- | --- |
| `swift format lint --strict`, `swift build` | Pass |
| `swift test` | 1203 tests in 148 suites; one known failure on main, `MirrorAccountTests.a401OnSyncSignsThePhoneOut` (FakeHubAPI's parked long poll is not woken; fixed separately) |
| `cargo fmt --check`, `cargo clippy -D warnings` | Pass |
| `cargo test --workspace --locked` | Pass: 422 (`b4hub` 291, `b4hub-core` 28, `b4hub-db` 103) |
| `xcodebuild` for the Simulator: `B4App-iOS` Debug, Release, Release-Local; `B4App-iOS-Beta` Debug-Beta, Release-Beta; `B4App-macOS` | Six `** BUILD SUCCEEDED **`. Each iPhone app embeds `PlugIns/B4App-iOSWidget.appex`; the app's and the widget's `B4AppAppGroup` and entitlement group are the flavour's (`group.com.cacheplane.b4app.local` for Debug and Release-Local, `group.com.cacheplane.b4app` for Release, `….beta` for the Beta configurations), the widget id is the app's plus `.widget`, and `UIBackgroundModes` is `remote-notification` and `fetch` in Debug only |

The live gate was not rerun after this merge.

### Live gate (Simulator)

Setup, isolated from the owner's app, the Compose hub on port 8080, and the sign-in session that last started it: a separate Compose project `b4hub-m8f` from this branch's `Hub/` on `127.0.0.1:8081` with its own image tag and volume and `B4HUB_PUSH_SENDER=spool` into a scratch directory; a scratch debug coordinator (`B4APP_RUNTIME_DIR`, `B4APP_DATA_DIR`) joined to it with a fixture Codex connection (`fake-codex.py`, where a turn saying "approve" asks for a command approval); a new Simulator "M8f iPhone 17 Pro" (iOS 26.5) running the branch's Debug build, paired through a `b4app://pair` link; `Scripts/sim-push.sh` with `B4APP_SIM_DEVICE` set to that Simulator. Times are UTC from the hub's request log and the spool file names; `sim-push.sh` prints whole seconds.

| Exit item | Result |
| --- | --- |
| Token registration | Pass. After "Allow", the phone's `POST /v1/devices/self/push-token` answered 204 (17:55:15Z) and `push_tokens` held one `sandbox` row for `com.cacheplane.b4app.ios` (160 hex characters; the token itself was not printed). |
| App in the background, a fixture approval on the Mac notifies within five seconds | Pass. The Mac's push completed at 17:55:33.223Z, the spool file is stamped 17:55:33.223, and `sim-push.sh` sent it in the same second. Notification Center showed "M8f approval check" / "Waiting for your approval". |
| A finished turn notifies | Pass. Answering the approval on the Mac (`request respond --accept`) completed the turn: hub 17:57:02.352Z, banner "M8f approval check" / "Replied" in the same second. |
| Tapping opens the thread | Pass for a banner: tapping the "Replied" banner opened "M8f approval check" at its transcript. Not shown: a tap on the lock screen's notification list did not respond to the Simulator's synthetic touches (the system "Open" swipe action appeared but did not launch). |
| The widget shows the three most urgent threads | Pass. The medium widget, added from the gallery, listed the three threads with the project "work"; the small one showed the same in the gallery. |
| The widget updates after the notification | First run failed: SpringBoard refused the background launch ("this app doesn't declare the proper UIBackgroundMode"), because `simctl push` wakes through background fetch (D-128). After adding the `fetch` mode, with the app in the background: a "Replied" push (hub 18:03:00.105Z) and a new approval on another thread (18:03:04.282Z) each woke the phone, which pulled at 18:03:00.835Z and 18:03:04.581Z; the widget moved "M8f quiet thread" to the top with the needs-input dot and showed "M8f reply check" as unread. No launch was refused. |

Screenshots: notification, banner, the thread opened from it, the widget before and after (kept with the session; not committed).

### Live gate again, after merging sign-in (2026-11-02, 12:05 to 12:19 PST)

The phone code changed in the merge (flavours, accounts), so the gate ran again on the merged branch: the Debug build (local flavour, `com.cacheplane.b4app.ios.local`, App Group `group.com.cacheplane.b4app.local`) on the same Simulator, against a fresh `b4hub-m8f` stack built from the branch. The Mac was played by a script that enrolled a `macos` device with an enrollment code and pushed the rows a coordinator uploads (a connection, a project, three threads, then a turn with a pending command approval and its answer), because the merged debug coordinator now asks for Keychain access to the hub token and that prompt was not answered. The hub, the spool, `sim-push.sh`, and the phone were the real ones.

| Exit item | Result |
| --- | --- |
| Sign-in and token | Pass. "Use an enrollment code" signed the phone in; after "Allow" the hub held one `sandbox` token for `com.cacheplane.b4app.ios.local`. |
| App in the background, an approval notifies within five seconds | Pass. The push returned at 12:07:07.994 (spool file 12:07:07.990) and `sim-push.sh` finished sending at 12:07:08.900; the banner read "M8f approval check" / "Waiting for your approval". |
| Tapping opens the thread | Pass. From the background, a "Replied" banner tapped while it showed opened "M8f quiet thread" (12:19); in the foreground a banner tap and `xcrun simctl openurl b4app-local://thread/<id>` opened theirs. A first attempt seemed to fail; the SpringBoard log showed the tap had landed on the widget after the banner timed out, and a widget row tapped from the background opened its thread. |
| The widget shows the top three and updates | Pass. The medium widget (from the flavour's group) listed the three threads with the project "gate", moved "M8f approval check" to the top with the needs-input dot behind the first banner, and showed "M8f quiet thread" as unread behind the "Replied" banner, both while the app was in the background. |

The approval card read "cannot be answered here" because the script's request payload lacks fields a real Codex approval carries; it does not bear on M8f.

### TestFlight export with entitlements (D-129), 2026-11-02

`B4APP_UPLOAD=0 ./Scripts/upload-ios.sh` (prod, build 2611022136) archived, attached the entitlements, exported with cloud-managed signing (`Apple Distribution: Brian Love`), and passed the new check: the app is signed with `aps-environment` (`production`), `com.apple.developer.applesignin`, `com.apple.developer.associated-domains` (`webcredentials:b4.run`, `applinks:b4.run`), and `com.apple.security.application-groups` (`group.com.cacheplane.b4app`), the widget with the App Group. App Store Connect validation reported no errors; nothing was uploaded. The same check run against an export made the old way reports all four entitlements missing. The profiles came from the export, refreshed after the portal gained the App Groups, push, and the widget App ID (`iOS Team Store Provisioning Profile: com.cacheplane.b4app.ios` and `….ios.widget`, valid to 2027-11-01); Xcode first reused a stale cached app profile without them until it was moved aside. The beta flavour passed the same way (`B4APP_FLAVOR=beta`, the app's App Group `group.com.cacheplane.b4app.beta` and site domain `test.b4.run`), and the owner then uploaded beta build 0.1.0 (2611022211) to TestFlight with the fixed script at 14:15 PST (altool: upload succeeded with no errors).

### Not exercised, and blocked

- APNs, a real iPhone, and TestFlight: `blocked` on the deploy slice (Developer Program key, the App Group, push capability, and the widget's App ID on the portal). `B4HUB_PUSH_SENDER=apns` refuses to start.
- The "as of" label on the widget (fixture-tested only); `0xdead10cc` termination, which the Simulator does not enforce; a tap on a lock-screen notification.
