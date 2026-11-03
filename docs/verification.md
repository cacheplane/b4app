# Verification record

Gate results and unresolved checks, newest first. Each entry names what was exercised, how, and what remains open. Live checks are only those run on the target Mac against real runtimes.

## 2026-11-03: A dropped B4 stream's second part waits for the reattach

A fixture-only change. No test or assertion changed.

- **`B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting`.** Under 10 CPU burners it failed at line 241 (`deltas(turnId: "turn-1") != "Part one. Part two."`), and in CI it timed out. `fake-b4.py`'s "drop" run closed the response and emitted "Part two." 1 s later. A reattach to a live run gets only frames emitted after it attaches, and a reattach after `done` gets `live: false` and none, so the test assumed the adapter's reattach (backoff 250, 500, 750 ms) landed within 1 s. Adding 1.5 s to that backoff reproduced it every time, at line 241. The real server behaves the same way: `RunControl::subscribe` (`crates/b4-http/src/control.rs`) hands a live attach a `state` cut and only later frames, and `attachment.rs` answers a finished run with `live: false` and `done { output: null }`. So the replay rules stay as they are, and the "drop" run now holds "Part two." until a reattach subscribes (20 s cap) instead of sleeping 1 s. With the same 1.5 s added, the test passes.

Runs (10 CPU burners, test bundle run 4 at a time through `swiftpm-testing-helper` so the runs share no SwiftPM lock):
- **Old fixture:** 0 failures in 100. The natural window is narrow; the added delay is the reproduction.
- **New fixture:** 0 failures in 200 (0.9 to 3.4 s each).
- **Suites:** `swift test --filter "B4AdapterTests|CoordinatorTests"` (346 tests) passed. An earlier pass failed `AccountManagerTests.hub401SignsOut` once with "The store is closed." (`AccountManagerTests.swift:410`). That test uses no fake B4 server, and it passed 3 times alone (open, not fixed here).
- **Gates:** `swift format lint --strict` is clean.

## 2026-11-03: M8c loose ends (Already answered, Camera pair link, beta passkeys)

Branch `blove/drop-already-answered`.

- **"Already answered" dropped (D-154).** The owner chose to drop the copy over a "Your Mac answered first" notice. Fixture: `SendStateTests.aStaleAnswerClearsQuietly`, `MirrorModelTests.theMacAnsweringFirstTakesTheCardAwayQuietly`. Full `swift test`: 1293 tests. Two failures outside the change passed when re-run alone: `B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting` and `LifecycleTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`.
- **The iPhone Camera app opening a pair link.** The owner's iPhone (TestFlight beta 2611030054, already paired and connected) and the Beta Mac app (`9140cf5`) on `https://hub.test.b4.run`. Before the run, `https://test.b4.run/.well-known/apple-app-site-association` and Apple's CDN copy (`app-site-association.cdn-apple.com/a/v1/test.b4.run`) both served `applinks` for `GJJKL34HCT.com.cacheplane.b4app.ios` on `/pair`, and `webcredentials` for that app and `GJJKL34HCT.com.cacheplane.b4app.beta`.
  1. On the Mac: Settings → Remote access → Pair iPhone….
  2. The owner scanned the code with the system Camera and tapped its banner. Agent Workspace opened (`onContinueUserActivity`) with the pairing offer.
  3. Pair answered "This iPhone is already paired" (`merge_refused`, `same_account`, D-098), and the phone stayed paired.

  Pass. The owner expected a paired phone's offer to say "already paired" before the tap. By design it cannot: nothing is sent until Pair (D-066, D-110), and the code does not tell the phone which account it belongs to. Knowing up front needs a hub check that does not spend the code; the owner made that a separate task.
- **Rebuilt for the step-up.** The test hub serves D-150's step-up, and both earlier beta builds predated it. With the owner's go-ahead, both were rebuilt from this branch (`419b7d8`, main `5882a60` plus the D-154 change):
  - The Beta Mac app: `B4APP_FLAVOR=beta B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY=… ./Scripts/package.sh`, swapped into `~/repos/b4app/dist` with its coordinator booted out first. It came back with the same device and account, and the relay connected.
  - The iPhone app: TestFlight beta 0.1.0 (2611030608), by `B4APP_FLAVOR=beta ./Scripts/upload-ios.sh`.
- **A passkey on the Beta Mac app.** The first try failed. The Apple step-up passed and the hub's `passkeys/begin` answered 200, but the system passkey request ended without a sheet.
  - `sudo swcutil show` had a `webcredentials` entry for the Local app (`local.b4.run`, approved) and none for `com.cacheplane.b4app.beta`. In six hours of `swcd` logs, test.b4.run's association file was never fetched.
  - The app's signature and its embedded `app-beta` profile were correct (`webcredentials:test.b4.run`; the profile allows `associated-domains: *`), and so was the site's file.
  - The cause: LaunchServices had seven bundles registered for `com.cacheplane.b4app.beta`. Six were Xcode `Debug-Beta`/`Release-Beta` products in DerivedData folders (other worktrees, scratchpads, CI evidence), signed without the entitlement. `swcd` evidently read one of those for the bundle id, so it saw no associated domain.
  - The fix: `lsregister -u` on the six build products, then `lsregister -f` on the `dist` app. `swcd` synced and fetched `test.b4.run` from Apple's CDN within a second.
  - The second try passed: Settings → Account → Add passkey, the Apple step-up, then the macOS sheet saved the passkey. Log out, then Sign in with passkey, signed back in to the same account (`u-tvedt5h6@o-cxzqzfmn`, same device), and the relay reconnected.
  - Anyone building beta or prod in Xcode on the Mac they run the packaged app on can hit this again. Unregister the build products, or keep Xcode's products out of LaunchServices.
- **A passkey on the iPhone (build 2611030608).** Settings → Account → Add passkey asked for the Mac's passkey, which iCloud Keychain had synced, for the step-up, and that passed. The add then said "This device already has a passkey for this account." and made nothing: the hub lists the account's passkeys in `excludeCredentials`, and the phone already holds the synced one (a known limitation in `docs/milestones.md`). The phone then logged out and signed back in with that passkey, to the same account, still paired with the Mac. Pass.
- During the session, a deploy of the test hub stopped its only task at 05:51Z and served 503 until 05:53:20Z. The Beta Mac's relay reconnected by itself at 05:53:30Z.


## 2026-11-03: Step-up by enrollment code, live (D-151, D-152)

Run on the owner's MacBook Pro from main `2338c2e` (#81 merged), by the build session alone: no Touch ID was needed, and the owner's Mac stayed signed in to cacheplane throughout. No other session was running; only the Local app, the Compose hub (`hub-hub-1`), and the Local iPhone app on the iPhone 17 Pro Simulator were touched (the Beta and prod apps and the M8f Simulator were left alone).

**What was rebuilt**
- **The Compose hub.** `b4hub:local` from `2338c2e` (the cached `rust:1.93.1` tag in place of the pinned digest, as before; the repository's Dockerfile is unchanged); `migrate` applied 0015 ("migrated: 15 applied, 0 pending") and `/readyz` was ok. The old image is tagged `b4hub:local-before-step-up-live`.
- **The Local app.** `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh` in a scratch checkout; the old app and `agent-workspace db backup` (774 rows) are in `~/Library/Application Support/b4app-signin-gate-backups/20261103T193308Z-step-up-live/` with a `pg_dumpall` of the hub. Every other LaunchServices registration of `com.cacheplane.b4app.local` was unregistered first.
- **The iPhone.** The local flavour from `2338c2e` (`B4App-iOS`, Debug) on the iPhone 17 Pro Simulator, iOS 26.5.

**Found on the way: Docker Desktop's disk was full.** The image build filled the Docker VM's disk (58 GB, 0 free), and the hub's PostgreSQL crash-looped in recovery ("could not write to file \"pg_logical/replorigin_checkpoint.tmp\": No space left on device"); the first `pg_dumpall` failed for that reason. `docker builder prune` freed the 17.6 GB of unused build cache (no images, volumes, or containers were removed), PostgreSQL finished its recovery by itself ("database system is ready to accept connections"), the backup was taken, and only then was the hub migrated and started. The Mac's disk had 760 GB free; the limit is Docker Desktop's own disk.

| Check | Result |
| --- | --- |
| Codex's "no rollout found" counts as gone (D-152) | Pass. The four Codex deletes left from the thread cleanup had been waiting with `lastError` "no rollout found for thread id …" for 20 attempts each; at their next retry (19:46:20Z) the new coordinator marked them done: `threadDeletes` 13 done, 0 waiting |
| An enrollment code confirms a change when no passkey can (D-151) | Pass, on the iPhone. A throwaway operator user ("Code Check", seeded) was given a passkey row copied from another with a fresh random credential id and user handle, so no device holds it, the state of an account whose passkey was deleted from the keychain. The Simulator logged out of cacheplane and signed in to it with "Use an enrollment code". In Settings → Account, Delete account… with the org name typed asked iOS for the passkey: iOS found none and offered another device ("Bluetooth Off", then "Scan QR Code"); closing it showed, in the still-open delete sheet, "Can't confirm it's you here? Enter an enrollment code from your hub's operator." with a field, Confirm, and Cancel. A wrong code showed "That code didn't work. A code works once and expires; ask your hub's operator for a new one." and kept the row (hub: `401` "a step-up code was refused"). A real `enroll` code, typed in mixed case, stepped up ("stepped up", method `code`), but the delete was refused `409 shared_org`, because a seeded org is shared (D-107), not a fault of the code; after the throwaway org was marked personal and owned by its user, a fresh code stepped up again and the hub "deleted an account" (`204`), and the phone returned to the sign-in screen. The hub then held only cacheplane (1 user, 1 passkey), and the phone was paired back to cacheplane by link |
| A passkey sheet that cannot open says what to do | Not seen live: no sheet failed with 1004 during the run (fixture-tested only) |

## 2026-11-03: Two more flaky tests now wait for what they depend on

Test-only changes. No assertion is weaker.

- **Rust `instances::readiness_reports_a_stale_heartbeat`.** The `settle()` fix above covered the pause. CI then failed the test's *first* `/readyz` (503 where 200 was expected, run 41553837650). With the test's 200 ms beat, the liveness window is 800 ms. A loaded runner can stall the heartbeat writes for longer than that, so the instance already reports `"instances": "stale"` before anything is paused. Reproduced locally (`"instances":"stale"`, 1 run in 15 of the `instances` binary under 30 CPU burners). The test now waits (`eventually`) for a fresh heartbeat before it pauses, as its last step already did. The probe test in the same file (`the_probe_passes_…`) asserts `"instances": "ok"` with the same window, so it now runs on the default 5 s heartbeat; it is about the relay, not the heartbeat.
- **`LifecycleTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`.** The fake B4 "slow" run ends on its own after 3 s. The test needs that end to happen after `h.stop()`. Under load, the stop took longer (the CI run took 44 s), so the first coordinator saw the run finish and marked the turn `terminal` (`SessionTests.swift:1216`, run 41561882799). A 4 s pause before `h.stop()` reproduced it every time. `fake-b4.py` has a new "held" run that ends only on `POST /threads/<id>/release`, a fixture control. The test releases the run once the coordinator is down, and still passes with that 4 s pause.

Runs:
- **Rust:** 15 alone. 25 of the whole `instances` binary under 30 CPU burners. 10 alongside a parallel `cargo test --workspace`, which passed.
- **Swift:** 10 alone. 10 inside `swift test --filter CoordinatorTests` (297 tests each, all passing), 5 of them with 12 CPU burners.
- **Gates:** `swift format lint --strict`, `cargo fmt --check` and `cargo clippy -D warnings` are clean.

Environmental, not this flake:
- `#[sqlx::test]` names each test's database by hashing its path. Two processes running the same test on one server drop each other's database ("database … does not exist", or a failed `Db::connect`).
- `test-db.sh --stop` from another worktree ends every run on port 54329.
- These runs used private clusters on other ports.
## 2026-11-03: Apple's web flow through an https callback (D-160)

Fixture gates only. Nothing deployed; the hosted hubs keep `B4HUB_APPLE_CALLBACK_SCHEME` until a Mac build with this ships.

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| `cargo test --workspace --locked` (throwaway PostgreSQL) | 462 pass. New: `config.rs` `the_web_flow_can_hand_back_to_an_https_url_instead`; `apple.rs` `a_hub_with_a_callback_url_hands_back_there`; `begin_web` now checks every web begin's `callback`; `auth_fixture` checks `httpsCallback` and `callback` |
| `swift format lint --strict`, `swift build` | Pass |
| `swift test` | 1294 tests; 1 failed in the full run, `SessionTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`, which this change does not touch and which passed 3 of 3 alone (it failed the same way in the D-140 run). New: `AccountCommandTests.appleStartsTakeTheHubsHttpsCallbackOnlyOnTheirSite`, `AppleSignInTests.theCallbackBecomesTheSessionsWait`; `AuthWireTests` round-trips both new fields |
| `helm unittest Hub/chart/b4hub`, `helm lint` with the CI values | 57 pass; lint clean; the schema refuses a `callbackUrl` with a query |

Open (live): Continue with Apple through `.https(host:path:)` with a Mac build that has this, against the test hub set to `B4HUB_APPLE_CALLBACK_URL=https://test.b4.run/app/auth/apple`. Whether `ASWebAuthenticationSession` takes the result back through the app's `webcredentials:test.b4.run` association can only be shown there.

## 2026-11-02: Step-up by enrollment code (D-151), Codex "no rollout found" (D-152), and the 1004 line

Branch `blove/step-up-code`, from main at `5882a60`. Fixture gates only; nothing here has run live.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass (exit 0) |
| Build | `swift build` | Pass |
| Swift tests | `swift test` (PostgreSQL from the main checkout's `.build/postgres`) | 1300 tests in 161 suites; the new and changed tests pass (`AccountCommandTests.anEnrollmentCodeConfirmsADelete`, `MirrorAccountTests.anEnrollmentCodeConfirmsAChange`, `AccountSettingsTests.aClosedConfirmationOffersAnEnrollmentCode`, `anEnrollmentCodeConfirmsRemovingAndAdding`, `aPasskeySheetThatCannotOpenIsOneLine`, `SignInTests.aPasskeySheetThatCannotOpenSaysWhy`, `everySystemCancelOfAnAssertionMeansNoPasskey`, `AuthWireTests.stepUpCodeRoundTripsAndNeverDescribesTheCode`, `HTTPHubAPITests.stepUpCallsSendTheBearerAndTheirBodies`, `CodexDeleteTests.noRolloutFoundIsAlreadyGone`). The full run had 2 issues, both in `HubSyncTests.joinPushesTheBacklogAndMarksItSynced` (the timing flake the sign-in gate recorded); it passed three times alone |
| Rust format | `cd Hub && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `source <(./scripts/test-db.sh) && cargo test --workspace --locked --no-fail-fast`, then `./scripts/test-db.sh --stop` | Pass: 464 tests against PostgreSQL 17.11, 0 failed. New: `accounts.rs` `an_operator_code_steps_up_once_on_its_own_device`, `a_step_up_code_is_the_callers_own_operator_code`, `step_up_codes_count_with_the_sign_in_finishes`; `auth_fixture.rs` decodes `stepUpCode` and sends it to the route; `b4hub-db` `an_operator_code_is_taken_once_by_its_own_user`, `migrate.rs` expects 15 migrations; `maintenance_pauses_sign_in_and_account_writes` and `no_secret_in_logs` cover the new route |
| Apps | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` and `-scheme B4App-macOS -destination 'platform=macOS'`, `CODE_SIGNING_ALLOWED=NO` | Two `** BUILD SUCCEEDED **` (the code field's iPhone keyboard modifier compiles only there) |

Not run live: a code step-up against a running hub, and Settings → Account's code row on screen. The Codex fix matches what codex-cli 0.166.0 answered live during the thread cleanup (four `thread/delete` calls, each `-32600 no rollout found for thread id …`; none of the ids among Codex's 383 threads).

## 2026-11-02: The attention burst test waits out a slow runner

`AttentionModelTests.aBurstOfDeltasSendsNoReadAndTurnEventsCoalesce` failed CI once on main (`7c38573`): three `thread.read` calls where it expected two. The model reads the test's 56 events on its own task, and a slow runner took longer than the 200 ms refetch window to get through them, so a second window rightly opened. `WorkspaceModel.refetchDelay` is now per model (as `draftSaveDelay` is), so the test widens its own window to 1 s without changing the others'; the app keeps 200 ms. Local: the test 5 of 5 alone, `WorkspaceUITests` 284 pass, `swift format lint --strict` clean.

## 2026-11-03: M8f APNs on a real iPhone (live gate 2) and the cancelled-BEGIN fix (D-153)

Target: Brian's iPhone with the beta TestFlight build 0.1.0 (2611030437, uploaded from `main` at `5882a60` with `Scripts/upload-ios.sh`, beta flavour), signed in to `hub.test.b4.run`; the test hub at task definition revision 16 (`B4HUB_PUSH_SENDER=apns`, the three APNs secrets set per runbook 3a, `INCLUDE_APNS_SECRETS=1` from #76); the Mac side was the packaged beta Mac app on the build Mac, driven in the background, with a Claude Code connection added through its bundled `agent-workspace` (its Codex follows `~/.codex/config.toml`, `approval_policy = "never"`, so Codex never asks). Evidence is the test hub's CloudWatch log (`APNs accepted`, kind, key, status 200, `apns-id`), never a token or payload.

- The new build registered its token on first launch (05:45:44 UTC). A notification the earlier build had left behind (an approval answered while that build had no withdrawal code) was removed by the new build's backstop when it opened.
- An approval from the Mac (`curl -sI https://example.org` under Claude Code's default permission mode) reached the locked iPhone's lock screen through `api.push.apple.com` (alert accepted 05:46:01). Answering it on the Mac withdrew it (background push accepted 05:46:29, the phone woke and pulled), and it left the lock screen; the badge matched the list (1: an unread reply, nothing waiting).
- "Replied" arrived (05:46:30); tapping it opened the thread in the app, and the phone's read withdrew it (accepted 05:48:55, after the retry below). Earlier, a Codex turn's "Replied" was withdrawn by the Mac reading it (05:34:22 alert, 05:34:31 withdrawal).
- With the earlier build (2611022211) installed, the same pushes arrived and woke the app, but its approval stayed: that build has no withdrawal code. Recorded so the cause is not mistaken for a delivery failure.
- Found during the gate: at 05:46:37 the test hub's pool kept a connection inside a read-only transaction that sqlx did not know about (D-153), and the phone's read failed with "current transaction is aborted" until a retry reached a good connection. Restarting the test service (`aws ecs update-service --force-new-deployment`) cleared it; no error in the minute after. Prod's log has none in two days.
- The fix, at this branch's head: `cargo test --workspace --locked` 464 passed, 0 failed (the new `tests/cancel.rs`: 4, and its three cancellation tests failed on `main` before the change, 3 of 3; 5 repeated runs passed); `cargo clippy --workspace --all-targets --locked -- -D warnings` and `cargo fmt --all -- --check` clean.
- Not exercised: Low Power Mode, an app swiped away in the switcher (the backstop then clears notifications at the next launch, D-146), prod (`hub.b4.run` runs hub-v0.1.0, which predates the APNs code; it sends through Apple after the next release).

## 2026-11-02: Sign-in polish, live (D-132, D-133)

Run on the owner's MacBook Pro from main `8e7a4ca` (#68 merged), with the owner at Touch ID for the passkey step and the build session driving the apps.

**What was rebuilt**
- **The Local app.** `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh` in a scratch checkout of `8e7a4ca`; the package carries `webcredentials:local.b4.run`. Before the swap: `agent-workspace db backup` (746 rows) and the old app, both in `~/Library/Application Support/b4app-signin-gate-backups/20261103T042407Z-polish/`; the old coordinator was stopped with `coordinator stop`. LaunchServices held eleven registrations of `com.cacheplane.b4app.local` (Xcode Debug builds, scratch packages, the backup), so every one but `dist`'s was unregistered (`lsregister -u`), as the README's "Signing in" says, before any passkey step.
- **The Compose hub.** The first Add a passkey failed with "That didn't work. Try again.": main's app first calls `POST /v1/me/step-up/passkey/begin` (D-150), and the running `b4hub:local` predated it, so the hub logged two `404 POST (unmatched)`. After a `pg_dumpall` (same folder) and tagging the old image `b4hub:local-before-polish-checks`, `b4hub:local` was rebuilt from `8e7a4ca` (with the cached `rust:1.93.1` tag in place of the pinned digest, the workaround the earlier gates used; the repository's Dockerfile is unchanged); `migrate` applied 0012 to 0014 ("migrated: 14 applied, 0 pending") and `/readyz` was ok.
- **The iPhone.** The local flavour from `8e7a4ca` (`B4App-iOS`, Debug) on the iPhone 17 Pro Simulator, iOS 26.5.

| Check | Result |
| --- | --- |
| The profile button follows the account's name | Pass. Signed in to cacheplane, Settings → Account renamed "Brian Love" to "Brian Love Live": `account status` and the sidebar's profile button read "Brian Love Live" at once, while `hub status` still had the name `HubSync` read at join, "Brian Love", which is the staleness that showed `u-not33mk7` at the sign-in gate. Renamed back; cacheplane is not a personal org, so its name never changed. A freshly joined operator-enrolled account, "Passkey Check", showed its name on the profile button too |
| The local sign-in screen offers one way in | Pass. Signed out, the screen shows only Continue with a passkey and "New here? A passkey creates your account." |
| The pairing sheet closes without the typed form | Pass. The phone logged out (the landing, "Connect your Mac"), then the Mac's `hub.pair` link went straight to `simctl openurl` (never printed): "Pair this iPhone with the hub at localhost?", then Pair. A screen recording through the dismissal (about 56 frames in its last second) shows the question with "Pairing…" until the thread list, and no frame of the hub URL and code form. The phone was signed in to cacheplane again with its threads |
| An added passkey takes the account's name in Passwords | Pass, on the operator-enrolled account. On cacheplane, the step-up passed twice ("stepped up", then `passkeys/begin`), but the system refused to make a second passkey: "This device already has a passkey for this account.", because the hub lists the account's passkeys in `excludeCredentials` and the owner's synced keychain holds one. So a throwaway user was seeded (`seed --org passkey-check --user passkey-check --name "Passkey Check"`, not personal), the Mac logged out and joined it with an enrollment code piped from `enroll` into `hub join` (never printed), and the owner added a passkey in Settings → Account: one Touch ID (no step-up, since the account had no sign-in method). The hub logged `added a passkey`, stored under its placeholder name "Agent Workspace account", and the Passwords app lists the new `local.b4.run` passkey as "Passkey Check" |
| Adoption boots the old LaunchAgent out | Not run: the owner's install was adopted at the sign-in gate, so the fix can be seen only on a fresh adoption |

## 2026-11-03: M8c pairing and relay on a physical iPhone (beta flavour, test hub)

The owner's iPhone, with TestFlight beta build 0.1.0 (2611030054). It was uploaded from #63's branch (`abb41df`, which contains main `9140cf5`) by `B4APP_FLAVOR=beta ./Scripts/upload-ios.sh`, and reached the Internal group. The Mac is `Agent Workspace (Beta).app`, packaged from main `9140cf5` (`B4APP_FLAVOR=beta`, Developer ID, not notarized) beside the prod and Local apps, against `https://hub.test.b4.run`.

- **Sign-in:** the Beta Mac signed in with Apple, creating a new account ("Brian's Org").
- **Pairing:** "Pair iPhone…" showed `https://test.b4.run/pair#c=…`, and the phone's **Scan the code** read it with the camera and paired. The Mac's `hub.pairStatus` reported `paired` ("iPhone"), with its relay connected.
- **Sync:** a Codex thread started on the Mac, "Pairing check", replied "paired" and synced to the phone.
- **Relay:** a message the owner sent from the phone ("Reply phone") reached the Mac through the relay, ran as turn 2, and completed with "phone".
- **Found and fixed on the way: `test.b4.run` had no DNS record.** The Vercel project `b4-run` lists the domain, and `*.b4.run` is a wildcard ALIAS. But `hub.test.b4.run` makes `test.b4.run` an empty non-terminal, which a wildcard never covers. So passkeys and universal links had no association file for the beta flavour. An explicit `test` ALIAS to `cname.vercel-dns-016.com.` (Vercel DNS, team cacheplane) fixed it. `https://test.b4.run/.well-known/apple-app-site-association` and Apple's CDN (`app-site-association.cdn-apple.com/a/v1/test.b4.run`) now serve the beta file (`webcredentials` for `com.cacheplane.b4app.beta` and the iPhone app; `applinks` `/pair`).
- **Also seen:** the earlier beta build 2611022211 predated the "Scan the code" landing, so its sign-in screen offered only Apple and a passkey. A deploy to the single-task test hub answered `503` for about three minutes, and the Mac's relay reconnected by itself afterwards.
- **Not exercised:** the iPhone Camera app opening the pair link; a passkey on the beta Mac or iPhone.

## 2026-11-02: The hub's relay tests await events

Branch `blove/happy-rosalind-d60dae`. Three relay tests (`b4hub --test relay`) failed one or two per run, a different one each time. Each now waits for the event it depends on; no assertion is weaker:

- **`presence_is_sent_when_the_queue_has_room_again`.** It read the phone's backlog until 300 ms passed with no frame. On a loaded runner the drain paused longer than that, the read stopped before the presence, and the test saw none (`[]`). It reproduced 3 runs in 4 under CPU load. `fill_queue` now returns how many frames it queued. The test reads that many events and the presence, each with the usual 2 s frame wait, and only then checks that nothing but a second presence follows.
- **`interrupt_is_held_and_delivered_on_reconnect`.** The phone's command needs two database lookups before it is held. The test gave it `settle()`'s 100 ms of real time and then moved the paused clock 20 s. A slow lookup could straddle that jump, firing the pool's 5 s acquire timeout, or `held` could still read 0. The test now waits until the command is held (`World::await_held`) before moving the clock. `held_answer_expires_after_sixty_seconds` has the same pattern and gets the same wait.
- **`watching_tells_the_mac_the_full_set`.** It checked that the iPad's second `watch` sent the Mac nothing by waiting 300 ms. The phone's `unwatch` that followed runs on another link, so if the iPad's lookup was slower than 300 ms, the unwatch emptied the set first and the Mac was sent `watching []`. A link handles its frames in order, so each `watch` or `unwatch` is now followed by a `ping`. The silence check starts only after the `pong`.

The relay suite (62 tests) passed 7 runs in a row: 2 alone, 2 alongside `cargo test --workspace` (which also passed), and 3 under CPU load (20 `yes` processes on 10 cores). Before the change, the same load failed the presence test 3 times in 4. `cargo fmt --check` and `cargo clippy --workspace --all-targets -D warnings` are clean.

Not changed: `a_mac_whose_queue_stays_full_is_relay_timeout_not_offline` sends a command and moves the clock 4.9 s with no event to await before the jump, because the hub does not expose when the command reaches `send_wait`. It did not fail here.
## 2026-11-02: Step-up for account changes (D-150, resolves D-113)

Built on `blove/xenodochial-morse-e3bed8`.

**Automated**
- Hub, against a throwaway PostgreSQL: `cargo test --workspace --locked`, `cargo fmt --all -- --check`, and `cargo clippy --workspace --all-targets --locked -- -D warnings` pass. New or changed: `a_step_up_grant_is_taken_once_by_its_own_user_and_device` (`b4hub-db`), `add_second_passkey_then_sign_in_with_either`, `a_step_up_and_an_add_belong_to_one_device`, `a_step_up_needs_one_of_the_accounts_own_passkeys`, `remove_last_identity_is_last_identity`, the `delete_me_*` tests, `no_secret_in_logs` (the step-up's challenge, assertion, and grant stay out of the logs), `maintenance_pauses_sign_in_and_account_writes` (`tests/accounts.rs`); `an_apple_only_account_steps_up_with_its_apple_id`, `an_apple_step_up_belongs_to_its_device_and_its_kind`, `a_web_apple_step_up_removes_a_passkey`, `routes_404_without_apple_config` (`tests/apple.rs`); `step_up_types_match_the_hub_types` and the route run in `auth_fixture.rs`, which matches `stepUpRequired` word for word.
- Swift: `swift build`, `swift test`, and `swift format lint --strict` pass. New or changed: `stepUpTypesRoundTrip` (`AuthWireTests`), `stepUpCallsSendTheBearerAndTheirBodies`, `aStepUpRefusalCarriesTheMethods`, and the `B4-Step-Up` header checks (`HTTPHubAPITests`), `anAppleStepUpRedeemsItsHandoffWithTheKeptVerifier` and the passkey step-up in the identities test (`AccountCommandTests`), `anAppleOnlyAccountConfirmsWithAppleNatively` (`MirrorAccountTests`), `aClosedConfirmationSendsNothingAndAStepUpRefusalSaysSo` and `addAPasskey` (`AccountSettingsTests`), and the Connect Apple ID tests (`AppleSignInTests`).
- Seen once each under a loaded machine and not since (three clean reruns each), neither touched by this change: `presence_is_sent_when_the_queue_has_room_again` (`tests/relay.rs`) and `reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown` (`SessionTests`).

**Live gate: pending (the owner's Touch ID).** Not run: the real passkey and Apple sheets need the owner. On a hub built from this branch (migration 14 applied) and the Local app and phone built from it:

1. Settings → Account on the Mac, with a passkey account: **Add a passkey** shows the system passkey sheet first, offering only this account's passkey (and a nearby iPhone or security key), then the registration sheet; the new passkey is listed.
2. **Cancel** the confirmation sheet for Add a passkey, Remove, and Delete account…: nothing changes and no line shows; the Delete sheet stays open.
3. **Remove** the second passkey: confirm sheet, then the row goes. The removed passkey no longer signs in.
4. **Delete account…** on a throwaway account (type the org name, Delete account, confirm): the account is gone at the hub and the Mac is signed out.
5. On the iPhone, the same three changes run Face ID / Touch ID first, through `MirrorAccount`.
6. With Apple enabled (beta, after D-114): an Apple-only account's **Add a passkey** opens Apple's page first (web on the Mac, the native sheet on the phone), then the registration sheet; **Connect Apple ID** on a passkey account asks for the passkey first.
7. `curl -X DELETE -H "Authorization: Bearer <a device token>" <hub>/v1/me` answers `403 step_up_required` with `details.methods`; the hub's log has "a change was refused: it needs a step-up" and no token or grant.

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

## 2026-11-02: The hub's changes-pull TCP test bounds by the wait, not a second

Branch `blove/flaky-changes-pull`.

- **`pull_over_real_tcp_does_not_miss_a_push_in_the_gap`** (`b4hub` `tests/changes.rs`) failed once in a full workspace run, at its `elapsed < 1 s` assertion. Each of its 121 rounds starts a long poll with `wait=5` and a push, and required the round to take under a second. A pull that misses its wake-up still returns the change, by querying again after the wait. So the only sign of a missed wake-up is that the round takes the whole wait. A loaded runner can take over a second on an ordinary round. The pull now asks for the longest wait (`MAX_WAIT_SECS`, 25 s), and the round must end before that wait runs out. A missed wake-up therefore still fails the test, and a slow round no longer does. With the bug put back in (`notified` taken after the first query in `long_poll`), the test failed 4 runs in 6, each round at 25.0 s with the new message. That is the same "some of the time" detection as before; the `long_poll` unit test stays the deterministic check.
- `profile_sets_onboarded_and_renames_org` failed in the same report inside sqlx's per-test database setup (`testing/mod.rs:226`), before the test ran. That is the shared test cluster on 127.0.0.1:54329, not the test. During this work, another worktree restarted that cluster mid-run ("terminating connection due to administrator command", then `PoolTimedOut`). These runs therefore used a private cluster on another port.

The `changes` suite (14 tests) passed 5 runs in a row under CPU load (20 `yes` processes on 10 cores) and once more alongside `cargo test --workspace --no-fail-fast`, which passed in full. The original failure did not reproduce locally, in 8 loaded runs of the test alone and 3 loaded workspace runs. `cargo fmt --check` and `cargo clippy --workspace --all-targets -D warnings` are clean.

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

## 2026-11-02: Sign-in polish from the live gate (D-132, D-133)

Branch `blove/sign-in-polish`, from main at `b5c0f5b`. Fixes the five minor findings of the sign-in live gate (below): the profile button's name, the added passkey's name, the local flavour's "New here?" line, the enrollment sheet's flash after Pair, and the old LaunchAgent left loaded by adoption. No hub, wire, or fixture change.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass (exit 0) |
| Build | `swift build` | Pass |
| Swift tests | `swift test` (PostgreSQL from the main checkout's `.build/postgres`) | 1212 tests in 154 suites; the new and changed tests pass: `SignInTests.theProfileButtonShowsTheNameOnboardingGave` and `signInViewCopy`, `AccountSettingsTests.addAPasskey`, `ConnectMacTests.theEnrollmentSheetKeepsItsConfirmationWhileClosing`, `LegacyAdoptionTests.jobStateReadsLaunchctlPrint`, `anUnreadableJobIsBootedOutByItsPlist`, `retiringTheOldAgentBootsItOutThenRemovesItsPlist`, `bootOutDecisionFollowsTheProgramPath`. The last full run had 3 issues in two timing tests this change does not touch, `B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting` and `SessionTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown` (the second also in an earlier run, with `MirrorSyncTests` long-poll timeouts and a `MirrorRelayTests` presence check off by 0.23 s); each passed three times run alone, and `PostgresServerTests`, `MirrorSyncTests`, `MirrorRelayTests`, and `SessionTests` passed together (82 tests) |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` (`EnrollView` is compiled only here) |

Not run live: the passkey rename in Passwords, the enrollment sheet's dismissal on a device or Simulator, and the boot-out on a fresh adoption (the owner's install is already adopted). A new account starting with no connections is expected (connections are per account, D-065); recorded in `docs/milestones.md`.

## 2026-11-02: Deleting threads, the review's minors (D-138)

Branch `blove/delete-threads-minors`. Each fix was test-first: the test failed, then passed with the fix.

**Gates**
- `swift format lint --strict` was clean; `swift test` passed 1217 tests in 154 suites.
- Hub: `cargo fmt --check` and `clippy -D warnings` were clean. `cargo test --workspace --locked --no-fail-fast` passed every `b4hub-db` and `b4hub-core` test, the new one included. Across two full runs, four timing tests failed once each and passed when re-run alone: `profile_sets_onboarded_and_renames_org` (at sqlx's test-database setup), `pull_over_real_tcp_does_not_miss_a_push_in_the_gap`, `held_answer_expires_after_sixty_seconds`, and the relay's `presence_is_sent_when_the_queue_has_room_again`. The last one also failed alone, but it fails on a clean `origin/main` checkout too (3 of 4 runs there, every run here), on a Mac busy with other worktrees' builds. It was already listed as flaky above.

**New tests**
- Adapters: `invalidParamsWithoutNotFoundAreNotAlreadyGone` (Codex, `FAKE_CODEX_DELETE_INVALID`), `aRoutelessNotFoundIsUnsupportedWhenTheThreadStillExists` (B4, `FAKE_B4_DELETE_404`), and for Claude `removesTheSessionFromEveryProjectFolder`, `anUnreadableRootIsNotAlreadyGone` (mode 000) and `aMissingRootIsNotAlreadyGone`.
- Hub: `clearing_the_delete_mark_is_refused`: a null `userDeletedAt` from the phone or the Mac is rejected `cannot_clear` however new its clock, and a newer insert carrying null leaves the mark.
- Mac: `aPulledNullNeverClearsTheDeleteMark` (`RemoteApplyTests`).
- UI: `confirmationCopyLeavesOutARuntimeSignedInAsSomeoneElse`.
- Coordinator: `aSweepSkipsAThreadAnotherSweepFinished` (a slow sweep's stale due list no longer deletes the second thread twice), `theBackoffDoublesFromThirtySecondsAndCapsAtAnHour`, and `aPulledPhoneDeleteIsSweptToTheRuntime` (a phone's mark pulled through `HubSync` from `FakeHubAPI`, then the sweep, then Codex's `thread/delete`). The last two cover behaviour that was already right, so they passed at once.
- The `COLLATE "C"` on `nextAttemptAt` has no failing test: the timestamps are fixed-width ISO strings, which sort the same under any collation.

## 2026-11-02: The iPhone's thread list toolbar (D-131)

Run in the iPhone 17 Pro Simulator (local flavour, Debug, this branch) against the owner's Local app and Compose hub.

- **The layout:** the list opens under a large "Threads" title, with the filter and compose buttons at the top right and the search field at the bottom (iOS 26's placement). The first thread is where the New thread row used to be.
- **Search:** "b4run" narrowed the list to the three b4run threads, matching regardless of case. Clearing it brought back all seven. The field no longer capitalises what is typed.
- **The filter button:** it opened the project and connection filters. Choosing "B4 Run (Mac)" retitled the list to that project, filled the filter icon, and showed its four threads. "All projects" restored "Threads".
- **Compose:** it opened New thread.
- **Gates:**
  - `swift format lint --strict` is clean.
  - `swift test --filter WorkspaceUITests` passed 273 tests, including `ListSearchTests.theListSearchMatchesShownTitles`, which failed first.
  - Both `xcodebuild` builds (iOS Simulator, macOS) succeeded.

## 2026-11-02: Live deletes in each runtime, the Mac's Delete menu, and pairing the Simulator by link

Run on the owner's MacBook Pro against the Local app and Compose hub built from main `ddc8db8`, with the iPhone 17 Pro Simulator. These close three items the previous entry left open. Each thread below was a throwaway, made for the check.

| Check | Result |
|---|---|
| Codex, live | Pass. A thread with one real turn ("Reply with just the word OK") had a rollout file in `~/.codex/sessions`, and `thread/resume` reported it held by the coordinator's Codex. After `thread.delete`, the runtime delete settled in 17 s, the rollout file was gone, and `thread/resume` answered "no rollout found". |
| Claude Code, live | Pass. A thread with one real turn had `<sessionId>.jsonl` in its project folder beside Claude's own `memory` folder. After the delete only the transcript was gone; `memory` and the project folder stayed. It settled in about a second. |
| B4, live | Pass. With the managed `research` server (`@b4run/cli` 0.15.8) started, the server answered `GET /threads/<id>` 200 for a new thread and 404 after the delete, which settled at once. No turn was needed. The server was stopped again. |
| The Mac's Delete… on screen | Pass, through background accessibility control of the Local app. The thread's toolbar Delete… opened `Delete "Mac menu delete"?` with "It's removed from this app and from Codex. You can't undo this.", Cancel and a red Delete. Delete closed the open thread to the empty "Threads" view and removed the row, and its project group with it, since it was empty. The hub row has `userDeletedAt`, and Diagnostics settled to `[]`. The sidebar's right-click menu was not opened: background control cannot open context menus. |
| Pairing the Simulator by link (fix) | The Mac's `https://local.b4.run/pair#c=…` links had opened Safari's pairing page. `swcd`'s log showed why: its fetch of `local.b4.run`'s association file, started when the app was installed, timed out (`NSURLErrorDomain -1001`) after about 80 s and had not been retried 25 minutes later; the file itself is correct. The local flavour's old-form link fell back on `b4app://`, which on this Simulator belongs to the prod app (D-066 gave the local flavour `b4app-local`). With the fix, `xcrun simctl openurl … b4app-local://pair?hub=…&code=…` opened the local app at "Pair this iPhone with the hub at localhost?", and Pair answered "This iPhone is already paired", since it was signed in to that account already. `theLocalFlavourReadsTheOldLinkUnderItsOwnScheme` failed first, then passed. |

## 2026-11-02: Usage on the phone and deleting threads, on screen (D-118, D-119, D-120)

Run on the owner's MacBook Pro from main `ddc8db8`, after #46 and #51 merged.

**What was rebuilt**
- **The Compose hub.** `b4hub:local` was built from `Hub/Dockerfile` with the cached `rust:1.93.1` tag in place of the pinned digest, the same workaround the sign-in gate used. It was restarted with `docker compose up -d --no-build hub`. The hub's ledger shows migrations 1 to 11.
- **The Local app.** `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh` ran in a scratch checkout of `ddc8db8`, because `package.sh` clears `dist/`, which also held the prod app with a running coordinator.
  - Only `Agent Workspace (Local).app` was swapped into `~/repos/b4app/dist`, after the app was quit and its coordinator stopped.
  - The coordinator came up signed in to `blove@cacheplane`, with the relay connected and the store migrated (0007, 0008).
- **The phone.** The local-flavour iOS app (Debug) was installed over the existing app on the iPhone 17 Pro Simulator.
  - It came up at "Connect your Mac". The Mac's `hub.pair` links opened Safari's `/pair` page three times: this Debug build does not open the `local.b4.run` universal link.
  - So the phone paired through "Use an enrollment code" with the code `hub.pair` minted, pasted from the Simulator's pasteboard. It showed the Mac's 7 threads.

**Checks**

| Check | Result |
|---|---|
| Usage on the phone (D-118) | Pass. After `connection inspect` on Codex, the hub's `connectionUsage` row carried the weekly window (90%). The phone's Connections page drew the Codex card's Weekly meter at 90% with "Resets Tue 22:36", and no longer says "Usage shows on your Mac". Claude Code and the B4 cards read "Usage appears after the first turn" and "Token use appears after the first turn", as designed. |
| Delete on the Mac | Pass, through the coordinator's `thread.delete` (the command the Mac's menu and alert send) on a throwaway Codex thread. The Mac's list dropped it. The hub kept the row with `userDeletedAt` set and `deleted_at` null. The phone's list never showed it. Diagnostics' `threadDeletes` was `[]`: the Codex delete was answered. |
| Delete on the iPhone | Pass, on a second throwaway Codex thread. Swiping left showed Pin, Archive and a red Delete. Delete opened `Delete "Delete check (phone)"?` with "It's removed from this app and from Codex. You can't undo this.", Cancel and a red Delete, and the row stayed until Delete was tapped. Then the row left the phone at once. The hub row gained `userDeletedAt`, and the Mac's list dropped it. Diagnostics showed one Codex delete waiting, then `[]` within one sweep: the Mac deleted the runtime's copy after pulling the phone's mark. |

**Not checked**
- **The Mac's own Delete… menu and alert, clicked on screen.** That needs screen control of the owner's Mac. The alert is the same SwiftUI modifier the phone showed.
- **That Codex no longer holds the deleted threads.** Both throwaway threads had no turns, and Codex writes a thread to disk only after its first turn, so `thread/resume` answered "no rollout found" for either. A turn was not spent to prove it, because the owner's Codex weekly window was at 90%. Codex accepted `thread/delete`, and the coordinator recorded it as done.
- **Claude Code's transcript removal and B4's `DELETE`, live.** Both are fixture-tested only.

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

## 2026-11-02: Sign-in (fixture gates; live gate, owner's passkey steps pending)

## 2026-11-02: Deleting threads (D-119, D-120)

Branch `blove/delete-threads`, stacked on `blove/phone-usage`.

**Gates**
- `swift format lint --strict` was clean.
- `swift test` passed: 902 tests in 134 suites (after the review's fix pass).
- Hub: `cargo test --workspace --locked` passed 249 tests on two consecutive runs; `cargo fmt --check` and `clippy -D warnings` were clean. After merging the updated `blove/phone-usage` (with the soft-delete work, D-089), 250 passed. The relay suite (`b4hub --test relay`, which this branch does not touch) failed one or two timing tests per run, a different one each time: `presence_is_sent_when_the_queue_has_room_again`, `interrupt_is_held_and_delivered_on_reconnect`, `watching_tells_the_mac_the_full_set`. One earlier run also had a flaky `b4hub-db` `settings` failure that did not recur.
- Both `xcodebuild` builds (macOS, iOS Simulator) succeeded.

**New tests**
- Storage: `ThreadDeleteStoreTests`. A deleted thread leaves every list; the mark keeps its first time and is logged; the runtime-delete record and its backoff; the Diagnostics counts. `OrganisationSchemaTests` pins `userDeletedAt` as a clocked column of the change trigger.
- Adapters: `CodexDeleteTests`, `ClaudeDeleteTests` and `B4DeleteTests`. These cover deleted, already gone and unsupported for each runtime. For Claude, only the one session's `.jsonl` and folder go; `../x`, `a/b`, `.` and `s1.jsonl` are refused and touch nothing.
- Coordinator: `ThreadDeleteTests`.
  - A Codex delete hides the thread and reaches `thread/delete`.
  - A running B4 turn is interrupted before the `DELETE`.
  - A phone's delete is swept later.
  - An unreachable B4 is retried after its backoff and then done.
  - A server without the route is final.
  - A late event for a deleted thread publishes nothing. Disabling that guard fails the test.
  - After merging sign-in (#49): `aRetryWaitsFromTheFailedTry`. CI ran a delete against a stopped B4 server that hung for 70 s instead of being refused, and the retry was then due at once; the wait now counts from the failed try. `thread.delete` is gated on a signed-in account (`Router.needsAccount`).
  - From the review's fix pass: `aPhonesDeleteStopsTheRunningTurn` (a delete pulled from the phone interrupts the running B4 turn before the `DELETE`, and nothing is left in active work), `aReconcilingTurnOfADeletedThreadIsEnded`, and `deletingAnswersBeforeASlowRuntimeDelete` (the command answers in under 3 seconds while the runtime delete takes 5).
- Hub: `a_phone_marks_a_thread_deleted_and_the_row_stays`. A phone's mark is applied by clock, an older Mac write does not clear it, and the row and its turns stay. Also the `writable.rs` lists and the `0011` migration guards.
- Mirror: `MirrorDeleteTests`. A phone delete hides the thread, makes it unreadable, and queues one `userDeletedAt` update; a repeat queues nothing; a pulled mark hides it too. The schema version 5 migration guards are covered as well.
- UI: `ThreadDeleteDiagnosticsTests` (the Diagnostics "Deleted threads" counts by runtime) and `ThreadDeleteModelTests`. Deleting the open thread closes it and discards the unsent text; the confirmation copy covers each runtime, a disabled connection and a running turn; a late turn event keeps the thread gone.

**Checked by hand:** Codex 0.166.0's generated schema has `ThreadDeleteParams { threadId }` and an empty `ThreadDeleteResponse`.

**Not run before merge**
- **The alert and the iPhone swipe on screen.** SwiftUI alerts don't render in the offscreen snapshot harness.
- **The Simulator check against the owner's Compose hub.** That hub needs `0011`, so it waits until this merges and the hub is rebuilt from main.
- **A live delete in real Codex, Claude Code or B4.** The fixtures stand in for all three.

## 2026-11-02: Usage on the phone (D-118)

Branch `blove/phone-usage`.

**Gates**
- `swift format lint --strict` was clean.
- `swift test` passed: 868 tests in 125 suites.
- Hub: `cargo test --workspace --locked` passed 248 tests; `cargo fmt --check` and `clippy -D warnings` were clean. After merging the soft-delete work (#45, D-089), `connectionUsage` has `deleted_at` too, and the hub passed 251 tests with fmt and clippy clean.
- Both `xcodebuild` builds succeeded.

**New tests**
- Mac: `syncedUsageIsLoggedWhenItChanges` (the synced row is logged when it moves, and not when it doesn't) and `usageIsWrittenForThePhone` (a Codex check and a B4 turn write the row).
- Hub: `connection_usage_syncs_under_its_connection` and `connection_usage_is_mirrored_and_pulled`. The migration guards now include `0010` and the table's row-level security.
- Mirror: `usageReadServesTheMacsUsage`, `publishAnnouncesUsage`, and the schema version 4 migration tests.
- UI: `tokenTotalsAreNamedByTheirDay` and `aUsageEventWithTheWholeUsageReplacesIt`.

**Not run before merge: the live check in the Simulator against the owner's Compose hub.** Running the hub from this branch would apply `0010` to the owner's hub database, and a hub binary without it would then refuse to start (sqlx `VersionMissing`). So the check runs after the merge, on the hub and apps rebuilt from `main`, and is recorded there.

## 2026-11-02: Claude completions find their streamed items; M8c device checks

Branch `fix/claude-block-ids`.

- **Found live with D-088.** A Claude Code reply showed twice, on the Mac and the phone. Claude Code sends each content block in its own `assistant` frame. `ClaudeTurnTracker` named a completed block by its position in that frame (`msg#0`), not its stream index (`msg#1` after a thinking block at `msg#0`). So the text completed onto the thinking item, which lost its reasoning card, and the streamed text item stayed empty. Before D-088 that empty item was invisible; D-088 then stored its streamed text at the turn's end, so the text showed twice. Each completion now takes the first unfinished streamed block of its type for that message, falling back to the frame position when nothing streamed. `ClaudeTurnTrackerTests.completionsGoToTheItemsTheStreamStarted` covers it and fails without the fix.
- **Keep the Mac awake: off** (M8c, open until now). Run on the owner's Local app with `settings.update`, as the Settings toggle does. With `keepAwake: false`, the coordinator released its "Agent Workspace keeps this Mac reachable from your phone" assertion, and `hub status` showed `awake      not held`. Turning it back on took the assertion again. Other coordinators on the same Mac hold assertions of their own.
- **Answer from both** (M8c, "Already answered"). In the iPhone 17 Pro Simulator against the Compose hub, on a real Claude Code tool permission:
  1. The hub container was paused, and the phone tapped Allow once.
  2. The Mac answered with `request respond --accept`.
  3. The hub was unpaused.

  The hub logged `request.respond` → `stale_runtime_request`, and the command ran once. The phone showed no "Already answered": the Mac's "resolved" event reaches the phone before the refused answer on the same ordered link, so the card is gone first. The copy can only show if that event is lost. The user still sees the right outcome: the card disappears and the result arrives.

## 2026-11-02: Sign-in (fixture gates and live gate)

Target: the build MacBook Pro (macOS 26.5, Xcode 26.6), run from the worktree on `blove/sign-in` at code head `e6aaf6d` (Tasks 1 to 17 and X1 of `docs/superpowers/plans/2026-11-01-sign-in.md`, with `origin/main` through PR #40 merged). The documentation commit that records this changes no Swift or Rust, only the iPhone's `PrivacyInfo.xcprivacy` and these documents; the four `xcodebuild` builds ran after that change. Nothing touched the owner's app, its data directory, the Keychain, or the Compose stack. Decisions D-090 to D-112.

Rerun after the final review's fix wave (I1, I2, M1, M2, M5 to M9, M11 to M13; D-113 to D-117), including M11 narrowed to the hub's `unknown_credential` reason (D-117): the format, build, Swift and Rust test rows below are that run's; of the app builds, `B4App-macOS` and `B4App-iOS` were rebuilt (`** BUILD SUCCEEDED **` each, `CODE_SIGNING_ALLOWED=NO`), the Beta schemes were not. The `registryMigrations` NOTICE no longer appears in the test output (M12).

### Sign-in (fixture gates)

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass (exit 0, no findings) |
| Build | `swift build` | Pass |
| Swift tests | `swift test` | Pass: 1158 tests in 144 suites after merging main's #43 (1147 at `2cc466c`; 1144 before X3; 1113 in 142 before the final fix wave; 858 when this branch first merged main, 1022 after the second merge), exit 0. The sign-in suites: `FlavorTests`, `LegacyAdoptionTests`, `LegacyAdoptionGateTests`, `LegacySecretCopyTests` (Task X2), `CoordinatorAdoptionOrderTests`, `AccountRegistryTests`, `AccountManagerTests`, `AccountCommandTests`, `AccountCLITests`, `AuthWireTests`, `HTTPHubAPITests`, `SignInTests`, `AccountSettingsTests`, `AppleSignInTests`, `MirrorAccountTests`, `MirrorLogOutTests`, `PhoneFlavorTests`, `PairLinkTests` (protocol and mirror), `PairingTests`, `RemoteAccessTests`, `ConnectMacTests`. `HubSyncTests.joinPushesTheBacklogAndMarksItSynced`, seen to fail once in a full run during Task 15, passed |
| Rust format | `cd Hub && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `source <(./scripts/test-db.sh) && cargo test --workspace --locked --no-fail-fast`, then `./scripts/test-db.sh --stop` | Pass: 392 tests against PostgreSQL 17.11 at `2cc466c` (387 before X3 and the pairing-code fix) (379 before the final fix wave, 245 at M8e Part B): `b4hub` 278 (unit 88, `accounts` 14, `apple` 38, `auth` 19, `auth_fixture` 9, `changes` 14, `enroll` 17, `health` 5, `instances` 8, `maintenance` 3, `relay` 62, `request_log` 1), `b4hub-core` 26, `b4hub-db` 83 (unit 3, `accounts` 24, `changes` 35, `instances` 4, `logging` 1, `migrate` 8, `rls` 5, `settings` 3) |
| Chart | `cd Hub/chart/b4hub && helm unittest . && helm lint . -f ci/kind-values.yaml` | Pass: 56 tests in 4 suites (helm-unittest 1.2.1); lint 1 chart, 0 failed (one `INFO`: icon is recommended) |
| Project | `./Scripts/generate-project.sh` | `B4App.xcodeproj` regenerated; schemes `B4App-macOS`, `B4App-macOS-Beta`, `B4App-iOS`, `B4App-iOS-Beta` |
| Apps | `xcodebuild build -project B4App.xcodeproj -scheme <scheme> -destination <'platform=macOS' or 'generic/platform=iOS Simulator'> CODE_SIGNING_ALLOWED=NO` for the four schemes | Four `** BUILD SUCCEEDED **`. Warnings only in code the Beta builds compiled again: unused results in `WorkspaceStorage` (`WorkspaceDatabase`, `Migrator`, `AccountRegistry`) and `Ports.swift`, the deprecated `posix_spawn_file_actions_addchdir_np` in `ManagedProcess.swift`, and the duplicate case at `Remediation.swift:122`. Both iPhone builds carry the new privacy manifest (`plutil -extract NSPrivacyCollectedDataTypes` on each built app: name, email address, user id) |
| Privacy manifest | `plutil -lint Apps/iOS/B4App/PrivacyInfo.xcprivacy`, and the keys checked against Apple's documentation (`describing-data-use-in-privacy-manifests` and the `NSPrivacyCollectedDataType` and `…Purposes` pages) | OK |
| CI | the Swift package job, the apps job, the `hub` job, and the chart jobs | Recorded in the pull request, not here |

What the fixtures cannot show, and is left to the live gate or later:

- A real passkey ceremony: the Mac needs a Developer ID package with the `webcredentials:` entitlement and `local.b4.run`'s association file through Apple's CDN; an unsigned build only reaches the failure line. The "no passkey" path (D-104), `excludeCredentials`, the orphan report and the rename (D-105) have run only against fakes.
- Sign in with Apple on any hub: no hub has the Apple key (the local flavour hides it, and the hosted hubs are not deployed); the hub's side is fixture-tested against a fake Apple.
- Adoption of the owner's install with the real `launchctl` boot-out and cluster read (D-094). The copy of the owner's secrets from the real prod keychain group (Task X2) has run only against in-memory stores; step 2 below is its first real run.
- The system Camera opening a pair link on a device, the Safari sheet, and the Settings window closing on sign-out in the running app.
- A Developer ID package of any flavour from this branch (the owner's profiles pass `B4APP_CHECK_PROFILES_ONLY`), a release, and the Homebrew tap.
- The repository's `Hub/Dockerfile` with the sign-in crates: its pinned base digests could not be pulled through this Mac's Docker Desktop during the build, so the image for the live gate was built from a scratch copy using the cached `rust:1.93.1` tag (the Dockerfile itself is unchanged). CI's `hub-image` and `compose-smoke` jobs are the check.

### Live gate

Run on 2026-11-02 between 17:18Z and 18:00Z on the owner's MacBook Pro, by the build session while the owner was away (steps 2, 6, 7), from `blove/sign-in`: the Mac app and the hub image at `df7a85d` for the first pass, then `aac49ec` (X3) for the rejoin recheck and the second pairing. Steps 3 to 5 ran later the same day (19:16–19:20Z) with the owner at Touch ID and the build session driving the app, on a rebuild at `e5087d1` (the hub image and the Mac app).

Setup:
- Backups first, outside both data directories: `agent-workspace db backup` (544 rows), a `pg_dumpall` of the hub, and a copy of `Hub/.env`, in `~/Library/Application Support/b4app-signin-gate-backups/20261102T171856Z/`. Main's hub image was kept as `b4hub:main-before-signin`.
- `Hub/.env` gained `B4HUB_SECRET_KEY` (generated, never printed), `B4HUB_SIGNUP=open`, and `B4HUB_WEBAUTHN_RP_ID=local.b4.run`.
- The hub image was built from a copy of `Hub/Dockerfile` that names the cached `rust:1.93.1` tag instead of the pinned digest, because Docker Desktop's proxy hangs pulling the digest on this Mac; the repository's Dockerfile is unchanged and CI builds from the pin. The Compose stack moved to the branch's `Hub/` on the same `hub_b4hub-db` volume; `migrate` reported "migrated: 8 applied, 0 pending", and `/readyz` showed migrations current, relay and instances ok; `/v1/auth/config` answered `{"passkeys":{"rpId":"local.b4.run"},"apple":{"native":false,"web":false},"signup":"open"}`.
- The Mac app: `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh`; the package's entitlements carry `webcredentials:local.b4.run` and both keychain groups (`…b4app.local.shared`, `…b4app.shared`) on the app and the coordinator. Main's app was quit, and `Agent Workspace (Local).app` was installed beside it in `~/repos/b4app/dist`.
- The phone is the iPhone 17 Pro Simulator (iOS 26.5), the local flavour built from the branch.

| Step | Result |
| --- | --- |
| 1. Package the local flavour and launch it | Pass (build session) |
| 2. The owner's existing threads appear without a sign-in (adoption) | Pass (build session). `b4app` became `b4app-local`; the app came up signed in to `blove@cacheplane` with no sign-in screen; `hub status` showed the relay connected and `account status` `signedIn`, so the hub token was copied from the prod keychain group (D-094, D-116); the Codex, Claude Code, and B4 connections were ready. The legacy plist was gone. **Found (minor, not fixed):** the legacy job `com.cacheplane.b4app.coordinator` was still loaded ("spawn scheduled", last exit 78) and needed `launchctl bootout` by hand: adoption's boot-out reads a timed-out `launchctl print` as "not loaded" (Task 3's deferred minor). With the plist gone it would not have come back at the next login |
| 3. Add a passkey in Settings → Account, log out, sign back in with the passkey: the same threads appear | Pass (owner at Touch ID, build session driving the app, 19:16–19:19Z on `e5087d1`). Add a passkey: the hub logged `added a passkey`, and Account listed "Passkey · Agent Workspace account · added Nov 2". Log out from the profile menu ("Log out of cacheplane?", no work listed), then Continue with a passkey: `signed in with a passkey` on the same device `01a19d4c`, all 7 threads back. **Found (fixed in the README, not in code):** the first two attempts failed with "That didn't work" (`ASAuthorizationController` 1004; `AuthenticationServicesAgent`: "not associated with domain local.b4.run", then "SWC approval state was unspecified"): LaunchServices held several copies of `com.cacheplane.b4app.local` (Xcode Debug builds without a team or associated domains, the worktree's Release-Local build), and `swcd` had not yet approved the packaged app. Unregistering the others (`lsregister -u`) and re-registering the package made `swcd` fetch `local.b4.run` from Apple's CDN; the next attempt showed the system's passkey sheet. README "Signing in" now says how to clear it |
| 4. Sign up a second account with a new passkey and complete onboarding: "Brian's Org" (or the typed name's) | Pass (owner). Continue with a passkey, Cancel on the system sheet, "Create account", Touch ID, then "Test Person" on onboarding: the hub logged `signed up with a passkey` (19:19:30Z); `account status` showed org "Test's Org", name "Test Person", and cacheplane among the known accounts; the new passkey was renamed "Test Person" in Passwords. **Found (minor, not fixed):** the sidebar's profile button showed the username `u-not33mk7` instead of "Test Person" after onboarding; a passkey added from Settings → Add a passkey keeps the generic name "Agent Workspace account" (only the sign-up passkey is renamed); a new account starts with no connections, so New thread is disabled until one is added (connections are per account; the runtimes' own logins are shared) |
| 5. Create a thread, log out, sign in to the first account: its threads appear, the second account's thread does not | Pass (owner at Touch ID). In Test's Org a Codex connection was added and the thread "Test account thread" created (CLI); `account logout --stop-work`; the system sheet listed both passkeys ("Test Person", "Agent Workspace account"); signing in with cacheplane's showed its 7 threads and not "Test account thread", on device `01a19d4c` |
| 6. `agent-workspace thread list` while signed out: exit 4 with the message | Pass (build session). `account logout` with the `research` server running was refused with `work_running` listing it; `account logout --stop-work` logged out in under a second; `thread list` then printed "error [signed_out]: Nobody is signed in. Sign in from the Agent Workspace app." and exited 4. The Mac signed back in with an operator enrollment code piped into `hub join` (never printed): the same registry row and database, all 7 threads |
| 7. In the iPhone Simulator (local flavour), open the pair link with `xcrun simctl openurl` and see the threads | Pass (build session). The Mac's `hub.pair` (sent over the coordinator's socket; the link went straight to `simctl openurl`, never printed) answered a `https://local.b4.run/pair#c=…` link. The first link after a fresh install opened Safari (b4.run's `/pair` page), before the Simulator had fetched `local.b4.run`'s association file; the next one opened the app at "Pair this iPhone with the hub at localhost?", and Pair signed the phone in with the account's threads. On the recheck after X3 a clean install paired the same way and showed all 7 threads with the Mac online |

Found at the live gate:

- **A Mac that rejoined with an enrollment code became a new device (fixed: X3, D-096 amended).** After the step-6 log-out (the session ends, the device is kept, D-105), `hub join` with a code made a second `macos` device, because `POST /v1/enroll` took no device id. Every row the Mac had synced kept the old device as its owner, so the phone showed "Brian's MacBook Pro (2) is offline · last seen 09:26" and relayed turns for those threads would have gone to the dead device. The same gap made a phone that re-paired by code a new device each time (D-108). Fix: `POST /v1/enroll` takes `deviceId` and `candidateDeviceIds` with the sign-in rule (`devices::redeem_reusing`, sharing `accounts::create_session`); `hub join` offers the registry's devices for that hub, and the phone its remembered devices on a typed code, a pairing scan, and the merge-first path. Fixture tests: `enroll.rs` (`enrolling_again_reuses_this_device`, `enrollment_passes_over_foreign_and_revoked_candidates`, `enrollment_candidates_are_capped_and_validated_before_the_code_is_used`), `accounts.rs` (`enroll_merging_reuses_only_a_device_of_the_codes_account`), `AccountCommandTests.hubJoinOffersEveryKnownDeviceOfThisHub`, `PairLinkTests.aPhoneThatPairsAgainOffersItsDevice` and `aMergingPairOffersEveryDeviceThePhoneHasHad`. **Rerun live** with `aac49ec`: log out, then rejoin by code kept device `01a19d4c`, and every thread kept it as owner. Review follow-up `2cc466c`: a pairing code is redeemable only as `ios`, so its holder cannot take over the Mac's device through a candidate (`enroll.rs` `a_pairing_code_pairs_only_a_phone`).
- **The owner's local hub was repaired by hand** for the first rejoin, before the fix: in one transaction, `owner_device_id` moved from the old device `01a1988c…` to `01a19d4c…` in `connections` (4 rows), `displayItems` (45), `drafts` (2), `projectFolders` (3), `projects` (3), `runtimeRequests` (6), `threads` (7), and `turns` (14), and `01a1988c…` was revoked. The pre-gate dump above is the way back.
- **Minor, not fixed:** on the local flavour the sign-in screen still says "New here? Either one creates your account." with only one button; and while the pairing confirmation closes after Pair, the "Use an enrollment code" form shows for a moment before the sheet dismisses.

## 2026-11-02: The hub keeps synced rows (D-089)

Branch `blove/dreamy-hamilton-b5adc9`, from main at `3f3cc15`. Hub only; no Swift, wire, or fixture change.

- **Automated.** `cargo test --workspace --locked` passes 249 tests against the throwaway PostgreSQL (`scripts/test-db.sh`); `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` are clean. `swift test` and `swift format lint` were not run: nothing under `Sources`, `Tests`, or `Apps` changed.
- **New tests** in `Hub/crates/b4hub-db/tests/changes.rs`. `a_delete_keeps_the_row_and_its_clocks_and_the_feed_carries_it`: a deleted thread and turn keep every column and the title's clock; a pull still yields both deletes; the snapshot leaves them and their clocks out and never carries `deleted_at`; a later update, a child insert, the relay's thread lookup, and a second delete all leave the row as it was. `an_insert_revives_a_deleted_row`: a thread re-inserted under an older clock, a project folder removed and added again, and a draft the Mac cleared and the phone wrote again all come back live with the re-insert's values. `a_deleted_row_stays_with_its_user_and_its_org`: another user of the org can neither revive nor see the deleted row, and another org or no tenant sees nothing of it. All three fail on main's hub code and pass with the change; so do the updated assertions in `push_materialises_and_is_idempotent` (the fixture's deleted draft is kept) and `mirrored_columns_are_the_macs_columns` (the new hub column).
- **Not exercised live.** No hub was migrated to 0009 here; the Compose and hosted hubs pick it up on their next deploy.

## 2026-11-02: Settings follow-ups (the deferred review minors of D-081 to D-084)

Branch `blove/settings-connections-minors`. Gates: `swift format lint --strict` clean; `swift test` 862 tests in 125 suites passed; both `xcodebuild` builds succeeded. Each fix has a test that failed first:

- **Claude windows.** The top-level figures now fill whichever window `unifiedWindows` lacks, and the per-model weekly buckets are no longer shown as "Weekly" (`fillsTheMissingWindowFromTheTopLevel`, `perModelWeeklyWindowsAreNotTheWeek`).
- **Codex windows.** Windows are ordered by length and named by it, so a daily window reads "Daily" and two short windows are both kept (`windowsAreOrderedByLengthAndKeepTheirLength`, `windowsAreNamedByTheirLength`, `aDailyWindowIsCalledDaily`).
- **Token counts** round once in the unit shown, so they never read "1000k" (`tokensNeverReadAThousandK`).
- **Renames** reach every client: `connection.changed` carries the whole connection (`aRenameCarriesTheConnection`, `aConnectionChangeWithTheConnectionUpdatesTheList`).
- **Orphaned keys.** The new `credential.remove` deletes a key that no connection uses, and the form takes back a key whose add or edit failed (`credentialRemoveKeepsASecretInUse`, `aFailedAddLeavesNoKeyBehind`).
- **Saved edits.** Deleting a replaced key is best effort once the edit is saved (`aSavedKeyChangeIsNotReportedFailedWhenTheOldKeyStays`).

Not covered by a test: B4 token counts are now recorded last in `turn.finished`, and a failure there is ignored. Observing that needs a fault injected into the database.

## 2026-11-02: Flaky CI tests now await events

Branch `fix/flaky-tests-await-events`. These are tests that failed on `main` or a PR and passed on rerun. Each now waits for the event it depends on instead of a fixed time, or a fixed time that a loaded runner can outlast:

- **`HTTPHubAPITests.appendFeedsAReaderAndALongPollWakesForIt`.** `FakeHubAPI`'s long poll used to re-read every 10 ms. It now parks until something can change its answer: `append`, a push, `setFailNext`, `revokeSelf`, its deadline, or cancellation. `untilPulling()` lets the test append once the pull is parked, replacing a 50 ms sleep.
- **`ClaudeSessionTests.resumesKnownSessionsAndReportsMissingOnes`.** A real race in `ClaudeSession`. A missing session is recognised by its stderr line, which could arrive after the exit was seen, giving `endpoint_unavailable`. The read loop now awaits stderr's end (`waitForStderrEnd()`, bounded at 2 s for a grandchild that keeps it open) before reporting the exit. `aMissingSessionIsRecognisedWhenStderrTrailsTheExit` reproduces it deterministically: `fake-claude.py` `missing-late` writes the line from a grandchild 300 ms after exiting. It fails without the fix.
- **`ManagedProcessTests.portsAllocateAndDetectInUse`** (failed twice). A just-released port can go to a parallel test's connection. The test now checks "free" on the first of up to five allocations that stayed free, then holds the port with its own listener.
- **`ManagedProcessTests.terminateGroupKillsAGrandchild`.** It already waited on the grandchild's exit event, but its 10 s guard sat under a 30 s sleep. The sleep is now 600 s and the guard 120 s, so a missed signal still fails and a slow runner doesn't. A `defer` kills a leftover sleeper.
- **Rust `instances::readiness_reports_a_stale_heartbeat`** (and the claim-takeover test, which pauses the same way). A heartbeat write already past the pause check could land after the pause and refresh the instance. `InstancesState::settle()` returns once no write is in progress, and the tests await it after pausing.
- **Already fixed on `main`:** `MirrorSyncTests.failuresAreRecordedAndRetriedWithBackoff` (`3e3427a`) and `request_log::a_503_is_a_warning_…` (`828e6f9`).

`swift test` passes 864 tests; lint, `cargo fmt` and `cargo clippy` are clean.

## 2026-11-02: A stopped reply keeps its streamed text (D-088)

Branch `fix/stopped-reply-text`, from main at `3f3cc15`.

- **Automated.** `swift test` passes 852 tests and `swift format lint --strict` is clean. `SessionServiceTests.aStoppedReplyKeepsItsStreamedText` covers two cases, a reply never completed and one completed empty. It failed before the fix: no assistant completion was published, and the item stayed empty.
- **Live, real Codex on a scratch coordinator** (`.build/debug`, its own `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`; the owner's app untouched). A 60-line reply was stopped after 12 s. The turn ended `cancelled`, and its agent message was stored with the 780 characters that had streamed. Before the fix it was stored empty (seen live in the M8c transcript check).
- **Not exercised live.** The phone showing the stopped reply. That needs the owner's app on this build; the phone applies the same `message.completed` event as the Mac.

## 2026-11-02: M8c phone transcript fixes (D-087)

Branch `fix/m8c-transcript`, from main at `3151915`.

- **Automated.** `swift test` passes 851 tests, `swift format lint --strict` is clean, and the iOS and macOS app builds pass. Each new test fails without its fix and passes with it: `MirrorModelTests.reloadingTheOpenThreadMidReplyKeepsTheLiveText` and `SendStateTests.aConfirmedStartWhosePlaceholderExpiredStaysStarted`. `anUnconfirmedStartWhoseReadFailsShowsNotConfirmed` pins the unchanged spec case.
- **Live, iPhone 17 Pro Simulator** against the Compose hub and the owner's Mac app (both on main `3151915`), with a real Codex turn:
  - **Reopen mid-reply.** A 60-line reply was streaming. Going back and reopening the thread showed the reply from its first line, still growing. Before, the text started over from the next delta.
  - **Stop.** After a Stop mid-reply, the transcript ended at "Turn stopped." with no blank space past it.
  - **Opening a thread.** A long thread opens at its latest message (before, at its first), and a short thread still starts at the top.
- **Not exercised live.** A confirmed start whose row is more than 2 minutes late; it needs the Mac's sync held back. It is fixture-tested.
- **Seen, then fixed in D-088.** A Codex reply stopped mid-stream was stored on the Mac with empty text, so the partial reply disappeared on both the Mac and the phone after a Stop.

## 2026-11-02: Settings, connections and B4 projects (D-081 to D-084)

Branch `blove/settings-connections-design`.

**Gates**
- `swift format lint --strict` was clean.
- `swift test` passed: 633 tests in 108 suites, after the review fixes.
- Both `xcodebuild` builds passed: macOS, and iOS for the Simulator.

**New tests**
- Protocol: `UsageTests`.
- Storage: `UsageStoreTests`, plus the migration list now includes `0006_usage`.
- Codex: `CodexUsageTests`, which parse the pinned snapshot and read it through `fake-codex.py`.
- Claude: `ClaudeUsageTests`, which parse the window variants and emit through `fake-claude.py`.
- Coordinator: `UsageTests`. These cover:
  - usage for Codex and for Claude;
  - B4 tokens counted once;
  - retries numbered 1, 2 and 3 against a closed port, and no retry on an incompatible route;
  - update (rename, replace and remove the key, an unknown reference, a shared secret);
  - the local day and week boundaries on the day daylight time ends.
- UI model: `ConnectionsModelTests`.
- UI copy: `UsageFormatTests`, `ConnectionCardTests` and `B4ProjectCardTests`.
- Snapshots: `ListSnapshotTests.b4ProjectCards` and `settingsSheets`.

**Live checks (2026-11-02, against the owner's installs)**
- Codex 0.166.0: `account/rateLimits/read`, with no inference.
  - The plan is `promax`, with `ordinaryUsageAllowed: true`.
  - There was only a `primary` window: 10080 minutes, 87% used.
  - This led to the leading-edge meter fix and the plan names (`planCodesReadAsNames`, `windowsFillFromTheLeadingEdge`).
- Claude Code 2.1.282: one `claude -p` turn on haiku with the plan login (`apiKeySource: none`).
  - One `rate_limit_event` arrived, with status `allowed_warning` and `rateLimitType: seven_day`, at 0.25.
  - Its `unifiedWindows` held only `seven_day`.

**Mac, measured on 2x snapshots**
- Shots: `docs/screenshots/settings-connections-{light,dark}.png`, `settings-b4-projects.png`, `settings-sheets.png`.
- Connection card:
  - padding 16 pt;
  - mark slot 24 pt, with 8 pt to the name;
  - 12 pt from the header to the meters;
  - 16 pt between the meters;
  - the "…" button 30 pt, at the card's 16 pt inset.
- Sheets:
  - 24 pt margins, 4 pt from the title to the lede, 16 pt to the group, 24 pt to the buttons;
  - rows at least 48 pt, with a 96 pt label column and 30 pt fields.
- Problems found and fixed while measuring:
  - Secondary pills vanished on the surface, so `llaOutline` was added.
  - Placeholders drew in ink on the Mac; empty fields are now muted.
  - The open-time check queried a connection with a turn in progress; such connections are now skipped.

**Phone (iPhone 17 Pro Simulator, default and AX3)**
- Shot: `docs/screenshots/ios-settings-connections.png`.
- The cards are read-only, say "Usage shows on your Mac", and have no "…" menu.
- At AX3 the card headers stack (mark and status above the name), after a letter-by-letter wrap was seen.
- The Settings page list drops its symbols at accessibility sizes, after "Connecti / ons" was seen.

**Review**

A whole-branch review by a fresh reviewer on Opus found no critical issues. It raised four important findings, and two minor ones were re-graded important. Each fix has a test written to fail first:

- Checks on page open ran one after another on the client's single queue and froze Send and approvals. They now run in the background (`connection.inspect background`) and skip a connection checked in the last two minutes.
- A key change during a running turn dropped the adapter mid-turn. It is now refused with `turn_active`.
- Codex's sparse `account/rateLimits/updated` overwrote a refusal. It now triggers a full read.
- A refusal outlived its reset. It now ends when the window that ran out resets.
- A check that ended early could leave a spinner turning. It now always publishes its closing event, and a snapshot clears check progress.
- A server that had never reported tokens showed "0 tokens". It now shows no figure.

The rest were deferred as minor; the PR lists them.

While re-running the snapshots, the full Mac snapshot test timed out waiting for an approval. The cause was in `fake-codex.py`, and it predates this branch: while waiting for an approval answer the fake dropped every message, so the coordinator's `thread/read` waited until it timed out. On `main` the test took about 135 s. The fake now answers reads while it waits, and the test passed three runs in three at about 38 s.

**Not checked**
- Clicking the "+" menu, the sheets' Save, and Edit against the running app. The sheets were rendered and their logic is tested; they were not driven by clicks.
- A retry seen on screen against a real unreachable B4 server.

## 2026-11-02: M8c relay (fixture gates and live gate)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6), run from the worktree `feat/m8c-relay`, whose code head is `1373553` (the merge of `origin/main` after the final fix wave `3cfa867..497a42c`); the documentation commit that records this adds no code but one comment in `Hub/crates/b4hub/src/relay/link.rs`. The fixture gates below ran first, without touching the owner's app or the Compose stack. The live gate followed (see "Live gate" at the end of this section).

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass (exit 0, no findings), rerun on the documentation commit's tree |
| Build and tests | `swift build`, then `swift test` | Pass: 779 tests in 116 suites in 54.0 s (517 at the end of M8b, 770 at Task 15). `swift test` exit 0 on `1373553` |
| Project | `./Scripts/generate-project.sh` | `B4App.xcodeproj` regenerated from `project.yml` |
| macOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **`, 0 warnings |
| iOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **`, 0 warnings |
| Rust format | `cd Hub && cargo fmt --all -- --check` | Pass (rerun on the documentation commit's tree) |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked`, then `./scripts/test-db.sh --stop` | Pass: 209 tests against a real PostgreSQL 17.11 (117 at the end of M8b): `b4hub` 136 (unit 41, `changes` 14, `enroll` 17, `health` 5, `relay` 59), `b4hub-core` 24, `b4hub-db` 49 (unit 3, `changes` 35, `migrate` 7, `rls` 4) |
| CI | the Swift package job, the apps job, and the Ubuntu `hub` job | Recorded in the PR for `feat/m8c-relay`, not here |

The Swift, clippy, and Rust-test results were read from one gate run on `1373553` (logs in the build session's scratchpad: `gate3-swift.log`, `gate3-clippy.log`, `gate3-cargo.log`); the format lints and both `xcodebuild` builds were run afterwards, in this worktree, on the tree that includes the documentation changes.

### Flaky tests fixed in the final wave

The final review found two tests that failed now and then under load. Both turned out to expose a real fault, fixed in production code (`2ee71b9`), and each was run 20 times in a row after the fix and again on the final head.

| Test | Cause | Result |
| --- | --- | --- |
| `MirrorModelTests.relayedDeltaStreamsThenSyncedItemReplacesIt` | Two races. The transport could start listening before the relay's subscription existed, so an early frame was lost; `MirrorRelay.updates()` now subscribes synchronously and the transport subscribes before its listener starts. And `WorkspaceClient.resetCursor` moved the cursor back after the model's startup `host.presence` had advanced it, so every later event read as a gap and was dropped (D-080). Reproduced by adding a delay in the listener task (5 and 20 ms passed, 100 and 300 ms failed); after both fixes delays of 0, 1, 2, 3, 5, and 100 ms pass. Covered by `WorkspaceClientTests.aSnapshotOlderThanDeliveredEventsKeepsTheCursor` (red before) | 20/20 passed, twice |
| `HubLinkRelayTests.aRefusedPushStopsTheLink` | The test asserted before the link had finished going offline; it now waits for `hub.status().link?.state == .offline` | 20/20 passed, twice |

### Live-gate items and the fixture evidence for each

The live gate is the spec's list (`docs/superpowers/specs/2026-11-01-m8c-relay-design.md`, "Not in CI"). The left column is its item; the rest is what the fixtures show and what they cannot.

| Live-gate item | Fixture evidence | Not covered by fixtures |
| --- | --- | --- |
| 1. Pair the Simulator: the Mac's sheet shows a QR code, the Simulator opens the link and confirms, the sheet closes with the device name | passed 2026-11-02 | Both accounts bootstrapped by hand (runbook 1, with GitHub's immutable OIDC subject pinned); PR plans run read-only against both (PR #44 onward); `apply-test` ran on the merge of PR #44 (it stopped at an SNS policy wildcard, fixed in PR #52, and plans clean since). |
| 2. Start a thread in a project from the phone, once on Codex or Claude and once on a managed local B4 connection; it appears on the Mac and its reply streams with tool calls | passed 2026-11-02 | Image: run 41378882037 and every push to `main` since. Deploy: the test hub served `sha256:f0d822d8…` (run 41508325663) and `sha256:7ab37b70…` (run 41534584558) within minutes of the merge; the migration task's log listed the applied migrations (9, then 11). |
| 3. Continue an existing Mac thread from the phone, with streaming | passed 2026-11-02 | `hub-v0.1.0` (run 41536625546): the `deploy` job waited on the `production` Environment, the owner approved, production deployed and the chart published; no `mac-v*` release has been cut, so that half is by construction (the jobs are guarded on the `hub-v` prefix). |
| 4. Answer an approval on the phone and the Mac's card resolves once; answer on the Mac first and the phone's tap reads "Already answered" (D-154: the phone now says nothing) | `SessionTests.answersAnApprovalExactlyOnce`, `simultaneousAnswersReachTheRuntimeOnce` (the second answer gets `stale_runtime_request`); hub: `answered_request_is_stale_without_forwarding`; phone: `SendStateTests.aStaleAnswerClearsQuietly`, `MirrorModelTests.theMacAnsweringFirstTakesTheCardAwayQuietly` (was `alreadyAnsweredCopy`) | Since `6baba39`: `RelayExecutorTests.relayedAnswerResolvesAPendingRequest`, `relayedAnswerToAnAnsweredRequestIsStale`, `HubLinkRelayTests.relayedInterruptAndAnswerRunFromTheLink`. Not covered: a real runtime approval card on both screens |
| 5. Stop a running turn from the phone | Phone: `SendStateTests.stopWaitsNinetySecondsThenNotConfirmed`; hub: `interrupt_is_held_and_delivered_on_reconnect`, `held_answer_expires_after_sixty_seconds`; `SessionTests` cover the interrupt itself | Since `6baba39`: `RelayExecutorTests.relayedInterruptStopsARunningTurn`, `HubLinkRelayTests.relayedInterruptAndAnswerRunFromTheLink`. Not covered: a real stop of a running Codex or Claude turn from the phone |
| 6. Stop the coordinator: "Reconnecting…", then after about 60 s the notice with the last-seen time, the list still browsable; a send is refused with that time; restart clears it | Hub: `send_to_an_offline_mac_is_refused_with_last_seen`, `last_seen_is_the_last_frame_heard_after_a_dead_link_close`, `a_device_never_reads_offline_before_its_last_seen_is_written`, `presence_reaches_clients_on_connect_and_drop`, `revoking_an_offline_mac_updates_the_phones_list`; phone: `HostPresenceTests.phasesConnectedReconnectingDisconnectedConnected` (on an injected clock), `disconnectedDisablesControlsButListAndTranscriptsLoad`, `offlineNotice`, `leftHubShowsNoticeAboveTheList`, `phoneLinkDownShowsConnectingToTheHub`, `SendStateTests.disconnectEndsTheRelayState`; link: `RelayLinkTests.pingsEveryTenSecondsAndReconnectsAfterThirtySilent`, `backoffDoublesToTheCapWithJitterAndResets`; Mac: `HubLinkRelayTests.wakeReconnectsAtOnce`, `pathChangeReconnectsAtOnce`, `leaveStopsTheLink` | A real coordinator stop and restart; the 60 s grace on a wall clock; the notice rendered; the Mac app's wake handler reaching `reconnectLink` (the sleep watcher and path monitor are what the tests exercise) |
| 7. "Keep the Mac awake" with the Mac joined: `pmset -g assertions` lists the coordinator's assertion; off, it is gone | `KeepAwakeTests.assertionHeldOnlyWhenEnabledAndJoined`, `leaveReleasesTheAssertion`, `stoppingTheCoordinatorReleasesTheAssertion`, `turningTheToggleOffReleasesAndOnTakesAgain`, `aRefusedAssertionIsReportedAsNotHeld`, `settingsAreServedOverTheSocketAndDiagnosticsShowTheAssertion`; `RemoteAccessTests.keepAwakeToggleSendsSettingsUpdate` | The real IOKit assertion: the tests use `FakePowerAssertions`, so `pmset -g assertions` has not been looked at |

Cross-language: `relay.json` decodes in the hub (`b4hub-core`) and in `RelayWireTests.relayFixtureRoundTrips`; `RelayWireTests.limitsMatchTheHub` pins the constants the two sides share; `changes.json` (now carrying `connections.projectId`) decodes in both suites. `URLSessionLinkTests` run `URLSessionHubLinkConnection` against a fake hub built on `NIOWebSocket` over loopback: the upgrade carries the bearer and `B4-Protocol` headers, frames go both ways, close codes and refused upgrades (401, 429) are reported.

### Live gate

Run on 2026-11-02 between 07:08Z and 07:37Z on the owner's MacBook Pro, from `feat/m8c-relay` at `207fa62` (the app and the hub image), with `88a8e3e` installed in the Simulator for the last check. Real runtimes: Codex and Claude Code; a managed local B4 server (`research`, `/Users/blove/repos/b4app-live-check`, route `/chat#agent`).

Setup:
- Backups first: `agent-workspace db backup` (288 rows) and a `pg_dumpall` of the hub (17 tables) in `~/Library/Application Support/b4app/backups/`.
- The Compose stack moved to the branch's `Hub/` on the same `hub_b4hub-db` volume; `migrate` reported "migrated: 4 applied, 0 pending" (`0004_relay`), and `/readyz` showed `{"migrations":"current"}`.
- The Mac app was packaged with `B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh` and swapped into `~/repos/b4app/dist`, with main's bundle parked in `dist-main/`; the old app and coordinator were stopped first and no stale cluster survived. `agent-workspace coordinator restart` brought the store to `0005_relay`.
- `agent-workspace hub status` then showed `relay connected since 07:22:20.802Z` and `awake kept awake`.
- The phone is the iPhone 17 Pro Simulator (iOS 26.5) against `http://localhost:8080`, built from the branch and installed over the M8b build.
- For item 2 the gate added one managed B4 connection, `research chat`, and started the `research` server. Both are left in place.

| Live-gate item | Result |
| --- | --- |
| 1. Pair the Simulator | Pass, with one part not exercised. The phone was logged out (its old device revoked). `hub.pair`, the command the "Pair iPhone…" sheet sends, minted a code at 07:24:02Z, and `xcrun simctl openurl booted "b4app://pair?..."` opened it. iOS asked "Open in 'Agent Workspace'?", then the app showed "Pair this iPhone with the hub at localhost?" with the device name. Pair was tapped at 07:24:10Z, and `hub.pairStatus` read `paired` ("iPhone 17 Pro") at 07:24:11Z. The Mac's QR sheet itself was not looked at (no screen-control grant while the owner was away); the QR round trip is unit-tested |
| 2. Start a thread from the phone (Codex, and a managed local B4 connection) | Pass. Codex: New thread → "B4 Run (Mac)" → Codex → Start at 07:25:00Z showed "Starting…", and the Mac created thread `546f3af9` in `/Users/blove/repos/b4run`, whose turn completed at 07:25:08Z. Local B4: for the automatic project `b4app-live-check` the sheet offered Codex, Claude Code, and `chat` (the route's name). It did not offer the attached, offline `chat @ 127.0.0.1`, and showed no folder step. Start at 07:27:52Z gave thread `5baa7fa3`, route-bound (`context` `/chat#agent`), reply "Hello from the phone." **Found:** the phone selected the new thread but did not open it. The sheets sat outside the split view's `showDetail` environment; fixed in `88a8e3e` and checked at 07:36:20Z, when the next thread started from the phone opened at once with its reply |
| 3. Continue a Mac thread from the phone | Pass. Sent into `b4run` at 07:25:25Z. The phone showed Running and Stop, then a Reasoning item, then the reply streaming mid-sentence at 07:26:30Z while the turn ran. The Mac's message (2350 characters) completed by 07:26:36Z, and the phone showed it once, with no doubled text |
| 4. Approval answered on the phone, and on the Mac first | Pass. A Claude Code thread started from the phone asked to run `touch /private/tmp/m8c-approval-1`. The phone showed the card ("Waiting for you"; Allow once, Allow for session, Deny). Allow once at 07:29:40Z created the file and completed the turn. A second request (07:30:08Z) was declined on the Mac first (`agent-workspace request respond --decline`, 07:30:15Z), and the phone's card cleared within about a second, before the phone's tap could reach it. The runtime saw one answer: no file, and Claude replied that the command was declined. The "Already answered" copy itself was not reachable through the screen, because the card had already cleared |
| 5. Stop from the phone | Pass. A Codex turn sent at 07:30:51Z; Stop at about 07:31:00Z; the Mac's turn was `cancelled` at 07:31:01.594Z, and the phone shows "Turn stopped." **Found (minor, not fixed):** after the stop, the transcript stayed scrolled past its new end (a blank view) until scrolled up |
| 6. Coordinator stopped and restarted | Pass. `agent-workspace coordinator stop` at 07:31:19Z: the open thread showed "Reconnecting to your Mac…" at once. A send at about 07:31:28Z was refused with "Brian's MacBook Pro (2) is offline · last seen 23:31"; the message was removed and the draft kept. At 07:32:22Z the thread and the list showed the persistent notice with Send and New thread disabled, and every thread still listed and opened. `agent-workspace coordinator restart` at 07:32:34Z: relay connected at 07:32:35.039Z, and the notice cleared within 2 s |
| 7. Keep the Mac awake | Pass for "on". `pmset -g assertions` listed `b4app-coordinator` `PreventUserIdleSystemSleep` "Agent Workspace keeps this Mac reachable from your phone" while joined with the toggle on. "Off" was not toggled live (fixture-tested) |

Also checked: the hub's log lines for the relay carry only method, outcome, and latency (none of the message text appears in `docker logs`). No change row holds a `secret:` reference or an executable path. The `connections` rows have `target`, `authReference`, and `localServerId` blank, with `projectId` set only on the managed B4 connection.

## 2026-11-02: M8e Part B, the relay on more than one instance (D-085, D-086)

Fixture run on the build Mac (`blove/m8e-relay-multi-instance`), against the throwaway PostgreSQL from `Hub/scripts/test-db.sh`: `cargo fmt --all -- --check` clean, `cargo clippy --workspace --all-targets --locked -- -D warnings` clean, `cargo test --workspace --locked` 245 passed, 0 failed (new: `b4hub/tests/instances.rs` 7, `b4hub-db/tests/instances.rs` 4, a maintenance-over-the-link test in `relay.rs`, and unit tests for the cookie, staleness, the probe identity, `close_user`, `relocated`, and `B4HUB_HEARTBEAT_MS`); `tests/instances.rs` passed three runs in a row. `swift test` 789 passed in 116 suites; `swift format lint --strict` clean. `terraform test` in `Infra/modules/hub` 51 passed (new: stickiness off for one task, on for two), `tflint` clean.

What the two-instance tests show (two `serve` instances in one test process, each on its own loopback listener, one database, different instance ids, a 200 ms heartbeat so the liveness window is 800 ms): a phone linking to the instance that does not hold its user gets `409 relocated` naming the owner, with no `Set-Cookie`, and nothing enters that instance's relay; the retry on the owner (with a `Cookie` header) is accepted with `Set-Cookie: b4hub-instance=<owner>` and completes a `turn.send` to the Mac and back; the same Mac is refused on the other instance three times while its link on the owner stays up, and a second link on the owner replaces the first with 4000; with the owner's heartbeat stopped the user is still refused halfway through the window and claimed by the other instance just after it, and when the owner's heartbeat resumes it closes the Mac's link with 1001, the Mac's reconnect to it is relocated to the new owner, and a command flows there; SIGTERM on an instance holding an interrupt for an offline Mac answers it `device_offline` before the phone's link closes with 1001, the drain finishes, the user's claim is gone, and the phone is claimed at once by the other instance; `/readyz` reports `"relay": "ok", "instances": "ok"` with the instance cookie, the probe never appears in the registry or the phone's frames, raising the relay's minimum client protocol above the hub's makes it `503 not_ready` with `details.relay: "failed"`, and lowering it restores `200`; with the heartbeat stopped for the window `/readyz` is `503` with `details.instances: "stale"` and recovers when it resumes. Over the link with maintenance on (50 ms poll), `turn.send`, `thread.start`, and `request.respond` get a `maintenance` reply with the HTTP guard's message and never reach the Mac, while `turn.lookup` and `watch` do; off again, a send is forwarded. Swift: a 409 at the upgrade is retried at once three times and the fourth backs off, a link resets the count, the last successful upgrade's cookies are sent on the next one and dropped after a 409, and over a real `URLSessionWebSocketTask` the `Cookie` header goes out and a `Secure; HttpOnly` cookie and an `Expires`-dated cookie on the `101` come back.

Not exercised: an AWS load balancer (the `AWSALBAPP` behaviour is from AWS's documentation), two tasks in a hosted environment, and the pending live gate: `task_count = 2`; a rolling deploy during an open phone link (one reconnect, the thread kept); a user re-linking during deregistration (between the ALB deregistering the old task and its SIGTERM, 5 s with two tasks) and connecting after its backoff; `/readyz` showing `relay: ok` on both tasks.

## 2026-11-02: Hub operability, Part A (D-073, D-074)

Fixture run on the build Mac for the request-id logging and maintenance mode branch (`blove/m8e-hub-operability-61a040`), against the throwaway PostgreSQL 17.11 from `Hub/scripts/test-db.sh`: `cargo fmt --all -- --check` clean, `cargo clippy --workspace --all-targets --locked -- -D warnings` clean, `cargo test --workspace --locked` 135 tests passed, 0 failed (b4hub 65 across the unit tests and `changes`, `enroll`, `health`, `maintenance`, `request_log`; b4hub-core 19; b4hub-db 51 across the unit tests and `changes`, `migrate`, `rls`, `settings`). What the new tests show: the id is a fresh UUIDv7 on every response and a caller's `X-Request-Id` never replaces it (a well-formed one is recorded as `client_request_id`, a malformed one is dropped and never appears in the log); the span's `path` is the route pattern and the raw path and query string appear nowhere in the log; a 5xx completes at `ERROR`; an authenticated `GET /v1/me` logs `request_id`, `client_request_id`, and `device_id` and never the bearer token, and a wrong token answers 401 with no `device_id` and without the wrong token in the log; `maintenance on` makes `POST /v1/changes`, `POST /v1/enroll`, and `DELETE /v1/devices/self` answer `503 maintenance` with `Retry-After: 30` and the full envelope within one 50 ms poll while `GET /v1/changes` (including a long-poll that waits out a 1 s window), `GET /v1/me`, and `/readyz` (`200`, `"maintenance": "read_only"`) keep answering; `maintenance off` restores writes within one poll; `b4hub_app` gets `42501` on `INSERT`, `UPDATE`, and `DELETE` against `hub_settings` and can `SELECT`; sqlx 0.8 applies a lower-numbered migration added after a higher one and refuses only the reverse. Not exercised: a hosted hub (none is deployed), CloudWatch's rendering of the JSON lines, and the Swift client's reaction to `503 maintenance` beyond what already holds for any hub error (the code is a free string; the outbox is kept on failure).

## 2026-11-01: Flavoured builds, entitlements, and packaging (sign-in plan, Task 2)

Run from `blove/sign-in` on macOS 26.5. Nothing was signed with a Developer ID identity, notarized, or uploaded.

| Check | Command | Result |
| --- | --- | --- |
| Project | `./Scripts/generate-project.sh` | Generated; schemes `B4App-macOS`, `B4App-macOS-Beta`, `B4App-iOS`, `B4App-iOS-Beta` |
| Four schemes | `xcodebuild build -scheme <scheme> -destination <platform=macOS or generic/platform=iOS Simulator> CODE_SIGNING_ALLOWED=NO` | Four `** BUILD SUCCEEDED **` |
| Info.plist | `plutil -p` on each built app | Mac local `com.cacheplane.b4app.local`, Mac beta `com.cacheplane.b4app.beta`, iOS local `com.cacheplane.b4app.ios.local`, iOS beta `com.cacheplane.b4app.ios`; `B4AppFlavor` and the `CFBundleURLSchemes` entry agree with each |
| iOS entitlements | Simulator builds signed ad hoc, `*-Simulated.xcent` | Beta: `webcredentials:test.b4.run`, `applinks:test.b4.run`, Sign in with Apple. Local: the same two with `local.b4.run?mode=developer`, no Sign in with Apple |
| Ad hoc packages | `B4APP_FLAVOR=local ./Scripts/package.sh` and `B4APP_FLAVOR=beta ./Scripts/package.sh`, no identity | `Agent Workspace (Local).app` and `(Beta).app` with `Agent-Workspace-Local-<v>.zip` and `-Beta-`; `B4AppFlavor` and the flavoured bundle id in the app and `B4AppCoordinator.app`; LaunchAgent plist and label `com.cacheplane.b4app.<flavour>.coordinator`; CLI identifier `com.cacheplane.b4app.<flavour>.agent-workspace`. The packaged CLI, run with no environment, emits the beta label, so the walk up to its `.app` works |
| Profile check, dry | `B4APP_CHECK_PROFILES_ONLY=1 B4APP_TEAM_ID=<team> B4APP_FLAVOR=<flavour> ./Scripts/package.sh` | Refuses for all three flavours, as intended: prod names the missing `webcredentials:b4.run` in the owner's existing profile; beta and local name the missing profile files, the associated domain, and each keychain group |

Open: a Developer ID package of any flavour. It needs profiles regenerated with Associated Domains (all flavours, app profile) and new App IDs for beta and local (`~/.b4app/signing/{app,coordinator}-{beta,local}.provisionprofile`), so `codesign -d --entitlements -` on a signed local package, listing the associated domain and both keychain groups, is not yet run. The checks that match profile contents against the flavour were exercised only with hand-written profiles, not Apple-issued ones.

## 2026-11-02: Hosted hubs (D-068 to D-072)

Implementation is on `blove/cloud-hub-deployment-arch-4b6348`; nothing has been applied to AWS, because the owner has not created the AWS Organization or the two accounts. The gates are the eight in `docs/deployment-architecture.md` ("Verification gates"), plus 2b (the 9 MiB push through the WAF). Each is `passed` (with evidence), `pending` (with the step that produces the evidence and what it must show), or owned by another project. A gate that needs a live hub is never `passed` from a mock.

| Gate | Status | Evidence, or what will close it |
| --- | --- | --- |
| 1. Both accounts bootstrapped; `terraform plan` from a PR is clean and read-only; `apply` from `main` reaches test with no human step | pending | Needs the owner's accounts. Close with the "Bootstrap runbook" in `Infra/README.md` for both accounts, then the first apply; it must show a `plan` comment on a PR with no changes after the apply, and an `infra.yml` run on `main` whose `apply-test` job runs with no approval. Offline only: `terraform fmt`, `validate` of the roots, `tflint`, and `terraform test` with mocked providers (bootstrap 9 passed, hub module 49 passed). No plan or apply has run. |
| 2. A merge to `main` produces a multi-arch image on GHCR with attestations; the test hub serves that digest within 15 minutes; the migration task's log shows the migration list | image half passed, deploy half pending | Image half, 2026-11-02: the `hub-image.yml` dry run on the branch (a temporary push trigger, since dispatch needs the file on the default branch), https://github.com/cacheplane/b4app/actions/runs/41378882037, all jobs green (`changed`, `build` on amd64 and arm64, `merge`, `check`); the index `sha256:e133ca31...ac82` lists `linux/amd64`, `linux/arm64`, and two attestation manifests; `gh attestation verify oci://ghcr.io/cacheplane/b4hub@sha256:<digest> -R cacheplane/b4app` exited 0; `Hub/scripts/check-image.sh` passed (the `check` job of https://github.com/cacheplane/b4app/actions/runs/41378882037). Deploy half: after runbook 4 ("First deploy") the `deploy-test` job must show the pushed digest, the log group `/b4hub/test/migrate` must list the migrations, and `https://hub.test.b4.run/readyz` must report `"migrations":"current"` within 15 minutes of the merge. The deploy and chart scripts pass bats (48 tests in `Infra/scripts/tests`, local run after the review cleanup) against stub `aws`, `docker`, and `curl` only; nothing has run against AWS. |
| 2b. A 9 MiB `POST /v1/changes` from the Mac client through the WAF is accepted | pending | Needs the test hub and its WAF (D-071: no body-inspecting managed rule group). Close by pushing a 9 MiB batch from the Mac client to `https://hub.test.b4.run/v1/changes`; it must be accepted (200), with no WAF block in the web ACL's sampled requests. |
| 3. A `hub-v*` release deploys production after the owner's approval; a `mac-v*` release deploys nothing | pending | Needs production and the `production` GitHub Environment. Close by publishing `hub-v0.1.0`: the `deploy` job of `hub-release.yml` must wait for the Environment approval and then deploy the release digest; a `mac-v*` release must show that job (and `promote`) skipped. Offline: `.github/scripts/test-tag-guard.sh` and `actionlint` run in CI's lint job. |
| 4. Sign in with a passkey against `hub.test.b4.run`, pair, and run a relayed turn from a packaged Mac app and a TestFlight iPhone | owned by the sign-in project and M8c | Those projects' live gates, run against this hub once gates 1 and 2 pass. Not run. |
| 5. A deploy during an open WebSocket: the phone reconnects within the backoff window and no change is lost | pending, needs M8c | The relay's WebSocket is M8c, which is not merged. Close after M8c: hold a phone session open, deploy a digest (runbook 5), and compare the device's cursor before and after; it must reconnect inside the backoff and the cursor must be unchanged. |
| 6. `aws ecs stop-task` by hand: the alarm fires, Better Stack pages, ECS replaces the task | pending | Needs the test hub, the confirmed SNS email, and the Better Stack monitor. Close by stopping the test task (runbook 9, "Incident basics", for the commands and first look); expect the running-tasks alarm email, the Better Stack phone page, and a replacement task healthy on `/readyz`. |
| 7. Restore drill, once end to end in the test account | pending | Needs the test database. Close with runbook 8 ("Restore drill"); it must end with the drill's own verification step passing and the scratch instance removed. |
| 8a. `docker compose --profile tls up` from the self-hosting docs on a clean VM reaches `/readyz` | partly passed | `Hub/deploy/compose/test.sh` passed on the build Mac against the locally built image (`b4hub:check`): `readyz` reported `"migrations":"current"`, the `migrate` service exited 0, and teardown removed the containers, volume, and network (no durable record). That is the first-boot path on a Mac, not a clean VM, and not the `tls` profile. The CI `compose-smoke` job in `hub-image.yml` exists but has not run on `main`. Close by running `test.sh` on a clean Linux VM, then the `tls` profile there with a real hostname. |
| 8b. `helm install` of the chart on kind with a CloudNativePG cluster reaches `/readyz`; the hook Job shows the migration | passed | `hub-chart.yml` on GitHub, 2026-11-02: https://github.com/cacheplane/b4app/actions/runs/41389901877 (push) and https://github.com/cacheplane/b4app/actions/runs/41390300766 (dispatch), lint and install green: kind v0.31.0 on node v1.31.14, CloudNativePG chart 0.29.1, both migrate hook Jobs `Completed`, `applied migrations: 3`, `/readyz` reported `"migrations":"current"`, the upgrade moved the Deployment from revision 1 to 2, and uninstall left nothing behind. The image was `ghcr.io/cacheplane/b4hub:blove-cloud-hub-deployment-arch-4b6348`. The same script passed locally (kind 0.32.0). A dispatch with the default `image_tag=main` (https://github.com/cacheplane/b4app/actions/runs/41389942642) failed fast on `:main: not found`: no `main` image exists until `hub-image.yml` runs on `main`, a bootstrap condition and not a chart fault. Not covered: publishing the chart to GHCR (skipped in every run; it happens on a `hub-v*` release). |

Static checks run in CI and locally: `actionlint`, `shellcheck` over the deploy and chart scripts, `helm lint --strict`, `helm unittest` (56 tests locally after the review cleanup; 47 on GitHub before it), `ct lint`, and `kubeconform` for five value variants against Kubernetes 1.31.0.

### Owner steps outstanding

Every pending gate above waits on these (details in `Infra/README.md`). None is recorded as done.

1. Create the `b4hub-test` and `b4hub-prod` accounts inside the `b4run` OU of the existing cacheplane Organization (runbook 1, "Bootstrap runbook"). Done 2026-11-02: `355069727528` and `268895852483`.
2. Sign the CLI in with `aws login` and configure the `b4hub-test` and `b4hub-prod` profiles (done 2026-11-02: both answer `sts get-caller-identity`), then bootstrap both accounts (runbook 1, "Bootstrap runbook"). Test bootstrapped 2026-11-02 (18 resources; state in `b4hub-test-tfstate`, plan clean after migration; roles `b4hub-test-{plan,infra,deploy}`, state key `d9c975b5-6ea7-4610-99ae-7020f3091262`; re-applied the same day to pin GitHub's immutable OIDC subject `repo:cacheplane@269322961/b4app@1440075505`, without which `Plan test` failed `AssumeRoleWithWebIdentity`). Prod bootstrapped 2026-11-02 the same way (state in `b4hub-prod-tfstate`, state key `496dd803-4674-4422-b959-3e74e44043bd`, plan clean). Repository variables `AWS_ROLE_PLAN_<ENV>` and `TFSTATE_KMS_KEY_ARN_<ENV>` are set for both so PR plans run; `AWS_ROLE_INFRA_<ENV>` and `AWS_ROLE_DEPLOY_<ENV>` are deliberately withheld until `B4HUB_ALARM_EMAIL`, the Vercel CNAMEs, and (for prod) the `production` Environment exist, since a push to main would otherwise apply the test hub root. `B4HUB_ALARM_EMAIL` set 2026-11-02. ACM certificates for `hub.test.b4.run` and `hub.b4.run` were created by targeted applies the same day; their validation CNAMEs were added at Vercel and the apex CAA set gained the four Amazon issuers beside Vercel's three (a CNAME cannot share a name with CAA, so the hub names inherit the apex set); both certificates were issued within minutes. Test hub root applied by CI on the merge of PR #44; `hub.test.b4.run` CNAME to the ALB added the same day. Runbook 2 (database owner) done in test 2026-11-02 (the psql session driven through a pty; `b4hub_owner` and database `b4hub` created, real URLs in both secrets); runbook 3 done except the Apple private key. First test deploy (run 41508325663, digest `f0d822d8…`, sign-in included): migrations applied (9), service at revision 4 with the rollout COMPLETED and desired count 0; the job itself reported failure because `deploy.sh` read the rollout state before ECS flipped it, fixed by the bounded settle loop in this change. Apple private key stored and the service scaled to one task by hand (runbook 4) on 2026-11-02: `https://hub.test.b4.run/readyz` answers `{"ok":true,"migrations":"current","relay":"ok","instances":"ok","minClientProtocol":1}` with a valid certificate, the ALB target is healthy, and the hub's JSON request log reaches CloudWatch. The `RunningTaskCount` and `UnHealthyHostCount` alarms were created by a local apply; PR #56 records `desired_count = 1` so main agrees. The GHCR package was made public the same day (the organization's package policy had to allow public packages first).
3. Add repository variables: `AWS_ROLE_PLAN_*`, `AWS_ROLE_INFRA_*`, `AWS_ROLE_DEPLOY_*`, `TFSTATE_KMS_KEY_ARN_*` (`TEST` and `PROD`), and `B4HUB_ALARM_EMAIL`.
4. Create the `production` GitHub Environment (required reviewer: the owner; deployment branches and tags: `main` and `hub-v*`). Create none for test. Done 2026-11-02 (the Environment had been auto-created empty by a workflow run; reviewer `blove`, branch `main`, tag `hub-v*`).
   Runbook 6 done in test on 2026-11-02 after two admin-task fixes (the hub container needed `B4HUB_APPLE_AUDIENCES` with the sign-in secrets, and a writable root filesystem for ECS Exec): `b4hub seed` created org `cacheplane` and user `blove`, `b4hub enroll` minted a code, and `agent-workspace hub join https://hub.test.b4.run` on the owner's Mac reports `account blove@cacheplane`, `relay connected`.
5. Make the GHCR package `ghcr.io/cacheplane/b4hub` public. Done 2026-11-02 (the organization's package policy had to allow public packages first).
6. Add the Vercel CNAMEs (`hub.test.b4.run`, `hub.b4.run`) and the ACM validation records the first apply prints. Done 2026-11-02 for both hostnames.
7. Set the database owner and sign-in secrets (runbooks 2 and 3). Done 2026-11-02 in both accounts, except the production Apple private key.
8. Flip `desired_count` from 0 to 1 in each env root after the first deploy (runbook 4). Done for test and prod 2026-11-02 by `update-service` (Terraform ignores `desired_count` drift by design, so the edit only adds the task-gated alarms).
   Production hub root: applied by hand on 2026-11-02 after allowing AWS Backup and KMS in `us-west-2` in the Organization's region SCP (it had denied them, which would have stopped the apply at the copy vault); `AWS_ROLE_INFRA_PROD` and `AWS_ROLE_DEPLOY_PROD` set the same day, so later applies go through CI with the `production` reviewer. The exception also needed `backup-storage:*`. Prod runbook 2 done the same day (`b4hub_owner`, database `b4hub`, real URLs in both secrets) and runbook 3 except the Apple private key; `hub.b4.run` CNAME points at the prod ALB. Apple private key stored, release `hub-v0.1.0` cut from `a95c83d` and approved by the owner on 2026-11-02: 11 migrations applied, service at revision 2, chart 0.2.0 published to `oci://ghcr.io/cacheplane/charts/b4hub`; scaled to one task by `update-service`, target healthy, `https://hub.b4.run/readyz` ok with migrations current and the relay probe passing; `desired_count = 1` recorded with the two task-gated alarms applied. The owner's Mac moved to prod the same day (`hub leave` from test, then runbook 6 against prod: `account blove@cacheplane`, `relay connected`).
9. Create the Better Stack monitors on both `/readyz` URLs with phone escalation and the status page at `status.b4.run` (a Vercel CNAME); confirm the SNS subscription email; subscribe to the AWS Health Dashboard, GitHub status, and Apple status.
10. Set the repository variable `HUB_GHCR_CLEANUP_LIVE=true` after one dry run of `hub-ghcr-cleanup.yml`.

## 2026-11-01: iPhone follow-ups (D-060, fixture gates and Simulator)

Run from `blove/iphone-hig-followups` (on `main` at `4552bdb`) on macOS 26.5 with Xcode 26.6, iPhone 17 Pro Simulator (iOS 26.5).

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 573 tests in 99 suites pass |
| Mac app | `xcodebuild build … -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Read-only Settings | Simulator: Settings › Connections and › Local servers | Connections shows its two cards with status and account only, and the sentence about the Mac; no Add section, Check, Sign in, or Re-check runtimes. Local servers shows the sentence and "No projects registered on your Mac."; no Add a project or server controls |
| Titles follow the text size | `xcrun simctl ui <udid> content_size accessibility-extra-large`, then `large`, with the screen open | The open Connections large title grew in place; a thread's inline title measured 140.7 pt wide at Large, 166.0 pt at AX3, and 140.7 pt again after switching back, without leaving the screen |

`docs/screenshots/ios-hig-followups.png`. The Mac's pages are unchanged (`WorkspaceDevice.managesWorkspace` is true there; the server controls moved into a property, same views).

## 2026-11-01: Composer (D-061, fixture gates, Simulator, and Mac snapshots)

Run from `blove/ios-mobile-fit` after the merge of `main` (#31) on macOS 26.5 with Xcode 26.6, iPhone 17 Pro Simulator (iOS 26.5).

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 573 tests in 99 suites pass, including `ThemeTests.composerChoosesLineOrBox`. The first run failed `DetailMinimumSizeTests` (the Mac detail's minimum height 1317 pt against 548): the turn caption above the field wrapped a character per line at zero width; it is two lines at most on the Mac now |
| Mac app | `xcodebuild build … -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Phone geometry | 3x screenshots scanned pixel by pixel | Box with one line 74.3 pt tall; send 32 pt, 6.0 pt from the trailing and bottom edges; text 16 pt in, its cap-height centre 21.5 pt from the top (22 is the centre of a 44 pt line); three lines 116 pt, the fourth scrolls |
| Mac geometry | `B4APP_SNAPSHOT_DIR=… swift test --filter SnapshotTests`, 2x | One-line capsule 44 pt; stop 32 pt, 6 pt from the top, trailing, and bottom edges; text 16 pt in, cap centre at 21.3. The first capture showed flattened capsule ends (continuous corners); circular corners fixed it |
| Behaviour | Simulator | Typing grows the field a line at a time to three, then scrolls; Return adds a line; the field rides 8 pt above the on-screen keyboard; the caret is cobalt; the transcript scrolls under the field behind the soft edge; at AX3 the button grows to 48 pt and stays concentric; dark mode reads on the theme's surface and rule |

`docs/screenshots/composer.png` shows the phone empty, at three lines, with the keyboard, and at AX3 in dark, and the Mac's line. Open: the iPad's one-line shape was checked through the Mac (the same code path); no iPad Simulator is enrolled with the hub. Test drafts typed on the phone were cleared afterwards.

## 2026-11-01: iPhone sizes, targets, and accessibility text sizes (D-060, fixture gates and Simulator)

Run from `blove/ios-mobile-fit` (on `main` at `2e05bad`) on macOS 26.5 with Xcode 26.6; the iPhone 17 Pro Simulator (iOS 26.5) showed the mirror of the Mac's threads through the local Compose hub.

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 572 tests in 99 suites pass |
| Mac app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Mac unchanged | `B4APP_SNAPSHOT_DIR=$TMPDIR/b4snap swift test --filter SnapshotTests` | The sidebar, profile menu, and Settings pages draw at the desktop scale as before (by eye) |
| Phone, default size | Simulator build with team `GJJKL34HCT`, `xcrun simctl ui <udid> content_size large`, screenshots before (`main`) and after | `docs/screenshots/ios-hig-default.png`. Sidebar and thread rows measured 28 pt tall on a 52 pt pitch before and 44 pt on a 44 pt pitch after (selection highlight, 3x screenshot); profile-menu items 28 to 44 pt; body text 15 to 17 pt; one title on the thread instead of two |
| Phone, AX3 | `content_size accessibility-extra-large` | `docs/screenshots/ios-hig-ax3.png`. Before: symbols ran into labels, the avatar and marks stayed small, "completed" broke inside its badge, the command title truncated to "/b…md'". After: titles wrap, the card and header stack, Diagnostics and Connections read label above value, Send drops below the editor |
| Hit regions | Taps 3 pt inside a thread row's top edge on its empty right side, and on a transcript card's padding | The row opened its thread; the card toggled Show/Hide |

Design review (same branch, after the first gates): New thread, Search, the More menu, Settings, and Connections were added to the pass, in light and dark (`xcrun simctl ui <udid> appearance dark`) and at AX3. The fixes are listed under D-060; `docs/screenshots/ios-hig-review.png` shows New thread before and after and the dark Settings and Connections pages. Gates rerun after the fixes: lint clean, `swift test` 572 tests in 99 suites pass, both app builds succeed, the 7 Mac `SnapshotTests` pass. The Hanken navigation titles are computed when the app starts, so a text-size change while it runs takes effect at the next launch (system inline titles barely scale either).

Open: the Connect screen was checked in code only (the phone is joined, and leaving would need a new enrollment code); its fields and button were already 44 pt and now share the 16 pt margin and the phone scale. No `performAccessibilityAudit` UI test exists yet (no XCUITest target).

## 2026-11-01: Sidebar, profile menu, and Settings window (D-053, fixture gates)

Run from `blove/sidebar-profile-menu` at `42e329f` (on `main` after #25) on macOS 26.5.

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 556 tests in 94 suites pass |
| Mac app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Snapshots | `B4APP_SNAPSHOT_DIR=$TMPDIR/b4snap swift test --filter SnapshotTests` | 7 tests pass; sidebar, profile menu, search, notice, not signed in, Host disconnected, and the three Settings pages in light and dark compared by eye with the mockups. The first profile-menu capture showed the panel over the button; fixed in `42e329f` and captured again |

New tests: `ThemeTests` (`runtimeMarksLoad`, `parserHandlesArcsAndPackedNumbers`), `HubSyncTests` (`joinReportsTheDisplayName`, `leaveClearsTheDisplayName`, `restartFetchesTheDisplayName`), `AccountModelTests` (initials of odd names, log out and its failure, the phone's host-supplied account, the status line), `SettingsRequestTests`, `SearchPaletteTests`, `ThreadListTests.rowSpeaksItsReasonAndConnection`, `DevicePresenceTests` (an empty devices list is not a lost host), and `DetailMinimumSizeTests` (`sidebarFooterStaysBounded` at 240 pt with every notice at 3,000 characters; `settingsFitsItsMinimum` at 760 × 500 for each page).

Final review (a fresh reviewer over `a03a230..42e329f`) found no critical issues and six important ones, fixed in `088ba69`: iPhone search did not move to the thread it opened; the phone's Log out kept the outbox of unsent edits (now `MirrorLogOut` in `WorkspaceMirror`, with `MirrorLogOutTests`); the display name was never fetched again after a failed `/v1/me` (`aFailedNameFetchIsRetriedAfterTheNextSuccessfulPush`); the Mac's account did not refresh after a CLI join or leave (it now refreshes when the window becomes active); thread-row context was in the accessibility hint rather than the label; and two empty SVGs had shipped. After the fixes, at `088ba69`: lint clean, `swift test` 559 tests in 95 suites pass, both `xcodebuild` builds succeed.

Not run: the live checks (`B4APP_LIVE_*`), and the app on screen. Log out against a real hub, "Host disconnected" on a real phone, and ⌘, / ⌘K / ⌘N in the running app are still to be checked by hand.

## 2026-11-01: Coordinator robustness (D-052)

- `HubSyncTests.aKeychainPromptIsReportedAndTheTokenIsReadOncePerRun`: with the secret store's read held open (an unanswered prompt), `hub status` answers and names the Keychain wait; after release the push drains and later pushes and the pull reuse the one read.
- `KeychainCallTests`: a Keychain call made from the main actor runs off it, and its error reaches the caller.
- `PostgresServerTests.replacesAPostmasterFromAnotherInstall` and `aPostmasterRunningAnotherBinaryIsNotThisInstalls`: a server whose binary was written after it started, or that runs another file, is stopped and replaced; this install's own server is still adopted.
- `ReasonLineTimeTests`: a reply up to a minute old, or a few seconds in the future, reads "Replied just now".
- Manual, scratch coordinator with the fake Codex: `turn send <id> please hang around --no-wait` returned in 0.05 s and the stored message was "please hang around".

## 2026-11-01: distribution, provisioning, and the Mac keychain (D-051)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, XcodeGen 2.46.0). Research: `docs/research/reports/App Store and TestFlight signing.md`. The owner's running app and coordinator were left alone; the package checks ran in the worktree's own `dist/` and a scratch runtime and data directory.

| Check | How | Result |
| --- | --- | --- |
| File-based keychain across rebuilds | A throwaway tool (`com.cacheplane.b4app.kcprobe`) with `SecKeychainSetUserInteractionAllowed(false)` added an item, then was rebuilt to a new CDHash and read it | Developer ID rebuilds: read OK with no prompt. Ad hoc rebuild: `-25293` (it would have prompted). Probe item deleted |
| Data-protection keychain without a profile | The same probe, Developer ID, `kSecUseDataProtectionKeychain` | `-34018` "A required entitlement isn't present", as TN3137 says |
| iOS, as CI builds it | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` | Pass |
| iOS Release bundle | The same, `-configuration Release`, signing to run locally | `ITSAppUsesNonExemptEncryption = false`, the local-network string, versions from build settings (0.1.0, 1), `PrivacyInfo.xcprivacy` in the bundle, no `NSAppTransportSecurity`; the Debug build keeps the localhost exception |
| macOS, as CI builds it | `xcodebuild build -scheme B4App-macOS CODE_SIGNING_ALLOWED=NO` | Pass |
| Coordinator bundle | `B4APP_SKIP_PROFILES=1 B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: Brian Love (GJJKL34HCT)" ./Scripts/package.sh` | `Contents/Helpers/{B4AppCoordinator.app,agent-workspace}`; identifiers `com.cacheplane.b4app.coordinator` and `com.cacheplane.b4app.agent-workspace`, hardened runtime, team GJJKL34HCT; the bundle's LaunchAgent plist names `Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator` |
| Wrapped coordinator runs | The package's CLI `doctor` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`, then `coordinator stop` | Spawned the wrapper's executable, which found `SharedSupport/postgres` and served; `secrets: login keychain (file-based)` (no profile) |
| Suite, lint | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass: 334 tests in 76 suites; lint clean. A first incremental run crashed (SIGSEGV decoding `DiagnosticsReport`) because the test bundle was linked against the old `CoordinatorInfo` layout; clearing `.build/arm64-apple-macosx/debug` fixed it |

### Live, with the owner's profiles and API key

Both Developer ID profiles (App IDs `com.cacheplane.b4app` and `com.cacheplane.b4app.coordinator`, Keychain Sharing group `GJJKL34HCT.com.cacheplane.b4app.shared`, expiring 2044-10-27) are tied to the Developer ID certificate under the Previous Sub-CA, which expires 2027-02-01; the profiles must be regenerated with its successor.

| Check | How | Result |
| --- | --- | --- |
| Notarized package with profiles | `B4APP_SIGN_IDENTITY="Developer ID Application: Brian Love (GJJKL34HCT)" ./Scripts/package.sh` at `3cff73e` (this branch merged with M8b) | Submission `63e2dc2a-7047-4372-acf2-9ed722f13cfd` Accepted, stapled; `spctl`: `source=Notarized Developer ID`; `syspolicy_check distribution` passed. An earlier package before the merge: `c541ae47-b369-4aed-8773-34bf4c56b98e`, same results |
| Installed on the owner's Mac | Old `dist/` moved aside, the zip unpacked, `Agent Workspace --register-agent` | The LaunchAgent names `Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator`; launchd started it; `doctor`: `secrets data-protection keychain (GJJKL34HCT.com.cacheplane.b4app.shared)` |
| Moving the existing items | First read of the hub token by the new coordinator | **Failed, and lost the token.** The read prompted once (the item's ACL named the old ad hoc coordinator), was allowed, and the value was written to the group; then the delete of the login-keychain copy, which set no `kSecUseDataProtectionKeychain`, also deleted the new copy: an entitled process with no flag deletes from both keychains. The next read found nothing, so the hub answered 401. Found from the coordinator's unified log (`SecItemAdd_ios`, then `SecItemDelete_ios`). The coordinator was stopped before it read the one other item (`secret:0bfa…`), which is still in the login keychain |
| The fix | `3062544`: every query sets `kSecUseDataProtectionKeychain` explicitly; `everyQueryNamesItsKeychain` | An entitled probe (`com.cacheplane.b4app.coordinator`, the coordinator profile and entitlements) compiled from `Secrets.swift` on a throwaway service: the old file loses the item on the second read, and even after `put`; the fixed file migrates it, keeps it, updates and removes it. With an explicit `false`, a delete leaves the group's copy alone |
| Fixed build installed | The same package at `82569b2`, swapped in the same way | Submission `cf6cb03e-7468-4733-819f-0e5d3245bfd4` Accepted; `spctl`: `source=Notarized Developer ID`; the coordinator started from the wrapper on the data-protection keychain; `secret:0bfa…` still in the login keychain; the hub still 401 (no token) |
| Re-joined, on the fixed build | `hub leave` (local only; the hub refused the revoke without a token), a code from `docker compose run --rm migrate enroll --user blove` on stdin to `hub join http://localhost:8080`, then `coordinator restart` and the app opened | New device "Brian’s MacBook Pro (2)" (`01a1988c-…`, the Mac's current name); 188 changes pushed, `unsynced 0`; the token went straight into the group (the login keychain still holds only `secret:0bfa…`); after the restart every hub request read it and got 200, with no `last error`; the app attached to the running coordinator over its socket. The old device `01a194cf-…` stays at the hub, unrevoked, with no usable token |
| iOS archive and export | `B4APP_ASC_KEY_ID=… B4APP_ASC_ISSUER_ID=… ./Scripts/upload-ios.sh` | The archive is unsigned (an automatically signed archive needs a registered device, and the team has none); the export registered the App ID and signed with a cloud-managed Apple Distribution certificate and "iOS Team Store Provisioning Profile: com.cacheplane.b4app.ios" |
| iOS upload | The same script | Xcode 26.6's `destination: upload` failed ("Cannot verify client's JWT headers") with the same key that had just provisioned the export; `altool --validate-app` then `--upload-app` with that key passed. Build 0.1.0 (2611011615), delivery `f960f188-4368-4338-a1e2-1da8fab89c11` |

Open: the move of the remaining login-keychain item (`secret:0bfa…`, created before the hub join) on its first read by the fixed build; revoking the old Mac device at the hub, which has no operator command yet; adding the TestFlight build to an internal group and installing it on a phone.

## 2026-11-01: M8b live gate

Run on the owner's MacBook Pro (macOS 26.5) from `feat/m8b-organisation` at `2c5ccef`, plus `87a494e` (the phone's project rename, found missing below). Backups first: `agent-workspace db backup` (152 rows) and `pg_dump` of the hub (13 tables), both in `~/Library/Application Support/b4app/backups/`. The Compose stack moved to the branch's `Hub/` on the same `hub_b4hub-db` volume: migration `0003_organisation` applied, `/readyz` `{"migrations":"current"}`. The packaged app was rebuilt with `./Scripts/package.sh` and swapped into `~/repos/b4app/dist` (main's bundle parked in `dist-main/` for the restore). The store migrated to `0004_organisation` and backfilled 2 projects. Then `agent-workspace hub status` showed `unsynced 0` and the coordinator a pid started at 14:40:00Z. The phone is the iPhone 17 Pro Simulator against `http://localhost:8080`. Real runtimes: Codex 0.166.0 and Claude Code.

| Exit item | Result |
| --- | --- |
| 1. Attention order on both devices | Pass. The phone list opened with both threads quiet (the `0004` backfill). A Codex reply moved its thread to the top as unread. A Claude Code turn asking to run `touch` opened a `tool_permission` request at 14:50:39.9; the phone showed the thread first with the cobalt dot and "Waiting for your input". Declined on the Mac at 14:53:50.9 (`request respond --decline`): the phone showed "Working" (ring) below the unread thread within seconds, then unread when the reply finished. Opened on the phone at 14:54:03.8: the Mac's `readTurnId` matched the latest turn 0.15 s later. The Mac sidebar showed "Pinned" and a collapsible "B4 Run (Mac)" section, with the b4app section hidden while its only thread was pinned |
| 2. Phone and Mac edits show on the other | Pass, each within about 1 s of the tap: pin (14:54:11), thread rename (14:54:23 at the hub, on the Mac by 14:54:25.2), draft (14:54:28; `draft.read` on the Mac returned it), archive (on the Mac 0.14 s after the tap), and project rename (on the Mac 0.2 s after). Reverse, from the CLI and the socket: title, unpin, unarchive, pin, project rename, and draft all showed on the phone within a few seconds. The project rename needed `87a494e`: the phone had no rename control, although the spec gives the phone that edit and the mirror already answered `project.rename` |
| 3. Live convergence | Pass. `docker compose stop hub` at 14:58:32 (the phone showed "Not synced"). The phone renamed the thread "Offline phone title" and drafted "Offline phone draft"; then the Mac set "Offline Mac title" and "offline Mac draft" (4 unsynced). `docker compose start hub` at 14:58:57. The phone's edits reached the hub at 14:59:03 and the Mac's at 14:59:13, with greater clocks (`…1979ecbc9` over `…1979ea41b`). By 14:59:14 the Mac showed `unsynced 0`, and both devices showed the Mac's title and draft. The reversed-clock order is fixture-tested only |
| 5. The real hub's rows | 198 change rows over `connections`, `displayItems`, `drafts`, `projectFolders`, `projects`, `runtimeRequests`, `threads`, `turns`: none holds a `secret:` reference, an executable path, a `pid`, or a socket path |

Found during the run, outside the exit items:

- **Keychain prompt blocks the hub actor.** Each ad-hoc `package.sh` rebuild changes the coordinator's signature, so its first read of the hub token raises a Keychain access prompt. Until someone answers, `HubSync` is suspended inside `SecItemCopyMatching`: nothing pushes, and `hub status` times out after 15 s. The coordinator that main's 2026-10-31 rebuild started sat there for 8 hours. Answering the prompt cleared it.
- **A stale cluster survives a coordinator swap.** That stuck coordinator did not exit within `coordinator stop`'s 10 s, and when it did go it left its PostgreSQL server (started from the old bundle) running. The new coordinator reused that server, and `0004` failed: the server could not `dlopen` the new bundle's `plpgsql.dylib`, whose ad-hoc signature differs. The migration rolled back. After `pg_ctl stop` with the old bundle's binaries, the new coordinator started its own server and migrated.
- **Simulator team prefix.** With the Developer ID certificate now installed, Xcode signs Simulator builds as `GJJKL34HCT.com.cacheplane.b4app.ios` instead of `FAKETEAMID…`, so the reinstalled app could not read the token the earlier build had stored, and every request got a 401. The Simulator was enrolled again (the old phone device revoked at the hub).
- `agent-workspace turn send --no-wait` did not return after the turn opened a request; the request itself was recorded correctly.
- A just-finished reply reads "Replied in 0 sec." on the phone when its time is a moment ahead of the phone's clock.
- The Codex connection runs with its sandbox off, so a Codex turn never opens a command approval; the approval check used Claude Code.

## 2026-11-01: M8b final-review fix wave (fixture gates)

Run from `feat/m8b-organisation` at `446c8c0` (six commits over `6baea96`: read marks wait for the thread to be on screen; `0004` backfills `readTurnId` and indexes `runtimeRequests("threadId", "state")`; the phone's push is capped at 8 MiB and unsent edits of one column collapse; an advisory lock orders local writes against pulled batches; a router test waits for its events; README and D-048/D-049). `Hub/` was not touched, so the Rust gates were not rerun. The live gate below is still pending.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 526 tests in 89 suites in 37.7 s, no issues on the first run |
| Project | `./Scripts/generate-project.sh` | Regenerated |
| macOS app | `xcodebuild build ... -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iOS app | `xcodebuild build ... -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |

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

## 2026-10-31: Developer ID signing and notarization (D-039 gate)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, notarytool 1.1.2). The owner created the certificate and the `b4app` notarytool profile; neither password passed through the script or this session. The owner's running app was quit, `~/repos/b4app/dist` was moved aside and replaced from the stapled zip, `agent-workspace coordinator restart` ran, and the app was reopened.

| Check | How | Result |
| --- | --- | --- |
| Identity found | `security find-identity -v -p codesigning` | 1 valid identity: `Developer ID Application: Brian Love (GJJKL34HCT)` |
| Notary profile | `xcrun notarytool history --keychain-profile b4app` | Succeeds ("No submission history.") |
| Signing | `B4APP_SIGN_IDENTITY="Developer ID Application: Brian Love (GJJKL34HCT)" ./Scripts/package.sh` | Every PostgreSQL Mach-O, both helpers, and the bundle signed with `flags=0x10000(runtime)` and a secure timestamp; `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement; `TeamIdentifier=GJJKL34HCT`; entitlements an empty dictionary |
| Before notarization | `spctl -a -vv --type exec` | `rejected`, `source=Unnotarized Developer ID` (expected; the script shows it and goes on) |
| Notarization | `xcrun notarytool submit … --keychain-profile b4app --wait` | Submission `7f19144e-ec91-40b3-95ab-928ac1221b32`: **Accepted** on the first submission, no entitlement changes |
| Stapling | `xcrun stapler staple`, `stapler validate`, then re-zip | "The staple and validate action worked!"; the shipped `dist/Agent-Workspace-0.1.0.zip` (39 MB; app 122 MB) holds the stapled app |
| Gatekeeper | `spctl -a -vv --type exec "dist/Agent Workspace.app"` | `accepted`, `source=Notarized Developer ID`, `origin=Developer ID Application: Brian Love (GJJKL34HCT)` |
| As downloaded | The zip copied with a `com.apple.quarantine` attribute, unpacked with `ditto -x -k`, then `spctl -a -vv`, `syspolicy_check distribution`, `stapler validate` | Quarantine propagated to the app; `accepted`, `source=Notarized Developer ID`; "App passed all pre-distribution checks and is ready for distribution."; ticket valid |
| Coordinator | `agent-workspace coordinator restart`, `doctor --json`, `thread list` | Launch agent loaded and running, last exit 0, from the new bundle; the bundled `postgres` serves the store; the coordinator mapped the bundled `libpq.5.dylib` under the hardened runtime; both stored threads listed |
| First launch | `open "dist/Agent Workspace.app"` | Launched; the app's Unix socket is connected to `coordinator.sock` in the LaunchAgent coordinator, and it hosts nothing itself (no child processes). The installed copy came from a local unzip, so it carries no quarantine and Gatekeeper's first-launch check has nothing to show; the downloaded case is the row above. Screen access was declined, so nobody watched the window on screen |
| `SMAppService` after a rebuild (D-042) | A throwaway bundle (`com.cacheplane.b4app.smprobe`) with `Contents/Library/LaunchAgents` and a `BundleProgram` helper, registered with `SMAppService.agent(plistName:)`; the helper rebuilt to a new CDHash and re-signed, then `launchctl kickstart -k`, without re-registering | Developer ID: the job (`has LWCR`) respawned the rebuilt helper at once (`state = running`, the new build's log line). Ad hoc control under a fresh label: the first build ran, and the rebuild went to `spawn scheduled`/`spawn failed`, the D-042 failure. After a Developer ID registration, an ad hoc build under the same label could not spawn even after unregister and register. Both probes unregistered afterwards |
| Ad hoc path | `./Scripts/package.sh` with no identity, in the worktree's own `dist/` | `Signature=adhoc`, `flags=0x2(adhoc)`, verify passes, no notary step; the bundle is now re-signed with its (empty) entitlements file |
| Suite, lint | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass: 332 tests in 75 suites; lint clean (no Swift source changed) |

So the managed agent's requirement is stable across rebuilds once the build is team-signed; the per-user plist of D-042 stays in place unless the owner asks to switch. Still open: Developer ID builds on another Mac, and an on-screen first launch of a downloaded copy (macOS still asks once to confirm opening an app downloaded from the internet; it no longer refuses it).

## 2026-10-31: blank window on a pending Claude request

Found in the owner's running app: a new Claude thread asked to run Bash, and when the thread opened the window went blank, sidebar and detail, with the toolbar still working; relaunching restored it until the thread was opened again. Root cause and rule in D-047.

| Check | How | Result |
| --- | --- | --- |
| Reproduce | The stored thread exported to `Tests/Fixtures/ui/waiting-thread.json`; the packaged app quit and a Debug build of the same tree launched against the running coordinator; env switches hid one part of the thread detail per round | Blank with the request card; rendered without it; rendered with the command text plain or selectable; blank again with only `fixedSize(horizontal: false, vertical: true)` on the command |
| Measure | `NSHostingController(rootView: ThreadsView(model:)).sizeThatFits(in: .zero)` on the mirrored thread | 184 points without the request, 4,749 with it; 822 with the `fixedSize` removed; 485 with the bounded list (then 240-point cap) |
| Near the limit | The rendering variant with the window dragged to 900 by 652 points | Not blank, but the sidebar's top was pushed out and the composer off the bottom |
| Regression test | `swift test --filter DetailMinimumSizeTests` against the unfixed views (`RuntimeRequestView`, `ThreadsView`, `ComposerView` stashed) | Fails: 4,749; 100,969; 201,733; 103,418 points at zero width, 650 at 610 wide for the banner variant |
| With the fix | The same | Pass, five variants (the long-draft case is folded into each) |
| Live | The Debug build with the fix, thread "test" opened, then the window dragged to its minimum | Renders: transcript, the whole command, Allow once / Allow for session / Deny, the composer with Stop and Send; the pending permission was left unanswered for the owner |
| Suite, lint, apps | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift`, both `xcodebuild` schemes | Pass: 328 tests in 75 suites (324 before; the new test runs four variants); lint clean; macOS and iOS build |

## 2026-10-31: `db restore` of a store with updates (jsonb scalars)

Found while bringing up the M8a hub: `agent-workspace db restore` failed with `invalid input syntax for type json` on any archive from a store whose change log held an update. An update row in `changes` stores the changed column's value as jsonb, which for most columns is a scalar (`"ready"`, `true`, `7`, `null`). The version 1 exporter parsed every jsonb cell into a value, so a scalar string landed in the archive bare, and the restore bound it back to the jsonb column as raw text. Objects (inserts, display-item payloads, capabilities, routes) were unaffected, which is why `exportAndRestoreRoundTrip`, seeded with inserts only, passed.

| Check | How | Result |
| --- | --- | --- |
| Reproduce | New `exportAndRestoreRoundTripKeepsScalarChangeValues` seeds a store, then updates a string, a boolean, a number, a JSON null (optional column set to nil), and a nested payload, and restores the archive | Failed on the old code with the reported error on the first scalar (an `updatedAt` string) |
| Fix | Archive version 2: every `json`/`jsonb` cell travels as its JSON text in a string; restore looks the table's JSON columns up in the catalog and binds that text as jsonb. Version 1 archives are still read, each jsonb value re-encoded as JSON, so an old archive with bare scalar strings now restores too (`restoreReadsAVersionOneArchive`). An archive newer than this build is refused | Both new tests pass; the restored change log, threads, connections, and display items equal the source's, and the JSON null is a jsonb null in both stores |
| Suite | `swift test` after clearing `.build/debug` | Pass: 264 tests in 62 suites in 35 s. A first incremental run on a `.build` left by an older worktree build reported 8 error-code mismatches in the adapter suites; the test modules had been linked against a stale `WorkspaceProtocol`, and a clean build cleared them |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Live | `agent-workspace connection add --kind codex` on scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`, then `db backup`, `db restore --replace` into the same store, `coordinator stop`, and `db restore` into a second, empty scratch store | Pass. The archive (version 2, 9 rows) held 7 update rows with scalar values (`"ready"`, `"authenticated"`, timestamps, the account scope) and one object (`capabilities`); both restores returned 9 rows, `db status` on the fresh store showed 1 connection and 8 changes, and `connection list` returned the connection as `ready / authenticated` with its capabilities. Before the fix, the first scalar update row made the same restore fail |

Still SQL NULL after restoring a version 1 archive: a jsonb null, which the old exporter could not tell from an absent cell. No row the app writes carries one outside the change log, where `ChangeRecord` reads both as a missing value.

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

## 2026-10-31: switching the running app to the M7 build

| Step | Result |
| --- | --- |
| First switch (package built from the M7 branch) | Quit, `coordinator restart` through launchd, the new coordinator imported the real store (2 connections, 1 thread, 1 server, 5 items, 1 draft) and retired the SQLite files; the app relaunched against it. |
| Second switch (after #13) | `coordinator restart` timed out at its 10 s limit; `launchctl kickstart -k` by hand returned after 16 s but the old coordinator kept its pid, and `launchctl print` showed `spawn scheduled`, `last exit code = 78: EX_CONFIG`, 193 runs, and `needs LWCR update`. The helper ran fine by hand under launchd's environment, so launchd was refusing to spawn it: the rebuilt, re-signed ad hoc binary no longer matched the pinned code requirement. Unregistering and relaunching did not clear it either, because the app skipped `register` for an already-enabled agent. |
| Re-registering the managed agent | Registering again from the rebuilt app changed nothing (`needs LWCR update`, 47 runs, still EX_CONFIG), and neither did unregister-and-register. The same helper bootstrapped under a throwaway label with `launchctl bootstrap` ran at once, so launchd could exec the file; the managed registration was refusing it. |
| Fix (D-042) | The app now writes and bootstraps a per-user LaunchAgent plist with the coordinator's absolute path, rewriting it when the path changes or launchd reports a spawn failure, and unregisters the old managed agent once. `coordinator status` prints launchd's state and last exit; `coordinator restart` allows 90 s. |
| Outcome | `Agent Workspace --register-agent` from the rebuilt bundle: launchd `running`, 1 run, pid 11713 from `Contents/Helpers`; the store intact (2 connections, 1 thread, 18 change-log rows); `coordinator restart` replaced it with pid 11944 in about ten seconds; the relaunched app connected to it. |

## 2026-10-31: Claude Code live gate (A03) closed

Target: the same MacBook Pro, after the owner signed in to Claude Code 2.1.282 (claude.ai, Max plan). `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`, real inference, run twice.

| Step | Result |
| --- | --- |
| Inspection | `ready`, `authenticated`, 2.1.282, "Signed in as brian@brianflove.com (max) via claude.ai"; the native scope is the account. |
| First turn | "Reply with exactly the single word: pong" streamed and finished `completed`; the reply was `pong`. |
| Interrupt | A long counting turn was interrupted after its first delta; the CLI confirmed, and the result frame came back with `is_error` set and terminal reason `aborted_streaming`. The first run recorded that turn as `failed`; the translator now treats a stop it asked for (or a reason naming interrupt, cancel, or abort) as `cancelled` before it looks at the error flag, and the second run recorded `cancelled`. The fixture now emits the same shape. |
| Native resume | A new adapter on the same native session id asked what word it had been told to reply with: `pong`, `completed`. |
| Transcript | Rebuilt from the session file: four user and assistant pairs in order. |

Open on Claude: a tool-permission prompt and an `AskUserQuestion` live (fixture-tested since M2); hook callbacks and MCP messages are out of scope.

## 2026-10-31: M7 PostgreSQL store

Target: the same MacBook Pro. PostgreSQL 17.11 from the pinned zonky build (`Scripts/fetch-postgres.sh`, SHA-256 verified against Maven Central's published checksum before extraction). The owner's running app was left alone; every live row below ran on scratch directories, including an import of a copy of the real `workspace.sqlite` with its `-wal` and `-shm` files.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 261 tests in 62 suites in 31 s, every suite now on a shared ephemeral cluster with a fresh database per test (`PostgresServerTests` 3, `SQLiteImportTests` 5, `ChangeLogTests` 2 new); one run saw a timing flake in `WorkspaceModelTests` that did not repeat |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass (the store and the server manager are macOS-only modules; the window background modifier is now platform-aware) |
| Package | `./Scripts/package.sh` | Pass: 119 MB app, 39 MB zip; the PostgreSQL tree under `Contents/SharedSupport/postgres` with every Mach-O signed; `codesign --verify --deep --strict` clean |

### Live on this Mac

| Scenario | How | Result |
| --- | --- | --- |
| Bundled cluster from the packaged app | `open -n dist/Agent Workspace.app` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` (the registered agent serves the real directories, so this instance hosted in-process) | `coordinator status` running 0.1.0; `doctor` reported `postgresql:///workspace?host=<runtime dir>&port=5432`; `postgres -D <data dir>/pg` ran from `Contents/SharedSupport/postgres/bin`; the socket and its lock sat in the runtime directory; `PG_VERSION` and the cluster tree under the data directory. |
| Cluster lifetime | SIGTERM to that app instance, then `pg_ctl stop` by hand | A SIGTERM is not an orderly quit, so the owned cluster stayed up (adopt-on-next-start, by design); a CLI-spawned coordinator stopped with `coordinator stop` took its cluster down with it. |
| Import of the real store | Copy of `~/Library/Application Support/b4app/workspace.sqlite{,-wal,-shm}` into a scratch data directory; `db status` through a CLI-spawned coordinator | Imported in one transaction: 2 connections (Codex authenticated, Claude mid-login as on the real store), 1 thread, 1 turn, 5 display items, 1 draft, 1 server registration; `connection list`, `thread list`, `server list` showed them; the three files renamed `.imported`; `db import-sqlite` on the retired file: "nothing imported (the store already holds data)". The first attempt, without the `-wal` and `-shm` copies, found two defects now fixed: a read-only open of a WAL-mode file fails, and an import error trapped the coordinator at top level and left the freshly started cluster running. |
| Backup and restore | `db backup`; `db restore <archive>`; `db restore --replace <archive>`; `db status` | 21 rows written (mode 0600, header with format, time, and applied migrations); restore refused on a non-empty store with the `--replace` hint; replace restored 21 rows and left the change log at the archive's 10 entries (the first run doubled it because the log was silenced after the clearing, now before). |
| Schema and status | `db status`, `db migrate` | `0001_init, 0002_changes`; row counts per table; unsynced change count; backups folder. |

### Open after M7

- Device identity, the hybrid logical clock, and sync itself (M8); the hub schema's tenant and user columns.
- Developer ID signing: executables under `SharedSupport` are sealed as resources, which an ad hoc build accepts and notarisation would not; the tree moves to a nested-code layout when a certificate exists.
- A major-version move (export, new cluster, import) has not been exercised; the bundled version is pinned.
- `docs/schema.md`.

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

## 2026-10-31: LiveLoveApp visual system

Target: the same MacBook Pro. Screen control for the app was requested and declined in this session, so the window was not clicked; every surface was rendered offscreen instead, by `SnapshotTests` over a real coordinator with the fixture Codex and Claude runtimes, in both appearances (`docs/screenshots/threads-{light,dark}.png`; the full set lands wherever `B4APP_SNAPSHOT_DIR` points).

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 245 tests in 55 suites (5 new in `ThemeTests`: SVG parse and fit, font registration, fallback without fonts, palette contrast in both appearances) |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass; `AppIcon.icns` and the `WorkspaceUI` resource bundle with the three fonts are inside the app |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Offscreen render | `B4APP_SNAPSHOT_DIR=<dir> swift test --filter SnapshotTests` | Pass: threads (pending approval, running and waiting dots, pinned and archived rows), empty threads, connections, local servers, diagnostics, light and dark |

### Seen in the renders

- The mark draws from the vendored SVG; Hanken Grotesk and JetBrains Mono are the faces in use; headings carry the tight tracking.
- The accent appears only on the "Waiting for you" badge and dot and on link buttons; running is an ink dot with a faint ring; failures use the danger red; everything else is ink and grey.
- Cards are hairline-bordered with radius 16, buttons are pills, no shadow or gradient anywhere; dark mode keeps every pairing above 4.5:1.
- The composer grows with its draft and the request card sits above it in the 720 pt reading column.

### Clicked later the same day (screen control granted)

The packaged window at first showed only its toolbar: the root's ideal height was 1458 pt in an 800 pt window (an infinite-height frame inside a split-view column) and the window centred the oversized view, so the sidebar and detail sat outside the visible area; `IdealSizeTests` now pins the root's ideal height. After the fix, seen and driven on screen: the sidebar (mark, surfaces, thread rows, link status), the Threads empty state and its button, the new-thread sheet (connection picker, directory, title, Create), and a thread created on the real Codex connection with the composer, toolbar Rename, Pin, Archive. Still not clicked: hover states, the context menu, the rename alert, the Quit dialog, the continuity banner, a sent turn.

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

## 2026-10-31: M4 managed B4 execution and the shared CLI

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), Node v24.20.0 on `PATH` from nvm, no `b4` on `PATH`. Fixture runs use `Tests/B4AdapterTests/Fixtures/fake-b4-cli.py` (a `b4` stand-in serving the M3 fixture protocol) behind `fake-node.sh`, in scratch projects built by `Tests/CoordinatorTests/FakeB4Project.swift`. Live runs first registered the M3 scratch project in place under `/tmp` (`@b4run/cli` 0.15.8, one `gpt-5-mini` `agent()` route, `.b4` stores from M3) with `--env-file` pointing at this repository's gitignored `.env`, under scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`; the built macOS app was launched from the command line with the same scratch directories. After the owner chose it, the project was copied to `~/repos/b4app-live-check` (node_modules and `.b4` included) and the registration, both launch modes, restart continuity, and stop were repeated there as the server `research` (last table row).

### Live against the real project and `@b4run/cli` 0.15.8

| Scenario | How | Result |
| --- | --- | --- |
| Register and inspect | `server add <project> --name live --env-file <b4app>/.env --port 3101` | Pass in 1.1 s: Node v24.20.0 (`path`), CLI 0.15.8 from the project's `package.json`, `b4 routes --json` found `/chat#agent`; the registration printed the trust line first. |
| Source mode start and a real turn | `server start live`; `connection add --kind b4 --server live --route /chat#agent`; `thread new`; `turn send … pong` | Pass: `b4 start --host 127.0.0.1 --port 3101` was ready in 1.1 s (pid owned, log shows `b4 start listening on http://127.0.0.1:3101` after B4's anonymous-auth notices); the connection stored `managed_local` with target `http://127.0.0.1:3101`; gpt-5-mini answered `pong` in 2.4 s. |
| Development mode and continuity across restart | `server stop`; `server add … --mode development`; `server start`; `server restart`; `turn send` on the same thread | Pass: the profile updated in place (same id, same port); `b4 dev` was ready in 1.9 s (`Loaded 1 variable(s)`, `B4.run dev ready at …`); `restart` took 2.6 s to generation 2 with a new pid; the next turn on the same thread recalled its earlier `pong`, so `.b4/{threads,checkpoints}.sqlite` survived the restart. |
| Coordinator restart with the server running | SIGTERM to the coordinator; `server status live` from a fresh coordinator | Pass: the `b4 dev` process stayed alive; the new coordinator reported `ready … (adopted)` with the same pid and `owned`; a turn completed; `server stop` ended the `b4 dev` parent and its runtime child (pid gone, port free). |
| Port conflict | `python3 -m http.server 3101`, then `server start live` | Refused `owned_process_conflict` "Port 3101 is in use by another process; nothing was stopped"; the Python server was still alive afterwards. Exit 1. |
| Attached server survives everything | `node node_modules/@b4run/cli/dist/index.js dev --port 3102` by hand; `connection add --url http://127.0.0.1:3102 …`; a turn; coordinator kill; app Quit; new coordinator | Pass: the hand-started server answered `pong`, never appeared in `server list`, and was still alive after the coordinator was killed, after the app quit, and under the next coordinator; only my own `kill` ended it. |
| GUI start, CLI inspect and stop (app-hosted coordinator) | Launch `Agent Workspace.app` with the scratch directories (lock pid = app pid 53028); `server start live`, `server list`, `server logs`, `turn send`, `server status --json`, then `tell application "Agent Workspace" to quit` | Pass: the CLI started the server through the app's in-process coordinator (pid 53317 owned, `b4 dev` ready), listed and tailed it, and ran a turn (`pong`); after Quit the app was gone, the lock released, and the managed server still alive. |
| CLI adopts after Quit, then the reverse order | `server status live` (CLI spawns a coordinator), a turn, `server stop`; relaunch the app, `server start`, `server stop`, Quit | Pass: adopted by verified identity (same pid), `pong`, stopped (pid gone); the relaunched app's coordinator started generation 5 as owned and stopped it; Quit left nothing behind. |
| Doctor | `agent-workspace doctor` | Managed servers appear as `b4` rows with the CLI path, version, health, port, mode, and project; attached endpoints keep their reachability rows. |
| The owner's chosen project | `server add ~/repos/b4app-live-check --name research --env-file <b4app>/.env --port 3101`; source start and a turn; `server add … --mode development`; start; a turn; `restart`; a turn; `server logs`; `server stop` | Pass: route `/chat#agent` found; `pong` in source mode; after the switch to development mode the same thread answered `pong` to "which word did you answer last time" and again after `restart` (`.b4` preserved across the mode change and the restart); the log tail showed `B4.run dev ready at http://127.0.0.1:3101`; stop left no process behind. |

Not exercised live: clicking Start / Stop / Restart / Connect / Logs in the Local servers view (built for macOS and iOS; no screen control in this session), a project whose `b4.config.ts` sets `env`, two different projects at once, a `b4 dev` file change mid-turn.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 218 tests in 44 suites (38 new) in 21 s; no fixture server left running afterwards |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

New fixture coverage: `WorkspaceProtocol` (server methods and their mutation flags, params round trips, `LocalServerRoute` keys, `server.changed`); `WorkspaceStorage` (migration `v2`, server rows with routes, update, unique names, connections by server); `WorkspacePlatform` (dotenv quoting, comments, escapes, no expansion; process identity of self and a child; spawn with output to a 0600 file and an exit status; group terminate reaching a grandchild; missing executable; redaction of bearers, `sk-` keys, and key/value pairs; log tail with offsets and copy-truncate bounding; port allocate and in-use detection); `LocalServerService` over the socket (registration with route discovery, refusals for a missing CLI, an old CLI, no config, a missing env file; profile matching and updates; env-file values reaching the child but never a result; source and development starts to ready; idempotent start; concurrent starts joining one launch; port conflict without a kill; restart generations; monitor detecting an exit; stop reaching a `b4 dev` grandchild whose parent ignores SIGTERM; re-adoption after a coordinator restart; a stale pid left alone; an unready start failing with the log tail; a start over a live owned instance marked `unhealthy` refused by pid with the instance still stoppable; a stop racing a start serialized so the new generation is owned and the old process gone; `b4 routes` stderr redacted before it reaches a result; logs tailed, redacted, and followable by offset; doctor rows); managed route connections (`offline` with the start hint while stopped and no thread created; a conversation through the managed server and `offline` after stop; stop refused with `turn_active` then forced, after which the turn is not `completed`, a stopped server stops again without force, and a reconciling turn does not block restart; a server exit marking the connection `offline`, its running turn `reconciling`, and the next turn refused `endpoint_unavailable` with `server_stopped`; a `workflow` route `incompatible` and an unknown route `not_found`). The platform port probe also sees a listener that set `SO_REUSEADDR` (as Node does) through a non-blocking connect and answers within 200 ms against a saturated backlog.

A fresh-context review of the whole branch found no critical issue and five important ones, all fixed with a failing test first: a start on an unhealthy owned server discarded its monitor and blamed another process; a stop racing a start could orphan an owned process behind a `stopped` row; `b4 routes` stderr reached the client unredacted; the CLI sent relative paths unresolved (`server add .` now resolves against the shell's directory, checked by a CLI smoke); and the server-exit test accepted a turn still `running`. Deferred minors are listed in the PR.

### Open after M4

- The Local servers view has not been driven on screen.
- Removing a registration, changing a port that route connections use, and the Quit choice dialog (spec 10.3) are not built; Quit keeps managed servers running.
- Built artifacts (`b4 build` + `node .b4/build/server.mjs`) and `b4 typegen` before `b4 start` are not run by the app.

## 2026-10-31: M3 B4 local and remote conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3). No `b4` on PATH. Fixture runs use `Tests/B4AdapterTests/Fixtures/fake-b4.py`, a stdlib Python server that implements the Agent Protocol subset the adapter uses with the shapes read from `@b4run/cli` 0.15.8 source and corrected from the live run. Live runs use a scratch project with `@b4run/cli` 0.15.8 project-installed, one `gpt-5-mini` `agent()` route, a `workspace/` directory, and `OPENAI_API_KEY` loaded by `b4 dev --env-file` from this repo's gitignored `.env` (the key was copied from the b4run checkout and checked against `GET /v1/models`, HTTP 200).

### Live against a real B4 server (`b4 dev` 0.15.8 on 127.0.0.1:3101)

| Scenario | How | Result |
| --- | --- | --- |
| Opt-in adapter test | `B4APP_LIVE_B4_URL=http://127.0.0.1:3101 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` | Pass in 3 s: inspection `ready`, thread `t-…`, reply "pong" `completed`, cancel of a counting turn confirmed and finished `cancelled`, history `[userMessage, agentMessage, userMessage]`, reconcile of the first turn `completed`. |
| CLI attach and turns | `connection add --kind b4 --url http://127.0.0.1:3101 --route /chat#agent`, `thread new`, `turn send` | Pass: `ready / not_required`; "pong" streamed in 2.0 s; a second turn answered "pong" from the same native thread (continuity). |
| Real permission prompt | `turn send --no-wait <id> "Use your runBash tool to run exactly: ls -la …"`, `thread show`, `request respond <rid> --accept` | Pass: the turn parked `waiting_for_user` with a `command_approval` request carrying the server's `interrupt` envelope (`perm-…`, `kind: command`, `detail.command: "ls -la"`, `toolCallId`); `--accept` resumed it; the transcript ended with the tool card, then "AGENTS.md\nnotes.txt"; the turn was `completed`. |
| Tool card from live `step` frames | `turn send <id> "Use your runBash tool to run exactly: pwd …"` | Pass: `[toolCall started]`, `[toolCall completed] pwd`, one card labelled "Ran pwd" with the output, then the answer. No `step` or `usage` items in the transcript. |
| Parked prompt across a real server restart and a coordinator restart | park on `ls -la`; stop `b4 dev` and the coordinator; start `b4 dev` again on the same `.b4/{threads,checkpoints}.sqlite`; fresh coordinator `thread show`; `request respond --accept` | Pass: after the restart `GET /threads/:id` still read `interrupted` with `metadata.parked_route` and `GET /pending_interrupts` listed the same `perm-…` prompt; `thread show` on the fresh coordinator reconciled the turn to `waiting_for_user` with the request re-opened at adapter generation 2; `--accept` resumed the run, the tool card showed `ls -la`, the answer listed the files, and the turn ended `completed`. The server's turn list showed one `done` turn per prompt sent. |
| Raw protocol capture | `curl -N` of `runs/stream`, `GET /turns`, `GET /state`, `GET /pending_interrupts` | Recorded in `docs/research/2026-10-30-b4-runtime.md`. Two differences from the source reading were found and fixed before merging: `GET /turns` nests the list under `turns.turns` (the ordinal reconcile had silently fallen back to status-only and reported the wrong outcome), and `usage`/`step` events plus serialized `ToolMessage` outputs needed folding instead of rendering as items. |

Not exercised live: a remote HTTPS endpoint with a real endpoint credential, approval grants, `detached capacity`, the macOS forms (built, not clicked).

### Live Codex approval (M1 gate closed from this branch)

| Scenario | How | Result |
| --- | --- | --- |
| Approval under the owner's configuration | CLI thread, "create `/tmp/…` with a shell command" | No request: `~/.codex/config.toml` sets `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`, so Codex ran `printf hello > /tmp/…` directly. Honest result for daily use on this Mac. |
| Real `item/commandExecution/requestApproval` round trip | `B4APP_LIVE_CODEX=1 B4APP_LIVE_CODEX_APPROVALS=1 swift test --filter CodexLiveTests/commandApprovalRoundTrip` (the test alone asks `thread/start` for `on-request` + `workspace-write`) | Pass in 6.4 s: the request arrived as `command_approval` with `command: /bin/zsh -lc 'curl -sI https://example.com'`, `cwd`, and `reason: "Allow curl to access https://example.com outside the network-blocked sandbox?"`; `allow_once` → `{ decision: accept }`; the turn completed and the reply was `HTTP/2 200`. A first attempt that wrote under `/tmp` needed no approval because `workspace-write` keeps `/tmp` writable. |

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 180 tests in 35 suites (35 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live B4 (opt-in) | `B4APP_LIVE_B4_URL=http://127.0.0.1:3101 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` | Pass in 3 s against `b4 dev` 0.15.8 with gpt-5-mini (see the live table) |

New fixture coverage: `B4TurnTranslator` (ordered streamed turn, tool calls paired with results and messages split around them, park keeps the turn open and the resume stream continues item numbering, failed and cancelled outcomes, final message from `done.output` when nothing streamed including LangChain envelopes, capability events and reasoning visible, reattach `state live:false` ends without an outcome, durable prompt re-open, transport-loss event); `B4Protocol` (route keys, HTTP error mapping, exact resume bodies, decision mapping, LangChain state projection); `B4Adapter` against the fixture (inspect, create, two consecutive turns with ordinals `turn-1`/`turn-2`, tool turn and `loadSession` history, park then `once` with a stale second answer refused, `always`/`deny`/decline all reaching the server, stop on a parked turn declining the prompt, hang then cancel with a later stop returning the known outcome, failed run, **dropped stream reattached with one server-side turn**, **parked prompt answerable after a server restart** under a new generation, **server restart mid-run fails the turn and the thread accepts the next one**, reconcile distinguishing recorded from unrecorded ordinals with a `submission_unknown` error event, bearer middleware 401 as `auth_required` then success with the credential, unknown route 404 and `workflow` route as compatibility results, malformed route as an error); `SessionService` over the socket (a B4 conversation beside Codex with both threads listed and re-adding the same endpoint returning the same connection, a permission answered through `request.respond` with the turn `waiting_for_user` in between, `credential.add` producing a reference the endpoint accepts while an unknown reference is refused and an anonymous turn fails `auth_required`, route and URL problems rejected with codes, **a parked B4 turn answerable after a coordinator restart** via `thread.read` reconciliation to `waiting_for_user`).

### Live on the target Mac (coordinator and CLI against the fixture server)

| Scenario | How | Result |
| --- | --- | --- |
| Credential path | `echo s3cret \| agent-workspace credential add fake-endpoint` with scratch `B4APP_RUNTIME_DIR`/`B4APP_DATA_DIR` | Pass: printed `Stored "fake-endpoint" as secret:<uuid>` and the `connection add` hint; the value appeared nowhere else. The item was written to the login keychain (service `b4app`) by the real `KeychainSecretStore` and removed afterwards. The TTY `readpassphrase` path was not exercised (no terminal in this session). |
| Attach an endpoint with the credential | `connection add --kind b4 --url http://127.0.0.1:<port> --route /chat#agent --auth-ref secret:<uuid> --name fake-b4` | Pass: `ready / auth=unknown`, `route /chat#agent (attached_local)`, message "Server reachable (readyz: ready). Model credentials are not verified by this check." Exit 0. |
| Workflow route | `connection add --kind b4 … --route /dispatch#workflow` | Stored as `incompatible` with "Route /dispatch#workflow is a workflow route. Conversations support standard agent routes only (D-023)." Exit 2. |
| Remote plain HTTP | `connection add --kind b4 --url http://agent.example.com …` | Refused `protocol_invalid` "Remote B4 endpoints must use HTTPS". Exit 4. |
| Thread and streamed turn | `thread new --connection fake-b4 --title smoke`, `turn send <id> hello there` | Pass: thread `native thr_1 route /chat#agent`; streamed "Hello from fake B4." then `[turn completed]`, exit 0. |
| Permission through the CLI | `turn send --no-wait <id> please approve`, `thread show`, `request respond <rid> --accept` | Pass: `thread show` listed the `command_approval` request with `command: rm -rf tmp` and the `request respond` hint; after `--accept` the transcript ended with "Approved (once). Command ran." and the turn was `completed`. |
| Stop a running turn | `turn send --no-wait <id> hang around`, `turn interrupt <id>` | Pass: `stopping`, then `turn-4 terminal cancelled`. |
| Reopen after a coordinator restart | `thread show` from a fresh coordinator process | Pass: three terminal turns and seven cached items; no reconciliation needed. |
| Missing credential | keychain item deleted, then `turn send <id> hello` | Failed honestly with `auth_required` "Credential secret:<uuid> is not in the credential store. Run `agent-workspace credential add` and update the connection." Exit 1. |
| No resubmission | `GET /threads/thr_1/turns` on the fixture after the session | `idle`, exactly one server-side turn per `turn send` (`run_2`, `run_6`, `run_13` all `done`). |
| Doctor | `agent-workspace doctor` | Lists each B4 connection as a runtime row with its reachability message. |

### Open after M3

- A compatible remote HTTPS endpoint with its real endpoint credential has not been attached; the local live run used no middleware.
- Approval grants (`approvals.grants`) are reviewed from source and fixture-tested only.
- The macOS Connections form and new-thread sheet for B4 build but were not clicked through in this session.
- Mac sleep/wake across a long SSE stream and the reattach cap (`detached capacity`) are untested.

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
