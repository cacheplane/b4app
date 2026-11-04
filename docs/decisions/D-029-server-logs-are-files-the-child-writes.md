## 2026-10-31 (M4)

- **D-029 Server logs are files the child writes directly; the coordinator serves redacted tails on request and bounds the file by copy-truncate (4 MiB, keep the last 1 MiB).** Bearer values, `sk-…` keys, and `key|token|secret|password|authorization` pairs are masked before the text leaves the coordinator. Log lines are never published as events, so a chatty server cannot evict conversation events from the replay buffer; `--follow` and the GUI poll `server.logs` with the last offset.
