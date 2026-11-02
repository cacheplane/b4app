# M8e Part B: the relay on more than one hub instance

Date: 2026-11-02. Owner: Brian Love. Status: reviewed by the M8c build session on 2026-11-02 ("route-by-user is the right call"); its requested change (relocate at the upgrade, never after `hello`) is incorporated; built after `feat/m8c-relay` merges. Amends D-057 ("One replica") when built.

This document designs the two hub items the hosted deployment (`docs/deployment-architecture.md`, "next" tier) needs from the relay: a readiness probe that exercises the relay path, and relay routing that keeps working when the ECS service runs two or more tasks behind the Application Load Balancer. It builds on `2026-11-01-m8c-relay-design.md` (D-054 to D-059) and on the M8c build's description of its hub code (`Hub/crates/b4hub/src/relay/{registry,route,link,limits,mod}.rs`, `b4hub-db/src/relay.rs`), whose names it uses. Part A of M8e (`2026-11-02-m8e-hub-operability-design.md`, PR #36) added `MaintenanceState` and the request span the probe and the routing log lines reuse.

## Intent

Today the relay's routing state (links, presence, watches, in-flight commands, holds, pending threads) lives in one process, so the service runs one task and every deploy is a short outage (D-068). The owner wants the "next" tier: two tasks across two zones with rolling deploys and no outage, without rewriting the relay. The constraint set from the M8c build is binding: a `NOTIFY` payload is at most 8000 bytes while frames reach 256 KiB; `message.delta` is tens of frames a second and is never stored; commands carry a 10 s hub-clock deadline; in-flight deduplication is keyed by `(caller device, command id)` and must stay on one instance; presence and "one link per device" must hold across instances; the readiness probe must not mint a device.

## Decision: route by user, do not forward frames

Every link of one user (the Macs and the phones of that user) is served by **one instance at a time**, chosen deterministically, so commands, replies, watches, deltas, holds, and in-flight entries never cross instances. Nothing in `route.rs` changes. What changes is how a link finds its instance and how instances learn about each other.

Why not forward frames between instances: it would need an internal transport for 256 KiB frames and high-rate deltas (a second listener per task with service discovery), it would split the in-flight map, and every design in the research that did this (Phoenix PubSub with PG adapter, Soketi horizontal mode) pays for a broker. Routing by user keeps the M8c code intact and matches what the owner's "next" tier buys: zero-downtime deploys and zone redundancy, not a bigger relay.

### B2.1 Instances know each other

- `hub_instances (instance_id uuid primary key, started_at, heartbeat_at, public_url text)`: each `serve` registers on start with a UUIDv7 and refreshes `heartbeat_at` every 5 s; a row older than 20 s is dead. `public_url` is the hub's `B4HUB_PUBLIC_URL` (the same for every instance behind one ALB; kept for a later per-instance address).
- `user_links (user_id uuid primary key, instance_id uuid not null, claimed_at timestamptz not null)`: the instance that currently serves a user's links. Claimed with `INSERT ... ON CONFLICT (user_id) DO UPDATE SET instance_id = excluded.instance_id, claimed_at = now() WHERE user_links.instance_id NOT IN (SELECT instance_id FROM hub_instances WHERE heartbeat_at > now() - interval '20 seconds')`: a live owner keeps the claim; a dead owner's claim is taken over.
- Both tables are hub-internal (no `org_id`, no RLS; `b4hub_app` reads and writes them, like `device_tokens`). Rows for users with no links are pruned with the change-log prune.

### B2.2 A link finds its instance

On `GET /v1/devices/self/link`, after authentication and before the upgrade:

1. Read `user_links` for the device's user. If the row names this instance, or there is no row, or the row's instance is dead, claim it (B2.1) and accept the upgrade; the link is served here.
2. If the row names another live instance, the upgrade is **refused before any socket exists** (the M8c build's preferred seam: after the revocation check and before `on_upgrade`): the response is `409` with B4's envelope `{"error":{"kind":"request_error","message":"your links are served by another hub instance","details":{"code":"relocated","instanceId":"<id>"}}}` and the header `Set-Cookie: b4hub-instance=<id>; Path=/; Max-Age=3600; Secure; HttpOnly`. No `hello` is ever sent, so neither client publishes a false `.connected`, the Mac does not reset its watched set, and the relocated link never enters `Relay`, presence, or `watching`.
3. The device treats `409 relocated` as "retry now": it stores the cookie value from the response (or from `details.instanceId`) and repeats the upgrade at once with `Cookie: b4hub-instance=<id>`, which the ALB's application-cookie stickiness (`app_cookie`, name `b4hub-instance`, 1 h) routes to that target; every instance sets `Set-Cookie: b4hub-instance=<its own id>` on its `/readyz` and successful upgrade responses so the ALB learns the mapping. At most 3 immediate retries, then the normal backoff (1 s doubling with full jitter). Devices without the cookie land anywhere and are relocated at most once per owner change.
4. If stickiness cannot be relied on (a target replaced during a deploy), the device gets another `409 relocated`; the cap then falls back to backoff, and the dead-owner rule in B2.1 lets the new instance claim the user within 20 s.

Client changes (both platforms, `Sources/WorkspaceSync/RelayLink.swift` and the Mac's `HubLink`): a `relocated` case for a 409 upgrade response that sets `skipBackoff` and the cookie; `URLSessionHubLinkConnection.open` sends the `Cookie` header itself (each socket has its own `URLSession`, so the ALB's `Set-Cookie` is not picked up automatically); `relocated` joins Swift's `ErrorCode` and `Tests/Fixtures/sync/relay.json`. No new frame type is needed.

Consequences for the M8c rules:

- **One link per device** holds because a device's links are always on its user's instance; the existing generation-checked replacement stays.
- **Presence**: `online` is "has a link on the owning instance"; `last_seen_at` writes are unchanged; a client on the owning instance sees presence exactly as today.
- **Watches**: `Watchers`/`Missed` are keyed by device id plus link generation and cleaned on unregister; a relinked client re-sends its watched set (`MirrorRelay` does on every link; the Mac gets the full `watching` after `hello`), so nothing crosses instances.
- **In flight**: the `(caller device, id)` map is per instance. After a takeover a phone's resend reaches the new instance and is forwarded again; the Mac deduplicates `turn.send` and `thread.start` durably by `operationId` and runs interrupt and respond idempotently, so the worst case is a second reply to an id the phone has already settled, which the phone ignores. Accepted.
- **Holds**: the 60 s holds live on the instance that queued them. A draining instance answers every held command with `device_offline` explicitly before it releases its claims, so a hold never silently times out on an instance nobody is connected to. A crash loses holds, as a crash does today.
- **Pending threads**: the `threadId → owner` map (300 s after `thread.start`) is per instance. If a takeover falls between a phone's `thread.start` and the Mac's push of the thread row, a `watch` or `turn.send` on that thread answers `not_found` until the row syncs (seconds). The phone already retries `watch` on relink; `turn.send` surfaces the error to the person. Accepted as an edge.
- **Maintenance mode** (Part A): the `WritesAllowed` guard also applies to `turn.send`, `thread.start`, `request.respond` arriving over a link; the hub answers those with the `maintenance` error frame while on.

### B2.3 Deploys and failover

- A rolling deploy drains one task (SIGTERM, 1001 close, 60 s `stopTimeout`): its users' claims become dead within 20 s of its last heartbeat (sooner: the draining instance **releases** its claims on shutdown by deleting its `user_links` rows after closing links), and the devices reconnect to the surviving task, which claims them. A deploy therefore costs each device one reconnect, as today, with no window where the hub is down.
- A crashed task is covered by the 20 s heartbeat rule.
- Two tasks are enough for the "next" tier; the design has no per-instance limit.

### B2.4 Not done here

- No cross-instance delta forwarding; a phone whose link is on the wrong instance is relocated, never served stale.
- No change to the change-log sync (HTTP push/pull is stateless and works on any instance already).
- The per-IP rate limits stay per instance (D-057), as the deployment design accepted.

## B1 Readiness probe for the relay

`/readyz` gains a relay check when the relay is enabled: a separate internal function (not a route, and not `upgrade`, whose `AuthedDevice` extractor runs first) builds the per-link task over an in-memory duplex with a probe identity that `register` skips, so the probe never appears in `Relay`, presence, or `watching`; it performs the `hello` exchange and closes. The probe must complete in 2 s; success adds `"relay": "ok"` and failure answers `503 not_ready` with `"relay": "failed"` and a warning log line (the deployment's external probe then pages). No device token is minted and no row is written. When the relay is disabled the field is absent. B2.1's registration also feeds `/readyz`: an instance whose heartbeat write has failed for more than 20 s reports `"instances": "stale"` and 503, so a hub that cannot claim users is not routed to.

## Changes to Terraform (the deployment project)

- `alb.tf`: target-group `stickiness { type = "app_cookie", cookie_name = "b4hub-instance", cookie_duration = 3600, enabled = true }`.
- `envs/prod/main.tf`: `task_count = 2`, `private_tasks = true` (the "next" tier's NAT); `desired_count = 2`; the deployment percentages flip to 100/200 by the module's existing expression.
- `deploy.sh`: the `desiredCount` readiness skip is unchanged; `run-migrate.sh` is unchanged.

## Wire additions (`Hub/API.md`)

- `GET /v1/devices/self/link` may answer `409 relocated` (`details.instanceId`) ~~with `Set-Cookie: b4hub-instance=<id>`; devices retry at once with `Cookie: b4hub-instance=<id>`~~ (struck: see "Build notes", the `409` carries no cookie and devices replay their last upgrade's cookies); at most 3 immediate retries. No new frame type and no new close code.
- `Set-Cookie: b4hub-instance=<own id>` on `/readyz` and successful upgrade responses from every instance.
- `/readyz`: `relay: "ok" | "failed"`, `instances: "ok" | "stale"`.
- Error frame code `maintenance` for commands while the switch is on.

## Decisions to record (numbers at commit)

- The relay runs on several instances by routing each user's links to one instance (`user_links` claim with heartbeat takeover; a `409 relocated` upgrade refusal plus ALB application-cookie stickiness), never by forwarding frames; amends D-057.
- `/readyz` exercises the relay through an in-process probe principal, never a minted device.

## Verification

- Fixture: two `serve` instances in one test process sharing a database; a client linking to the wrong instance gets `409 relocated` with the owner's id and no socket, and, after reconnecting with the cookie header to the right instance, completes a command; a draining instance answers its held commands `device_offline` and releases its claims; killing the owner's heartbeat lets the other instance claim within the test's shortened window; one link per device holds across instances; the probe passes on a healthy instance and fails when the acceptor is stopped.
- Live (test account): `task_count = 2`, a deploy during an open phone link, the phone reconnects once and keeps its thread; a user re-links during deregistration (between the ALB deregistering the old task and its SIGTERM) and connects after its backoff; `/readyz` shows `relay: ok` on both tasks.

## Build notes (2026-11-02)

Built on `blove/m8e-relay-multi-instance` as D-085 and D-086. Where the build differs from the text above, the build is right and this is why:

- **The `409` carries no cookie, and the device replays the ALB's cookies rather than naming an instance.** AWS documents application-cookie stickiness as: when a target's response sets the configured cookie, the load balancer adds its own `AWSALBAPP-*` cookie encoding *that target*, routes a later request only when it carries both cookies, and never inspects the application cookie's value. So `Set-Cookie: b4hub-instance=<owner>` on a `409` from the wrong instance would stick the device to the wrong instance, and `Cookie: b4hub-instance=<owner>` on its own routes nowhere in particular. The hub sets the cookie only on accepted upgrades and `/readyz` (its own id, as designed); `RelayLink` keeps the cookies of its last successful upgrade response (both, behind an ALB), sends them on the next upgrade, drops them on a `409`, and retries at once up to three times, landing by round robin, then backs off. `details.instanceId` is in the body as designed but the device does not read it: `URLSessionWebSocketTask` exposes a refused upgrade's status, not its body, and a device cannot address an instance through the ALB.
- **The liveness window is four heartbeats, a parameter, not a literal `interval '20 seconds'`**, so the fixture tests run two instances with a 200 ms heartbeat. `B4HUB_HEARTBEAT_MS` (default 5000) sets it; every instance of one hub must agree. The claim's upsert also skips the update when the row already names the claiming instance.
- **Drain order.** Held commands are answered `device_offline` *before* the links close (each link writes what is queued before its 1001), then the claims are released; answering after the links closed would lose the answers. The instance row is deleted with the claims.
- **The drain is bounded.** The shutdown deadline starts when the signal arrives, before the holds are answered, and releasing the claims is itself bounded by what is left of it, so the whole drain stays within `B4HUB_SHUTDOWN_WAIT_MS`.
- **Rolling deploys on ECS** (from the review): with `task_count > 1` the target group's `deregistration_delay` is 5 s instead of 60 s, because the ALB waits that long after deregistering a task before ECS sends SIGTERM, and during it the old task keeps its claims while receiving no connections. The sequence is deregister, 5 s, SIGTERM, holds answered, links closed 1001, claims released, relink claimed by the new task.
- **A recovered instance lets go.** If an instance's heartbeat fails for the window, another instance may claim its users while their links stay open on the first; the first, once a heartbeat succeeds again, closes those users' links with 1001. The design did not cover this split.
- **The probe** runs the real link task (made generic over a `LinkSocket`) over an in-memory socket pair; `Identity::probe()` gets a handle and queues from `Relay::register` without entering the registry. It exchanges `hello`, `presence`, and `ping`/`pong`. The failure fixture raises the relay's minimum client protocol above the hub's own rather than stopping an acceptor (there is none to stop in process).
- **Client changes are in `RelayLink` only**, which both the Mac's `HubLink` and the phone's `MirrorRelay` use; neither needed changes. No wire shape changed, so `Tests/Fixtures/sync/relay.json` is untouched; `relocated` joined Swift's `ErrorCode`.
- **Terraform.** `stickiness.enabled = var.task_count > 1`, not `true`, so the one-task "now" tier is unchanged; the env roots are unchanged (the move to two tasks is the owner's step, `Infra/README.md` runbook 13).
