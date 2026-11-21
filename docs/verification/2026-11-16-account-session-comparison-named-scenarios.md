## 2026-11-16: Account-session comparison named scenarios

### Observed source F3 snapshot: CI completed, qualification withheld

**UNQUALIFIED.** [Run 44027186219, attempt 1](https://github.com/cacheplane/b4app/actions/runs/44027186219/attempts/1) naturally completed **FAILURE: 7 successful jobs, 4 failed, 0 cancelled**. This snapshot binds [source F3](https://github.com/cacheplane/b4app/commit/f3fef4188c785d2e76e1d5cb2a4f10cf655c3630), tree `935cdec760b27d3fe72a8298ebf1c8bdac1a9ca2` (1,427 files), to tested synthetic merge `6f65d42369a7e9b97bc5a4032aa42fa2c9c9cee7`, whose parents are `da8b4cf4b04a968a46908aa0f7919d42a2e1c196` and F3. It does not qualify a later head.

All **23 new B17/B18 scenarios and all 41 native methods PASS** in default, focused and serial contexts. The broader selected source population is 127 = 41 native + 86 companions: **default 125 PASS / 2 FAIL; serial 127 PASS**. Focused companion success comes from three actual lanes (carrier 16, selected writer 53, publication 17), separately from focused native 41; these are not one focused invocation of all 86. The physical writer 55 PASS in default, dedicated focus and serial, separately from selected writer 53. Individual parameter terminal outcomes were not printed or inferred.

The authoritative default failures in `HubOwnerCarrierTests` are `actualCurrentLinkedScopeIssuesRedactedOriginalCarrier` and `childIsRegisteredBeforeLaunchAndCannotAdoptReplacement`. Each has a 10-second observation-deadline guard issue, setup-failure issue and caught `.failed` error issue, followed by one failed family terminal: six issues total across the two families, already within the package's 121 issues. The evidence cannot identify which await in `refreshJoined` → `failed` caused the delay. Focused/serial success does not override default. No runtime, performance or root-cause claim, budget relaxation or new gate criterion follows. [D-245](../decisions/D-245-account-session-comparison-scenarios-have-independent-test-budgets.md)'s exact operations, joins, assertions, cleanup, limits and fixture bodies remain preserved; owner, helper and workflow pins remain as recorded below.

C6 is package-only: **33 receipts / 11 profiles / 11 summaries**; serial adds zero. ABI, import, freshness, semantic canonicalization, physical-quiescence and HTTP qualification flags remain **FALSE / HELD**. Raw compiler diagnostics, expanded temporary vectors, description bytes and runner-module bytes were not preserved; receipt hashes do not permit independent recomputation. All 69 native owner fixture chains / 4,323 markers have complete source phase order, monotonic elapsed values and stable indices. Raw-line event-order gaps (15 focused, 19 serial) are documented practical limits, without physical-escape or causal inference. No numeric effect snapshots were printed.

Keep failure domains separate. Twelve physical Swift runs contain 4,022 family observations = 3,876 PASS + 131 FAIL + 15 SKIP, with 166 issues. Current **181 issue/skip observations = 166 issues + 15 skips** remain OPEN, separately from the **2,160 prior observations = 2,061 issues + 99 skips**, also OPEN. Their additive 2,341 Swift issue/skip records are not unique tests and exclude other frameworks. Python is 37 = 36 PASS / 1 FAIL (workflow-boundary guard); macOS smoke is 5 = 4 PASS / 1 FAIL / 0 SKIP (historical/read-only B4 fixture). Actual iOS tests: 3 PASS; two Debug app builds PASS; Rust 594 PASS; aimock 14 PASS. All failures/history remain OPEN; full CI remains red.

### Test-only CI boundary followup

The correction in [Scripts/tests/test_ci_scope.py](../../Scripts/tests/test_ci_scope.py) separates every actual job boundary before projecting the unchanged ten ordinary jobs. Original cache-policy assertions, the four ordinary macOS expectations, workflow, runtime and native budgets remain exact. Three authored regressions cover adjacent hyphenated diagnostic jobs and nested/root limits, fail-closed inputs, and an actual in-memory package cache violation invoking the unchanged policy. The existing managed RED supports only this boundary defect; no new regression RED or local GREEN is claimed. Fresh managed validation is recorded separately in [PR 180](https://github.com/cacheplane/b4app/pull/180); this F3 snapshot neither predicts its result nor transfers qualification.

**STOP_FROZEN / UNQUALIFIED; all holds HELD.** PR 180 remains draft, without auto-merge or merge-queue entry. Release, SDK PR 1131, npm publication, coordinated activation and new production deployment remain HELD, as do P2c/Q01, startup, real HTTP, endpoint handoff, sync and checked-link effects. There is no blanket waiver or qualification transfer. The following pre-CI design is retained verbatim as historical evidence; its pending-CI wording is not current run status.

### Reviewed design before execution (historical)

Status: **UNQUALIFIED — managed CI pending**. This record describes the reviewed pre-CI named-scenario source inputs; no new CI run, pass or native qualification is claimed. [D-245](../decisions/D-245-account-session-comparison-scenarios-have-independent-test-budgets.md) records the owner-approved one-minute budget for each of 23 ordinary named scenarios. A logical B17 or B18 group may take longer. The [implementation plan](../superpowers/plans/2026-11-16-account-session-comparison-named-scenarios.md) is an exact historical checkbox-plan copy; its checkboxes are not current completion evidence.

The integration baseline is `bb6a137c3dff01942116e7c1c7a6047425f428c6`, tree `e98bcd6e2b9f80cde273447e9f8efe7377ed57a5`, with 1,424 files. It merges feature `deb4a6cc4e4c56597ddff1d5acdd2122c7013a45` and accepted main `da8b4cf4b04a968a46908aa0f7919d42a2e1c196`. It retains D-242 merge-queue policy and D-244's current CI scope: two debug app builds, one layout job and five smoke tests, together with protocol controls and PR 180's unchanged serial diagnostic.

| Candidate file | Bytes | SHA256 |
| --- | --- | --- |
| [AccountSessionComparisonOwnerTests.swift](../../Tests/CoordinatorTests/AccountSessionComparisonOwnerTests.swift) | 58,782 | `1f137aa6aafbb44a0f5c50f689588b7c89ef71ce1059ab15d93e857d5b6f2f56` |
| [check-owner-carrier-compiler-controls.py](../../Scripts/check-owner-carrier-compiler-controls.py) | 66,647 | `f15bee984d191efb642e349cadf535581ad9669bb0d1e5a54044ab4c32aa12e6` |
| [ci.yml](../../.github/workflows/ci.yml) | 78,346 | `8ec09d21b1561afe781ecac1866cdde8bf10085d929f8d2e86e7392e663232bd` |

The two grouped methods are removed in the candidate. Each of the following 23 ordinary named methods inherits the serialized suite's one-minute test limit and has independent failure, cancellation, reporting and ordering identity. Each invokes exactly one fresh fixture. There is no cross-case ordering dependency. Six shared non-test helpers preserve the exact original fixture bodies with dedentation only. Runtime behavior, the fixture exception boundary, assertions, operations, raw joins, cleanup, rollback, hold, poll, worker and database budgets remain unchanged. There is no endpoint/owner/API change, task sharing, new retry, exclusion or global serialization. Default aggregate parallelism is unchanged. No performance improvement or cause of the historical time-limit failures is established.

Stable observation indices and source-only case inventory (21 linked fixtures; two unlinked):

| Logical control / index | Ordinary named method | Fixture |
| --- | --- | --- |
| B17 / 1 | `p2bB17PoolSlotWaitSameOwnerAllows` | linked |
| B17 / 2 | `p2bB17PoolSlotWaitRetiredOwnerRefuses` | linked |
| B17 / 3 | `p2bB17AfterConnectBeforeG3SameOwnerAllows` | linked |
| B17 / 4 | `p2bB17AfterConnectBeforeG3RetiredOwnerRefuses` | linked |
| B17 / 5 | `p2bB17AfterStatementBudgetBeforeG6SameOwnerAllows` | linked |
| B17 / 6 | `p2bB17AfterStatementBudgetBeforeG6RetiredOwnerRefuses` | linked |
| B17 / 7 | `p2bB17AfterFactsBeforeG7SameOwnerAllows` | linked |
| B17 / 8 | `p2bB17AfterFactsBeforeG7RetiredOwnerRefuses` | linked |
| B17 / 9 | `p2bB17AfterRollbackBeforeG8SameOwnerAllows` | linked |
| B17 / 10 | `p2bB17AfterRollbackBeforeG8RetiredOwnerRefuses` | linked |
| B17 / 11 | `p2bB17RealRelationLockWaitSameOwnerAllows` | linked |
| B17 / 12 | `p2bB17RealRelationLockWaitRetiredOwnerRefuses` | linked |
| B18 / 1 | `p2bB18AccountIDChangedRefuses` | linked |
| B18 / 2 | `p2bB18DatabaseChangedRefuses` | linked |
| B18 / 3 | `p2bB18HubURLSpellingChangedRefuses` | linked |
| B18 / 4 | `p2bB18DeviceIDChangedRefuses` | linked |
| B18 / 5 | `p2bB18TokenRefChangedRefuses` | linked |
| B18 / 6 | `p2bB18TokenRefRemovedRefuses` | linked |
| B18 / 7 | `p2bB18UnicodeDeviceIDBytesChangedRefuses` | linked |
| B18 / 8 | `p2bB18UnicodeTokenRefBytesChangedRefuses` | linked |
| B18 / 9 | `p2bB18NativeAbsentTokenNonNilToNilRefuses` | unlinked |
| B18 / 10 | `p2bB18NativeAbsentTokenNilToNewRefuses` | unlinked |
| B18 / 11 | `p2bB18MetadataAllowedThenGateAndOwnerReplacementNeverRetargets` | linked |

The source inventory is **26 Owner + 15 storage = 41 physical native methods**, with **20 logical controls retained**. The 86 selected companions remain carrier 16 + selected writer 53 + publication 17. The physical writer suite and dedicated writer lane each remain 55; neither is the selected-writer denominator of 53. **41 + 86 = 127 is a source count only**, not evidence of 127 starts or passes.

Historical default evidence is [run 43839534425, attempt 1](https://github.com/cacheplane/b4app/actions/runs/43839534425/attempts/1) at feature head `deb4a6cc4e4c56597ddff1d5acdd2122c7013a45`: 18 pass / 2 fail, with B17 and B18 time-limit failures. Independent focused 20-pass and serial 20-pass results did not qualify the default run. Historical 20/106 denominators and all **2,160 distinct failure/skip observations remain OPEN**. They remain attached to their original evidence; there is no blanket rewrite, waiver or transfer of prior qualification.

Qualification requires fresh managed CI evidence bound to the actual tested head/tree and context, with actual terminal PASS for **all 23 named scenarios + the other 18 native methods + all 86 selected companions in every applicable context**, including default execution. Any missing, failed, skipped or cancelled result blocks it. Focused or serial success never substitutes for default success. Keep the existing C6 33 receipts, 11 profiles, 11 summaries and checks vectors, bound to their exact source and evidence. Source preservation supplies no ABI or physical quiescence qualification. No local Swift, compiler, build, test, native, application, PID or ABI experiment is claimed by this documentation work.

[PR 180](https://github.com/cacheplane/b4app/pull/180) remains **draft / no auto-merge / outside the merge queue / HELD**. SDK PR 1131, npm publication, coordinated activation, new production deployment and release remain HELD. P2c/Q01, startup, real HTTP, endpoint handoff, sync and checked-link effects remain HELD. This record adds no runtime, activation, merge or release approval.
