# Phoenix socket layer vs. b4hub relay: hardening notes

Date: 2026-11-03. Read-only study.

- Phoenix: `/Users/blove/repos/phoenix` at `6daf29b32` (main, 2026-11-02). Paths below are relative to that root.
- b4hub: this worktree (`blove/phoenix-beam-b4hub-research-d4c3f2`, `7af501a`). `Hub/...` and `Sources/...` paths are relative to the worktree root. `crates/` means `Hub/crates/`.

Every b4hub claim below was checked against the code, not the docs. Where I could not verify something (runtime behaviour, a library's allocation strategy), it is marked **uncertain**.

---

## 1. Heartbeats and idle timeout

**Phoenix**
- Server idle timeout: the WebSocket transport defaults `timeout: 60_000` (`lib/phoenix/transports/websocket.ex:31`), documented as "the timeout for keeping websocket connections open after it last received data" (`lib/phoenix/endpoint.ex:1051-1052`). The adapter (Cowboy/Bandit) enforces it; any inbound data resets it. Test: "shuts down if client goes quiet" (`test/phoenix/integration/websocket_channels_test.exs:917-930`).
- Application heartbeat: the client sends `phoenix/heartbeat` every 30 s (`assets/js/phoenix/socket.js:181`), the server replies `ok` (`lib/phoenix/socket.ex:703-712`).
- Half-open detection on the client: `sendHeartbeat` records `pendingHeartbeatRef` and arms a timer of one interval (`socket.js:835-840`); if the reply has not cleared it (`socket.js:855-858`) the client closes the connection itself and reconnects (`heartbeatTimeout`, `socket.js:558-575`). Worst case ~60 s to notice.
- Control frames are ignored unless the handler defines `handle_control/2` (`lib/phoenix/socket/transport.ex:196-217`).

**b4hub**
- Server: a link silent for `DEAD_LINK` = 30 s is closed with 4003 (`crates/b4hub-core/src/relay.rs:19`; `crates/b4hub/src/relay/link.rs:446-461`). Any frame, including a protocol-level Ping/Pong, resets it (`link.rs:478-483, 499-501`).
- Client: `ping` every `heartbeatSeconds` = 10 s (`relay.rs:17`; `Sources/WorkspaceSync/RelayLink.swift:323-340`) and a 30 s watchdog over *any* received frame, re-armed on every frame including undecodable ones (`RelayLink.swift:252-262, 347-361`).
- Writes are bounded: each socket write times out after `DEAD_LINK` (`link.rs:659-671`), so a peer that stops reading cannot wedge a link task forever.

**Gap:** none material. b4hub detects a silent peer faster than Phoenix on both ends (30 s vs 60 s). One design note, *no Phoenix precedent*: while a Mac is half-open (asleep without FIN) the hub still reads it as online for up to 30 s and forwards `turn.send` into the void, which then costs the phone a 30 s `relay_timeout` (`route.rs:556-559` reply wait, `relay.rs:23`). The hub knows `last_frame` (`link.rs:372`); it could treat a host silent for more than ~1.5 heartbeats as offline for routing purposes. Optional; not in the prioritized list.

## 2. Backpressure, slow consumers, frame size, memory

**Phoenix**
- Mailboxes are unbounded; Phoenix has no per-socket outbound queue limit. The long-poll server even buffers without bound (`lib/phoenix/transports/long_poll_server.ex:146`). So Phoenix is *not* a model for bounded queues.
- `max_frame_size` defaults to infinity (`endpoint.ex:1054-1055`).
- Memory: `fullsweep_after` (`endpoint.ex:1057-1060`), an explicit `:garbage_collect` message (`lib/phoenix/socket.ex:588-591`), and channel hibernation (`lib/phoenix/channel/server.ex:478-479`).
- Fan-out efficiency ("fastlane"): a broadcast is encoded once per serializer and the *same binary* is sent to every subscriber's transport (`lib/phoenix/channel/server.ex:99-124`, comment at 113-114).
- Per-connection resource cap: `max_channels_per_transport`, default 100 (`socket.ex:654`, `socket.ex:722-735`, `endpoint.ex:784-796, 892-900`; test "rejects the 101st channel join by default", `websocket_channels_test.exs:343`).

**b4hub**
- Bounded outbound queue of 256 frames per link (`relay.rs:40`; `registry.rs:390`). Events are dropped when a client's queue is full and replaced by one `stream_gap` per thread once there is room (`registry.rs:131-203`); presence is coalesced to the latest (`registry.rs:146-153`); replies and commands wait up to 5 s (`route.rs:54`, `registry.rs:527-553`); `watching` is written by the host's own task so it is never dropped (`link.rs:430-443, 470-477`). This is stronger than Phoenix.
- Frame limits: 64 KiB from a client, 256 KiB from a host, refused with an error frame (`relay.rs:32-34`; `link.rs:485-491, 511-527`); 1 MiB hard cap at the socket layer (`link.rs:48-52, 165-167`).
- Per-link resource caps: 4 watches (`relay.rs:36`; `registry.rs:604-638`), 32 held commands per offline Mac (`relay.rs:38`; `route.rs:251-279`).

**Gaps**
- (a) **Unbounded command tasks per link.** Every client `command` frame is `tokio::spawn`ed (`link.rs:576-582`). The in-flight claim is taken *before* the rate limit (`route.rs:321-333`, by design so resends attach), and even a rate-limited refusal is delivered through `send_wait` with a 5 s bound (`route.rs:352-358`). A client that sends distinct ids faster than it reads keeps up to (frames received in 5 s) tasks and `in_flight` entries alive; the link loop never blocks on them, so TCP backpressure does not kick in. Bounded only by ingress bandwidth. Needs a valid device token.
- (b) **Queue bounded by count, not bytes.** 256 frames x 256 KiB host events = up to 64 MiB queued per client link, and `fan_out` deep-clones the `serde_json::Value` per watcher (`registry.rs:670-685`, `registry.rs:135-144`), then each link re-serializes it (`link.rs:660-664`). Phoenix's fastlane encodes once.
- (c) Socket buffers: tungstenite 0.29 defaults to 128 KiB read + 128 KiB write buffers per connection (`~/.cargo/registry/src/*/tungstenite-0.29.0/src/protocol/mod.rs:96-100`), and axum 0.8.9 exposes `read_buffer_size`/`write_buffer_size` on `WebSocketUpgrade`. `link.rs:165-168` sets only the message/frame caps. **Uncertain** whether those buffers are allocated eagerly or grow on demand; measure before changing.

## 3. Connection admission

**Phoenix**
- `check_origin` runs before connect (`websocket.ex:54`; `transport.ex:341-397`), because browsers send cookies cross-site and the socket can read the session (`endpoint.ex:934-972`, the CSWSH warning at `endpoint.ex:1031-1044`).
- Auth at connect: `connect/3` returns `:error` -> 403 or a custom `error_handler` (e.g. 429) (`websocket.ex:75-91`; `endpoint.ex:1072-1086`). Tokens are typically `Phoenix.Token` with `max_age` (default 86400 s, `lib/phoenix/token.ex:129-130`), optionally passed in `Sec-WebSocket-Protocol` (`websocket.ex:99-128`).
- `connect_info` exposes only whitelisted data (peer_data, x_headers, uri, user_agent, session with CSRF) (`endpoint.ex:976-1044`; `transport.ex:482-575`).
- Serializer/version negotiation refuses an unknown `vsn` with 403 (`socket.ex:611-638`; test `websocket_channels_test.exs:907-915`).
- **Socket id and forced disconnect:** `id/1` names the socket (e.g. `users_socket:<user_id>`), the transport subscribes to that topic on init (`socket.ex:549-553`), and `Endpoint.broadcast(id, "disconnect", %{})` stops every socket of that user on every node, because it goes through PubSub (`socket.ex:25-52, 236-246, 571-573`; test "shuts down when receiving disconnect broadcasts on socket's id", `websocket_channels_test.exs:838-884`).
- Duplicate join on the same topic closes the old channel first (`socket.ex:769-786`, `shutdown_duplicate_channel` with a 5 s kill fallback at `socket.ex:900-911`; test `websocket_channels_test.exs:886-905`).
- Connection-count limits and accept rates live in Ranch/Bandit, not in this repo (**not verified here**).
- **Drain:** `PoolDrainer` (`lib/phoenix/socket/pool_supervisor.ex:66-137`) collects every socket, sends `phx_drain` in batches of `batch_size` (default 10 000) every `batch_interval` (default 2 000 ms), bounded by `shutdown` (default 30 000 ms) (`pool_supervisor.ex:77, 88-89, 110-136`; docs `endpoint.ex:856-880`). It is fire-and-forget: it does not wait for each socket to finish (`pool_supervisor.ex:127-131`). Each batch emits `[:phoenix, :socket_drain]` telemetry (`pool_supervisor.ex:116-125`). A drained transport closes with 1012 (`socket.ex:575-578`).

**b4hub**
- Origin: not checked, and **not needed**: the link authenticates with `Authorization: Bearer` (`link.rs:118-139`, `Hub/API.md` "Authentication"), which a browser cannot attach to a WebSocket; the only cookie (`b4hub-instance`) is a stickiness hint, not a credential (`instances.rs:130-138`). This changes if a token is ever accepted from a query string or subprotocol (Phoenix's `auth_token` path, `websocket.ex:99-128`).
- Auth before upgrade, then a per-device upgrade limit of 10/min (`link.rs:127-135`; `limits.rs:12-15`), then the revocation re-check (`link.rs:136-139`), then the instance claim (`link.rs:140-154`), then a second revocation check after registration to close the race (`link.rs:323-335`).
- Protocol: `B4-Protocol` header; too old -> error frame + 4002 (`link.rs:264-273, 286-296`).
- One link per device; a newer link replaces the older with 4000 (`registry.rs:387-440`) = Phoenix's duplicate-join rule.
- Forced close: `Relay::close` / `close_user` (`registry.rs:469-496`), used by device revoke (`routes/devices.rs:21-23`), account delete (`routes/me.rs:351-355`), merge on enroll (`routes/enroll.rs:80-82`), and stale-claim relocation (`instances.rs:183-196`). These are **in-process only**; `Hub/API.md` ("DELETE /v1/me") says so for account deletion ("on the instance that served the request").
- Drain: holds answered first (`serve.rs:251`, `route.rs:294-306`), then every link closes with 1001 at once (`link.rs:453-459`), then the server and `relay.drained()` (`serve.rs:258-262`), then claims are released (`serve.rs:282-293`; `instances.rs:200-209`). Bounded by `B4HUB_SHUTDOWN_WAIT_MS` (default 30 s).

**Gaps**
- (a) **Logout does not end the live link.** `DELETE /v1/sessions/self` deletes the token row and nothing else (`routes/me.rs:301-314`; `crates/b4hub-db/src/devices.rs:411-419`); it never calls `relay.close`. Device tokens never expire (`devices.rs:326-358` has no TTL), and a link never re-checks its token after the upgrade (`Identity` carries no token id, `registry.rs:263-275`). So a link opened with a token that has since been deleted keeps relaying commands (for a client: driving the Mac's agent) until it disconnects. The well-behaved Mac and phone clients stop their own links on logout, so this is defense-in-depth against a stolen or misbehaving token, not a bug users hit.
- (b) **Forced close does not cross instances.** With more than one instance, a revoke/delete/merge served by instance B leaves the link on instance A up (same root cause as (a)). Phoenix's disconnect goes through PubSub to every node. b4hub already has the cross-instance channel it would need (`notify.rs` over `LISTEN`/`NOTIFY`, `b4hub_db::wakes`).
- (c) **Drain releases claims only after the slowest link finishes.** The heartbeat loop stops as soon as shutdown triggers (`instances.rs:166-169`), but the claims stay until `relay.drained()` returns (`serve.rs:258-262, 282-293`). Each closing link can spend up to `DEAD_LINK` (30 s) per write flushing its queue and sending its close (`link.rs:453-459, 666-686`) plus `CLOSE_GRACE` 2 s (`link.rs:56, 690-698`). Meanwhile every reconnect of every user of this instance reaches another instance, which sees a live owner (`crates/b4hub-db/src/instances.rs:81-89`, 20 s liveness window) and answers `409 relocated`. The client retries at once 3 times and then backs off 1, 2, 4 s... (`RelayLink.swift:222-227, 177-183`). Typical cost per deploy is a few seconds; one peer that is not reading can stretch it to the full shutdown wait for everyone on that instance. Not measured; derived from the code.
- (d) All links close in one instant (`link.rs:453-459`) rather than in batches. Clients use full jitter on a 1 s base (`RelayLink.swift:180-182`), so the herd lands within about a second on the remaining instances, each upgrade costing several queries on a 10-connection pool (`crates/b4hub-db/src/lib.rs:108-110`). Fine at today's scale.

## 4. Message routing robustness

**Phoenix**
- Every client push carries `ref` and `join_ref`; replies echo them (`socket.ex:726-758`; `lib/phoenix/socket/serializers/v2_json_serializer.ex:63-73`).
- Stale messages for an earlier join are ignored on the server (`socket.ex:803-819`), and a leave racing a server close is tolerated (`socket.ex:788-801`). The client drops outdated pushes before sending (`socket.js:780-795, 820-822`) and outdated inbound messages (`channel.js:241-249`).
- A resent push gets a *new* ref, so a late reply to the old one is ignored (`assets/js/phoenix/push.js:24-28, 98-114`).
- Crash isolation: each channel is a process; the socket monitors it and turns a crash into `phx_error` for that topic only (`socket.ex:560-565, 866-876`; test `websocket_channels_test.exs:746`); channels monitor the transport and exit with it (`channel/server.ex:363-366`).
- Malformed frames: `decode!` pattern-matches and raises, which kills the connection (`v2_json_serializer.ex:112-122`). Unjoined topics and unmatched topics get an error reply (`socket.ex:838-842, 878-881`).
- Join is synchronous in the transport process with no timeout of its own (`channel/server.ex:36-56`); the client's join push times out after 10 s and rejoins with 1/2/5/10 s backoff (`channel.js:30-32, 61-67`; `socket.js:182-188`).

**b4hub**
- Commands: claimed per (caller device, id) so resends attach and get one reply (`route.rs:182-249, 321-333`); routed to the caller's *current* link (`registry.rs:527-553`). Mac replies are matched by (host device, id) (`route.rs:172-179, 364-379`); late replies are dropped.
- Generations: a watch decided after its link was replaced is not added (`registry.rs:612-619`); a replaced link drops its watches (`registry.rs:411-426`); cleanup only unregisters the matching generation (`registry.rs:450-467`).
- The phone fails every pending command when the link drops (`Sources/WorkspaceMirror/MirrorRelay.swift:280-292`), so a reply that lands on the next link finds no waiter. Resends reuse the same id on purpose (idempotency on the Mac), unlike Phoenix's fresh refs; acceptable because the Mac's answer for an id is the same either way.
- Malformed frames: an error frame and the link stays up (`link.rs:529-543`); an unknown method is answered by id (`route.rs:381-395`); frames a role may not send are refused (`link.rs:600`). The client skips undecodable frames but still counts them as liveness (`RelayLink.swift:252-257`).
- Crash isolation: command work runs on its own tasks (`link.rs:576-582`); mutexes recover from poisoning everywhere (`registry.rs:166-170`, `route.rs:127-131`, `limits.rs:53-56`). No `panic = "abort"` profile, so a panic unwinds one task.

**Gaps**
- (a) **Watch errors carry no thread id.** `handle_watch` answers failures with a bare `error` frame (`route.rs:401-427`, `not_found`/`internal_error` without details; `watch_limit` via `mod.rs:51-57`). The phone therefore ignores them ("a watch miss names no thread", `MirrorRelay.swift:320-323`) and keeps believing it watches. After a reconnect it re-sends several watches at once (`MirrorRelay.swift:283-286`), so it cannot tell which failed. A transient DB error (`route.rs:526-538` -> `lookup_failed` at `route.rs:746-753`) silently stops live streaming for that thread until the user re-opens it. Phoenix correlates every reply by ref and retries joins.
- (b) **A panic in the link task leaves a ghost registration.** Cleanup (`write_last_seen`, `unregister`, presence broadcast) is straight-line code after `run` (`link.rs:337-362`), not a drop guard; only `LiveLink`'s count is RAII (`registry.rs:306-314`). If the link task panicked, the device would stay "online", keep its watches, and commands would fail as `device_offline` only after `send_wait` notices the closed channel. I found no panic path in the current code; this is a robustness-by-construction point.
- (c) `watch` is not rate limited and does its DB lookup before checking whether the thread is already watched (`link.rs:588-591` -> `route.rs:407` -> the `contains_key` check only at `registry.rs:622-624`). Concurrency is 1 per link (awaited inline), so the blast radius is one pool connection per misbehaving link.

## 5. Client reconnect behaviour (`assets/js/phoenix/*` vs `RelayLink.swift`)

| | Phoenix JS | b4 `RelayLink` |
| --- | --- | --- |
| Backoff curve | fixed table 10, 50, 100, 150, 200, 250, 500, 1000, 2000 ms, then 5 s (`socket.js:189-195`) | 1 s doubling to 30 s (15 s on the phone) (`RelayLink.swift:180`) |
| Jitter | **none** (`timer.js` schedules `timerCalc(tries)` exactly) | full jitter (`RelayLink.swift:88, 182`) |
| Reset | on every open (`socket.js:544-553`) | only after 60 s up (`RelayLink.swift:168-169, 331-345`), so a link that opens and dies at once keeps backing off |
| Heartbeat-timeout reconnect | yes (`socket.js:558-575`) | yes, 30 s silence watchdog (`RelayLink.swift:347-361`) |
| Which closes are terminal | none; any close reconnects "as the server, proxies and load balancers also close with 1000" (`socket.js:663-678`) | only 4000/4001/4002 and 401 (`RelayLink.swift:220-221, 296-309`); 1000/1001/4003 retry |
| Rejoin | channels rejoin with 1/2/5/10 s (`socket.js:182-188`, `channel.js:30-47`) | the phone re-sends every watch after `hello` (`MirrorRelay.swift:283-286`); the Mac is sent the whole `watching` set (`link.rs:430-443`) |
| Buffering while down | `sendBuffer` replays pushes on open, dropping ones for an outdated join (`socket.js:780-795, 842-847`); channel `pushBuffer` (`channel.js:156, 180-184`) | none: `send` throws `notConnected` (`RelayLink.swift:145-148`); the phone answers "not sent" at once (`MirrorRelay.swift:225, 262-265`) |
| Wake / visibility | reconnect immediately when the page is shown (`socket.js:235-252`) | `reconnectNow()` skips the backoff (`RelayLink.swift:129-142`) |
| Transport fallback | long-poll fallback with memorized choice (`socket.js:469-528`) | none |
| Rate-limit hint | n/a | 429 retried with plain backoff; `Retry-After` (set by the hub, `crates/b4hub/src/error.rs:401-406`) is not read (`RelayLink.swift:228-229`) |

**Assessment:** RelayLink is already more careful than the Phoenix client on backoff (jitter, stable reset) and on terminal close codes. Not buffering commands while disconnected is the right call for side-effecting commands; the stable command id makes a user-driven resend safe. The only client-side gap is ignoring `Retry-After` on 429 (low).

## 6. Other lessons

- **Observability.** Phoenix emits telemetry for connect (with duration and result, `socket.ex:521-532`), every handled message (`channel/server.ex:330-340`), joins, and each drain batch (`pool_supervisor.ex:116-125`); `lib/phoenix/logger.ex:56-71, 141-144` lists them. b4hub logs link open/close with the close code (`link.rs:310-312, 357-362`), each command's outcome and latency (`route.rs:338-343`), limit hits (`link.rs:133`, `route.rs:454`), and relocation (`link.rs:152`, `instances.rs:188-192`). It does **not** record: events dropped / `stream_gap`s issued (`registry.rs:135-144, 186-202`, silent), presence coalescing, how many links a drain closed and how long it took, or a live-link gauge (the count exists in `Relay::track`/`drained`, `registry.rs:442-448`, but is not exported). There are no metrics at all; logs are the only signal.
- **Transport fallback** (long-poll): not worth it for native clients on WSS; Phoenix's own long-poll carries an exhaustion warning (`endpoint.ex:1100-1108`) and an unbounded buffer (`long_poll_server.ex:146`). Not recommended.
- **Token rotation / max_age**: Phoenix tokens are stateless with `max_age` (`token.ex:129-130`); long-poll session tokens are signed with a 2-week max_age (`long_poll.ex:22`). b4hub's opaque DB-backed tokens with server-side revocation are stronger for revocation; the only lesson is that a long-lived connection must not outlive its credential (see 3a/3b).
- **Malformed frames**: Phoenix kills the connection; b4hub answers and keeps the link. With b4hub's frame caps this is fine; no change.

---

## Prioritized recommendations

Each item: gap, Phoenix precedent, proposed change, risk if left alone. Nothing here is something b4hub already does.

### High

**H1. A live link outlives the credential (and, across instances, the revocation) that admitted it.**
- Gap: `DELETE /v1/sessions/self` never closes the link (`routes/me.rs:301-314`); tokens never expire and the link never re-checks its token (`devices.rs:326-358`, `registry.rs:263-275`); `close`/`close_user` from revoke, account delete, and merge reach only the local instance (`registry.rs:469-496`; `routes/devices.rs:23`, `routes/me.rs:355`, `routes/enroll.rs:82`).
- Phoenix precedent: socket `id` + `"disconnect"` broadcast, which every transport of that id on every node obeys (`lib/phoenix/socket.ex:25-52, 236-246, 549-553, 571-573`; pinned by `test/phoenix/integration/websocket_channels_test.exs:838-884`).
- Proposed change (cheapest first):
  1. Carry the token's row id (or hash) in `Identity` from the upgrade (`relay/link.rs:155-162`, needs `AuthedDevice`/`b4hub_db::devices::authenticate` to return it). Fold a "token row still exists and device not revoked" check into the once-a-minute `last_seen_at` write the link already does (`link.rs:604-622`); on a miss, close with 4001. This bounds every case (logout, any-instance revoke, operator DB deletion) at about 60 s with no new messaging.
  2. Make `end_session` (`routes/me.rs:303-314`) close the calling device's local link at once, as `revoke_self` does.
  3. For immediate cross-instance effect, publish a "close links of user/device" notice over the existing `LISTEN`/`NOTIFY` path (`notify.rs`, `b4hub_db::wakes`) and have each instance apply it to its registry. Optional once (1) exists.
- Risk if left alone: a stolen or misbehaving token's link keeps sending `turn.send`/`request.respond` to the user's Mac after the user logged out, or after account deletion/merge was processed on a different instance, until the socket happens to drop. The Mac's agent can act on those commands.

### Medium

**M1. Drain keeps every user's claim until the slowest link is gone.**
- Gap: claims are released only after `relay.drained()` (`serve.rs:258-262, 282-293`); shutdown writes use the 30 s `DEAD_LINK` timeout (`link.rs:453-459, 666-686`); other instances refuse reconnects with `409 relocated` while the claim is held by a still-"alive" instance (`b4hub-db/src/instances.rs:81-89`).
- Phoenix precedent: `PoolDrainer` tells sockets to go and moves on; it never waits on a slow socket, and the whole drain is bounded (`lib/phoenix/socket/pool_supervisor.ex:77, 110-136`).
- Proposed change: in `serve::run` (`Hub/crates/b4hub/src/serve.rs:246-254`), once holds are released and the links have been *told* to close, release this instance's claims (`instances::release`) or mark the instance draining so `try_claim` ignores it (`b4hub-db/src/instances.rs:74-108`, e.g. `heartbeat_at = 'epoch'` or a `draining` column); keep the final `release` as a backstop. Use a short write timeout (e.g. `CLOSE_GRACE`) for the shutdown flush and close frame instead of `DEAD_LINK` (`link.rs:453-459`). Brief overlap (B serves a user while A finishes writing its closes) is harmless: A is closing everything and no longer accepts.
- Risk if left alone: every deploy of a multi-instance hub costs each user a few seconds of `relocated` retries and backoff, and a single unresponsive peer can stretch that to the whole shutdown wait (~29 s) for every user of the instance. Held `turn.interrupt`/`request.respond` from phones that reconnect during that window get `device_offline` instead of being held.

**M2. No cap on concurrent command tasks per link.**
- Gap: each client `command` is spawned (`link.rs:576-582`); the claim precedes the limiter (`route.rs:321-333`) and a refused command still waits up to 5 s to deliver its reply (`route.rs:352-358`, `QUEUE_WAIT` at `route.rs:54`). The read loop never blocks, so TCP backpressure never applies.
- Phoenix precedent: per-transport resource cap `max_channels_per_transport` (default 100), refused with an error reply rather than queued (`socket.ex:654, 722-735`; `endpoint.ex:784-796`; test `websocket_channels_test.exs:343`).
- Proposed change: give each link a small in-flight budget (e.g. an `Arc<Semaphore>` of 2 x `COMMAND_BURST` = 40 in `Link`, `relay/link.rs:365-382`); in `on_frame` (`link.rs:552-583`) take a permit with `try_acquire_owned` and move it into the task; with none left, answer `rate_limited` inline by id without spawning (a resend of an id already in flight still needs to attach, so check the `in_flight` map first or let the attach path bypass the budget). Document the cap in `Hub/API.md` "Limits".
- Risk if left alone: one authenticated device (buggy resend loop or stolen token) can grow tasks and the `in_flight` map without bound for as long as it sends faster than it reads, starving the instance's memory and scheduler for every other user.

**M3. Watch failures are not correlated, so the phone cannot recover from them.**
- Gap: `handle_watch` error frames carry no thread id (`route.rs:401-427`; `mod.rs:51-57`); the phone ignores all `error` frames for that reason (`Sources/WorkspaceMirror/MirrorRelay.swift:320-323`).
- Phoenix precedent: every reply carries `ref`/`join_ref`/`topic` (`socket.ex:726-758`; `v2_json_serializer.ex:63-73`), and a failed or timed-out join is retried with backoff (`assets/js/phoenix/channel.js:30-32, 61-67`).
- Proposed change: add `details: { threadId }` to every error frame answering a `watch` (`relay/route.rs:401-427`); in `MirrorRelay.receive`, on `internal_error` re-send the watch after a short delay, on `not_found`/`watch_limit` drop it from `watched` and surface it. This is an additive wire change: update `Tests/Fixtures/sync/relay.json` together with both suites, per AGENTS.md.
- Risk if left alone: a DB blip during a watch (or a `not_found` race with a just-started thread) silently stops live streaming for that thread; the phone shows a stalled reply until sync catches up or the user re-opens the thread.

### Low

**L1. Encode fan-out events once and bound the queue by bytes.**
- Gap: `fan_out` clones the `Value` per watcher and each link serializes it (`registry.rs:670-685, 135-144`; `link.rs:660-664`); the queue bound is 256 frames regardless of size (`relay.rs:40`), up to 64 MiB per client link with 256 KiB host frames.
- Phoenix precedent: fastlane encodes a broadcast once and shares one binary (`lib/phoenix/channel/server.ex:99-124`).
- Proposed change: let the outbound queue carry pre-encoded text (`axum::extract::ws::Utf8Bytes` or `Arc<str>`) for events, encoding once in `Relay::fan_out` (`relay/registry.rs`); track queued bytes per `LinkHandle` and treat a byte budget (e.g. 4 MiB) like `Full` for events, which already maps to `stream_gap`.
- Risk if left alone: memory per slow phone can reach tens of MiB under a large-event stream. Low at current scale.

**L2. Make link cleanup a drop guard.**
- Gap: unregister/presence/last-seen run only if `serve_link` returns normally (`link.rs:337-362`).
- Phoenix precedent: monitors turn any channel death into cleanup and `phx_error` (`socket.ex:560-565`), and channels die with their transport (`channel/server.ex:363-366`).
- Proposed change: move `unregister` (and a spawned presence broadcast for hosts) into a guard owned by `serve_link` (`relay/link.rs:276-363`), like `LiveLink` (`registry.rs:306-314`).
- Risk if left alone: a future panic in the link path would leave a device "online" with stale watches until it reconnects. No current panic path found.

**L3. Observability for the relay.**
- Gap: event drops, `stream_gap`s, presence coalescing, and drain progress are silent; live links are not exported (`registry.rs:135-203, 442-448`; `link.rs:453-459`).
- Phoenix precedent: `[:phoenix, :socket_connected]`, `[:phoenix, :channel_handled_in]`, `[:phoenix, :socket_drain]` (`socket.ex:521-532`; `channel/server.ex:330-340`; `pool_supervisor.ex:116-125`; `lib/phoenix/logger.ex:56-71`).
- Proposed change: count drops per link and log them once when the gap is flushed (`registry.rs:186-202`) with device and count, never content; log "drain: closing N links" and the drain duration in `serve.rs`; add the live-link count to `/readyz`'s body (`routes/health.rs`).
- Risk if left alone: backpressure problems and slow drains are invisible in production logs; M1 and L1 cannot be measured.

**L4. Stagger the drain.**
- Gap: all links close in one instant (`link.rs:453-459`).
- Phoenix precedent: `batch_size`/`batch_interval` (`pool_supervisor.ex:88-89, 112-136`).
- Proposed change: only if instance link counts grow into the thousands; otherwise client full jitter is enough. Do M1 first; staggering without M1 lengthens the 409 window.
- Risk if left alone: a reconnect burst on the surviving instances' 10-connection pools during deploys. Negligible today.

**L5. Cheaper `watch`.**
- Gap: re-watching an already-watched thread still does the DB lookup; `watch` has no rate limit (`link.rs:588-591`; `route.rs:407`; `registry.rs:622-624`).
- Phoenix precedent: weak; per-transport caps (`socket.ex:722-735`) and duplicate-join handling (`socket.ex:769-786`), not a rate limit.
- Proposed change: in `handle_watch` (`relay/route.rs:401`), return early when this link already watches the thread; optionally count `watch` against the device's command limiter.
- Risk if left alone: a looping client costs one pool connection continuously. Minor.

**L6. Client: honour `Retry-After` on a 429 upgrade.**
- Gap: `RelayLink` treats 429 as a generic retry (`Sources/WorkspaceSync/RelayLink.swift:228-229`); the hub sends `Retry-After` (`crates/b4hub/src/error.rs:401-406`); `URLSessionHubLinkSocket` already sees the response (`HubLinkConnection.swift:270-277`).
- Phoenix precedent: none directly (Phoenix leaves 429 to a custom `error_handler`, `endpoint.ex:1072-1086`).
- Proposed change: carry the header in `HubLinkError.refused` and wait at least that long.
- Risk if left alone: after a burst of `reconnectNow()` calls the client may hit the 10/min upgrade limit again sooner than needed.

**L7. Per-link socket buffers (uncertain).**
- Gap: tungstenite's 128 KiB read and write buffer defaults are not tuned (`link.rs:165-168`).
- Phoenix precedent: `fullsweep_after`, explicit GC, hibernation (`endpoint.ex:1057-1060`; `socket.ex:588-591`).
- Proposed change: measure RSS per idle link first; if the buffers are eager, set `read_buffer_size`/`write_buffer_size` on the `WebSocketUpgrade` (axum 0.8.9 supports both) to something near the 64 KiB client frame cap.
- Risk if left alone: higher idle memory per link; irrelevant until link counts are large.

### Considered and not recommended (b4hub already covers it, or it does not apply)

- `check_origin`: not applicable (bearer header, cookie is not a credential). Revisit only if a token is ever accepted in a query string or subprotocol.
- Max frame size, server idle timeout, client heartbeat and half-open detection, one connection per identity, protocol-version refusal, unknown-event handling: all present and at least as strict as Phoenix.
- Reconnect backoff with jitter, stable-reset, treating 1000/1001 as retryable: RelayLink is better than the Phoenix client here.
- Buffering commands while disconnected: deliberately not done; failing fast plus idempotent ids is safer for side-effecting commands.
- Long-poll fallback: not worth it for native clients.
- Fresh ref per resend (Phoenix `push.js:24-28`): b4 reuses the command id on purpose for idempotency; the phone already drops waiters on link loss.
