# Swift CI follow-up: fixture reliability and native/cold verification

**The focused reliability fixes pass the tested local paths. Delivery-speed verdict: Incomplete.** No concurrency optimization met the frozen improvement threshold, so none is retained. There is no hosted candidate, release, publication, download, installation or update claim. The earlier 45-criterion assessment in `../criteria.csv` remains the historical full-rubric record; this packet adds the local cases that were previously open.

## Implemented change

`FakeHubAPI.endSession` and `deleteAccount` now wake parked long polls, as `revokeSelf` already did. A new parameterized Swift regression parks first, revokes, and requires the actual unauthorized/401 error. Its two-second guard cancels a broken reader; CancellationError cannot pass the assertion. Before the fix, both cases failed with six issues; after it, both passed in 0.001 seconds. The existing phone sign-out test then passed in 0.031 seconds.

Recovery fixtures now establish the state each test intends to exercise:

- A restart test releases its fake run through a unique temporary file **after** coordinator shutdown. A three-second “slow” run could previously finish first, making the reconciling assertion fail. Timeout of the release produces an explicit fixture failure.
- A dropped-stream run waits for the reattaching GET to capture its cursor and write initial state. The old one-second delay could expire first under load; the unchanged transcript assertion would then fail. Missing reattachment fails explicitly rather than producing success.
- A pending permission is saved before its interrupt event is published. The held-out restart check exposed the opposite ordering: the test could stop the process after receiving the prompt but before persistence. The new Python test reads durable state at notification time; it failed with `busy != interrupted` before the ordering fix and passes afterward.
- HubSync tests stop background work before injecting a specific failed push or comparing store snapshots. Close is followed by waiting for any existing push to settle. Every existing unsynced-data, sign-out, restore-refusal, transcript, outcome and turn-count assertion remains.

No production adapter algorithm, real hub route, schema, dependency lock, native target, signing control or publication script changed. The new Python regression runs through the already-added CI unittest discovery step. All original serialized suites remain serialized; no tests were removed or filtered from full runs.

## Diagnosis and measurements

The examined hosted failure is run `41519013466`, source `e1be022fae74dda235fe13629887069706d6505c`. Its Test step reported 1,199 tests/153 suites and ten issues: phone revocation plus the two HubSync state assertions. Its Test step was about 751 seconds, including test compilation; the reported test runtime was 580.089 seconds. B4 adapter tests dominated that runtime, with many roughly 35-second cases. These hosted sources differ from this checkout, so they are diagnostic evidence, not an equivalent benchmark.

The local baseline is source `02f201c0e504004df512d88e267ca6d82af8410d` plus the prior observation-tool diff. It ran 1,159 tests/144 suites and reproduced phone revocation and restart failures. A warm repeat also exposed the dropped-stream assertion. An isolated local fake-B4 startup/health/shutdown probe took 0.591/0.081/0.010 seconds; it does not explain the hosted 35-second pattern. The hosted per-case latency remains unresolved, and no speculative DNS/process/runtime change is retained.

| Local case | Whole command seconds | Test runtime seconds | Result |
| --- | ---: | ---: | --- |
| Initial empty `.build`: `swift build` | 91.737 | — | Pass |
| Cold pinned PostgreSQL download/extraction | 19.193 | — | Pass |
| Original full `swift test`, including first test compilation | 181.837 | 79.312 | Fail, eight issues |
| Original warm full suite | 105.433 | 75.216 | Fail, nine issues |
| Original suite, width16 diagnostic trial | 95.886 | 66.029 | Fail, six issues; no setting retained |
| Corrected full `swift test`, including incremental build | 105.576 | 63.643 | Pass, 1,160 tests/145 suites |
| Final isolated cold-cache full suite | 275.422 | 83.224 | Pass, same 1,160 tests/145 suites |

These rows preserve their different build/cache/source boundaries. Failed baseline time is not accepted-availability time. Removing a failure is a correctness improvement; it does not establish a comparable-success latency reduction or predict a production first-pass rate.

The final concurrency experiment interleaved the **same corrected source hashes**, same complete suite, same toolchain and warm command boundary (`swift test --skip-build`). The two variants differed only in `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=32`:

| Variant | Individual command seconds | Median seconds | Median child CPU seconds |
| --- | --- | ---: | ---: |
| Retained default | 101.148, 89.569 | 95.359 | 67.259 |
| Candidate width32 | 95.263, 93.675 | 94.469 | 68.476 |

Observed median reduction: **0.93%**, against the prespecified 10% requirement. Child CPU proxy increased 1.81%, within its 5% bound, but it omits some reparented PostgreSQL/Xcode service work. The latency difference is within the observed control variation. **Reject width32**; width16's earlier approximately 9% result was also unsupported. Neither flag was added to CI. With two repetitions, no dependable percentile or reliability confidence estimate is warranted.

All six full-suite executions on the corrected sources passed: four at retained default concurrency (one with incremental build, two warm, one cold), and two on the rejected width32 variant. The additional fixture-order regression makes 19 Python checks. Failed intermediate and negative runs remain in `observations.jsonl`; eventual green does not erase them.

## Native and cold checks

Xcode 26.6 (17F113), Swift 6.3.3, macOS 26.5 arm64, macOS/iOS Simulator SDK 26.5; local hardware has ten logical CPUs and 32 GiB RAM. No hosted runner image is inferred from this machine.

All six builds succeeded with `CODE_SIGNING_ALLOWED=NO`, `-onlyUsePackageVersionsFromResolvedFile` and `-disablePackageRepositoryCache`:

| Case | Configuration | Seconds |
| --- | --- | ---: |
| B4App-macOS | Debug/local | 128.296 |
| B4App-iOS, generic Simulator | Debug/local | 52.460 |
| B4App-macOS-Beta | Debug-Beta | 76.182 |
| B4App-iOS-Beta, generic Simulator | Debug-Beta | 28.613 |
| B4App-macOS | Release/prod | 100.757 |
| B4App-iOS, generic Simulator | Release/prod | 54.638 |

The first native build began with absent SourcePackages and DerivedData roots; subsequent branches reused compatible native inputs. The generated project's resolved file was copied from the existing root lock, and the root lock hash stayed unchanged. `native-products.json` records each configuration/platform, flavor, bundle ID, version, executable and plist digest, architecture, and observed signature. Signing-disabled/possibly linker-ad-hoc products are **not** Developer ID, notarized, App Store or final distributable packages. The inherited beta and prod iOS configurations both resolve to `com.cacheplane.b4app.ios`; this records existing configuration and does not certify separate installation or distribution identities.

The final cold Swift run used new isolated download/checkout/manifest/build/config/security roots, disabled the shared dependency cache, and enforced Package.resolved. It used the pinned PostgreSQL tree fetched earlier; database state was fresh. Installed toolchain/SDK caches were not purged. Cold Swift and native validation overlapped; their timings are correctness/resource observations, not an equivalent baseline/candidate speed comparison. The cold-regression percentage objective remains untested.

All four existing CI app branches were built. Additional prod Release builds cover optimization mode. Beta Release, device archives, local Release packaging, signing/notarization, Finder use, real provider/hub interaction, install/update checks and distribution endpoints are not certified. No full Cartesian target/configuration matrix is implied.

## Evidence, gates, remaining limits

`manifest-v1.json`, the v2 amendment and four experiment records freeze identities, thresholds, selection, budgets and corrections. `observations.jsonl` retains named UTC boundaries, source/input identities where captured, conclusions, CPU proxies, raw private-log references and digests; `observations.csv` is its compact view. Raw logs remain under `/tmp/b4-ci-swift-evidence/`, and the historical hosted log under `/tmp/b4-swift-ci-failed.log`; they are not copied into shared text because fixture diagnostics include personal example data. The ledger preserves unknowns for the unusable initial sandbox probe. An initial cold-build harness mislabeled an end timestamp as start; the normalized record explicitly corrects the label, retaining monotonic duration and leaving start unknown.

`comparison.json` reproduces the fixed-source comparison. Historical harness snapshots `measure.py` and `native-checks.py` show collection logic; they use fixed `/tmp` paths, and repetition requires fresh case names/output roots to preserve observations. They are evidence helpers, not a new application interface. `findings.json` consolidates findings by cause and records retests; `cases.csv` maps new criterion-case checks back to the complete C01–C15 rubric. The original broader `../criteria.csv` is not silently replaced or rescored.

The dependency graph remains the one in `../README.md`: this diff fixes test signal within the existing package Test step, adding a small fixture durability check to lint. It does not remove cross-workflow dependencies or change construction, attestation, promotion, approvals, publication or deployment. There is no accepted-availability observation or identified release intent.

An existing SwiftNIO “Cannot schedule tasks on an EventLoop that has already shut down” diagnostic remains in passing as well as failing runs. It is recorded as an unresolved baseline S2 diagnostic, not suppressed or represented as a new regression fix. Hosted confirmation of the current candidate and the approximately 35-second per-B4-case behavior are also open. Correctness fixes are reviewable, but a supported delivery-speedup conclusion remains missing, hence **Incomplete** for that objective.

No new hosted runs, workers, services or material spending were introduced. Resource sums and their limitations are in `resources.json`; actual billed CPU/storage/transfer cost is unknown. Four substantive experiments were the stopping budget. The local validation-command budget was 2,700 seconds; concurrent intervals remain in the sum rather than being discarded as “saved” work. Native/cold results and the last build/lint checks are separate from warm comparison samples.

Three read-only review roles cover integrity/recovery, measurement/tests and dependency/performance. Findings were resolved by direct regression or source inspection; no vote or subjective score replaces execution evidence. Final gate results are in `final-checks.json` and `final-checks.log`.

Rollback is file-local: revert the two FakeHubAPI wakes and the recovery/sync fixture/test changes, and remove their new regression files if reverting their behavior. Preserve the prior observation collector and unrelated edits. There is no production data, tag, feed pointer or deployed state to roll back. No commit, push, publication, signing submission or deployment was made.

## Reproduce without publication

```sh
python3 -m unittest discover -s .github/scripts/tests -v
./Scripts/fetch-postgres.sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Apps Package.swift
./Scripts/generate-project.sh
```

Use a new output root for a cold run (the example paths must not already contain caches):

```sh
B4APP_POSTGRES_BIN="$PWD/.build/postgres/bin" swift test \
  --scratch-path /tmp/b4-new-cold/build --cache-path /tmp/b4-new-cold/cache \
  --config-path /tmp/b4-new-cold/config --security-path /tmp/b4-new-cold/security \
  --disable-dependency-cache --manifest-cache local --only-use-versions-from-resolved-file
```

Exact xcodebuild commands are retained per case in the ledger. They use `build`, not archive/export, and signing is disabled. Running hub image, Mac release, upload or deployment workflows is outside this reproduction plan. Swift Testing concurrency semantics were checked against [Apple's parallelization documentation](https://developer.apple.com/documentation/Testing/Parallelization); the experimental input was also observed in the installed Testing binary and exercised, but is not a retained dependency.
