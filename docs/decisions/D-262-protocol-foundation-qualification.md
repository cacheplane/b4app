## 2026-11-19 (protocol foundation qualification)

- **D-262 Keep everyday CI aligned with main and qualify the protocol foundation separately before merge (amends D-240, D-245 and D-260).**

D-259 shipped the turn fields at Store16, Hub23 and Mirror11. Keep those migrations intact. The protocol foundation follows at Store17 and Hub24. Mirror12 is reserved for future protocol storage. Format-3 Store16 archives retain the turn fields across restore. The format-4 generation marker starts at Store17.

The phone advertises client protocol 1 over HTTP and relay while its mirror lacks protocol storage. The coordinator can advertise 2. A hub requiring client protocol 2 must refuse the older mirror before it can consume sync work.

Everyday CI follows main and exercises representative protocol behavior using Swift Testing’s standard executor for ordinary cases. The writer and activation storage suites each serialize their own cases and provide an executor for blocking SQL. Qualification retains the per-case scheduling used for the full matrix. The exhaustive fault, contention and probe timing cases are opt-in with `B4APP_PROTOCOL_FULL_MATRIX=1`. That flag also enables the per-case native executor. The full matrix remains runnable on a developer Mac after merge. See the [test commands](../../README.md#protocol-qualification).

PR 180 requires the full matrix before merge. Run the separate qualification on the same source as everyday CI. Retire the PR-specific workflow, scheduling checks and compiler investigation scaffolding after merge. Keep the opt-in cases and the everyday regression tests. Runtime rollout remains separately gated.
