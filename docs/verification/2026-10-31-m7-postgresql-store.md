## 2026-10-31: M7 PostgreSQL store

Target: the same MacBook Pro. PostgreSQL 17.11 from the pinned zonky build (`Scripts/fetch-postgres.sh`, SHA-256 verified against Maven Central's published checksum before extraction). The owner's running app was left alone; every live row below ran on scratch directories, including an import of a copy of the real `workspace.sqlite` with its `-wal` and `-shm` files.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 261 tests in 62 suites in 31 s, every suite now on a shared ephemeral cluster with a fresh database per test (`PostgresServerTests` 3, `SQLiteImportTests` 5, `ChangeLogTests` 2 new); one run saw a timing flake in `WorkspaceModelTests` that did not repeat |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass (the store and the server manager are macOS-only modules; the window background modifier is now platform-aware) |
| Package | `./Scripts/package.sh` | Pass: 119 MB app, 39 MB zip; the PostgreSQL tree under `Contents/SharedSupport/postgres` with every Mach-O signed; `codesign --verify --deep --strict` clean |

### Live on this Mac

| Scenario | How | Result |
| --- | --- | --- |
| Bundled cluster from the packaged app | `open -n dist/Agent Workspace.app` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` (the registered agent serves the real directories, so this instance hosted in-process) | `coordinator status` running 0.1.0; `doctor` reported `postgresql:///workspace?host=<runtime dir>&port=5432`; `postgres -D <data dir>/pg` ran from `Contents/SharedSupport/postgres/bin`; the socket and its lock sat in the runtime directory; `PG_VERSION` and the cluster tree under the data directory. |
| Cluster lifetime | SIGTERM to that app instance, then `pg_ctl stop` by hand | A SIGTERM is not an orderly quit, so the owned cluster stayed up (adopt-on-next-start, by design); a CLI-spawned coordinator stopped with `coordinator stop` took its cluster down with it. |
| Import of the real store | Copy of `~/Library/Application Support/b4app/workspace.sqlite{,-wal,-shm}` into a scratch data directory; `db status` through a CLI-spawned coordinator | Imported in one transaction: 2 connections (Codex authenticated, Claude mid-login as on the real store), 1 thread, 1 turn, 5 display items, 1 draft, 1 server registration; `connection list`, `thread list`, `server list` showed them; the three files renamed `.imported`; `db import-sqlite` on the retired file: "nothing imported (the store already holds data)". The first attempt, without the `-wal` and `-shm` copies, found two defects now fixed: a read-only open of a WAL-mode file fails, and an import error trapped the coordinator at top level and left the freshly started cluster running. |
| Backup and restore | `db backup`; `db restore <archive>`; `db restore --replace <archive>`; `db status` | 21 rows written (mode 0600, header with format, time, and applied migrations); restore refused on a non-empty store with the `--replace` hint; replace restored 21 rows and left the change log at the archive's 10 entries (the first run doubled it because the log was silenced after the clearing, now before). |
| Schema and status | `db status`, `db migrate` | `0001_init, 0002_changes`; row counts per table; unsynced change count; backups folder. |

### Open after M7

- Device identity, the hybrid logical clock, and sync itself (M8); the hub schema's tenant and user columns.
- Developer ID signing: executables under `SharedSupport` are sealed as resources, which an ad hoc build accepts and notarisation would not; the tree moves to a nested-code layout when a certificate exists.
- A major-version move (export, new cluster, import) has not been exercised; the bundled version is pinned.
- `docs/schema.md`.
