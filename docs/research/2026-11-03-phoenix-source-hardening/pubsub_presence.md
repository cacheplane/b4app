# Phoenix.PubSub / Tracker / Presence source: hardening lessons for b4hub

Sources read (read-only):

- `phoenix_pubsub` v2.4.1 (`/Users/blove/repos/phoenix_pubsub`): `lib/phoenix/pubsub.ex`,
  `pubsub/{pg2,supervisor,sender}.ex`, `tracker.ex`, `tracker/{shard,state,replica,clock,delta_generation,shutdown_handler}.ex`,
  tests `test/phoenix/tracker/{shard_replication,state,replica}_test.exs`, `test/support/node_case.ex`.
- `phoenix` (`/Users/blove/repos/phoenix`, v1.8.8-158): `lib/phoenix/presence.ex`,
  `lib/phoenix/channel/server.ex`, `assets/js/phoenix/presence.js`.
- b4hub (this worktree, `Hub/`): `crates/b4hub/src/{instances,notify,serve}.rs`,
  `crates/b4hub-db/src/{instances,wakes,relay,lib}.rs`, `crates/b4hub/src/relay/{registry,link,route,limits}.rs`,
  `crates/b4hub/src/{auth,cli}.rs`, `routes/{changes,health}.rs`, migration `0008_instances.sql`,
  tests `crates/b4hub/tests/{instances,relay}.rs`, `crates/b4hub-db/tests/instances.rs`;
  `docs/decisions.md` D-085, D-086, D-161; `Hub/API.md` "More than one instance", "Watching and live events".
  Client side checked only where a hub gap depends on it: `Sources/Coordinator/HubSync/HubLink.swift`,
  `Sources/WorkspaceMirror/MirrorTransport.swift`.

Paths below: `pubsub/` = `phoenix_pubsub/lib/phoenix/`, `phx/` = `phoenix/`, `hub/` = `Hub/crates/`.

The two systems solve different problems. Phoenix.Tracker is AP: every node accepts presence
writes, duplicates are expected, and a CRDT (an ORSWOT-like set with per-replica clocks and
"clouds" of dots) merges them after a partition. b4hub's relay is single-owner: one instance per
user, chosen through a PostgreSQL row, with no cross-instance frame forwarding (D-085). So most
Tracker machinery (clocks, delta generations, transfer requests) has no direct counterpart and
should not be copied. The transferable lessons are about liveness detection, what to do on rejoin,
per-subscriber snapshots, ordering, bounding state, and testing partitions.

---

## 1. Failure detection

### What Phoenix does

- Heartbeat cadence: every `broadcast_period` (default 1500 ms) a shard broadcasts its delta if it
  has one; otherwise it stays silent for up to `max_silent_periods` (default 10) and then sends an
  `:empty` heartbeat carrying its clock, so silence itself is bounded (`pubsub/tracker/shard.ex:517-544`,
  defaults `shard.ex:117-118`).
- Down detection is purely local and receiver-timed: each received heartbeat stamps
  `last_heartbeat_at = System.system_time(:millisecond)` on the receiver (`pubsub/tracker/replica.ex:82-86`);
  every tick `detect_down` compares `now - last_heartbeat_at` to `down_period` (default
  `broadcast_period * max_silent_periods * 2` = 30 s) and `permdown_period` (default 20 min)
  (`replica.ex:49-64`, `shard.ex:120-124`, `shard.ex:414-430`). No cross-node clock is compared.
  Note `System.system_time` is wall clock, not monotonic: a local clock jump can mark replicas down.
- Config sanity is enforced at start: `down_period >= 2 * broadcast_period` and
  `permdown_period > down_period` (`shard.ex:129-130`, `shard.ex:165-175`; pinned by
  `test/phoenix/tracker/shard_test.exs:5-18`).
- Two-stage death. `:down` hides the replica's presences but keeps them (`state.ex:496-502`,
  filtered by `down_replicas` in every read, `state.ex:144-158`, `state.ex:668-671`); `:permdown`
  deletes them and the delta history for that replica (`shard.ex:477-492`, `state.ex:507-544`,
  `delta_generation.ex:54-62`).
- Slow vs dead vs restarted is distinguished by `vsn`: every shard start gets a unique
  `vsn` (`replica.ex:28-31`, `replica.ex:88-90`). A heartbeat with the same `vsn` from a `:down`
  replica just brings it back up and replays its presences as joins (`shard.ex:381-382`,
  `state.ex:490-494`). A heartbeat with a *new* `vsn` means the old incarnation is gone: the old one
  is permdowned at once, without waiting for `permdown_period` (`shard.ex:384-392`; pinned by
  `shard_replication_test.exs:101-131` "old pids from a node are permdowned when the node comes
  back up" and `:133-214` "tempdowns with nodeups of new vsn").
- Graceful exit: `graceful_permdown` broadcasts so peers drop the replica immediately instead of
  waiting `down_period` (`shard.ex:297-300`, `shard.ex:229-234`, `tracker.ex:71-74`,
  `shutdown_handler.ex:16-19`); opt-in via `permdown_on_shutdown` because clients reconnecting
  elsewhere may prefer the grace (`tracker.ex:73-94`).
- Flapping: tolerated, not damped. A tempdown emits leaves, a recovery emits joins again
  (`shard_replication_test.exs:151-170`). Initial heartbeats are jittered (`shard.ex:177-179`).
- Split brain: by design there is no owner, so no fencing. Duplicates converge through the CRDT
  merge (`state.ex:329-374`), and anti-entropy repairs lost deltas: heartbeats carry clocks, the
  receiver samples them for `clock_sample_periods` and sends `transfer_req` to any replica whose clock
  it does not dominate (`shard.ex:396-412`, `shard.ex:439-451`, `clock.ex:19-30`).
- Liveness work is kept off the heartbeat path: docs warn that `handle_diff` runs in the shard
  process and must not block (`tracker.ex:65-71`); `Phoenix.Presence` therefore runs `fetch/2` in a
  supervised task (`phx/lib/phoenix/presence.ex:609-633`).

### What b4hub does

- One row per process in `hub_instances`, `heartbeat_at = now()` every `B4HUB_HEARTBEAT_MS`
  (default 5 s) (`hub/b4hub-db/src/instances.rs:30-54`, `hub/b4hub/src/instances.rs:157-181`).
  Dead = no heartbeat within 4 beats = 20 s (`hub/b4hub/src/instances.rs:24-28`, `:88-92`).
- Clock skew: all comparisons use the database's `now()` (`b4hub-db/src/instances.rs:7-9`,
  `:82-88`, `:165`), so instance clocks are never compared. The instance's own staleness uses the
  monotonic tokio `Instant` (`b4hub/src/instances.rs:42`, `:105-112`). This is stronger than
  Phoenix's wall-clock `system_time`. No gap.
- Process incarnation: a fresh UUIDv7 per process (`b4hub/src/instances.rs:70-78`), the same role
  as Tracker's `vsn`. A restarted instance never inherits claims by identity. No gap.
- Claim: one upsert that keeps a live owner and takes a dead one's row, then a separate `SELECT`
  of the winner (`b4hub-db/src/instances.rs:60-107`); called only at link upgrade
  (`b4hub/src/relay/link.rs:144-154`). Concurrency is pinned by
  `hub/b4hub-db/tests/instances.rs:104` ("concurrent_claims_agree_on_one_winner").
- Split guard: after each *successful* heartbeat write, `lost_claims` finds users whose row now
  names another instance and closes their links here with 1001 (`b4hub/src/instances.rs:183-196`,
  `b4hub-db/src/instances.rs:119-133`; test `hub/b4hub/tests/instances.rs:150-218`).
- Graceful exit: holds answered, links closed, then `release_claims` deletes claims and the row
  (`b4hub/src/serve.rs:245-293`, `b4hub-db/src/instances.rs:138-151`) — the counterpart of
  `graceful_permdown`, but it runs at the *end* of the drain.
- Pruning of dead rows: `prune` deletes instances past the window and orphaned claims
  (`b4hub-db/src/instances.rs:162-179`), run from `prune_loop` once per `PRUNE_INTERVAL` = 24 h
  (`b4hub/src/serve.rs:45-46`, `:341-355`). Correctness does not depend on it (the claim checks
  liveness itself), so the cadence only bounds table size.
- Readiness: `/readyz` 503 when stale (`b4hub/src/routes/health.rs:65-77`; D-086). Only ECS acts on
  it; D-085 explicitly accepts that outside ECS a stale-but-running instance keeps its links.

### Gaps (verified)

1. **The liveness signal shares the service pool and is timed after the write returns.**
   `heartbeat` runs on `db.pool` (`b4hub-db/src/instances.rs:47-51`), the same 10-connection pool
   with a 5 s `acquire_timeout` that serves requests (`b4hub-db/src/lib.rs:108-110`). A pool
   saturated by request work makes the heartbeat wait (or fail after 5 s) and the instance looks
   dead to others while it is healthy, which triggers takeover, the split guard, and a reconnect
   wave — more load at the moment of load. `record_ok` stamps the local lease after the `UPDATE`
   returns (`b4hub/src/instances.rs:174-175`, `:95-101`) while the database stamps
   `heartbeat_at` at statement time, so the instance's own view of "fresh" is later than the
   others' by the round trip (tiny normally; up to the 5 s acquire wait under pool pressure). The
   loop sleeps then writes (`:165-181`), so the period drifts by the write latency. Phoenix
   precedent for isolating liveness from work: `tracker.ex:65-71`, `presence.ex:609-633`. b4hub
   already isolates the `LISTEN` connection this way (`b4hub-db/src/wakes.rs:39-53`).
   *Uncertainty:* at the owner's scale (two tasks, few users) pool saturation for ~20 s is unlikely;
   the fix is cheap and removes a positive-feedback loop.
2. **No self-fencing while the heartbeat fails.** On `Err` the loop `continue`s and skips
   `lost_claims` (`b4hub/src/instances.rs:177-180`), and nothing but `/readyz` reads `stale()`.
   An instance that cannot reach the database but still holds client sockets keeps the Mac's link
   while another instance takes the phone; the user is split until the database comes back (or ECS
   replaces the task after its health-check thresholds). Safety is not at risk — the relay writes
   nothing to the database but `last_seen_at`, which is `GREATEST`-monotonic
   (`b4hub-db/src/relay.rs:37-45`) — so the cost is liveness (phone sees its Mac offline; commands
   held then `device_offline`). D-085 lists this as accepted outside ECS. Phoenix has no fencing
   (AP), so there is no direct precedent; the relevant rule is Tracker's "absence of evidence means
   down" (`replica.ex:49-64`), which b4hub applies to others but not to itself.
   *Trade-off:* self-fencing on local staleness would also drop every link during a database-wide
   outage, when no other instance could take over anyway and live event fan-out (in-memory) still
   works. So this is a judgement call, not a clear bug.
3. **Liveness window is not tied to the owner row and the cadence is not validated.** Every
   instance judges others with its *own* `alive_within` (`b4hub-db/src/instances.rs:86-88`), the
   "same cadence everywhere" rule is documentation only (`b4hub/src/instances.rs:8-10`,
   `cli.rs:353-372` accepts any value >= 1 ms). A mismatch during a config change (one task at
   5 s, another at 1 s) lets the fast one declare the slow one dead after 4 s. And a window shorter
   than `acquire_timeout` (any `B4HUB_HEARTBEAT_MS` < 1250) makes one slow acquire look like death.
   Phoenix precedent: `validate_down_period`/`validate_permdown_period` (`shard.ex:165-175`);
   Phoenix itself does not enforce cross-node equality either (`pubsub.ex` docs: "pool_size must be
   the same throughout the cluster"), and uses `broadcast_pool_size` for safe migration
   (`pubsub/pubsub/pg2.ex:61-76`, `pubsub.ex:45-118`).
4. **Claim race with a just-registered instance (low).** `try_claim`'s upsert evaluates "owner is
   alive" against the statement snapshot of `hub_instances`, then a *separate* `SELECT` reads the
   winner (`b4hub-db/src/instances.rs:81-106`). If instance B registers and claims user U while C,
   whose snapshot predates B's row, takes over the same dead owner's row, C can overwrite B's
   fresh claim; if B's `SELECT` already ran it returns `Ours` too, and both serve U until B's next
   heartbeat's `lost_claims` closes B's link (≤ 1 beat). Needs a new instance plus a concurrent
   takeover of the same user. Bounded by the split guard. *Uncertain* how reachable in practice.

Not gaps: clock skew (database time), incarnation ids (UUIDv7 per process), graceful release
(exists), prune of dead instances (exists; only cadence differs), fencing tokens on the claim
(not needed: no owner-scoped durable writes; see gap 2).

---

## 2. Presence semantics

### What Phoenix does

- A presence is `(topic, pid, key)` with a unique `phx_ref`; the same key may be present many times
  (several pids/devices), only the same `(pid, topic, key)` twice is refused
  (`shard.ex:262-270`, `tracker.ex:144-153`; test `shard_replication_test.exs:349-362`).
- Update is leave+join with `phx_ref_prev`, so a client can tell an update from a churn
  (`shard.ex:324-338`, `state.ex:88-105`, `presence.ex:280-285`).
- All mutations of a shard go through one GenServer, so diffs for a topic are totally ordered;
  Presence's async `fetch` keeps that order with a queue and a `:continue` handshake, emitting
  results strictly in submission order (`presence.ex:502-504`, `:507-534`, `:574-583`, `:609-633`).
- Replica down: presences hidden, not deleted; replica back with same `vsn`: replayed as joins;
  new `vsn`: old ones permdowned (see §1; test `state_test.exs:112-144` "basic netsplit").
- Tombstones: there are none as such. Removes are encoded as dots in the causal context/clouds
  (`state.ex:570-579`, `observe_removes` `state.ex:390-416`), compacted (`state.ex:591-619`), and
  dropped wholesale on permdown. Down replicas are excluded from advertised clocks to stop a newly
  joined node from requesting full state forever (`state.ex:66-77`; test
  `shard_replication_test.exs:383-420` "rolling node update").
- Client: the JS `Presence` buffers diffs until it has a full `presence_state` for the *current*
  `joinRef`, then applies the buffered diffs (`phx/assets/js/phoenix/presence.js:21-43`, `:54-56`).
  Snapshot-then-diffs, keyed by join generation.
- Leave flapping: `permdown_on_shutdown: false` (default) deliberately keeps a shutting-down
  node's presences for `down_period` so clients that reconnect elsewhere do not cause a burst of
  leave/join (`tracker.ex:84-90`).

### What b4hub does

- One link per device, newest wins: `register` replaces and tells the older link to close with
  `link_replaced`/4000 (do not reconnect) (`b4hub/src/relay/registry.rs:387-440`, `:35-42`);
  `unregister` is generation-checked so an old task's cleanup cannot remove the new link
  (`registry.rs:450-467`). The 4000 "do not reconnect" rule prevents two holders of one device
  token from ping-ponging. Equivalent to Phoenix's per-`(pid,topic,key)` uniqueness; no gap.
- The phone's view of its Macs is a full snapshot, not a diff: `presence` lists every non-revoked
  Mac with `online` from the *local* registry and `lastSeenAt` from the database
  (`registry.rs:565-586`). Sent once after `hello` (`link.rs:409-419`) and on a Mac's first link
  or last unlink (`link.rs:421-426`, `:346-350`) and on revoke (`routes/devices.rs:29`). A full
  queue keeps only the latest (`registry.rs:146-153`, `:186-192`; test `tests/relay.rs:1924`).
- Snapshots instead of diffs is more robust than Phoenix's diff stream: a lost or reordered frame
  is fixed by the next one. No equivalent of `phx_ref` is needed for that reason.

### Gaps (verified)

5. **Two concurrent `broadcast_presence` calls can deliver out of order, and the stale one
   sticks.** Each call awaits `host_devices` from the database, reads `online` after it answers, then
   delivers (`registry.rs:568-601`). The comment at `registry.rs:566-567` addresses a stale flag
   *within* one computation, but nothing orders *delivery* between two calls on a multi-threaded
   runtime: Mac unlink (computes `online=false`) and the Mac's relink (computes `true`, delivers)
   can interleave so `false` lands last. The phone then shows the Mac offline until the next
   presence change or its own reconnect. Window is microseconds (between computing `online` and
   taking the `missed` lock), so *rare*. Phoenix precedent: single-writer ordering per shard and
   ordered async fetch (`presence.ex:574-583`, `:609-633`).
6. **Presence is only as wide as the instance.** `online` reads the local registry
   (`registry.rs:581`), so during a split (gap 2, or the ≤1-beat window after recovery) a phone on
   B sees a Mac connected to A as offline. Inherent to D-085's design; covered by closing the gap
   window rather than by cross-instance presence. Listed for completeness, no separate fix.
7. **Offline is published immediately on every unlink (low, product call).** A Mac's network
   blip (old link dies by `DEAD_LINK`, new link arrives seconds later, so it is not a replacement)
   produces offline→online on the phone. Phoenix chose a grace for exactly this reason
   (`tracker.ex:84-90`). Commands are held 60 s anyway (`route.rs` header, `HOLD_WINDOW`), so this
   is UI churn only.

---

## 3. Broadcast / fan-out delivery guarantees

### What Phoenix does

- PubSub is fire-and-forget: the PG2 adapter does `send/2` to each remote group member
  (`pubsub/pubsub/pg2.ex:17-31`) and `direct_broadcast` likewise (`pg2.ex:33-37`); local dispatch is
  `Registry.dispatch` (`pubsub.ex:549-551`). At most once, no acks, no gap signal.
- Everything that must converge is rebuilt by state transfer, never by trusting the stream:
  periodic clock-carrying heartbeats, `transfer_req`/`transfer_ack` (`shard.ex:209-227`), and a
  bounded delta history with a full-state fallback when no generation satisfies the remote clock
  (`delta_generation.ex:13-24`, `:27-52`; sizes `[100, 1000, 10_000]`, `shard.ex:127`). Pinned by
  `shard_replication_test.exs:33-51` (dropped gossip → transfer on resume).
- Fan-out cost: `Phoenix.Channel.Server.send/4` encodes a broadcast once per serializer and sends
  the same binary to every transport ("fastlane") (`phx/lib/phoenix/channel/server.ex:98-124`).
- Clients get a fresh snapshot on every (re)join (`presence.js:21-31`).

### What b4hub does

- Wake-ups between instances are hints over `LISTEN`/`NOTIFY`; the change log is the data
  (`b4hub-db/src/wakes.rs:1-8`, D-161). A long-poll takes its `Notified` before querying
  (`routes/changes.rs:148-160`), the push wakes local polls then announces after commit
  (`routes/changes.rs:57-66`), the listener wakes every poll whenever it (re)connects or reports
  `Lost` (`b4hub/src/notify.rs:64-100`). `sqlx`'s `PgListener` reconnects eagerly by default and
  re-listens before returning `None` (sqlx-postgres 0.8.6 `listener.rs:256-303`), so the comment at
  `notify.rs:95` is accurate. The long-poll's own `wait` (≤ 25 s) is the anti-entropy bound.
- Live events: dropped on a full queue with a `stream_gap` that is ordered after the hole
  (`registry.rs:131-144`, `:186-202`), watches die with the link (`registry.rs:420-421`), the host
  is told the whole watched set (`link.rs:430-477`), and the Mac sends a catch-up snapshot when a
  thread *enters* its watched set (`HubLink.swift:79-83`; API.md "Catch-up"). The phone treats its
  own reconnect as a gap and mutes deltas until a catch-up or completion (`MirrorTransport.swift:25-37`).
  This is a better contract than PubSub's (explicit gap signal).

### Gaps (verified)

8. **A silent (half-open) listener connection is never detected.** `listen_loop` only reacts to
   an error or `None` (`notify.rs:86-108`); `sqlx` sets no TCP keepalive (no keepalive option in
   sqlx-core/sqlx-postgres 0.8.6). If the listener's TCP path dies without a FIN/RST, `try_recv`
   waits forever, no `Lost` is reported, and every cross-instance long-poll silently degrades back
   to its full `wait` — the exact bug D-161 fixed, with no log line. The instance also skips its own
   announcements (`notify.rs:91`), which removes the one signal that could prove the channel works.
   Phoenix precedent: bounded silence — an `:empty` heartbeat at least every `max_silent_periods`
   (`shard.ex:532-539`) and death inferred from silence (`replica.ex:49-64`).
   *Uncertainty:* inside one VPC to RDS, half-open connections are uncommon (failover normally
   resets connections; the test at `tests/instances.rs:444-466` covers the reset case).
9. **Catch-up is triggered by host-set transitions, not per subscriber.** The host link compares
   the new watched set with the last one it told and sends nothing when they are equal
   (`link.rs:470-477`; documented in API.md "A change that leaves the host's set the same ... sends
   nothing"). Two cases lose the catch-up:
   (a) a second client (another phone, iPad, or the CLI) watching a thread another client already
   watches; (b) one phone reconnecting: `register` drops its old watches (epoch bump,
   `registry.rs:420-426`), the phone re-watches (another bump, `registry.rs:636`), and if both land
   before the Mac's link task polls `watch_changes` (it may be busy in a `write` that can take up to
   `DEAD_LINK`, `link.rs:466`, `:666-671`) the `watch` channel coalesces them and the set looks
   unchanged. In (b) the phone has muted the item after its reconnect, so it degrades safely to "no
   live text until sync" (`MirrorTransport.swift:25-37`); in (a) the new watcher starts from
   mid-stream deltas. Phoenix precedent: per-join snapshot keyed by join generation
   (`presence.js:21-56`) and full-state fallback per requester (`delta_generation.ex:13-24`).
   *Uncertainty:* how the phone renders (a) (whether a synced partial row gives it a prefix) was not
   traced end to end.
10. **Fan-out clones and re-serialises per watcher (low).** `fan_out` clones the `RelayMessage`
    (a `serde_json::Value` up to 256 KiB) per watching client (`registry.rs:671-685`) and each link
    task serialises it again (`link.rs:660-664`). Phoenix encodes once (`channel/server.ex:98-124`).
    With 1–2 watchers this is noise.

---

## 4. Sharding and lock contention

### What Phoenix does

- Subscriptions live in a partitioned `Registry`, default `ceil(schedulers/4)` partitions
  (`pubsub/pubsub/supervisor.ex:24-38`); remote fan-out uses `pool_size` PG2 groups, the sender
  picks one by `phash2(self())` (`pg2.ex:43-46`, `:78-91`).
- Tracker shards by `phash2(topic, pool_size)` (`shard.ex:45-49`), `pool_size` itself read from an
  ETS table with `read_concurrency: true` (`tracker.ex:121-125`, `:161-164`); state in a
  `:protected` `:ordered_set` ETS that readers can scan without a call (`state.ex:54-64`,
  `shard.ex:81-84`). Large scans are batched (`state.ex:678-688`, 1000 per batch).
- Crash isolation instead of poisoning: a shard crash restarts it (`tracker.ex:127-158`,
  `max_restarts: pool_size * 2`), and its state is rebuilt from peers.

### What b4hub does

- One `std::sync::Mutex<HashMap>` each for links, watchers, in-flight, pending threads, held
  counts (`registry.rs:331-347`, `route.rs:96-111`), plus per-link `Missed` mutexes
  (`registry.rs:118-119`). Critical sections are short, contain no `.await`, and take locks in a
  consistent order (links → watchers: `registry.rs:411-423`, `:453-462`, `:613-635`, `:643-651`;
  `fan_out` drops the watchers guard before touching links, `registry.rs:672-683`). No deadlock found.
- Poisoning: every lock recovers with `into_inner` (`registry.rs:166-170`, `:703-708`, `:787-792`,
  `route.rs:129-133`, `notify.rs:54-58`, `instances.rs:96-100`), so a panic never cascades. The
  residual risk is a panic mid-mutation leaving `Watchers.by_client`/`by_host` inconsistent
  (`registry.rs:225-247`); those sections contain only map operations and `to_string`, so I found
  no realistic panic source. No action.
- O(n) scans under the global links lock: `presence_subscribers` (`registry.rs:557-563`),
  `close_user` (`:483-496`), `users` every heartbeat (`:499-506`). Fine for "the handful a hub
  carries" (the code says so); becomes the first hotspot if one instance carries many users.
- Unbounded maps:
  - `Notifier`: one `Arc<Notify>` per org that ever long-polled on this instance, never removed
    (`notify.rs:27-36`). Roughly 100 bytes per org; bounded by orgs, not by time.
  - `LastTouched`: one `Instant` per device ever authenticated, never removed (`auth.rs:70-90`).
  - Rate limiters are bounded (`limits.rs:80-81`, `:140-141`; `auth_limits.rs:33`, `:77-89`);
    pending threads expire (`route.rs:149`); holds are capped (`route.rs:251-275`); in-flight
    entries are removed on drop (`route.rs:242`). No gap there.

### Gaps

11. **`Notifier` and `LastTouched` grow for the life of the process (low).** Phoenix precedent:
    Presence removes a topic when its last presence leaves (`presence.ex:648-653`, `:712-714`);
    Registry entries vanish with the process.
12. **Global-lock scans (low, scale-dependent).** Not worth sharding now; an index by user would
    make presence and `close_user` O(devices of user) and keep the heartbeat's `users()` cheap.
    Phoenix's partitioning exists because a single process/table was its bottleneck at large
    fan-out; b4hub is far from that.

---

## 5. Other hardening lessons

- **Drain ordering vs. reconnect.** Phoenix's graceful permdown tells peers *first*
  (`shard.ex:297-300`). b4hub releases claims only after every link has closed and finished its
  close handshake (`serve.rs:258-293`; `CLOSE_GRACE` 2 s per link, `link.rs:56`, `:688-699`), and
  stops heartbeating at the trigger (`instances.rs:166-169`) while its row stays "alive" for up to
  20 s. A device closed with 1001 reconnects at once, reaches the new task, and is refused
  `409 relocated` until the release (D-085 accepts this: three immediate retries, then backoff past
  the window). (Gap 13 below.)
- **Bounded history with a full-state fallback** (`delta_generation.ex:27-52`, `shard.ex:127`):
  b4hub already has the equivalent (retention horizon → `410 resync_required` → snapshot). No gap.
- **Thundering herd on recovery.** Phoenix jitters first heartbeats (`shard.ex:177-179`) and
  excludes down replicas from clocks to avoid repeated full transfers (`state.ex:71-76`). b4hub's
  `wake_all` on listener reconnect (`notify.rs:76`, `:96-98`) re-queries every waiting long-poll at
  once, which happens right after a database failover. At current scale (a few polls) it is
  harmless; noted, not recommended.
- **Test strategies Phoenix uses that b4hub partly has.**
  - Simulated netsplit by dropping gossip (`test/support/node_case.ex:72-78`, used in
    `shard_replication_test.exs:37-44`, `:69-83`) and a frozen node via `:sys.suspend`
    (`shard_replication_test.exs:154-164`). b4hub's `pause_heartbeat`/`settle` seams
    (`instances.rs:114-124`) and the gate seam (`registry.rs:316-324`, `:710-734`) are the same idea.
  - Rejoin with a new incarnation (`shard_replication_test.exs:101-131`) and rolling update with a
    replica in grace (`:383-420`). b4hub has takeover-and-recover (`tests/instances.rs:150-218`)
    and drain (`:221`).
  - Missing in b4hub: a heartbeat that *errors* (vs. pauses) while links stay up (gap 2), flapping
    around the window edge, a claim racing a just-registered instance (gap 4), concurrent presence
    broadcasts (gap 5), coalesced watch changes (gap 9), a listener that stops delivering without
    an error (gap 8).

---

## Prioritized recommendations

Each item: gap → Phoenix precedent → change (file) → risk if left. Effort is a guess.

### High

**H1. Give the instance heartbeat its own connection and a drift-free, start-stamped lease.**
- Gap: gap 1 — heartbeat on the shared 10-connection pool with 5 s acquire timeout
  (`hub/b4hub-db/src/instances.rs:47-51`, `hub/b4hub-db/src/lib.rs:108-110`); local lease stamped
  after the write (`hub/b4hub/src/instances.rs:174-175`); sleep-then-write cadence (`:165-181`).
- Precedent: keep liveness off the work path (`pubsub/tracker.ex:65-71`,
  `phx/lib/phoenix/presence.ex:609-633`); b4hub's own one-connection pool for `LISTEN`
  (`hub/b4hub-db/src/wakes.rs:44-53`).
- Change: in `hub/b4hub/src/instances.rs`, run `heartbeat` (and `lost_claims`) on a dedicated
  one-connection pool built like `Listener::connect`, with a short `acquire_timeout`
  (≤ one beat) and a per-statement timeout; drive the loop with `tokio::time::interval` +
  `MissedTickBehavior::Delay`; take `Instant::now()` *before* sending the `UPDATE` and pass it to
  `record_ok`, so the local lease never outlives the database's view. Log write latency above half a
  beat. Add a test that saturates the service pool (hold 10 connections) and asserts the instance
  stays alive to the other.
- Risk if left: request load that starves the pool makes a healthy instance look dead, which hands
  its users to another instance and then closes their links on recovery — reconnect churn caused
  by, and adding to, load. Low probability at today's scale; cheap to remove.

### Medium

**M1. Detect a silent `LISTEN` connection with a self-echo.**
- Gap: gap 8 (`hub/b4hub/src/notify.rs:86-108`, own announcements skipped at `:91`; no TCP
  keepalive in sqlx 0.8.6).
- Precedent: bounded silence and silence-as-failure (`pubsub/tracker/shard.ex:532-539`,
  `pubsub/tracker/replica.ex:49-64`).
- Change: every heartbeat (or every N s), `pg_notify` a distinct echo payload naming this instance
  (`hub/b4hub-db/src/wakes.rs`, e.g. `Wake::Echo`); in `listen_loop`, if no own echo has been heard
  for ~3 intervals, drop the listener (`listener = None`), reconnect, and `wake_all`. Optionally
  set socket keepalive on the listener connection if a future sqlx exposes it. Test with a seam
  that stops the listener reading without closing it.
- Risk if left: cross-instance long-polls silently fall back to 25 s latency after a network
  event, with no log — the regression D-161 fixed, undetectable in production.

**M2. Make catch-up per subscriber, not per host-set transition.**
- Gap: gap 9 (`hub/b4hub/src/relay/link.rs:470-477`, coalescing `watch` channel
  `hub/b4hub/src/relay/registry.rs:636`, `:687-701`; API.md "Watching and live events").
- Precedent: per-join snapshot keyed by join generation (`phx/assets/js/phoenix/presence.js:21-56`);
  full state to the requester when a delta cannot satisfy it
  (`pubsub/tracker/delta_generation.ex:13-24`).
- Change (protocol, both sides): keep a per-host "refresh" set in `Watchers`
  (`hub/b4hub/src/relay/registry.rs`) — every thread that gained a *new* client watch since the
  host was last told — and send it with the set, e.g. `watching { threadIds, refresh: [...] }`;
  the host link clears it when it writes the frame. `HubLink.swift` treats a thread in `refresh` as
  newly watched and sends its catch-up. Old Macs ignore the extra field. A cheaper hub-only
  alternative is to send `stream_gap` to a client whose watch joined an already-watched thread,
  which makes the phone wait for sync instead of showing mid-stream text. Add a test that drops and
  re-adds a watch before the host task polls (use the registration gate).
- Risk if left: a second watcher, or a phone whose reconnect coalesces, gets no catch-up — live
  text missing until the message completes and syncs (phone after its own reconnect), or starting
  mid-stream (second watcher). Correctness of synced data is unaffected.

**M3. Decide and test the stale-instance behaviour (self-fence or not).**
- Gap: gap 2 (`hub/b4hub/src/instances.rs:177-180` skips the split guard on error; only
  `/readyz` reads `stale()`, `hub/b4hub/src/routes/health.rs:65-77`). Accepted in D-085 outside
  ECS.
- Precedent: none direct (Tracker is AP); the closest rule is local "silence ⇒ down"
  (`pubsub/tracker/replica.ex:49-64`) and the config relation `down_period >= 2 * broadcast_period`
  (`pubsub/tracker/shard.ex:165-175`).
- Change: either (a) self-fence: when the local lease (start-stamped per H1) passes 3 of the 4
  beats, stop accepting upgrades and close links with 1001 so no takeover can find them still
  open — at the cost of dropping links during a database-wide outage when nobody else could take
  over; or (b) keep today's behaviour and record it, adding a test where one instance's heartbeat
  *fails* (an error seam, not `pause_heartbeat`) while the other's succeeds, asserting the split
  closes once the first recovers. I lean to (b) plus H1 for the owner's scale, since a database
  that one task can reach and the other cannot is rare inside one VPC. *Uncertain.*
- Risk if left: on Helm/Compose, a user can stay split (phone sees its Mac offline, commands
  `device_offline`) for as long as one instance's database path is broken.

**M4. Release claims as the drain empties a user, not after the whole drain.**
- Gap: §5 drain ordering (`hub/b4hub/src/serve.rs:258-293`, release after `relay.drained()`;
  heartbeat stops at trigger but the row reads alive for up to 20 s).
- Precedent: graceful permdown announced first (`pubsub/tracker/shard.ex:297-300`,
  `pubsub/tracker.ex:71-74`).
- Change: in `hub/b4hub/src/relay/link.rs` cleanup (after `unregister` returns `was_current`) while
  `state.shutdown.is_triggered()`, if `relay.users()` no longer contains that user, run
  `DELETE FROM user_links WHERE user_id = $1 AND instance_id = $2` (new
  `b4hub_db::instances::release_user`, compare-and-delete on the instance so it never removes
  another's claim); keep the final `release_claims` as the backstop. Alternatively mark the row
  `draining_at` at trigger and let `try_claim` treat a draining owner as dead.
- Risk if left: every deploy makes reconnecting devices spend their three immediate retries on
  409s and back off, lengthening the visible blip; D-085 already tuned `deregistration_delay` to
  limit it.

### Low

**L1. Order presence deliveries per user.** Gap 5 (`hub/b4hub/src/relay/registry.rs:568-601`).
Precedent: serialized shard writes and ordered async fetch (`phx/lib/phoenix/presence.ex:574-583`,
`:609-633`). Change: in `deliver_presence` (`registry.rs:149-153`), recompute each host's `online`
from the registry while holding the link's `missed` lock (cheap, in-memory), or stamp each
computation with a per-relay counter read after the database answers and drop an older one in
`Missed`. Risk: rare sticky "Mac offline" on the phone after a fast unlink/relink.

**L2. Store the liveness window on the instance row and validate it.** Gap 3. Precedent:
`pubsub/tracker/shard.ex:165-175`; `broadcast_pool_size` migration (`pubsub/pubsub/pg2.ex:61-76`).
Change: add `alive_within_ms` to `hub_instances` (new migration), write it in `register`, and judge
each owner by its own value in `try_claim`/`prune` (`hub/b4hub-db/src/instances.rs:82-88`, `:164-166`);
in `hub/b4hub/src/cli.rs:357-372` refuse a heartbeat whose window (×4) is not comfortably above the
pool's `acquire_timeout`. Risk: a cadence change rolled out task by task, or a too-small value, causes
false takeovers.

**L3. Make the claim one statement.** Gap 4. Change: in `hub/b4hub-db/src/instances.rs:75-107`,
do the upsert and the read of the winner in one CTE (or `SELECT ... FOR UPDATE` in a transaction)
so the answer reflects the row the upsert left. Risk: a brief double-serve of one user after a new
instance starts, already bounded by the split guard to one beat.

**L4. Prune idle `Notifier` entries and `LastTouched`.** Gap 11. Precedent:
`phx/lib/phoenix/presence.ex:648-653`. Change: in `hub/b4hub/src/notify.rs`, inside `wake_all`
(or a periodic sweep) `retain(|_, n| Arc::strong_count(n) > 1)` — an entry with no outstanding
`OwnedNotified` has no waiter, and `wake` already treats a missing entry as "nobody waiting"; in
`hub/b4hub/src/auth.rs:79-90`, drop entries older than the interval once the map passes a size.
Risk: slow memory growth proportional to orgs/devices seen; negligible for a personal hub.

**L5. Debounce "Mac offline" briefly (product call).** Gap 7. Precedent: `pubsub/tracker.ex:84-90`.
Change: in `hub/b4hub/src/relay/link.rs:346-350`, delay the offline broadcast a few seconds and
skip it if the device has linked again. Risk: offline/online flicker on the phone during network
blips and deploys.

**L6. Index links by user; encode fan-out once.** Gaps 10, 12. Precedent:
`pubsub/pubsub/supervisor.ex:24-38` partitions, `phx/lib/phoenix/channel/server.ex:98-124`
fastlane. Change: in `hub/b4hub/src/relay/registry.rs`, keep `HashMap<user, Vec<device>>` beside
`links`, and let `fan_out` share one `Arc<str>` of the encoded event. Only when profiling shows the
global lock or serialisation matters.

### Explicitly not recommended

- Copying the CRDT/clock/delta machinery: b4hub's single-owner model and snapshot `presence`
  frames do not need it.
- Fencing tokens on `user_links`: the relay has no owner-scoped durable writes (`last_seen_at` is
  `GREATEST`), so a stale owner cannot corrupt state; the split guard plus H1/M3 address liveness.
- Sharding the registry now; cross-instance presence; forwarding frames (against D-085).
- Adopting Elixir/Phoenix.

## Uncertainty summary

- H1's failure mode needs ~20 s of pool starvation; plausible only under heavy load.
- M1 depends on half-open TCP to RDS, which is uncommon inside a VPC.
- M2 case (a) rendering on the phone was not traced end to end; case (b) degrades safely.
- M3 is a trade-off, not a defect; D-085 records the current choice.
- L1's race window is microseconds.
