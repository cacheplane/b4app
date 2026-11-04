## 2026-10-31 (M4)

- **D-027 A registration allocates its loopback port once (or takes `--port`) and keeps it, so route connections have a stable origin; a start whose port is taken fails with `owned_process_conflict` and stops nothing.** The port cannot change once a route connection references the server, because managed connections carry `http://127.0.0.1:<port>` as their target and threads use that origin as their native scope.
