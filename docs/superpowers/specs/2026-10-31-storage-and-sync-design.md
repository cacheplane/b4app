# Storage and multi-device sync (brainstorm, awaiting the owner's decisions)

Date: 2026-10-31. Status: proposed. Brian asked for a more robust database with proper migrations, Postgres, and a local store that syncs with a remote so the workspace works across devices. This document lays out what the data is, what can and cannot follow a person between devices, the options, a recommendation, and the decisions only the owner can make. Nothing here is built.

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

## Options for the local store

1. **Local Postgres on each Mac, Postgres remote.** A second daemon per Mac (Postgres.app or Homebrew, or binaries bundled into the app with their own LaunchAgent and `pg_upgrade` on major versions); impossible on iOS, which would become a thin client of the remote; Postgres-to-Postgres bidirectional sync is not built in (logical replication is one way; multi-master needs BDR-class tooling or a change log of our own anyway). Gain: one SQL dialect and one migration toolchain on both ends.
2. **SQLite local (as now), Postgres remote as the hub.** Embedded, zero operations, offline first, the same code on iOS. Cost: two schemas kept in step and a sync protocol we own.
3. **A sync engine on top of option 2.** PowerSync (Postgres to SQLite replicas, writes through our own backend, Swift SDK), ElectricSQL (Postgres shapes to clients, TypeScript first), Turso/libSQL embedded replicas (remote primary is SQLite, not Postgres), CloudKit (Apple only, no Postgres). Each adds a service or a vendor between the devices and the data.
4. **Remote only.** Every read and write goes to Postgres. Breaks offline use and the coordinator's own need for a local store while a turn runs. Rejected.

## Recommendation

Option 2, with Postgres as the single remote truth for synced data: SQLite stays the device store (GRDB, on macOS and iOS), Postgres on Neon (already in use for other projects) is the hub, and sync is a change log replicated both ways by the coordinator (and, later, read by the iOS app). Why not Postgres locally: it adds a daemon and an upgrade path to every Mac and buys nothing a single-user embedded store needs; the robustness Brian is after comes from migrations, backups, and tests, which SQLite supports as well as Postgres does. If the owner still prefers Postgres on the Mac, option 1 is feasible with bundled binaries and a second LaunchAgent; the sync design below is the same either way, because the change log is what moves, not the engine.

### Sync model

- **Change log.** Every write to a synced table also appends a row to `changes(id, device_id, hlc, table, row_id, column, value, deleted)`. A hybrid logical clock orders changes across devices; last writer wins per column. Turns and display items are append-only facts keyed by their origin, so they never conflict; titles, pins, archive, and drafts are per-column LWW; deletes are tombstones.
- **Transport.** The coordinator speaks to Postgres directly over TLS with PostgresNIO (pure Swift, runs on iOS too), using a per-device credential stored through `credential add`, never in the database or arguments. Pull, then push, on a timer, after local writes, and on wake. Offline queues and converges later. A thin sync service (a B4 route, say) can replace the direct connection later without changing the log.
- **What syncs.** threads, turns, display items, drafts, and connections *as descriptions* with their owning device: a Codex connection owned by Brian's MacBook appears on the phone as read-only "on MacBook Pro"; a B4 remote connection is usable on any device that holds the credential reference and prompts to add it otherwise. Runtime requests sync read-only (answering stays on the owning device until the relay exists).
- **What never syncs.** Secrets, executable paths, pids, ports, sockets, log paths, process identities, local server registrations, the event log, diagnostics.
- **Identity.** A device id generated once and kept in the Keychain; a device name shown in the UI; the remote keeps a `devices` table.

### Migrations, both ends

- Local: keep GRDB's forward-only migrator, add a schema-version check at coordinator start, an automatic copy of the database file before any migration (`workspace.sqlite.pre-v4`), and `agent-workspace db status|migrate|backup`.
- Remote: SQL files in `Sources/WorkspaceStorage/Remote/migrations/NNNN_name.sql` applied in order inside a transaction by a migrator in the package (a `schema_migrations` table), run by `agent-workspace db remote migrate`, never automatically from a phone.
- A test asserts that the synced tables' columns match on both ends, so the two schemas cannot drift silently.

## Decisions for the owner

1. Local store: SQLite with a Postgres hub (recommended), or Postgres on every Mac as well?
2. Remote host: Neon, or something self-hosted?
3. Transport: the coordinator talking to Postgres directly, or a small sync service in front of it?
4. First device beyond this Mac: a second Mac, or the iPhone reading transcripts?
5. Transcript cache: sync every display item (tool output included), or the index and turns with items fetched on demand?

## Proposed milestones

- **M7 Storage hardening.** Migration tooling and backups, `db` CLI commands, schema documentation, a drift test between local and remote schemas, the change-log table populated locally (no network yet). Exit: a migration from a copied real database with a backup present; every write produces a change row; tests cover replay.
- **M8 Multi-device sync.** Remote schema and migrator, device identity, direct Postgres sync, device-aware connections in the UI, the iOS companion reading the synced index and transcripts, conflict tests (two devices editing offline then converging), a secret-boundary audit of the sync path. Exit: two devices show one list; offline edits converge; no credential value crosses the wire except the Postgres credential itself over TLS.
