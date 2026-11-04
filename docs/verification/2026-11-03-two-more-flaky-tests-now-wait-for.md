## 2026-11-03: Two more flaky tests now wait for what they depend on

Test-only changes. No assertion is weaker.

- **Rust `instances::readiness_reports_a_stale_heartbeat`.** The `settle()` fix above covered the pause. CI then failed the test's *first* `/readyz` (503 where 200 was expected, run 41553837650). With the test's 200 ms beat, the liveness window is 800 ms. A loaded runner can stall the heartbeat writes for longer than that, so the instance already reports `"instances": "stale"` before anything is paused. Reproduced locally (`"instances":"stale"`, 1 run in 15 of the `instances` binary under 30 CPU burners). The test now waits (`eventually`) for a fresh heartbeat before it pauses, as its last step already did. The probe test in the same file (`the_probe_passes_…`) asserts `"instances": "ok"` with the same window, so it now runs on the default 5 s heartbeat; it is about the relay, not the heartbeat.
- **`LifecycleTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`.** The fake B4 "slow" run ends on its own after 3 s. The test needs that end to happen after `h.stop()`. Under load, the stop took longer (the CI run took 44 s), so the first coordinator saw the run finish and marked the turn `terminal` (`SessionTests.swift:1216`, run 41561882799). A 4 s pause before `h.stop()` reproduced it every time. `fake-b4.py` has a new "held" run that ends only on `POST /threads/<id>/release`, a fixture control. The test releases the run once the coordinator is down, and still passes with that 4 s pause.

Runs:
- **Rust:** 15 alone. 25 of the whole `instances` binary under 30 CPU burners. 10 alongside a parallel `cargo test --workspace`, which passed.
- **Swift:** 10 alone. 10 inside `swift test --filter CoordinatorTests` (297 tests each, all passing), 5 of them with 12 CPU burners.
- **Gates:** `swift format lint --strict`, `cargo fmt --check` and `cargo clippy -D warnings` are clean.

Environmental, not this flake:
- `#[sqlx::test]` names each test's database by hashing its path. Two processes running the same test on one server drop each other's database ("database … does not exist", or a failed `Db::connect`).
- `test-db.sh --stop` from another worktree ends every run on port 54329.
- These runs used private clusters on other ports.
