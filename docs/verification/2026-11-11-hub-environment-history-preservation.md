## 2026-11-11: Hub environment history preservation

This branch starts at `2834f8f755b23acf9af820816f76181954fd4123`. The guard and its two integration-test files were copied from the separately tested `dd997eeed459d69216e24369c9c1a16d60d0f115` worktrees. The only subsequent Rust change borrows a one-element string slice with `std::slice::from_ref` instead of cloning the string in a test. Current main also contains the no-folder-start change; its combined source still needs the full gates below. The frozen migration 18 remains SHA256 `2a7090851b9ae1ff34813a75829203eb41fd1bff364cc8c8dad107ed547b3b48`.

- Raw frozen-SQL regression: genuine PostgreSQL failure after structural and metadata controls, reporting that opaque JSON history changed. Native exit 101; the failed database and evidence were retained. Acceptance receipt SHA256 `f8585eca3bccc9ed5fb65415a6854bd76f24a7e077b8fb6740f1e9978922f0ec`.
- Public production-runner regression: genuine failure before the guard, followed by one passing guarded case on the earlier base. Guarded acceptance receipt SHA256 `0deda75a00f8f3b39843143d91c6bc14590377217b6ce6155142a9ea75df5a8e`.
- Eleven new real-PostgreSQL controls on the earlier base: 11 passed, 0 failed, 0 filtered. They cover two-organization isolation, original RLS/FORCE states, non-superuser ownership, application-role and ambiguous-value refusals, restore failure, deferred commit failure, writer ordering, concurrent migration and deferred-trigger collision rollback. Native exit 0; normal private database stop exit 0 after joined Rust and client absence. The independent source/resource acceptance is SHA256 `679e3ea889a3149d2de33fa183049463be582d345fd44126cf6457f20b68e02f`.
- The first ten-control attempt had 8 passes and 2 failures because its deferred trigger on `changes` collided with RLS DDL before reaching COMMIT. That attempt remains retained and unqualified. The corrected commit seam uses the ledger; a separate eleventh case verifies safe rollback of the original collision. No unchanged native retry or timeout increase was used.
- The first current-main delivery candidate passed formatting, then Clippy refused the unnecessary cloned string slice in the new test. The no-run build was not launched. Its source, private target and raw results remain unchanged; this successor contains the borrow-only correction. Independent source/resource audit SHA256 `a97e9d10a600cdde683df552e54cf212d23ea163ff05646652946a3b8545e228` records the failed candidate's normal joins and retained inputs.

Current-source local checks passed for the corrected 162-file Hub/fixture source map `82246cf0bfcbaae3565087bcca0962f2038fa52a0674fad88a5f98baf7762d49`:

- [x] `cargo fmt --all -- --check`.
- [x] `cargo clippy --workspace --all-targets --locked -- -D warnings`.
- [x] `cargo test --workspace --locked --offline --no-run --jobs 2` in a fresh private target. Actual Cargo JSON identified 27 test harnesses and the ordinary Hub binary; all 28 received independent hash-matched copies. This compiled the targets and ran no test bodies. Independent source, artifact and finite resource audit SHA256 `cce168d49fa094a26d975bbfbd10be1b41e01ac533553e8fd230ffbda1d2082f` accepted all three phases.
- [x] `swift format lint --strict --recursive Sources Tests Apps Package.swift`: 374 source/config inputs unchanged, no diagnostics. Independent audit SHA256 `fb08380a546ea949394df3c65297e834f87f57c002448c48dc7cff1915878c55`.
- [x] `Scripts/docs-index.sh --check`.

The final PR checkout carries the same 162-file compiled source map and Swift formatting inputs; only documentation and decision D-205 are added there. The qualification checkouts, raw streams, targets and artifacts remain unchanged.

Merge acceptance requires independent final review and green required CI checks on the exact PR source. The PR's full Hub job must run `cargo test --workspace --locked` against real PostgreSQL, including the original migration tests and all new controls. Swift package tests, App builds and the other required repository jobs remain CI gates; the local no-run build does not satisfy them.

Finite process observations and preserved input hashes support the recorded runs; they do not establish universal process drain or isolation. No passing Hub case qualifies the local Store, broader App client, already upgraded data or coordinated release. Existing workspace Store history still needs its own genuine production-runner failure and prevention guard. No speculative repair is performed.
