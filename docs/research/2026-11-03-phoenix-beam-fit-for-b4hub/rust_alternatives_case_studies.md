# Alternatives to Phoenix/BEAM for a multi-node b4hub relay, and migration case studies

Research date: 2026-11-02. Older sources are dated inline.

Repository context the report writer needs (read from this repo, not the web): the hub already runs on more than one instance. Decision D-085 (M8e Part B, 2026-11-02) puts every link of one user on one instance and never forwards frames between instances. Each instance registers in `hub_instances` with a 5 s heartbeat, `user_links` names the instance that owns a user, a link upgrade that reaches a non-owner gets `409 relocated`, and the ALB's application-cookie stickiness on `b4hub-instance` makes reconnects sticky. The implementation is about 420 lines (`Hub/crates/b4hub/src/instances.rs` 240, `Hub/crates/b4hub-db/src/instances.rs` 179) next to a 2,986-line relay. Prod switches to it with `task_count = 2` (`Infra/README.md` line 637, `Infra/modules/hub/alb.tf`). Sources: `docs/decisions.md` (D-085), `Hub/API.md` ("More than one instance"). The premise that the relay is "single-process" therefore holds only for prod as currently deployed with one task. The code already uses the "sticky routing by user id" pattern below.

## 1. Rust patterns for multi-node WebSocket fan-out and routing, and how much code and ops each adds

### Takeaway
A two-device-per-user relay has three workable Rust options. In rising order of cost they are: user-affinity routing with ownership kept in Postgres (already built as D-085), a broker bus (Redis pub/sub or core NATS) that forwards frames between nodes, and Erlang-style distributed actors (ractor_cluster, kameo remote). The last one is the least mature, and its own README says it is not production ready. Postgres LISTEN/NOTIFY can carry small "ping" signals. It cannot carry 256 KiB relay frames (8,000-byte limit), and NOTIFY takes a global lock at commit.

### Cited Findings
**Postgres LISTEN/NOTIFY**
- The payload "must be shorter than 8000 bytes" by default, and the docs advise storing larger data in a table and sending its key. The queue is 8 GB in a standard install; "if this queue becomes full, transactions calling NOTIFY will fail at commit." A listener that sits inside a long transaction blocks queue cleanup. — [PostgreSQL 18 docs, NOTIFY](https://www.postgresql.org/docs/current/sql-notify.html)
- Notifications are delivered only when the transaction commits and only between transactions. Ordering within one transaction is guaranteed, and different transactions are delivered in commit order. Identical channel and payload pairs within one transaction are collapsed into one. — [PostgreSQL docs](https://www.postgresql.org/docs/current/sql-notify.html)
- Recall.ai (published July 1, 2025; outages March 19 to 22, 2025): a NOTIFY inside a transaction takes an AccessExclusiveLock on "database 0" during COMMIT, which serializes commits across the whole instance. With tens of thousands of concurrent writers they saw roughly 1 s lock waits, and CPU and I/O fell while throughput collapsed. They removed LISTEN/NOTIFY in under a day. — [Recall.ai](https://recall.ai/blog/postgres-listen-notify-does-not-scale)
- Recall.ai's post (updated May 8, 2026) says commit `282b1cde…` "eliminated the bottleneck" in Postgres core. — [Recall.ai](https://recall.ai/blog/postgres-listen-notify-does-not-scale). **This is contradicted** by DBOS (July 24, 2026), which says the patch shipping in Postgres 19 "does not remove the global lock" and only speeds up the case of many channels. — [DBOS](https://dbos.dev/blog/postgres-listen-notify-scalability). The pgsql-hackers thread shows Joel Jacobson's patch narrowing how long the lock is held, with Tom Lane discussing the remaining constraints. — [pgsql-hackers](https://www.postgresql.org/message-id/c8e84bb2-d2e5-4a77-b547-3a93c5778e7e%40app.fastmail.com)
- DBOS measured about 2.9K writes/s with one trigger-driven NOTIFY per row on a single Postgres server, and about 60K writes/s after buffering notifications in memory and flushing them in one batch transaction. Readers also poll as a fallback, because notifications are only pings and not the source of truth. — [DBOS](https://dbos.dev/blog/postgres-listen-notify-scalability)

**Redis pub/sub and NATS**
- Common pattern: every WebSocket node subscribes to channels and pushes to its local sockets. Redis pub/sub is fire-and-forget, and NATS core is similarly at-most-once. These are vendor and blog sources and should be read as directional. — [dev.to (2026)](https://dev.to/young_gao/pubsub-messaging-patterns-redis-nats-and-when-to-use-what-2el2); [kindatechnical](https://kindatechnical.com/api-design-development/scaling-websockets-pubsub.html)
- Core NATS is "at-most-once": a message reaches every subscriber connected at the moment of publish, with "no broker queue, no storage, and no acknowledgment." JetStream is "the persistence layer that sits on top of core NATS" for messages that must wait, survive a restart, or be replayed. — [NATS docs, Core NATS](https://docs.nats.io/nats-concepts/core-nats)
- Rust prior art: `socketioxide-redis` is a Redis adapter for multi-node socket.io servers on axum. It works with `redis` (standalone or cluster, using sharded pub/sub) or `fred`, and the docs cite about 1 ms of propagation overhead on a local cluster. Broadcasts become futures that must be awaited because remote nodes may be involved. Releases are labelled unstable (0.3 to 0.4, Oct 2025 onward). — [docs.rs socketioxide-redis](https://docs.rs/crate/socketioxide-redis/latest); [lib.rs](https://lib.rs/crates/socketioxide-redis)

**Sticky routing at the AWS ALB**
- ALB stickiness is cookie-based only (`lb_cookie` as AWSALB, or `app_cookie`). The docs offer no routing on a header or user id and no consistent-hashing algorithm. The algorithms are round robin, least outstanding requests, and weighted random, and weighted random cannot be combined with stickiness. — [AWS ELB docs, target group attributes](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html)
- "WebSocket connections are inherently sticky … After the WebSockets upgrade is complete, cookie-based stickiness is not used." For WebSockets the target is chosen by least outstanding requests. The LB-generated cookie expires after 7 days (not configurable). Stickiness requires cross-zone load balancing to be on. The default deregistration delay is 300 s. — [AWS ELB docs](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html)
- With application-cookie stickiness, the ALB issues its own `AWSALBAPP-*` cookie that encodes the target, and clients must send back both cookies. If a target fails, the session is re-stuck to a new target and stays there even after the old one recovers. — [AWS ELB docs](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html). (D-085 in this repo relies on exactly this behaviour.)

**Actor libraries with distribution**
- ractor is "inspired from Erlang's gen_server," with about 2.1k stars, version 0.16, and MSRV 1.85. It provides supervision, `pg` process groups, and a named registry. Its README says it "is used as the basis for Meta's Rust thrift overload protection scheme" and was part of a RustConf'24 talk. — [GitHub slawlor/ractor](https://github.com/slawlor/ractor)
- ractor_cluster: a `NodeServer` modelled on Erlang nodes and EPMD, running over TCP and serializing messages (protobuf for the inter-node protocol). The README says it "shouldn't be considered production ready, but it is relatively stable," and cluster support is tracked as work in progress in issue #16. There is no distributed global ordering. Message types need explicit derives when the cluster feature is enabled. — [GitHub ractor](https://github.com/slawlor/ractor); [docs.rs ractor_cluster](https://docs.rs/crate/ractor_cluster/latest/source/src/lib.rs)
- kameo is a Tokio actor library whose remote feature runs on libp2p (TCP, WebSocket, and QUIC transports). It registers and looks up actors across nodes through a Kademlia DHT. The API changed a lot between 0.12 and 0.2x. — [GitHub tqwewe/kameo](https://github.com/tqwewe/kameo); [docs.rs kameo](https://docs.rs/crate/kameo/latest/source/README.md)

### Inferences
- Ranked by added code and ops for b4hub:
  1. User-affinity routing (D-085): about 420 lines, no new infrastructure, already built.
  2. A frame-forwarding bus: Redis (ElastiCache) or NATS is a new stateful service on AWS to run, secure, and pay for. It also needs an internal envelope format, per-node subscription management, and handling for at-most-once loss, which the relay's `relay_timeout` and `device_offline` replies partly cover already.
  3. Distributed actors (ractor_cluster or kameo): ECS service discovery, mesh networking between tasks, and transport security the README does not document, all on a self-declared not-production-ready crate.
- LISTEN/NOTIFY suits low-rate control signals such as "user X's owner changed" or "close your links for user X." It cannot carry relay frames: D-085 cites 256 KiB frames and high-rate deltas, against the 8,000-byte limit, and the commit lock contends with the hub's own `changes::push` write path.
- D-085 already records why the hub chose affinity over forwarding: forwarding "would need an internal transport for 256 KiB frames and high-rate deltas and would split the in-flight map." Any Phoenix proposal should be weighed against that baseline, not against a single process.

### Gaps
- No primary benchmark of Redis pub/sub or NATS latency and throughput on AWS at b4hub's scale was found. The figures in blog posts (for example "500K msg/s per Redis") are unverified and were left out.
- actix (actor framework) was not researched in depth. Its actors are local only, with no maintained distribution layer that I could confirm.
- Redis Streams (persistent, consumer groups) was not covered beyond its being the persistent counterpart to pub/sub.
- The final form of the Postgres 19 NOTIFY change is not confirmed, because Recall.ai and DBOS conflict. Check the PG 19 release notes.
- I did not verify how ractor_cluster authenticates nodes (the README mentions authentication in `NodeSession` without naming a mechanism) or whether it supports TLS.

## 2. How small services handle presence ("which devices are online") across nodes without the BEAM

### Takeaway
Without the BEAM, the usual pattern is a shared store with TTL keys refreshed by heartbeats (Redis, or Postgres rows with a heartbeat column) plus pub/sub for presence changes. Supabase gets the Phoenix-native alternative, CRDT presence through Phoenix Tracker, for free on the BEAM. With per-user affinity, presence becomes node-local again, because both of a user's devices are on the same node.

### Cited Findings
- Common pattern: a presence key with a short expiry (for example 30 s), refreshed by heartbeats, so users on a crashed instance go offline automatically. Presence stays in Redis even when NATS carries messages. These are vendor blogs; treat as directional. — [oneuptime (2026)](https://oneuptime.com/blog/post/2026-03-31-redis-how-to-design-a-real-time-chat-system-using/view); [dev.to](https://dev.to/young_gao/pubsub-messaging-patterns-redis-nats-and-when-to-use-what-2el2)
- Supabase Realtime Presence is "an in-memory key-value store backed by a CRDT" built on Phoenix Tracker (a delta-based CRDT), with Broadcast as its transport. State converges across nodes without a central store. — [Supabase Realtime architecture](https://supabase.com/docs/guides/realtime/architecture)
- Discord (2017) ran presence as a separate Elixir service. In one incident presence crashed while sessions stayed up, and presence rebuilt within minutes. — [Discord blog, 2017](https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users)
- b4hub today: the instance heartbeat (5 s, dead after four missed) in `hub_instances` plus `user_links` already acts as a coarse Postgres-backed presence-of-owner. Device presence and `lastSeenAt` stay in the owning instance's memory. — `docs/decisions.md` D-085; `Hub/API.md` (`device_offline` carries `lastSeenAt`)

### Inferences
- With D-085's invariant that all links of a user live on one instance, "is the Mac online?" is answered locally, the same way it was with one process. Cross-node presence is only needed if the design moves to frame forwarding or to a separately scaled edge.
- If cross-node presence ever becomes necessary, a Postgres table with heartbeats (the pattern already used for instances) avoids adding Redis. The cost is write load of roughly one row update per device per heartbeat.

### Gaps
- I found no rigorous, sourced comparison of TTL-key presence and CRDT presence (convergence time, failure behaviour) for small deployments.

## 3. Case studies: Elixir with Rust, moves in both directions, and the two-language cost

### Takeaway
The best-documented large real-time system, Discord, kept Elixir for real-time fan-out and called into Rust only for hot data structures (and rewrote a Go service in Rust because of GC). The documented Elixir wins (Pinterest, Bleacher Report) are older, server-count stories reported second-hand. Moves away from Elixir are mostly anecdotal and cite GC pauses, hiring, or a maintainer's familiarity. No source quantifies the two-language cost for a solo developer.

### Cited Findings
**Discord**
- July 6, 2017: nearly 5M concurrent users. Clients hold a WebSocket to a session GenServer, and guild GenServers on remote Erlang nodes fan events out to sessions. Placement uses consistent hashing, a session VM holds up to 500,000 sessions, and the average user is in 5 guilds. — [Discord blog](https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users)
- Problems they hit on the BEAM: `send/2` cost 30 to 70 µs, so fan-out from a 30,000-user guild took 0.9 to 2.1 s. They fixed it with Manifold (one send per remote node). A single hash-ring process was a bottleneck, fixed with FastGlobal (0.3 µs lookups). A stampede of about 5M sessions on 10 registry processes caused OOM cascades, fixed with Semaphore. Lessons: Erlang processes are single-threaded, sends are costlier than expected, and callers should fail fast. — [Discord blog, 2017](https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users)
- May 17, 2019 ("Using Rust to Scale Elixir for 11 Million Concurrent Users"): the member list needed a mutable sorted set of up to 250K or more entries. The best pure-Elixir result took 640 µs to append at 250K items. A Rust NIF via Rustler took 0.61 to 3.68 µs at sizes up to 1M. The proof of concept took one week and the full build a few weeks. Real-time logic stayed in Elixir. — [Discord blog, 2019](https://discord.com/blog/using-rust-to-scale-elixir-for-11-million-concurrent-users); library still maintained (last push Jan 27, 2026) — [GitHub discord/sorted_set_nif](https://github.com/discord/sorted_set_nif)
- Discord's Go-to-Rust rewrite of the Read States service was driven by Go GC latency spikes. This is reported via a secondary source; Discord's own 2020 post was not fetched here. — [dev.to summary](https://dev.to/thepavansai/why-discord-keeps-rewriting-its-stack-59l3)

**Moves to Elixir**
- Pinterest notifications: "30 c32.xl instances" on Java became 15 on Elixir, quoted from engineer Steve Cohen. This is second-hand, and the primary talk was not fetched. — [Elixir Forum thread](https://elixirforum.com/t/elixir-saves-pinterest-2-million-year-other-marketing-examples/57909); [DockYard](https://www.dockyard.com/campaigns/business-value-elixir)
- Bleacher Report (Ruby to Elixir): servers fell from 150 to "five" (TechWorld) or "eight" (other write-ups), while sending about 200M push notifications a day. Sources disagree on the final count. — [Monterail](https://monterail.com/blog/famous-companies-using-elixir); [Elixir Forum](https://elixirforum.com/t/elixir-saves-pinterest-2-million-year-other-marketing-examples/57909)
- Remote (Jan 2025 case study): an Elixir monolith with about 180 engineers in one codebase, 90% of backend engineers in the monolith, satellite services also in Elixir, and Oban jobs running in the same pods. — [elixir-lang.org case study](https://elixir-lang.org/blog/2025/01/21/remote-elixir-case/)
- Supabase Realtime stays on Elixir. It is "a globally distributed Elixir cluster" on Phoenix Channels and Phoenix.PubSub (PG2 adapter over Erlang process groups), with Presence on Phoenix Tracker, Postgres changes via logical replication, and at least two nodes per region. — [Supabase docs](https://supabase.com/docs/guides/realtime/architecture); [Supabase GA blog, 2021](https://supabase.com/blog/supabase-realtime-multiplayer-general-availability)

**Moves away from Elixir, and the two-language cost**
- Farside (open-source, solo maintainer) was rewritten from Elixir to Go for maintainability. The maintainer already writes Go elsewhere, including at the day job, so Go is "a safer bet" long term. — [farside go.mod / repo](https://git.hackliberty.org/Git-Mirrors/farside/src/branch/main/go.mod) (as summarized in search; the commit message itself was not fetched)
- A director of engineering on Reddit said Elixir expertise had left the company and new hires were less keen to learn it. This is anecdotal. — [r/elixir thread](https://redlib.hbubli.cc/r/elixir/comments/13ub46o/why_elixir_over_golang/lp78w6l/?context=3)
- A developer moved a game engine from Elixir to Rust after profiling showed heavy GC time. This is anecdotal. — [dev.to](https://dev.to/built-from-africa/why-i-had-to-choose-between-my-love-of-elixir-and-the-performance-of-our-treasure-hunt-engine-2nh8)
- InfluxData went from Go to Rust, folding microservices into a monolith "to reduce the overall complexity." This is not an Elixir case, but it shows that consolidation, not raw speed, drives rewrites. — [InfluxData](https://www.influxdata.com/blog/rust-monolith-migration-influxdb/)

### Inferences
- Discord's lesson cuts both ways. The BEAM gave them distribution, and they still had to build Manifold, FastGlobal, and Semaphore, then add Rust for data structures. At Discord's scale the "free" BEAM fan-out took custom engineering. At b4hub's scale (two devices per user, no large groups) none of those pressures apply.
- The server-reduction stories (Pinterest, Bleacher Report) compare Elixir with Java and Ruby, not with Rust/tokio. They don't show that Elixir beats an existing Rust service on resource cost.
- For a solo developer whose codebase is Swift plus Rust, adding Elixir means a third production language: its toolchain, release and Docker build, CI job, dependency audits, and observability stack. Hub contracts (for example `Tests/Fixtures/sync/*.json`, decoded by both Swift and Rust today) would need a third decoder. The Farside case shows how a lone maintainer typically resolves this, by consolidating on the language they use daily.

### Gaps
- Pinterest and Bleacher Report numbers come from secondary sources, and the primary talks were not fetched.
- I found no first-hand write-up from a company that moved a WebSocket or realtime tier from Elixir to Rust or Go at production scale. The cases above are small or anecdotal.
- No quantitative study of the "two-language tax" for solo developers was found. This part is inference only.

## 4. Swift client libraries for Phoenix Channels

### Takeaway
SwiftPhoenixClient (about 530 stars) is the established client and supports Channels and Presence, but its README mentions no async/await or Swift 6 strict concurrency. A new client built for Swift 6, PhoenixNectar (actors, async/await, AsyncStream), appeared on the Swift and Elixir forums, but its maturity is unproven. Moving to Phoenix's protocol would mean replacing the app's own `RelayLink` and `HubLinkConnection` with one of these clients.

### Cited Findings
- SwiftPhoenixClient: 530 stars, 152 forks, 361 commits, 9 open issues, 2 open PRs. Install snippets reference 5.3 (CocoaPods/Carthage) and 5.2.2 (SPM). It is built on URLSession's WebSocket (iOS 13+), and the CocoaPods section says iOS 9, which conflicts. The core "provides the Phoenix Channels and Presence logic." The README thanks Daniel Rees for "continued maintenance" and says nothing about async/await or Swift 6. — [GitHub davidstump/SwiftPhoenixClient](https://github.com/davidstump/SwiftPhoenixClient)
- PhoenixNectar is "a Swift 6 client for Phoenix Channels" designed around actors, async/await, and AsyncStream, with auto-reconnect and rejoin, iOS 16+ and macOS 15+. Its author says it builds on SwiftPhoenixClient's work. A forum reply says SwiftPhoenixClient "would need a ton of work" to adopt strict concurrency. — [Swift Forums](https://forums.swift.org/t/phoenixnectar-a-swift-6-client-for-phoenix-channels/85396); [Elixir Forum](https://elixirforum.com/t/phoenixnectar-swift-6-client-for-phoenix-channels/74697)

### Inferences
- A Swift 6 strict-concurrency codebase like this one would either wrap SwiftPhoenixClient's callback API in actors and `@unchecked Sendable` shims or bet on a young library (PhoenixNectar). Neither beats keeping the custom JSON protocol over `URLSessionWebSocketTask` that the app already owns, unless the hub moves to Phoenix for other reasons.
- Phoenix can also serve a raw WebSocket (outside Channels) that keeps the custom JSON protocol, so moving the server does not force a client change. That is a Phoenix-internals point for the other researcher to confirm.

### Gaps
- I could not see SwiftPhoenixClient's latest release date or last commit date (the Releases section was empty on the page I fetched), so its maintenance cadence as of November 2026 is unconfirmed.
- PhoenixNectar's star count, release history, and production users were not verified.
- Unverified lead: supabase-swift (Supabase's Swift SDK) is believed to include a Realtime client that speaks the Phoenix protocol. This was not fetched or confirmed in this session.

## 5. Hybrid options: Phoenix as a realtime edge, Elixir only for the relay, or managed realtime

### Takeaway
Managed AWS options fit b4hub poorly. API Gateway WebSockets caps messages at 128 KB (32 KB frames), idle connections at 10 minutes, and connection life at 2 hours, all hard limits. AppSync Events is cheap but is channel pub/sub with 5 KB metering, not request and reply routing to a specific device. Self-hosted Supabase Realtime is an Elixir cluster, so it brings the BEAM operational cost without the code ownership. A "Phoenix edge plus Rust core" hybrid is the shape Discord and Supabase use, but for b4hub it splits one small service into two languages and two deploy units.

### Cited Findings
- API Gateway WebSocket quotas: connection duration 2 hours and idle timeout 10 minutes, neither adjustable. 500 new connections per second per account per Region by default (adjustable). Message payload 128 KB and frame 32 KB; a larger frame closes the connection with code 1009. — [AWS API Gateway WebSocket quotas](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-execution-service-websocket-limits-table.html)
- AppSync Events, launched late 2024: serverless WebSocket pub/sub with channels grouped in namespaces, wildcard subscriptions, and auth and handlers per namespace. — [AWS AppSync Events docs](https://docs.aws.amazon.com/appsync/latest/eventapi/event-api-welcome.html). Publishing over WebSocket was added in March 2025, limited to 25 requests per second per connection (third-party report). — [ssojet](https://ssojet.com/news/news-2025-03-aws-appsync-events-websocket-pub)
- AppSync Events pricing: $1.00 per million operations (publishes, broadcasts, handler invocations, connects, subscribes, pings), $0.08 per million connection-minutes, messages metered in 5 KB units (8 KB counts as 2). Free tier: 250K updates and 600K connection-minutes a month for 12 months. — [AWS AppSync pricing](https://aws.amazon.com/appsync/pricing/)
- Supabase Realtime is an Elixir/Phoenix cluster with Broadcast (Phoenix.PubSub), Presence (Tracker CRDT), and Postgres Changes (logical replication slot), at least two nodes per region. Its GitHub README labels Broadcast and Presence Beta, while the 2021 blog says GA, so the labels conflict. — [Supabase docs](https://supabase.com/docs/guides/realtime/architecture); [Supabase blog 2021](https://supabase.com/blog/supabase-realtime-multiplayer-general-availability)
- Discord's split: an Elixir real-time tier, Rust inside it via NIFs, and separate Rust and Go services elsewhere. — [Discord 2019](https://discord.com/blog/using-rust-to-scale-elixir-for-11-million-concurrent-users)

### Inferences
- API Gateway's 128 KB message cap is below b4hub's 256 KiB relay frame (D-085) and would force chunking. The 2-hour cap would force reconnects on the Mac's always-on link (the Mac holds a keep-awake link, per `HubSync/KeepAwake.swift`). The 10-minute idle cutoff is manageable with pings. API Gateway also routes each frame to a Lambda or HTTP backend, so the in-memory hold and in-flight state in `route.rs` would have to move to a store.
- AppSync Events: the relay is directed request and reply (phone to a specific Mac, with holds, deadlines, and `device_offline`), not topic fan-out. Rebuilding it on per-device channels is possible, but the hub would lose the in-process reply correlation. The 5 KB metering makes streamed deltas costly per byte compared with Fargate, where they are free.
- "Elixir only for the relay" would mean a Phoenix service that authenticates against the Rust hub's tokens and revocation (or shares its Postgres), owns the link registry, and calls back into Rust or Postgres for thread rows. That is a second deployable, a shared-auth contract, and a cross-service test fixture. Given that D-085 already gives multi-instance routing in Rust, the hybrid's main payoff would be BEAM-native frame forwarding and presence, which the affinity design deliberately avoids needing.

### Gaps
- AppSync Events' maximum message size and per-connection subscription limits were not verified.
- No public case study of a small team running Phoenix as a thin edge in front of a Rust core was found. Discord and Supabase are large-team examples.
- API Gateway WebSocket pricing (per million messages and connection-minutes) was not fetched.

## 6. Cost and resource comparisons: memory per idle WebSocket in tokio and the BEAM

### Takeaway
No rigorous apples-to-apples benchmark exists. Phoenix's 2015 test held 2M sockets on a 40-core, 128 GB box (limited by ulimit, not memory), which bounds it at about 64 KB per socket including everything. A 2015 community rerun reached 2.3M on 64 GB, about 28 KB per socket as an upper bound. Tokio is generally expected to be smaller per connection, but I found only unverified self-reported numbers (about 8 KB per connection). At b4hub's scale, a few devices per user, memory per connection is not a deciding factor either way.

### Cited Findings
- Phoenix, "The Road to 2 Million WebSocket Connections" (Gary Rennie, Nov 3, 2015): 2M connections on a 40-core, 128 GB Rackspace OnMetal box, "limited by ulimit." The 4-core, 15 GB box ran out of memory around 450K. Per-socket memory was not optimized. Optimizations included sharding PubSub by subscriber PID across ETS tables, which kept broadcast to 2M subscribers near 1 s. The post itself warns "This is not a typical use case." — [Phoenix blog](https://phoenixframework.org/blog/the-road-to-2-million-websocket-connections)
- A community reproduction held 2.3M Phoenix connections on a 64 GB, 20-core Droplet, about 28 KB per connection as an upper bound including OS overhead, and it "does not benchmark real use cases." — [GitHub dsander/phoenix-connection-benchmark](https://github.com/dsander/phoenix-connection-benchmark)
- Rust/tokio: a small npm-published Rust server claims about 80 MB for 10K connections (about 8 KB each), self-reported with no methodology. — [npm rust-websocket-server](https://npmjs.com/package/rust-websocket-server). An actix-web issue notes that per-connection `BytesMut` buffers keep their capacity after large messages, which inflates memory per client. — [actix-web #3367](https://redirect.github.com/actix/actix-web/issues/3367)
- Several 2026 DEV Community "Elixir vs Go vs Rust" posts give per-connection figures that contradict each other (for example 14 KB BEAM against 8 KB tokio in one, and 2.2 KB against 1.2 KB in another). They cite unverifiable versions. **Unreliable; excluded from conclusions.** — [dev.to example](https://dev.to/johalputt/comparison-elixir-117-vs-go-124-vs-rust-195-for-real-time-chat-app-throughput-and-fault-4d3k)
- Discord (2017) put up to 500K live sessions on one session VM, a real-world BEAM density figure with application state included. — [Discord blog](https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users)
- Current hosted-hub spend: about $110 a month for both environments at one task each ("now" tier, D-068). — `docs/decisions.md` D-068

### Inferences
- Both runtimes hold hundreds of thousands of idle sockets per node. b4hub's connection count (one Mac and one or two phones per user) is orders of magnitude below where either runtime's memory matters. The hosting cost is set by the Fargate task floor (and the second task for redundancy), not by memory per socket.
- If a measured comparison is wanted, the honest method is to run the same echo or broadcast workload on axum with tokio-tungstenite and on Phoenix, and record RSS at fixed connection counts. Published numbers do not support a precise ratio.

### Gaps
- No credible, recent, controlled benchmark of memory per idle WebSocket in tokio against the BEAM was found.
- No source compares AWS Fargate cost for an Elixir cluster (which needs node discovery, for example libcluster with DNS) against an equivalent Rust service.
