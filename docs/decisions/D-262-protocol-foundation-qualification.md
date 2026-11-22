## 2026-11-19 (protocol foundation qualification)

- **D-262 Keep everyday CI aligned with main and qualify the protocol foundation separately before merge (amends D-240, D-245 and D-260).**

D-259 shipped the turn fields at Store16, Hub23 and Mirror11. Keep those migrations intact. The protocol foundation follows at Store17 and Hub24. Mirror12 is reserved for future protocol storage. Format-3 Store16 archives retain the turn fields across restore. The format-4 generation marker starts at Store17.

The phone advertises client protocol 1 over HTTP and relay while its mirror lacks protocol storage. The coordinator can advertise 2. A hub requiring client protocol 2 must refuse the older mirror before it can consume sync work.

Everyday CI follows main. Add regression tests for externally observable protocol behavior, storage migrations, account isolation and ownership transitions. Keep each test that needs PostgreSQL focused on behavior that requires the native database.

Before merging PR 180, run the storage and coordinator suites at width two and serially on the same revision as everyday CI. Qualification also checks that other modules cannot construct restricted owner and proof values. Retire the PR-specific workflow and compiler probes after merge. Runtime rollout remains separately gated. See the [test commands](../../README.md#protocol-qualification).
