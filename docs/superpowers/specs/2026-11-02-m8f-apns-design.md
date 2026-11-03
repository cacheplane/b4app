# M8f APNs: real notifications on the iPhone

Date: 2026-11-02. Owner: Brian Love. Status: approved by the owner 2026-11-02 (builder-checked).

This builds on M8f, "attention on the phone" (PR #63) (the M8f section of `2026-10-31-m8b-remote-workspace-design.md`, plan `docs/superpowers/plans/2026-11-02-m8f-attention.md`, decisions D-121 to D-129). M8f decides on the hub which changes notify, stores each phone's push token, and hands the notification to a swappable `PushSender`; in the Simulator a `spool` sender writes `.apns` files that `Scripts/sim-push.sh` delivers. The `apns` sender was left as a stub that refuses to start. This slice builds it, and adds three behaviours the owner asked for while the notifications become real.

## Intent

Brian wants the notification M8f proved in the Simulator to reach his own iPhone's lock screen. What he said:

- **Where it first works:** prove it from the Compose hub on the Mac to the Simulator through Apple's servers, then make the first real-device delivery on the hosted test hub (`hub.test.b4.run`, up and healthy on 2026-11-02) with a beta TestFlight build on his iPhone, then prod once `hub.b4.run` serves. (My recommendation; he agreed.)
- **Buzz even at the Mac:** "Yes", the phone notifies for every approval, question, reply, and failure even while he is sitting at the Mac. M8f already does this; nothing changes.
- **Answered on the Mac, gone from the phone:** "Yes", answering an approval on the Mac removes its notification from the iPhone.
- **Read, gone:** "Yes", a "Replied" (or "Turn failed") notification disappears once that turn has been read, on the Mac or the phone.
- **A badge:** "Yes", the app icon shows how many threads need him.

## Goals, non-goals, anti-goals

Goals:

1. The hub delivers M8f's notifications through Apple's push service (APNs) to every signed-in iPhone, sandbox and production alike.
2. A notification is withdrawn from the phone when what it announced is over: its request was answered or expired, or its turn was read.
3. The app icon's badge is the number of threads that need Brian.
4. Proved twice live: Compose hub to the Simulator through APNs sandbox; the test hub to a TestFlight beta on Brian's iPhone through APNs production.

Non-goals (this slice): notification preferences or per-thread muting, rich or actionable notifications (answering an approval from the notification itself), a Notification Service Extension, Live Activities, notifications on the Mac, periodic background refresh for the widget (`BGAppRefreshTask`), and deploying prod.

Anti-goals:

- A send that pretends: a failure Apple reports is logged with its reason, never swallowed as success.
- A token, the key, or a JWT in a log line, a JSON result, or the UI.
- Transcript text, command text, or paths on the lock screen (M8f's rule stands).
- A notification for something already answered or read that never goes away, once the phone has synced.
- A flood: a Mac's first join, a rejoin, or a retried batch must not notify (M8f's ledger and 10-minute turn window stand).

## How it works

### The sender

`ApnsSender` implements M8f's `PushSender` trait in `Hub/crates/b4hub/src/push.rs`:

- **Endpoint by token.** Each `push_tokens` row carries its `environment`; `sandbox` goes to `api.sandbox.push.apple.com`, `production` to `api.push.apple.com`, port 443, HTTP/2 (APNs requires it), one long-lived connection per endpoint reused across sends.
- **Authentication.** A provider token: an ES256 JWT with `kid` = the key id, `iss` = the team id, `iat` = now, signed with the `.p8` key. Minted once and reused for about 50 minutes (Apple refuses tokens older than an hour and rate-limits re-minting faster than every 20 minutes). The hub already signs ES256 JWTs for Sign in with Apple (`jsonwebtoken`), and `reqwest` gains its `http2` feature.
- **Headers.** `apns-topic` is the token row's `bundle_id` (so every flavour works with one key); `apns-push-type` is `alert` for a notification and `background` for a withdrawal; `apns-priority` 10 for alerts, 5 for background; `apns-collapse-id` is the notification's key (below), so a resend replaces rather than stacks.
- **Apple's answers.** 200 is delivered. 410 `Unregistered`, 400 `BadDeviceToken`, and 400 `DeviceTokenNotForTopic` delete that `push_tokens` row (the app was deleted or the token belongs to another build). 403 `ExpiredProviderToken` or `InvalidProviderToken` re-mints the JWT and retries once. 429 and 5xx retry once after a short wait. Anything else is logged with Apple's `reason` and the `apns-id`, the device id, and the notification key, and dropped (M8f's delivery stays at most once).
- **Configuration.** `B4HUB_PUSH_SENDER=apns` with `B4HUB_APNS_KEY_ID`, `B4HUB_APNS_TEAM_ID`, and `B4HUB_APNS_PRIVATE_KEY` (or `B4HUB_APNS_PRIVATE_KEY_FILE`, the same `_FILE` pattern as the sign-in secrets). `serve` parses the key at start and refuses to start on a bad or missing value, naming the variable, never echoing the key. The key Brian made is team-scoped and covers sandbox and production (`34GWB4MSB5`, kept in `~/.b4app/signing/`), so one key serves every flavour and both hubs.

### What a notification carries

M8f's payload gains a key and a badge: `{"aps": {"alert": {title, body}, "sound": "default", "badge": <n>, "content-available": 1, "thread-id": <threadId>}, "threadId", "reason", "key": "request:<id>" | "turn:<id>"}`. The spool sender writes the same payload, so the Simulator path keeps working without APNs. The shared fixture `Tests/Fixtures/sync/push.json` gains the key, the badge, and a withdrawal payload, decoded by both languages.

### Withdrawing a notification

- **When.** In the push transaction, alongside M8f's detection: a request that was notified and is no longer `pending` (answered or expired), or a turn that was notified and whose thread's `readTurnId` now names that turn or a later one. `notifications_sent` gains a `withdrawn_at` in a new migration (M8f's `0012_push.sql` is not edited, since databases may already hold it), so each is withdrawn once.
- **To whom.** The same phones as the notification (signed in, with a token), including the one whose read caused it; it clears its own as well.
- **How.** A background push: `{"aps": {"content-available": 1}, "withdraw": ["request:<id>", …]}` with no alert, sound, or badge (Apple requires that of a background push). The app wakes, removes the delivered notifications whose `key` is listed, sets its badge, and finishes.
- **The backstop.** Background pushes are delivered when iOS chooses: they can be delayed or dropped (Low Power Mode, an app swiped away in the switcher). So after every sync the app also removes any delivered notification whose request is no longer pending or whose turn has been read in the mirror. Removal is usually within seconds and certain by the next sync.

### The badge

- **The number.** Threads that need Brian: non-archived threads in the needs-input or unread band, the two bands that lead the list (pinned threads count by their band).
- **Who computes it.** The hub, for every alert it sends, from its own rows; and the app, after every sync, from the mirror (`setBadgeCount`). The hub therefore gains the attention rules in Rust, checked against the shared `Tests/Fixtures/sync/attention.json` exactly as the Swift and SQL implementations are, so there is still one rule per language and no drift.

### The phone

- **Push environment from the build.** The Simulator, known when the app is compiled (`targetEnvironment(simulator)`), is `sandbox`. On a device, an embedded provisioning profile (`embedded.mobileprovision`, present in development and ad hoc builds) gives its `aps-environment` (`development` is sent as `sandbox`); a device build without one is a TestFlight or App Store build, whose profile Apple strips, and is `production`. This replaces M8f's guess from `#if DEBUG`. (My call, after the builder check pointed out that TestFlight builds carry no profile.)
- **One device per token.** Saving a token removes it from any other device row of the same org, so a phone that re-enrolled while the hub still holds its old device does not get every notification twice.
- **A wake does not wait too long.** A background wake waits for a queued suspend of the sync loop at most a few seconds before running its refresh, so the system's completion handler is always called well inside iOS's time budget (an M8f review finding).

## Deployment

- **Compose (local, the first proof).** `Hub/compose.yaml` gets the three APNs values (the key as a file) as an alternative to the spool; `.env.example` and the README say how to switch. The spool stays the default, so Compose without a key still works for the Simulator.
- **The hosted hubs, in two steps** (my call; `Infra/taskdefs/features.env` drives the test and prod deploys alike, and ECS will not start a task whose secret is still empty):
  1. This slice's PR adds the code, the three secrets in Terraform (`b4hub/apns-key-id`, `b4hub/apns-team-id`, `b4hub/apns-private-key`, created empty), the gated task-definition block, and `INCLUDE_APNS_SECRETS=0`, plus a runbook step in `Infra/README.md`. Merging it deploys a hub that still uses no sender, so nothing breaks.
  2. Brian applies the Terraform and puts the three values in both accounts (his AWS credentials). Then a one-line follow-up sets `INCLUDE_APNS_SECRETS=1`, which turns on `B4HUB_PUSH_SENDER=apns` with the secrets on the next deploy, test first.

## Owner's setup, confirmed

On 2026-11-02 Brian confirmed in the Developer portal: the three App Groups exist; `com.cacheplane.b4app.ios` and `com.cacheplane.b4app.ios.local` have Push Notifications and their App Groups; the widget App IDs `com.cacheplane.b4app.ios.widget` and `com.cacheplane.b4app.ios.local.widget` have their App Groups; the APNs key `34GWB4MSB5` is team-scoped for Sandbox and Production. So the Simulator's local build can receive through APNs sandbox.

## Exit (live)

1. **Simulator through APNs sandbox.** The Compose hub with `B4HUB_PUSH_SENDER=apns` and the key; the Debug app in the Simulator registers a sandbox token; with the app in the background, a fixture approval on the Mac notifies within five seconds, through Apple; answering it on the Mac removes the notification; the badge counts the threads that need input or have an unread reply. If the Simulator's background push is not delivered, the backstop must still clear the notification on the next foreground sync, and that is recorded.
2. **iPhone through APNs production.** After M8f and this slice are on `main` and step 2 of the deployment has run: the test hub with the APNs secrets; a TestFlight beta on Brian's iPhone signed in to it registers a production token; a real approval from his Mac notifies on the lock screen; tapping opens the thread; answering on the Mac removes it; reading a reply on the Mac removes its "Replied"; the badge matches the list.
3. Prod follows when `hub.b4.run` serves; not part of this exit.

## Constraints

Everything in M8f's constraints, plus: the key, tokens, and JWTs never appear in arguments, logs, JSON results, or UI; the attention rules stay one per language, checked by the shared fixture; `WorkspaceMirror` stays free of `UIApplication` and `UserNotifications` code (removal of delivered notifications lives in `Apps/iOS`); the hub's sender is chosen by configuration, and the spool keeps working.

## Left to the builder

- The HTTP/2 client's setup (timeouts, connection reuse, ALPN), the JWT cache's shape, and the retry waits, within the rules above.
- `apns-expiration` values (an alert stays useful for hours, a withdrawal for minutes).
- How the hub's attention rules are expressed (SQL or Rust), provided the shared fixture passes.
- Decision numbers: the next free after main and the open pull requests when the plan is written (D-141 or later: main and open pull requests hold up to D-140 on 2026-11-02).
