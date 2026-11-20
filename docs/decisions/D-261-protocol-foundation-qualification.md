## 2026-11-19 (protocol foundation qualification)

- **D-261 Keep everyday CI aligned with main and qualify the protocol foundation separately before merge (amends D-240 and D-260).**

D-259 shipped the turn fields at Store16, Hub23 and Mirror11. Keep those migrations intact. The protocol foundation follows at Store17 and Hub24. Mirror12 is reserved for future protocol storage. Format-3 Store16 archives retain the turn fields across restore. The format-4 generation marker starts at Store17.

The phone advertises client protocol 1 over HTTP and relay while its mirror lacks protocol storage. The coordinator can advertise 2. A hub requiring client protocol 2 must refuse the older mirror before it can consume sync work.

Everyday CI follows main. Before merging PR 180, run its separate qualification against the same head and base as the everyday checks. The temporary workflow retains focused compiler and publication checks, bounded database cases and serial qualification. After merge, retire the PR-specific workflow and its test scaffolding in a follow-up. Keep regression coverage for released data, archive restore and client compatibility. Runtime rollout remains separately gated.
