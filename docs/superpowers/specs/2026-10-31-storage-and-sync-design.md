# Storage and multi-device sync

Date: 2026-10-31. Status: the store is decided (Postgres on every Mac and as the hub, D-041); four smaller decisions remain below. Brian asked for a more robust database with proper migrations, Postgres, and a local store that syncs with a remote so the workspace works across devices. This document lays out what the data is, what can and cannot follow a person between devices, the options, a recommendation, and the decisions only the owner can make. Nothing here is built.

## What the store holds today

`~/Library/Application Support/b4app/workspace.sqlite`, opened only by the coordinator through GRDB, migrations `v1` to `v3` (forward-only, applied at start). Tables: connections, threads, turns, display items (the transcript cache), runtime requests, drafts, local servers, an event log with epochs, diagnostics. Secrets are not in it: they live in the Keychain and the database holds references. Per-Mac facts live beside the index: executable paths, pids, ports, socket and log paths, process identities.

Scale: one person, a few devices, thousands of rows, growth dominated by transcript items (tool output can be large). Nothing here needs a server-class database for its own sake.

## What multi-device can and cannot mean

A thread is bound to one native session (spec 3.3). Where that session lives decides what another device can do with it:

| Thread kind | Native session lives | From another device |
| --- | --- | --- |
| Codex, Claude Code | files on the Mac that ran the harness | read the cached transcript, rename, pin, archive, draft; continuing needs that Mac's coordinator (the relay of spec 15) |
| B4 remote endpoint | the server | everything, if that device holds the endpoint credential reference |
| B4 managed local | the server on that Mac | read and organise; continue only when that Mac is up and reachable |

So sync buys: one thread list everywhere, transcripts readable everywhere (the iOS companion's first real purpose), organisation and drafts that follow you, and remote B4 threads continuable from any device. It does not make a Codex thread continuable from a phone; that is the relay, a separate design.

## Decision: Postgres everywhere (2026-10-31)

The owner chose option 1 over the recommendation: Postgres on every Mac as the coordinator's store, Postgres as the remote hub, one engine and one migration toolchain end to end. What follows from that:

- **The app carries a Postgres server.** Pinned binaries (server, `initdb`, `pg_ctl`, `pg_dump`, `pg_upgrade`, their libraries and share files, with their licences) are fetched by `Scripts/fetch-postgres.sh` from a checksummed release and copied into `Contents/Helpers/postgres` by `Scripts/package.sh`. Expect 40 to 80 MB. Development and tests use the same fetched tree under `.build/postgres`; CI fetches it too, so no test depends on a machine-installed Postgres.
- **The cluster is private to the app.** `initdb` on first start into `~/Library/Application Support/b4app/pg` (mode 0700, UTF-8, the owner's macOS user as the superuser, trust auth on the socket only); `listen_addresses = ''`; the only endpoint is a Unix socket in the runtime directory next to the coordinator's socket. Nothing listens on TCP. Logs under the data directory's `logs`, bounded like the server logs.
- **A second LaunchAgent in the packaged app**, `com.cacheplane.b4app.postgres`, runs `postgres -D <data dir>` under launchd with `KeepAlive`; the coordinator's agent waits for the socket. Outside the package (Xcode runs, tests, a CLI-spawned coordinator) the coordinator starts and owns the server itself with the same ownership rules as managed B4 servers (pid plus start time plus argv, D-025) and stops it when it exits.
- **The storage layer is rewritten on PostgresNIO.** `WorkspaceDatabase` keeps its public surface (the coordinator barely changes) but every query becomes SQL against Postgres; GRDB leaves the package. The coordinator remains the only process that opens the store.
- **One migrator.** Versioned SQL files `Sources/WorkspaceStorage/Migrations/NNNN_name.sql` with a `schema_migrations` table, applied in a transaction, used unchanged for the local cluster and the hub. A `pg_dump` to `<data dir>/backups/pre-NNNN.sql` precedes every local migration. `agent-workspace db status|migrate|backup|restore`.
- **Existing data moves once.** On first start with a `workspace.sqlite` present, the coordinator imports it (connections, threads, turns, items, requests, drafts, servers, event epochs) and renames the file `.imported`; `agent-workspace db import-sqlite` does the same by hand.
- **Major versions.** The bundled version is pinned in `docs/compatibility.md`; a new major ships with a `pg_upgrade` step run by the coordinator before it opens the cluster, with the old data directory kept until the next successful start.
- **iOS has no Postgres**, so the companion reads the hub directly (or through the sync service, if that transport is chosen) and is online-only; it never hosts data of its own.
- **Sync stays a change log**, now written by Postgres triggers on the synced tables rather than by Swift, which removes a class of bugs; the apply step is SQL (`INSERT ... ON CONFLICT` with the hybrid clock as the tie-breaker).

## Options for the local store

1. **Local Postgres on each Mac, Postgres remote.** A second daemon per Mac (Postgres.app or Homebrew, or binaries bundled into the app with their own LaunchAgent and `pg_upgrade` on major versions); impossible on iOS, which would become a thin client of the remote; Postgres-to-Postgres bidirectional sync is not built in (logical replication is one way; multi-master needs BDR-class tooling or a change log of our own anyway). Gain: one SQL dialect and one migration toolchain on both ends.
2. **SQLite local (as now), Postgres remote as the hub.** Embedded, zero operations, offline first, the same code on iOS. Cost: two schemas kept in step and a sync protocol we own.
3. **A sync engine on top of option 2.** PowerSync (Postgres to SQLite replicas, writes through our own backend, Swift SDK), ElectricSQL (Postgres shapes to clients, TypeScript first), Turso/libSQL embedded replicas (remote primary is SQLite, not Postgres), CloudKit (Apple only, no Postgres). Each adds a service or a vendor between the devices and the data.
4. **Remote only.** Every read and write goes to Postgres. Breaks offline use and the coordinator's own need for a local store while a turn runs. Rejected.

## The recommendation that was not taken, for the record

Option 2 (SQLite on each device, Postgres as the hub) was recommended because a single-user embedded store needs no daemon or major-version upgrades and runs on iOS. The owner weighed one engine and one toolchain end to end higher, and chose option 1. The sync design below is unchanged by that choice: the change log is what moves, not the engine.

### Sync model

- **Change log.** Every write to a synced table also appends a row to `changes(id, device_id, hlc, table, row_id, column, value, deleted)`. A hybrid logical clock orders changes across devices; last writer wins per column. Turns and display items are append-only facts keyed by their origin, so they never conflict; titles, pins, archive, and drafts are per-column LWW; deletes are tombstones.
- **Transport.** The coordinator speaks to the hub directly over TLS with PostgresNIO (the same client it uses for the local cluster), using a per-device credential stored through `credential add`, never in the database or arguments. Pull, then push, on a timer, after local writes, and on wake. Offline queues and converges later. A thin sync service (a B4 route, say) can replace the direct connection later without changing the log.
- **What syncs.** threads, turns, display items, drafts, and connections *as descriptions* with their owning device: a Codex connection owned by Brian's MacBook appears on the phone as read-only "on MacBook Pro"; a B4 remote connection is usable on any device that holds the credential reference and prompts to add it otherwise. Runtime requests sync read-only (answering stays on the owning device until the relay exists).
- **What never syncs.** Secrets, executable paths, pids, ports, sockets, log paths, process identities, local server registrations, the event log, diagnostics.
- **Identity.** A device id generated once and kept in the Keychain; a device name shown in the UI; the remote keeps a `devices` table.

### Migrations, both ends

One set of SQL files and one migrator (see the decision above). The local cluster migrates at coordinator start after a `pg_dump`; the hub migrates only on `agent-workspace db remote migrate` from a Mac, never from a phone. The hub carries the synced tables plus `devices` and the server-side change log; local-only tables (local servers, event log, diagnostics) exist only in the local cluster, so the migration files mark each table local, hub, or both and the migrator applies the right subset.

## Decisions still open (with the defaults the plan assumes)

1. Remote host: Neon (assumed; already in use for other projects), or self-hosted.
2. Transport: the coordinator and the phone talk to the hub directly over TLS (assumed for v1), or a small sync service sits in front of it.
3. First device beyond this Mac: the iPhone reading transcripts (assumed), or a second Mac.
4. Transcript cache: sync every display item including tool output (assumed; the data is small and bounded per item), or the index and turns with items fetched on demand.

## Proposed milestones

- **M7 Postgres store.** Fetched and bundled Postgres, the private cluster and its LaunchAgent, the storage rewrite on PostgresNIO behind the existing API, the single migrator with backups, the SQLite import, `db` CLI commands, trigger-written change log, schema documentation. Exit: the packaged app starts its cluster from nothing and from an imported `workspace.sqlite`; every existing test passes against Postgres; a migration leaves a dump behind; every synced write produces a change row.
- **M8 Multi-device sync.** Remote schema and migrator, device identity, direct Postgres sync, device-aware connections in the UI, the iOS companion reading the synced index and transcripts, conflict tests (two devices editing offline then converging), a secret-boundary audit of the sync path. Exit: two devices show one list; offline edits converge; no credential value crosses the wire except the Postgres credential itself over TLS.
