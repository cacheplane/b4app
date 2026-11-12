## 2026-11-11: Store environment history preservation

### Causal regression

[Draft PR #176](https://github.com/cacheplane/b4app/pull/176) began as a regression-only change on `3cea9e216894b7bf3751dfd8829b6adf6a8408fb`. Its reviewed head was `7ad600f0881cff7016dbbceb9b5deb542121f256`. The CI merge checkout `d031bb1b3fc3aaae327314022001147e12b2a271` had the same tree (`5cbe18d1638b5df209f0cc45a2b77ec9bf1bc572`) as that head.

[CI run 43113221491, attempt 1](https://github.com/cacheplane/b4app/actions/runs/43113221491) completed. Formatting, PostgreSQL fetch and package build passed. The native package suite completed 1,587 tests in 195 suites with exactly one recorded issue: `environmentsRenameRunnerPreservesOpaqueJSONHistory()` reached its final preservation assertion and obtained `f` instead of `t`. The preceding structural and ledger controls passed. This establishes the preservation defect through the real migration runner. The six other CI jobs passed.

The package log also contains 33 SwiftNIO scheduling-after-shutdown diagnostics. Tests continued through the full suite footer and the normal failure exit. These diagnostics are retained as a separate lifecycle follow-up; this record does not attribute them to the Store regression or call the log error-free.

### Implementation qualification

[CI run 43129542893, package job 130890537341](https://github.com/cacheplane/b4app/actions/runs/43129542893/job/130890537341) completed successfully for PR head `8edd2c0d6cb88e2e1f0a5f87eebd47c7cff4fe02`: 1,606 tests in 196 suites passed with zero recorded issues in 180.150 seconds. The unchanged original preservation regression passed. All 19 new methods passed, including five methods with two cases each: 24 cases in total (one pure resource check and 23 native PostgreSQL cases).

The native matrix covers opaque/structural values and precision, enabled but inactive RLS flags, active filtering refusal, namespace/TEMP/type/ledger admission, ambiguous structural references, suppressed ledger/structural writes and unintended feed mutation, restore and deferred COMMIT faults, fixed application-error privacy, already-applied/no-repair history, future versions, per-file rollback/recovery, RC/RR writer inclusion and constructor serialization through COMMIT 11 and 12. Twenty cases use the public constructor; three session-specific TEMP/RLS cases use the labelled internal raw migration path. The original regression supplies an additional public-constructor control. Native BEGIN/transport/unlock edge faults are not claimed covered.

The executed checkout was synthetic merge `d1eca4759a236ddcdcf5c94070a72ca239ce9f77`, with tree `00af1f1f6afe156950ea4f002772d1a8e805d4fe` and parents official main `903e317e0afe8bcfc808c95f4fb288e4287f99c7` and reviewed head `8edd2c0`. Its entire tree differs from the head because main advanced; all nine owned PR file blobs were verified identical in the tested tree. The native log SHA256 is `c5e884f96bd43d2aee3715c96bc492e07dd7c88d70f1aa3c52807eba55d919ec`.

That successful log retains 14 nonfatal SwiftNIO scheduling-after-shutdown diagnostics. Zero test issues does not mean an error-free diagnostic log; the lifecycle follow-up remains separate. Final merge acceptance requires all seven CI jobs on the final PR head, available through [PR #176 checks](https://github.com/cacheplane/b4app/pull/176/checks). The final branch also incorporates main `2c71ec3`'s packaging changes; the Store production files, tests, published SQL and original regression remain unchanged. This record supplies no live account/device, coordinated protocol activation or release acceptance.

### Scope of the evidence

The tests use the standard managed-CI PostgreSQL fixture and its existing shared-process cluster, fresh database allocation and best-effort exit cleanup. This is conventional product CI evidence, not proof of custom local process ownership, bounded shutdown or retained-database forensic guarantees. Earlier failed local build experiments are preserved separately and supply no executable qualification.

Already applied migration 11 cannot reconstruct discarded opaque keys without trustworthy preimages. Published migration 12 remains the app-folder migration. The Hub migration-18 prevention is independently documented in [its record](2026-11-11-hub-environment-history-preservation.md); neither change completes Agent Protocol client qualification.
