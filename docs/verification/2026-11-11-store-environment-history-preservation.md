## 2026-11-11: Store environment history preservation

### Causal regression

[Draft PR #176](https://github.com/cacheplane/b4app/pull/176) began as a regression-only change on `3cea9e216894b7bf3751dfd8829b6adf6a8408fb`. Its reviewed head was `7ad600f0881cff7016dbbceb9b5deb542121f256`. The CI merge checkout `d031bb1b3fc3aaae327314022001147e12b2a271` had the same tree (`5cbe18d1638b5df209f0cc45a2b77ec9bf1bc572`) as that head.

[CI run 43113221491, attempt 1](https://github.com/cacheplane/b4app/actions/runs/43113221491) completed. Formatting, PostgreSQL fetch and package build passed. The native package suite completed 1,587 tests in 195 suites with exactly one recorded issue: `environmentsRenameRunnerPreservesOpaqueJSONHistory()` reached its final preservation assertion and obtained `f` instead of `t`. The preceding structural and ledger controls passed. This establishes the preservation defect through the real migration runner. The six other CI jobs passed.

The package log also contains 33 SwiftNIO scheduling-after-shutdown diagnostics. Tests continued through the full suite footer and the normal failure exit. These diagnostics are retained as a separate lifecycle follow-up; this record does not attribute them to the Store regression or call the log error-free.

### Implementation qualification

D-206 specifies the migration runner guard and native regression matrix. Implementation and final exact-head CI qualification are in progress. No passing implementation, merge, app build, live account/device integration, coordinated protocol activation or release acceptance is claimed by this record yet.

### Scope of the evidence

The tests use the standard managed-CI PostgreSQL fixture and its existing shared-process cluster, fresh database allocation and best-effort exit cleanup. This is conventional product CI evidence, not proof of custom local process ownership, bounded shutdown or retained-database forensic guarantees. Earlier failed local build experiments are preserved separately and supply no executable qualification.

Already applied migration 11 cannot reconstruct discarded opaque keys without trustworthy preimages. Published migration 12 remains the app-folder migration. The Hub migration-18 prevention is independently documented in [its record](2026-11-11-hub-environment-history-preservation.md); neither change completes Agent Protocol client qualification.
