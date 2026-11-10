## 2026-11-06: Archive-only changes wake the phone mirror

The owner requested the archive background-wake fix, a PR merged on green, and a production TestFlight build to retest archiving from the Mac. Prior physical evidence remains in `2026-11-06-widget-background-catchup.md`: archived Phone push tests stayed visible in the background widget, then eventually disappeared from both app and widget after foreground sync. Exact propagation latency was not measured.

### Reproduction and implementation

The existing PostgreSQL push baseline passed all 29 cases. A new real-route regression created a quiet thread, archived it, verified the committed archive flag and accepted sequence, then failed with `timed out waiting for the archive refresh`. No alert or withdrawal existed to wake the phone. After adding the silent refresh message, that exact test passed (1 test, 0 failures).

Winning applied archive-column updates now select one refresh per eligible other phone per batch, unless that phone already receives an alert or withdrawal. Duplicate uploads, rejected/skipped/losing changes and unrelated metadata updates request no refresh. The selection occurs in the row transaction; sending remains after commit. Quiet threads do not need a notification-ledger entry.

The payload is an additive silent refresh; the existing iOS delegate uses its normal end-of-feed catch-up and widget reload. No HTTP route, database migration, entitlement or minimum OS change is needed. Core, database and sender fixtures cover delivery, redaction, recipient isolation and coalescing. Swift fixtures cover absence of navigation/withdrawal semantics; the file-backed widget test reads archive removal through the read-only path.

Independent design, plan and implementation reviews found no blocking issues. The implementation review advised that the all-covered overlap test does not independently protect every mixed-recipient permutation; recipient-specific HashSet filtering was reviewed directly. No test-only public API was added.

### Validation and release status

Swift package build passed. The full Swift suite passed 1,453 tests in 179 suites; the full hub workspace passed 504 tests with no failures or ignored cases. Strict recursive Swift formatting, Rust formatting, clippy with warnings denied, and Helm lint passed. Both native builds passed, including the iOS widget; documentation-index and whitespace checks passed. Strict Helm lint also passed for defaults and every chart CI values file. A shared-fixture test initially referenced a helper scoped to another test; that compile error was corrected before rerunning the full hub suite. Only observed completed checks will be recorded as passed.

Planned release: merge the reviewed PR only after green CI; publish hub-v0.5.1 with fresh chart 0.6.1 from the exact merge image, verify test and production deployment/readiness through the existing attested release workflow, and upload the clean merged production iOS build. Production hub digest, workflow results, Apple processing state and the physical archive retest remain pending.

The local native build stalled in Clang’s installed-SDK metadata probe (`Command::Print` blocked in `write`), matching the earlier archive I/O issue. Its PID and worktree were verified before interrupting only that build. The process-local compiler adapter was independently reviewed and validated against 12 exact metadata queries (three installed SDKs, C/C++, with and without arm64): byte-identical output, both sequential read orders over small sockets, and identical ordinary C/C++ objects. All non-metadata compilation delegates to the original compiler with unchanged arguments. No tracked compiler or signing configuration changed. Both native build retries completed successfully. The original compiler and signing configuration stayed unchanged; only the exact metadata query I/O was adapted for those processes. Evidence is retained under `.build/verification/2026-11-06-archive-background-wake/`. The worktree’s throwaway hub database was stopped after verification.
