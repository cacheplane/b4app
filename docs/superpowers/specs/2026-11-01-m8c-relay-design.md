# M8c: the relay, remote chat, and pairing by QR code

Date: 2026-11-01. Owner: Brian Love. Status: approved by the owner 2026-11-01.

This document details slice M8c. It builds on `2026-10-31-m8-hub-design.md` ("The relay") and `2026-10-31-m8b-remote-workspace-design.md` ("M8c, remote chat"), whose content still holds unless a section below says otherwise. D-045 holds: a turn for a Mac that is offline is refused, never queued. The hub's current wire is `Hub/API.md`.

## Intent

From the phone, Brian holds a conversation that runs on his Mac: he sends a message and watches the reply stream, answers an approval, stops a turn, and starts a new thread in a project. The Mac does all the work. The hub only carries commands to the Mac and live progress back, so the change log stays the one record of what happened.

What the owner said in this design round, in his words where it matters:

- While the agent is working, "I should see visible progress".
- "If the Mac drops, and some amount of time has passed with intermittent reconnect attempts failing, we should show the disconnect screen."
- "You should still be able to browse threads. It should be visibly apparent that the Mac is disconnected, but you can still browse threads."
- "We'll also need UI for establishing the connection via scanning a qr code using ios camera with the qr code displayed on the mac", as part of M8c.

## Goals, non-goals, anti-goals

Goals:

1. From the Simulator: continue a Mac thread, start a new thread in a project, watch the reply and its tool calls stream, answer an approval, and stop a running turn. The Mac runs each of these exactly as if Brian had clicked in the Mac app.
2. A send to a Mac that is offline is refused at once with its name and last-seen time. A send that may or may not have reached the Mac is shown as not confirmed and is never repeated automatically.
3. When the Mac becomes unreachable, the phone says so plainly and keeps every thread readable.
4. Pairing a phone means scanning a QR code on the Mac (or opening the same link), with no `b4hub enroll` and no typing.
5. "Keep the Mac awake" (M8b design) keeps the Mac reachable while it is joined.

Non-goals:

- Queuing turns for an offline Mac, or running anything anywhere but the owning Mac.
- Several Macs per user, or a thread moving between Macs.
- Relaying any command other than the five below (four actions and one read). Managing connections, credentials, servers, and projects stays on the Mac.
- Remote B4 threads started from the phone: a remote B4 connection belongs to no project, so the phone has nowhere to offer it. Continuing an existing remote B4 thread works, because the Mac does the work with its own credential. Local B4 threads can be started from the phone (owner's decision, 2026-11-01).
- Push notifications and the widget (M8f), deployment off the Mac, TLS, and a physical iPhone (the slice after M8f).
- Accounts and sign-in (M8d). Pairing by QR code is the enrollment code made scannable, not a sign-in.
- More than one hub replica. The relay's routing state is in memory; cross-replica routing is M8e's.

Anti-goals:

- A turn that runs later than Brian meant it to: a command delivered after a sleep, a retry that lands minutes later, or a held send.
- Two turns from one tap.
- The phone showing a turn as finished, failed, or still running when it does not know, or showing a working spinner while the Mac is gone.
- The phone able to make the Mac do anything the four commands do not cover, such as starting a thread in a folder the project does not list.
- State reaching the phone only through the relay. Anything the phone keeps comes from the change log.
- A secret, a token, or a relayed frame's content in a hub log line.

## How it fits together

```
 iPhone ── WebSocket ──┐                              ┌── WebSocket ── Mac coordinator ── SessionService
 (client link)         ├──► hub: links, presence, ◄───┤   (host link)
 iPhone ── HTTPS ──────┘    routing, fan-out          └── HTTPS (push and pull, unchanged)
            (change log)          │
                               Postgres (change log, materialised rows, devices)
```

- Every device that is joined and running holds **one link**: a WebSocket to the hub, authenticated with the device token it already holds. A `macos` device is a **host**. An `ios` or `cli` device is a **client**.
- A client sends **commands**. The hub authorises each one, finds the owning host, and forwards it with a deadline. The host runs it through `SessionService` and answers with a **reply**, which the hub returns to the client.
- A client **watches** the threads it has open. The hub tells the owning host which of its threads are watched, and the host sends those threads' live **events**, which the hub fans out to the watchers without storing them.
- The hub tells clients the **presence** of the user's hosts: online, and last seen at.
- State still travels only through the change log: `POST /v1/changes` from the Mac and `GET /v1/changes` into the mirror. A reply carries an acknowledgement, ids, or an error. A relayed event only animates what is on screen. Nothing from the relay is written to the mirror.

Because the relay carries no state, it needs no cursor or replay. A lost event costs a moment of streaming, and the finished item still arrives through sync. This replaces the M8 design's "reconnect from a cursor" paragraph for the relay (the change log keeps its cursor).

## The link

**Endpoint.** `GET /v1/devices/self/link` with `Authorization: Bearer <device token>` and a WebSocket upgrade. Authentication runs before the upgrade, so a bad token gets the usual `401 unauthorized` and no socket. The hub's axum gains the `ws` feature.

- **One per device.** A new link from a device closes that device's old one, with an `error` frame `link_replaced` and close code 4000. A revoked device's link is closed with close code 4001 when it is revoked (`DELETE /v1/devices/self`), and its next upgrade gets the 401.
- **Hello.** The device names its protocol in a `B4-Protocol: 1` header on the upgrade request; a missing header counts as 1. The hub's first frame is `hello { protocol: 1, minClientProtocol, deviceId, role: "host" | "client", heartbeatSeconds: 10, hubTime }`. A device whose protocol is older than `minClientProtocol` gets an `error` frame `client_too_old` and a close.
- **Heartbeat.** The device sends `ping` every 10 s, and the hub answers `pong { hubTime }`. The hub closes a link that has sent nothing for 30 s. A device that has received nothing for 30 s treats the link as dead and reconnects. The `hubTime` values from `hello` and `pong` let a host estimate the hub's clock (offset = hub time − local time at receipt, taking the latest sample) for the deadline check below.
- **Frames.** Text frames of JSON, one message each, with a `type` discriminator. A client's frame may be at most 64 KiB and a host's at most 256 KiB. An oversized frame gets an `error` frame and is dropped; the link stays up.
- **Reconnect.** After a drop, a device waits 1 s, then doubles the wait up to 30 s, with full jitter. The wait resets once a link has stayed up for 60 s. The Mac also reconnects at once on wake (the coordinator's existing wake signal, D-034) and when the network path changes (`NWPathMonitor`). A 401 stops the link until the next `hub join`, as the push loop does today. The phone holds its link only while the app is active: it opens the link on becoming active, closes it on going to the background, and uses the same backoff, capped at 15 s.
- **Shutdown.** On SIGTERM the hub closes every link with close code 1001 inside its existing bounded drain. Devices reconnect with backoff.

**Presence.** A host is online while its link is up. The hub keeps, in memory, the time of the last frame it received on each link. `devices.last_seen_at` is written when a link opens, at most once a minute while it stays up (the existing throttle), and, unthrottled, when it closes, set to the time of that link's **last received frame**, not to the moment the hub noticed the drop. So `lastSeenAt` means "the last time the Mac was heard from", and a link closed by the 30 s dead-link timeout reports a time 30 s in the past. A client receives `presence { hosts: [{ deviceId, name, online, lastSeenAt }] }` with every non-revoked `macos` device of its user: once after `hello`, then whenever one changes.

## Wire messages

All ids are the client's own lowercase UUIDs unless stated otherwise. Times are RFC 3339 UTC with milliseconds.

| Direction | `type` | Body |
| --- | --- | --- |
| hub → any | `hello` | `protocol`, `minClientProtocol`, `deviceId`, `role`, `heartbeatSeconds`, `hubTime` |
| any → hub | `ping` | none |
| hub → any | `pong` | `hubTime` |
| client → hub | `command` | `id`, `method`, `params` |
| hub → host | `command` | `id`, `method`, `params`, `deadline`, `from: { deviceId, name }` |
| host → hub | `reply` | `id`, and either `result` or `error: { code, message, details? }` |
| hub → client | `reply` | the same |
| client → hub | `watch` / `unwatch` | `threadId` |
| hub → host | `watching` | `threadIds` (the full set of this host's threads that some client watches; sent after `hello` and on every change) |
| host → hub | `event` | `event` (an `AdapterEvent`, whose `threadId` must be in the host's watched set) |
| hub → client | `event` | `event` |
| hub → client | `stream_gap` | `threadId` (events were dropped for this client; see Limits) |
| hub → client | `presence` | `hosts` |
| hub → any | `error` | `code`, `message`, `details?` (a problem with the link or a frame, not a command) |

A shared fixture, `Tests/Fixtures/sync/relay.json`, holds one example of every message. The Rust and Swift suites both decode it and encode it back, as `changes.json` is used today, so neither side can drift. Edit it only with both suites updated.

## The four commands

| Method | Params | Routed to | Result |
| --- | --- | --- | --- |
| `turn.send` | `threadId`, `text` | owner of the thread | `turn` (the `Turn` the Mac created or found) |
| `turn.interrupt` | `threadId` | owner of the thread | `turn` |
| `request.respond` | `requestId`, `decision?`, `answers?`, `decline?` (as today) | owner of the request's thread | `request` |
| `thread.start` | `threadId` (minted by the phone), `projectId`, `connectionId`, `folder` (Codex and Claude only; absent for B4), `text` | owner of the project | `thread`, `turn` |
| `turn.lookup` (read-only) | `operationId`, `threadId` | owner of the thread | `state: "found" \| "in_flight" \| "none"`, `turn?` |

These are the four commands Brian uses, plus `turn.lookup`, which only reads: the phone uses it to settle a send whose reply never came (see "Sending and its states"). For `turn.send` and `thread.start` the command `id` is also the turn's `operationId`. The other params match today's local commands, so the Mac decodes them with the existing `WorkspaceProtocol` types. `thread.start` is new: a coordinator command that creates the thread and sends its first turn in one step. It is reachable only through the relay, and its types live in `WorkspaceProtocol` next to `ThreadCreate`.

### Authorisation (the hub)

The principal comes from the link's token. For every command the hub, inside a tenant transaction:

1. Refuses anything from a `host` link, and any method outside the five, with `not_found`. A Mac never sends commands in M8c.
2. Looks up the target row by id with `org_id` and `user_id` equal to the caller's: the thread for `turn.send`, `turn.interrupt`, and `turn.lookup`, the runtime request and then its thread for `request.respond`, and the project for `thread.start`. A missing row, and a row belonging to another user or org, both answer `not_found`, with no difference between them.
3. Takes the row's `owner_device_id` and requires that device to be the caller's user's, `platform = 'macos'`, and not revoked. Otherwise it answers `not_found`.
4. Answers `stale_runtime_request` at once, without forwarding, for `request.respond` when the materialised request is no longer `pending`. The Mac stays the authority; this check only saves a round trip.
5. Applies the rate limits below.

### Delivery, deadlines, and holds

- **Owner online.** The hub forwards the command with `deadline = hub now + 10 s` and waits for the reply: 30 s for `turn.send` and `thread.start` (starting a runtime can take that long), 15 s for the other two.
- **Owner offline, `turn.send` or `thread.start`.** The hub refuses at once with `device_offline`, `details: { deviceId, deviceName, lastSeenAt }`. These are never held (D-045).
- **Owner offline, `turn.interrupt` or `request.respond`.** If the owner's `last_seen_at` is within the last 60 s (a flap), the hub holds the command in memory. When the owner reconnects before `last_seen_at + 60 s`, it is delivered with a fresh deadline; when that moment passes first, the answer is `device_offline`. An owner last seen longer ago gets `device_offline` at once.
- **The deadline on the Mac.** The host drops a command whose `deadline` has passed by its estimate of the hub's clock, and replies `command_expired`. This covers a frame that sat in a socket buffer while the Mac slept. Commands are never stored, on the hub or on the Mac.
- **No reply in time.** The hub answers `relay_timeout`. A late reply is dropped.
- **Duplicates in flight.** A command whose `(caller device, id)` matches one still in flight is attached to that one's pending reply instead of being forwarded again. The in-flight entry is keyed by device, not by link, and outlives a drop of the caller's link: when the caller reconnects before the reply arrives, the reply goes to its new link.
- **Routing a thread the hub has not seen yet.** When the hub routes `thread.start`, it records `threadId → owner` in memory for 5 minutes. That lets `watch` and `turn.send` reach a new thread before the Mac's next push brings its row. The calling link also starts watching the new thread at once, so its first deltas are not missed.

### What the Mac does (`RelayExecutor`)

A new `RelayExecutor` in `Sources/Coordinator/HubSync/` turns a relayed command into the same `SessionService` call the `Router` makes for the local app. `SessionService` stays the only writer. Existing errors pass through unchanged in the reply: `stale_runtime_request` when an approval was already answered (on the Mac or by another relay), `auth_required`, `native_session_missing`, `submission_unknown`, `cancellation_unconfirmed`, and so on. This settles "first answer wins": the first answer `SessionService` records wins, and every other one gets `stale_runtime_request`. (The M8 design called this `request_already_resolved`; the existing code is kept, so the Mac app and the phone handle it the same way.)

- `turn.send` calls `sessions.turnSend(params, operationId: id)`. `SessionService` already finds an existing turn by `operationId` (`WorkspaceDatabase.turn(operationId:)`) and returns it instead of starting another, which makes a retry safe across a coordinator restart.
- **Single flight per operation.** That lookup runs before `turnSend`'s waits and before the turn is inserted (`SessionService.swift:513`–`526`), so a resend that overlaps the first attempt would otherwise fail with `turn_active` or a duplicate key. `RelayExecutor` therefore keeps a map of in-flight operation ids to their tasks. A command whose id is already running awaits the same task and returns its result. Ids are removed when the task ends; after that, the durable lookup covers retries.
- **Errors after the turn exists.** When `turnSend` fails after inserting the turn, its error carries `details.turnId` (`SessionService.swift:526`, `:582`). `RelayExecutor` passes that through unchanged, and the phone treats any reply error carrying `details.turnId` as accepted: the turn and the user's message exist and will arrive through sync with their failure or reconciling state. Only an error without a `turnId` is a refusal.
- `turn.interrupt` calls the existing method.
- `request.respond` calls the existing method, with one fix this slice needs. Today `requestRespond` checks `pending` (`SessionService.swift:830`), waits on `adapter.respond` (`:845`), and only then marks the request resolved (`:850`). Because `SessionService` is an actor that can be re-entered during that wait, two answers arriving together (one from the Mac, one relayed) can both reach the runtime. `SessionService` gains an in-memory set of requests being answered. A respond for a request already in that set fails at once with `stale_runtime_request`, before calling the adapter, and the id is removed when the call ends. That makes "first answer wins" true at the runtime, not only in the database.
- `turn.lookup` answers from this Mac's own database and `RelayExecutor`'s in-flight map: `in_flight` if the operation is still running, `found` with the turn if a turn has that `operationId`, otherwise `none`. Because the Mac drops a command after its deadline, `none` after the deadline is final: that send will never run.
- `thread.start` checks, refusing with `protocol_invalid` if any fails:
  - the project exists on this Mac;
  - the connection is on this Mac, is conversation-ready, and is one of:
    - a Codex or Claude connection, with `folder` given and one of the project's `projectFolders` paths, compared in canonical form;
    - a local B4 connection whose managed server's project folder belongs to this project (the coordinator's existing resolution, `ProjectService.folder(forThread:connection:)`), with no `folder`. A B4 thread is bound to the connection's route, not a directory (`SessionService.swift:308`), so its context is the route key, as for a B4 thread started on the Mac;
  - remote B4 connections are refused.

  Then:
  - if no thread with that `threadId` exists, it creates one through the existing `threadCreate` path with that id, the connection, and (for Codex and Claude) `folder` as the working directory;
  - if one exists with the same connection (and, for Codex and Claude, the same folder), it reuses it;
  - if one exists with anything different, it refuses with `protocol_invalid`;
  - it then calls `turnSend` with `operationId: id`.

  A retry therefore lands on the same thread and the same turn. `ThreadCreate` gains an optional `threadId` used only by this path.
- The Mac app sees all of this through its ordinary events, as if Brian had typed it. A thread started from the phone appears in the Mac's sidebar at once.

### Error codes added

To the hub's error table and to Swift `ErrorCode` (both additive): `device_offline`, `command_expired`, `relay_timeout`, `rate_limited` (`details.retryAfterMs`), `link_replaced`, and `client_too_old`. `not_found` and `stale_runtime_request` are reused.

### Which project a B4 connection serves

The phone needs to know which local B4 connections belong to a project, and the hub blanks `connections.localServerId` and `target`. So `connections` gains a synced, nullable, Mac-only column, `projectId`:

- **Value.** For a local B4 connection, the project of its managed server's project folder, resolved the way the coordinator already resolves a B4 thread's project (an automatic project is created if none owns the folder). Null for every other connection.
- **When it is written.**
  - when the coordinator creates a local B4 connection;
  - when `ProjectService` moves a folder between projects (beside the `threads.projectId` rewrite it already does);
  - when a project is deleted;
  - by a backfill in Swift right after the migration, run with `b4app.replaying` off so it syncs like any write.
- **What it reveals.** It is an id that is already on the hub (`projects.id`), never a path, so it reveals nothing the hub does not already hold.
- **Merging.** Only the Mac writes it, so it needs no column clock: it applies with M8a's plain semantics, and the phone-writable list does not change. `applyRemote` skips it like every Mac-only column.
- **Migrations.**
  - local `0005_connection_project.sql` adds the column;
  - hub `0004_relay.sql` adds the materialised `connections."projectId"`, along with `enrollment_codes.created_by_device_id` for pairing;
  - the mirror's schema v3 adds `connections.projectId`.

  The `SyncFilter` keeps the column, `b4hub-core`'s table spec gains it, and `Tests/Fixtures/sync/changes.json` gains a connection with a `projectId`, decoded by both suites.

## Live progress

- **Watching.** When a thread is open on the phone, the phone sends `watch { threadId }`, and `unwatch` when it leaves the thread or the app goes to the background. A client watches at most 4 threads. The hub keeps, per host, the set of its threads that any client watches, and sends the whole set in `watching` after the host's `hello` and on every change.
- **Catching up an open message.** Opening a thread mid-reply would otherwise show only the text streamed after the `watch`. `HubLink` therefore keeps, for each active turn on the Mac (watched or not), the accumulated text of each message item that has started but not completed, and drops it on completion. When a thread enters the watched set, `HubLink` first sends one `message.delta` per open item, carrying the text so far, then the live events.
- **What the host sends.** `HubLink` subscribes to the coordinator's `EventLog`. For every event whose `threadId` is in the watched set, it sends `event` if the kind is one of `turn.acknowledged`, `turn.state_changed`, `turn.finished`, `message.started`, `message.delta`, `message.completed`, `tool.started`, `tool.completed`, `runtime_request.opened`, or `runtime_request.resolved`, and the encoded frame fits in 256 KiB. A larger event (a big tool result) is skipped; its item arrives through sync. These are the events the local app already receives, after the coordinator's redaction (D-035).
- **What the phone does.** `MirrorTransport` re-emits each relayed event in its own epoch, so `WorkspaceModel` streams exactly as on the Mac: `message.delta` accumulates `liveText` by native item id, and a completed item replaces it. The phone ignores a relayed `message.delta` for an item that the mirror already holds as completed. Relayed events change only the on-screen model, never the mirror. When the change log's rows arrive, `MirrorTransport` emits its ordinary events, which upsert the same items by id, so nothing is shown twice.
- **Gaps.** If the hub cannot keep up with a client (its outbound queue is full), it drops that client's events for the thread and sends `stream_gap { threadId }` once the queue drains. The phone drops the thread's `liveText` and waits for sync. A reconnect does the same.

## The phone

### Sending and its states

The composer sends `turn.send` with a fresh `id` (its `operationId`). The message shows in the transcript as the user's pending message, as on the Mac, in one of these states:

| State | Shown | Draft |
| --- | --- | --- |
| sending | the message with a small "Sending…" | kept |
| accepted (reply `turn`) | the turn, then streaming | cleared (the Mac clears it everywhere, M8b) |
| accepted with an error (a Mac error carrying `details.turnId`) | the turn, with its failure or "reconciling" state once synced | cleared by the Mac |
| refused (`device_offline`, `rate_limited`, a Mac error without a `turnId`) | the reason in place of the spinner; the message is removed | kept |
| not confirmed (`relay_timeout`, the link dropped, or no reply 30 s after the tap) | "Not confirmed: your Mac may not have received this." | kept |

- **Retry.** If the phone's link drops while a send is pending, it resends the same `id` when the link returns, but only while 30 s have not passed since the tap. After that the send stays "not confirmed".
- **Resolving "not confirmed".** A turn with that `operationId` arriving through sync makes it accepted. Otherwise, once the Mac is online and the phone's link is up, the phone sends `turn.lookup` (no sooner than 30 s after the tap, so the command's deadline has certainly passed):
  - `found`: accepted;
  - `in_flight`: ask again in 5 s;
  - `none`: "Didn't reach your Mac", with the draft still there and Send available again.

  Only the Mac's own answer can declare a send lost, never the absence of a row in the mirror, so a turn the Mac created but has not yet uploaded is never mistaken for a lost one. While the Mac stays unreachable, the send stays "not confirmed".
- **`thread.start`** uses the same states (with `turn.lookup` on the new `threadId`). Its sheet follows the M8b design's, with B4 added: project → connection → folder (only for a Codex or Claude connection, and only when the project has several folders) → first message. The connections offered are those whose `ownerDeviceId` is the project's owner and whose status is conversation-ready: every Codex and Claude connection, plus each local B4 connection whose synced `projectId` is this project (see "Which project a B4 connection serves"). A B4 connection is labelled with its route's name, as on the Mac. The phone mints the `threadId`, keeps the sheet showing "Starting…" until the command is accepted, then opens the thread. Until the thread's row reaches the mirror, `MirrorTransport` answers `thread.read` for it with a placeholder held in memory: the title, project, and connection the sheet chose, with no items. It buffers that thread's relayed events (up to 256) and replays them to the model. The placeholder is never written to the mirror, and the synced row replaces it when it arrives. If no row arrives within 2 minutes, the placeholder is dropped and the thread shows "Not confirmed".
- **Stop and approvals.** Stop sends `turn.interrupt`, and an approval's buttons send `request.respond`. Each shows "Waiting for your Mac…" for up to 90 s (the hub's 60 s hold plus the 15 s reply wait, with margin), then the reply or "Not confirmed". `stale_runtime_request` reads "Already answered", and the request card resolves from sync. A "not confirmed" stop or answer is not retried: sync shows whether it took effect, and the buttons stay available while the request is still pending.

### When the Mac is unreachable

Presence drives one state per host. `WorkspaceModel` holds them as `hostPresence: [String: HostPresence]`, keyed by device id (name, phase, last seen), and receives them through a new additive event `host.presence`, which only `MirrorTransport` emits.

- **A thread's controls and notice** follow its own owner (`ownerDeviceId`).
- **The thread list's notice** concerns the **primary Mac**: the owner of the thread with the most recent `lastActivityAt`.
  - A user with one Mac (today's case) sees exactly that Mac.
  - A stale second device that never ran `hub leave` and owns no recent thread raises no notice in the list; its own threads show it when opened.
  - With no threads, the list notice uses the most recently seen host.

The phases are:

- **Connected.** The host is online and the phone's link is up. Everything works.
- **Reconnecting.** The host went offline less than 60 s ago, measured from its `lastSeenAt` on the phone's clock, corrected by the hub's `hubTime`. The open thread shows one quiet line, "Reconnecting to your Mac…". Sending is not blocked by the phone: a send in this window gets the hub's `device_offline` like any other, and the line explains it.
- **Disconnected.** The host has been offline for 60 s or more. A persistent notice sits at the top of the thread list and of every thread: "Brian's MacBook Pro is offline · last seen 14:02". Threads and transcripts stay fully browsable. The composer, Stop, approval buttons, and the new-thread button are disabled, with the notice as the reason. A turn the mirror still shows as active is labelled "Not confirmed while your Mac is offline" instead of a working spinner, and its band stays as synced: the phone does not invent an outcome.
- **Phone offline from the hub** (its own link is down and retrying): the composer reads "Connecting to the hub…", and the existing sync error state shows in Diagnostics. Presence is unknown, so no host notice is shown.
- **Back online.** The notice goes away, controls return, and sync brings what happened. The coordinator already reconciles turns on wake (D-034), and the phone shows the result when it arrives.
- **The Mac left the hub** (`hostDisconnected`, M8b): today's empty state, which hides the list, becomes the same persistent notice ("Your Mac has left the hub. Its threads come back when it joins again.") above a browsable list. One behaviour whenever the Mac is unreachable (the owner's direction, extended to this case as my call).

The grace period is 60 s from `lastSeenAt`, the same window D-045 already uses for holding interrupts and answers. Because `lastSeenAt` is the last frame heard (see "Presence"), the notice shows about 60 s after the Mac went quiet. For a clean close (the coordinator stopped), the phone hears about it at once and shows "Reconnecting…" for the full 60 s. For a silent drop (sleep, lost network), the hub notices after 30 s, so "Reconnecting…" shows for the remaining 30 s.

## Pairing by QR code

**The hub.** `POST /v1/pairing-codes`, authenticated, callable only by a `macos` device (any other platform gets `not_found`). It mints an enrollment code for the caller's own user and org, valid 5 minutes, single use, stored like `b4hub enroll`'s codes in `enrollment_codes` with a new nullable `created_by_device_id`. It answers `{ code, expiresAt, hubURL }`, where `hubURL` is `B4HUB_PUBLIC_URL` when set and is otherwise left out (the Mac then uses the URL it joined with). Limited to 10 per user per hour. The phone redeems the code with the unchanged `POST /v1/enroll`.

**The Mac.** The coordinator gains `hub.pair`, which calls that route and returns `{ url, code, expiresAt }`. The Settings window (D-053) gains a page, "Remote access", holding:

- "Pair iPhone…", which opens a sheet showing a QR code (CoreImage's QR generator) for `b4app://pair?hub=<url>&code=<code>`, the code also in text, and a countdown. When the coordinator mints a code, it records the ids of the user's current devices and then polls `GET /v1/devices` every 2 s until the code is used or expires. A new command, `hub.pairStatus`, answers `{ state: "waiting" | "paired" | "expired", deviceName? }`, with `paired` once a device id that was not in the recorded set appears with platform `ios`. The sheet polls it and closes with "Paired with <name>". When the code expires, it offers "New code". It is disabled with "Join a hub first" when the Mac is not joined.
- The "Keep the Mac awake" toggle, built in this slice exactly as the M8b design specifies (the `settings` table, `settings.read` and `settings.update`, the power assertion while joined). Nothing of it exists yet. The toggle sits on this page instead of the separate Settings scene that design described, because D-053 has since made Settings a window with pages.
- The link's status: connected since, or reconnecting with its last error.

The pairing code is a short-lived credential shown on purpose, as a typed enrollment code is today. It appears only in that sheet, travels only over the local socket and to the hub, is never logged or stored by the coordinator, and dies on use or after 5 minutes (a recorded exception to the "no secrets in UI state" rule, as narrow as `hub.join`'s code).

**The phone.**

- The app registers the `b4app` URL scheme. M8f's `b4app://thread/<id>` uses the same scheme.
- `HubConnectView` gains "Scan QR code", which opens a camera scanner (AVFoundation's metadata output, filtered to QR, in `Apps/iOS`, with an `NSCameraUsageDescription`). It is hidden where no camera is available, such as in the Simulator. Typing the URL and code stays.
- Scanning, or opening a `b4app://pair` link, fills the screen and asks for one confirmation: "Pair this iPhone with the hub at <host>?", with the device name editable. It never enrolls without that tap, so a link from elsewhere cannot silently enroll the phone into a stranger's hub.
- A pair link opened on a phone that is already enrolled shows "This iPhone is already paired" and does nothing.
- The scanned code is held in view state only until the enrollment request returns, like the typed code.

A real iPhone can only use pairing once the hub has a reachable URL (the deployment slice). In the Simulator, `localhost` works.

## Limits

In memory, per hub process. Over a limit the answer is `rate_limited` with `retryAfterMs`.

| Limit | Value |
| --- | --- |
| Commands per client device | 60 a minute, bursts of 20 |
| `turn.send` + `thread.start` per user | 20 a minute |
| Link upgrades per device | 10 a minute (`429` before the upgrade) |
| Watched threads per client link | 4 (`watch` beyond that gets an `error` frame `watch_limit`) |
| Frame size | client 64 KiB, host 256 KiB |
| Held commands per host | 32 |
| Outbound queue per link | 256 frames; when it is full, a client's `event` frames are dropped (then `stream_gap`), while other frames wait |
| Pairing codes | 10 per user per hour |

The hub logs a link's open and close, the method, outcome, and latency of each command, and limit hits. It never logs params, results, events, or tokens.

## The Mac's link (`HubLink`)

- A new actor `HubLink` in `Sources/Coordinator/HubSync/`, started and stopped with `HubSync` (on start when joined, on `join`, stopped on `leave`, `stop`, and 401). It owns the WebSocket, heartbeat, backoff, hub-clock estimate, watched set, and `EventLog` subscription, and hands commands to `RelayExecutor`.
- The WebSocket client is in `WorkspaceSync` (Foundation only, so the phone uses the same code): a `HubLinkConnection` protocol, `URLSessionHubLinkConnection` over `URLSessionWebSocketTask` with the bearer header on the upgrade request, and `FakeHubLinkConnection` for tests (the pattern of `HubAPI` and `FakeHubAPI`). The wire types are in `WorkspaceSync/RelayWire.swift`.
- `hub.status` gains `link: { state: "connected" | "connecting" | "offline", since, lastError? }`, and Diagnostics shows it.

The phone's `MirrorRelay` in `WorkspaceMirror` (`MirrorLink` is already the stored-link record) uses the same `HubLinkConnection` and wire types. `MirrorTransport` serves `turn.send`, `turn.interrupt`, `request.respond`, and the new local command `thread.start` through it, with `watch` and `unwatch` on `thread.read` and on leaving a thread. `turn.lookup` is internal to the phone's send states. The refusal text for what remains unserved changes from "arrives in M8c" to "is done on the Mac".

## Testing

**CI, hub (Rust, Ubuntu with Postgres).** Black-box over a real loopback listener with a fake Mac and a fake phone, written as test helpers on `tokio-tungstenite` (a dev dependency, pinned). Time-dependent cases run on tokio's paused clock. The cases:

- authentication before the upgrade
- one link per device, with replacement
- hello and heartbeat; the dead-link close
- presence on connect and disconnect, with `last_seen_at` written on close
- routing for each command to the owning host, including a thread just started and not yet pushed
- `last_seen_at` set to the last frame heard after a dead-link close
- an in-flight reply delivered to the caller's new link after it reconnects
- `not_found` for another user's or org's thread, a host-sent command, an unknown method, and a revoked owner
- the immediate `device_offline` with last-seen details
- the 60 s hold delivered on reconnect and expired after
- the deadline stamped on each command
- `relay_timeout`
- in-flight duplicate attach
- the early `stale_runtime_request`
- watch fan-out to watchers only, with the watched set sent to the host
- `stream_gap` under backpressure
- every limit
- pairing-code minting (`macos` only, single use, expiry, the rate limit)
- revocation closing the link
- the RLS test extended to the new lookups
- `relay.json` round trip

**CI, Swift package (macOS).**

- `HubLink` and `RelayExecutor` against `FakeHubLinkConnection`, with a real `SessionService` over a test cluster and the existing fake runtimes (`fake-codex.py`, `fake-claude.py`):
  - a relayed send runs a real turn
  - a resent `id` gives one turn, including after a coordinator restart
  - an expired deadline gives `command_expired` with no turn
  - an approval answered locally first makes the relayed one `stale_runtime_request`
  - an interrupt
  - `thread.start` with the fake B4 server (`fake-b4.py` and `FakeB4Project`) in a project, giving a route-bound thread
  - `thread.start` refusals: a folder outside the project, a local B4 connection whose server serves another project, a remote B4 connection, a reused `threadId` with a different folder
  - `connections.projectId` set on creating a local B4 connection, rewritten when its folder moves to another project, and backfilled after the migration
  - an overlapping resend of the same `id` awaits the first attempt and returns its turn (single flight)
  - two simultaneous answers to one request reach the fake runtime once; the second gets `stale_runtime_request`
  - `turn.lookup` answers `in_flight`, `found`, and `none` (the last after an expired command)
  - a failure after the turn's insert replies with `details.turnId`
  - only watched threads' events are sent, oversized events are skipped, and a new watch first gets the open message's text so far
  - backoff and reset on wake
- `URLSessionHubLinkConnection` against a minimal fake hub on `NIOWebSocket` over loopback (test target only): the upgrade carries the bearer header, frames go both ways, and close codes come through.
- `MirrorTransport`, `MirrorLink`, and `WorkspaceModel`:
  - the send state table
  - "not confirmed" resolving from a synced turn, and from `turn.lookup` (`found`, `in_flight` then `found`, `none`)
  - the `thread.start` placeholder and its buffered events, replaced by the synced row
  - relayed deltas then synced items without duplicates
  - `stream_gap`
  - presence phases on an injected clock (connected → reconnecting → disconnected after 60 s → connected)
  - the left-hub notice with the list still shown
- Pairing: `hub.pair` against `FakeHubAPI`; a QR image rendered by the Mac's generator and decoded with `CIDetector` gives back the exact link; the pair-link parser.
- `relay.json` round trip.

**CI, app builds.** Both apps build, including the scanner, the Settings page, and the URL scheme. No UI tests, as today.

**Not in CI: the live gate** (Simulator, the Compose hub on `localhost:8080`, and the owner's packaged app rebuilt from the branch with the dev loop, never rebuilding `dist/` while it runs). Recorded in `docs/verification.md`:

1. Pair the Simulator: "Pair iPhone…" on the Mac shows a QR code. The Simulator opens the same link through `xcrun simctl openurl booted "b4app://pair?..."` and confirms, and the Mac's sheet closes with the device name.
2. From the Simulator, start a thread in a project, once on a Codex or Claude connection and once on a managed local B4 connection of that project. Each appears on the Mac at once, and its reply streams on the phone with tool calls.
3. Continue an existing Mac thread from the phone, with streaming.
4. A fixture or live approval: answer it on the phone, and the Mac's card resolves once. Answer one on the Mac first, and the phone's tap reads "Already answered".
5. Stop a running turn from the phone.
6. Stop the coordinator (`agent-workspace coordinator stop`): the phone shows "Reconnecting…", then after about 60 s the disconnect notice with the last-seen time, and the list stays browsable. A send in that state is refused with that time. Restart it: the notice clears and the composer returns.
7. With "Keep the Mac awake" on and joined, `pmset -g assertions` lists the coordinator's assertion. Off, it is gone.

Live provider runs stay opt-in. Camera scanning gets checked on a real iPhone in the deployment slice.

## Constraints

Everything in the M8 and M8b designs' constraints, plus:

- `WorkspaceSync`, `WorkspaceMirror`, `WorkspaceProtocol`, and `WorkspaceClient` stay Foundation-only and never import NIO (`NIOWebSocket` is used only by a test target). The camera scanner and URL-scheme handling live in `Apps/iOS`. `WorkspaceUI` reaches the QR sheet and presence only through commands and events.
- `SessionService` stays the only writer of turns, display items, and runtime requests. `RelayExecutor` calls it and writes nothing itself.
- The hub stays one process. Its link registry, presence, holds, and limits are in memory and are lost on restart, which is safe because nothing in them is state.
- The five methods are an allowlist on the hub and again on the Mac.
- Two other sessions are open in this area: one making the iOS app follow Apple's HIG, which touches the phone's views, and one designing a sign-in screen, which may later change how a phone first joins (M8d). Pairing here reuses today's enrollment codes and stays useful as "add this phone" under accounts. The plan's phone tasks start from whatever `main` holds when they run.

## Calls made (mine; the owner can overrule while reading)

1. One link endpoint for both roles, with the role taken from the device's platform; only `ios` and `cli` devices send commands.
2. Heartbeat every 10 s with a 30 s dead-link timeout; a 60 s grace before the disconnect notice; backoff 1 s to 30 s on the Mac and to 15 s on the phone; the phone links only while the app is in the foreground.
3. Commands carry a 10 s deadline from the hub's clock; replies wait 30 s for a send and 15 s for the others; a phone retries the same `id` for 30 s after the tap and never later.
4. "First answer wins" is the Mac's existing `stale_runtime_request`, not a new hub-side record.
5. `thread.start` is one relayed command with a phone-minted `threadId`. It is allowed only in a folder the project lists (Codex, Claude) or on a local B4 connection serving that project, never on a remote connection.
6. Streaming covers the watched threads only, events up to 256 KiB, and no stored backlog; `stream_gap` tells the phone to wait for sync.
7. The left-hub empty state becomes a notice above a browsable list, the same as the offline case.
8. Pairing reuses enrollment codes, minted by a joined Mac through a new route, shown in a "Remote access" Settings page that also takes "Keep the Mac awake"; the phone always asks before enrolling.
9. The limits in the table above.

From the builder check (a reviewer read this as the engineer who would plan from it; these were settled from the code and the owner's direction):

10. A lost send is declared lost only by the Mac (`turn.lookup` after the deadline), never by the mirror's silence, so a turn the Mac has not yet uploaded is never re-sent by mistake.
11. A Mac error carrying `details.turnId` means the turn exists: the phone shows it as accepted with its failure, not refused.
12. `RelayExecutor` runs each operation id once at a time (single flight), and `SessionService` marks a request as being answered before calling the runtime, so overlapping retries and simultaneous answers from two surfaces are both safe.
13. The hub remembers a started thread's owner for 5 minutes and auto-watches it for the caller. The phone shows an in-memory placeholder until the row syncs. The Mac sends the text so far of open messages when a thread is first watched.
14. Presence is per Mac. A thread follows its own owner; the list's notice follows the Mac with the most recent activity.
15. `lastSeenAt` is the last frame heard, not the time the drop was noticed.
16. Phone waits up to 90 s for a stop or an answer; protocol version in a `B4-Protocol` header.
17. Local B4 threads can be started from the phone (the owner's answer to the one question the check raised). To make that possible, `connections.projectId` syncs as a Mac-only column, and the Mac checks that the connection's server serves the chosen project. Remote B4 threads cannot be started from the phone, since they belong to no project.

## Left to the builder

- Module layout inside `b4hub` for the link (a `relay` module beside `routes` is the obvious shape), and how the registry is shared with `AppState`.
- Whether the phone's send states live in `WorkspaceModel` (shared) or a phone-only layer, provided the Mac's behaviour is unchanged.
- The visual detail of the notice, the send states, and the pairing sheet, within the LLA visual system and Apple's HIG.
- How the coordinator's `EventLog` subscription filters by watched set (inside `HubLink` is fine).
- Exact crate and package versions (pinned, recorded in `docs/compatibility.md`).

## Decisions to record

- D-054 The relay is one WebSocket per joined device; it carries commands, replies, presence, and live progress, never state, so it has no cursor and a lost frame is harmless.
- D-055 Relayed commands are never stored, carry a deadline the Mac enforces, and are idempotent by phone-minted ids the Mac already stores; a reply that never came is "not confirmed", never resent after 30 s.
- D-056 The phone keeps every thread readable when its Mac is unreachable; a notice replaces the composer after a 60 s grace, including when the Mac has left the hub.
- D-057 Only `ios` and `cli` devices send relayed commands, only the five allowlisted methods, only to a non-revoked `macos` device of the same user and org that owns the thread or project.
- D-058 A joined Mac pairs a phone by showing a five-minute, single-use enrollment code as a `b4app://pair` QR code; the phone scans or opens it and always confirms before enrolling.
- D-059 A local B4 connection's project syncs as `connections.projectId`, a Mac-only column, so the phone can start B4 threads in a project; remote B4 threads are continued from the phone but never started there.
