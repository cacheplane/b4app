## 2026-10-31

- **D-023 Route kinds other than `agent` are stored as `incompatible` connections with an explanation.** Only `agent()` routes take the `input.messages` shape; `workflow`, `graph`, and `chain` routes are accepted at `connection add`, inspected, and reported, never run.
