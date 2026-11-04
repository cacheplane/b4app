## 2026-10-31

- **D-019 A B4 turn's native id is its ordinal in `GET /threads/:id/turns`.** The Agent Protocol has no run id (the thread id is the run identity). Reading the turn count before `POST /runs/stream` and naming the turn `turn-<n+1>` lets reconciliation tell "the server ran it" (the nth turn exists, with its recorded status) from "the prompt never arrived" (it does not) without ever resubmitting. When the count cannot be read the id falls back to `run-<uuid>` and reconciliation relies on the thread status alone.
