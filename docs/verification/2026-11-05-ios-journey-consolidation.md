## 2026-11-05: iOS journey consolidation baseline

The approved navigation-first design preserves each existing UI behavior on every PR. The baseline
retains all 25 UI methods, 62 app launches, 69 layout checkpoints, three component methods, and the
existing deadlines. A new result contract requires all 131 scenario/checkpoint markers from actual
xcresult activities in addition to passing target counts. Local focused diagnostics cannot enable
that override in CI.

The readiness helper now waits for the existing positive-height/hittability condition within the
original 10-second layout bound (five seconds for the copy helper), rather than waiting only for
existence before immediately asserting visibility. The unchanged seven-surface method passed locally;
an actual hidden shipped-banner fault failed, and exact source restoration passed with 14/14 markers.
This does not establish a definitive cause for the previous hosted visibility failure.

Local full Swift testing passed 1415 tests in 171 suites. The actual full native result bundle
contains 25 passing UI tests, three passing component tests, and all 131 required markers.
The first wrapper invocation returned 2 after a mid-run authoring edit; that failure is retained.
The current reader independently verified the unchanged native inputs/results, and a fresh native
pilot invocation of the byte-identical stable wrapper passed. Hosted full-path validation is pending. No elapsed-time improvement or replacement-coverage equivalence is claimed yet.
All original UI entry points remain until additive native proof and review pass. Temporary source-only
CI validation refs run the existing four-job matrix; no publishing or deployment is authorized.

See the approved design and implementation plan under `docs/superpowers/` for the proof gates.
