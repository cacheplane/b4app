# Storage hardening and multi-device sync: plan outline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the local store (migrations, backups, tooling) and sync the workspace index and transcripts through a Postgres hub so several devices show one workspace.

**Architecture:** SQLite stays the device store behind the coordinator; a change log records every synced write; the coordinator replicates the log to and from Postgres over TLS; the iOS app reads the same synced data.

**Tech Stack:** GRDB, PostgresNIO, SQL migration files, hybrid logical clocks.

**Spec:** `docs/superpowers/specs/2026-10-31-storage-and-sync-design.md` (awaiting the owner's five decisions; tasks below assume the recommendation).

## Global Constraints

- Secrets never enter the database, the change log, or the wire; the Postgres credential is a Keychain reference.
- Migrations are forward-only, versioned, applied in a transaction, with a file backup before any local migration.
- The UI never touches the database or the network; only the coordinator syncs on macOS; the iOS app reads through its own client once the transport decision is made.

## M7: storage hardening

### Task 1: migration safety
Create `Sources/WorkspaceStorage/MigrationSafety.swift`; modify `WorkspaceDatabase`. Before applying pending migrations, copy the database file to `<name>.pre-vN` and record the backup path in diagnostics. Tests: a v3 fixture database migrated to v4 leaves `workspace.sqlite.pre-v4`.

### Task 2: `db` CLI commands
`agent-workspace db status|migrate|backup` in `Sources/AgentWorkspaceCLI/DatabaseCommands.swift`. Tests through the CLI harness.

### Task 3: change log
Migration v4 adds `changes` and `devices`; `WorkspaceDatabase` writes a change row for every synced-table write; `HybridClock` in `WorkspacePlatform`. Tests: every mutating method on threads, turns, display items, drafts, connections appends rows; replaying the log onto an empty database reproduces the tables.

### Task 4: schema documentation and drift test
`docs/schema.md` generated from the live schema; a test that the synced columns in the local schema match `Remote/migrations`.

## M8: multi-device sync

### Task 5: remote schema and migrator
`Sources/WorkspaceStorage/Remote/migrations/0001_init.sql`; `RemoteMigrator` with `schema_migrations`; `agent-workspace db remote migrate`. Tests against a local Postgres in CI only when `B4APP_TEST_POSTGRES_URL` is set (never required).

### Task 6: device identity and credential
Device id in the Keychain, device name, `credential add` for the Postgres URL; `connection`-style inspection that checks TLS and the schema version without reading data.

### Task 7: sync engine
`SyncService` actor in the coordinator: pull since the last remote cursor, apply with LWW per column, push local changes since the last push, on a timer, after writes, on wake. Tests with two coordinators and one Postgres: offline edits converge; tombstones remove; append-only tables never conflict.

### Task 8: device-aware connections in the UI
Connections owned elsewhere show their device and are read-only; remote B4 connections prompt for the credential reference on a new device.

### Task 9: iOS reads the synced workspace
The iOS app opens the synced data read-only (transport per the owner's decision), shows the thread list and transcripts, and says plainly which threads can be continued from the phone.

### Task 10: audit and acceptance
Secret-boundary audit of the sync path; the exit gates in the design document recorded in `docs/verification.md`.
