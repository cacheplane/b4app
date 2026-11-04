## 2026-10-31 (M4)

- **D-030 `server stop` and `server restart` refuse with `owned_process_conflict` (`reason: turn_active`) while a route connection has a turn in `submitting`, `running`, or `stopping`, unless forced**, because stopping loses the in-memory run. A parked prompt is durable in `.b4` and a `reconciling` turn is already lost, so neither blocks. The CLI takes `--force`; the GUI confirms. The M5 Quit dialog builds on the same check.
