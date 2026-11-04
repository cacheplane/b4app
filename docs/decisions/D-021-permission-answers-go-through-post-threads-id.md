## 2026-10-31

- **D-021 Permission answers go through `POST /threads/:id/resume` with B4's own decisions.** `allow_once` → `once`, `allow_always` → `always` (B4 persists the pattern itself, unlike Claude in D-018; `once` when the prompt said `allowAlways: false`), `deny` → `deny`, decline → `status: cancelled`, each echoing the prompt's `grant`. The resume response is a second SSE stream that continues the same turn and item numbering. Stop on a parked turn declines the prompt, because nothing else can end it.
