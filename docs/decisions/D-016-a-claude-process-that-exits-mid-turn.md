## 2026-10-31

- **D-016 A Claude process that exits mid-turn ends that turn as `failed`.** Unlike Codex, where the app-server owns the thread and a turn's final status can be read back, nothing continues once the `claude` process is gone, so the adapter emits `turn.finished failed` with the exit status, and `reconcile` after a coordinator restart reports `failed` for a turn with no live process. The disconnect is scoped to that thread; the connection and other threads are untouched.
