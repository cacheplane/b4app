# Postgres store and multi-device sync: plan outline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SQLite store with a private Postgres cluster on every Mac (bundled, pinned, on a Unix socket), one migrator for the cluster and a remote Postgres hub, then sync the workspace index and transcripts through the hub so several devices show one workspace (D-041).

**Architecture:** The coordinator remains the only process that opens the store; `WorkspaceDatabase` keeps its API and is reimplemented on PostgresNIO. A `PostgresServer` manager owns the cluster when launchd does not. Versioned SQL files drive both ends. Triggers write the change log; the coordinator replicates it to the hub over TLS.

**Tech Stack:** PostgreSQL 17 (pinned binaries), PostgresNIO, SQL migrations, hybrid logical clocks, `pg_dump`/`pg_upgrade`.

**Spec:** `docs/superpowers/specs/2026-10-31-storage-and-sync-design.md`.

## Global Constraints

- The cluster listens only on a Unix socket in the runtime directory; `listen_addresses = ''`; data directory mode 0700.
- Secrets never enter the database, the change log, or arguments; the hub credential is a Keychain reference.
- Migrations are forward-only, versioned, transactional, with a `pg_dump` before every local migration; the hub migrates only from a Mac on an explicit command.
- Every existing test keeps passing; tests boot an ephemeral cluster from the fetched binaries, never from a machine install; CI fetches the same binaries.
- The UI never touches the database; the coordinator is the only writer; ownership rules for the server process are those of D-025.

## Review Focus

1. First launch on a Mac with an existing `workspace.sqlite`: import must be complete and idempotent (rerun does nothing).
2. The coordinator starting while launchd is still bringing the cluster up: wait, never start a second server on the same data directory.
3. A crashed server leaving `postmaster.pid`: start must recover, not refuse forever.
4. A migration that fails halfway: the transaction rolls back and the dump is still there.
5. Two devices editing the same title offline: the later hybrid clock wins on both after sync.

---

## M7: Postgres store

### Task 1: fetch and bundle the server
`Scripts/fetch-postgres.sh` (pinned version and sha256, extracts to `.build/postgres`, writes `LICENSE`s); `Scripts/package.sh` copies the tree to `Contents/Helpers/postgres` and signs each binary; `docs/compatibility.md` records the version. Verify: `.build/postgres/bin/postgres --version`; the packaged app's helpers verify with `codesign`.

### Task 2: `PostgresServer` manager
`Sources/WorkspacePlatform/PostgresServer.swift`: `initdb` on first start, `start/stop/status`, socket path in the runtime dir, `postmaster.pid` recovery, ownership by pid plus start time plus argv, log bounding. Tests: `PostgresServerTests` boot a cluster in a temp dir, restart it, recover from a stale pid file.

### Task 3: migrator and schema
`Sources/WorkspaceStorage/Migrations/0001_init.sql` (today's v3 schema, each table marked local, hub, or both), `Migrator` with `schema_migrations`, `pg_dump` before apply. Tests: fresh cluster migrates; rerun is a no-op; a failing migration rolls back and keeps the dump.

### Task 4: `WorkspaceDatabase` on PostgresNIO
Same public API, SQL bodies; `WorkspaceDatabase.temporary()` becomes a database on the shared test cluster (one database per test). Run the whole suite; fix what the dialect changes (booleans, timestamps, `RETURNING`, upserts).

### Task 5: coordinator wiring and the second LaunchAgent
`Coordinator.start` opens the cluster through launchd's agent when the bundle has it, else through `PostgresServer`; `coordinator plist` gains the Postgres agent; `package.sh` writes both plists; `CoordinatorHost` waits for the cluster. Live check: packaged app from nothing, Quit, relaunch, `coordinator status` shows both agents.

### Task 6: import from SQLite
`SQLiteImporter` (reads the old file with the system `sqlite3` library through a minimal wrapper, no GRDB), runs once at start when `workspace.sqlite` exists, renames it `.imported`; `agent-workspace db import-sqlite <path>`. Tests: import the M5 fixture database; a second run changes nothing.

### Task 7: `db` CLI and backups
`agent-workspace db status|migrate|backup|restore <dump>`; backups under the data directory, bounded in count. Tests through the CLI harness.

### Task 8: change log by triggers
Migration `0002_changes.sql`: `devices`, `changes`, triggers on the synced tables, `HybridClock` in `WorkspacePlatform` supplying the clock value per transaction. Tests: every mutating method yields rows; replay onto an empty database reproduces the tables.

### Task 9: docs and acceptance
`docs/schema.md`, README (data directory, backups, upgrade), `docs/verification.md` M7 record.

## M8: multi-device sync

### Task 10: hub schema and remote migrator
`db remote migrate` against the hub with the hub subset of the same files; the connection string comes from a Keychain reference.

### Task 11: device identity and hub credential
Device id and name in the Keychain and `devices`; `credential add` for the hub; a reachability and schema-version check without reading data.

### Task 12: sync engine
`SyncService` actor: pull since the remote cursor, apply with LWW per column, push since the local cursor; on a timer, after writes, on wake; offline queues. Tests: two coordinators, one hub, offline edits converge, tombstones delete, append-only tables never conflict.

### Task 13: device-aware connections
Connections owned elsewhere are read-only with their device name; remote B4 connections prompt for the credential reference on a new device.

### Task 14: iOS reads the hub
The iOS app reads the hub directly (or through the sync service if that transport is chosen), shows the list and transcripts, says which threads can be continued from the phone.

### Task 15: audit and acceptance
Secret-boundary audit of the sync path; the exit gates in the design recorded in `docs/verification.md`.
