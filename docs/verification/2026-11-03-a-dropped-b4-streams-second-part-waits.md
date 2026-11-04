## 2026-11-03: A dropped B4 stream's second part waits for the reattach

A fixture-only change. No test or assertion changed. It fixes the first flake that "A parked B4 prompt is saved before the fixture discloses it" (below) leaves open.

- **`B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting`.** Under 10 CPU burners it failed at line 241 (`deltas(turnId: "turn-1") != "Part one. Part two."`), and in CI it timed out. `fake-b4.py`'s "drop" run closed the response and emitted "Part two." 1 s later. A reattach to a live run gets only frames emitted after it attaches, and a reattach after `done` gets `live: false` and none, so the test assumed the adapter's reattach (backoff 250, 500, 750 ms) landed within 1 s. Adding 1.5 s to that backoff reproduced it every time, at line 241. The real server behaves the same way: `RunControl::subscribe` (`crates/b4-http/src/control.rs`) hands a live attach a `state` cut and only later frames, and `attachment.rs` answers a finished run with `live: false` and `done { output: null }`. So the replay rules stay as they are, and the "drop" run now holds "Part two." until a reattach subscribes (20 s cap) instead of sleeping 1 s. With the same 1.5 s added, the test passes.

Runs (10 CPU burners, test bundle run 4 at a time through `swiftpm-testing-helper` so the runs share no SwiftPM lock):
- **Old fixture:** 0 failures in 100. The natural window is narrow; the added delay is the reproduction.
- **New fixture:** 0 failures in 200 (0.9 to 3.4 s each).
- **Suites:** `swift test --filter "B4AdapterTests|CoordinatorTests"` (346 tests) passed. An earlier pass failed `AccountManagerTests.hub401SignsOut` once with "The store is closed." (`AccountManagerTests.swift:410`). That test uses no fake B4 server, and it passed 3 times alone (open, not fixed here).
- **Gates:** `swift format lint --strict` is clean.
