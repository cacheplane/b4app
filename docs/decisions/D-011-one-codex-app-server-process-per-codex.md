## 2026-10-30

- **D-011 One `codex app-server` process per Codex connection, started lazily and kept alive while the coordinator runs.** The adapter generation increments on every restart; pending runtime requests from an older generation expire and running turns become `reconciling` with an unknown outcome until the thread is reopened. A process exit is never read as a turn outcome.
