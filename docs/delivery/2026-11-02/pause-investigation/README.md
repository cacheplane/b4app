# Test startup scan investigation

This nonpublishing follow-up preserves the preceding NIO/B4 and delivery-observation changes. The manifests and plan define one focused change after a read-only diagnosis. Source remains HEAD `02f201c0e504004df512d88e267ca6d82af8410d` plus the working diff, identified in `candidate-files.sha256`. No CI test selection, timeout, worker cap, cache policy, signing, release or deployment behavior changed.

The final warm suite passes all **1,166 tests in 146 suites** with `SWIFTNIO_STRICT=1`. Two cleanup regressions were added; all prior coverage remains. Final cold verification also passes 1,166 tests/146 suites. Reported library spans are 54.501s warm and 55.835s cold; command walls are 95.412s and218.248s. Three fresh unsigned macOS builds and all static checks pass; three compatible prior iOS Simulator results are explicitly reused and their digests reverified. Exact evidence is in the ledger and `final-verification.json`. Overall hosted delivery-speed verdict remains **Incomplete**: no current hosted candidate or accepted distribution evidence is available under this local, nonpublishing scope.

## Observed blocker and change

An unchanged full-suite run passed 1,164 tests, while three samples inspected only its owned test helper. The first three-second sample found the main thread in `ModelHarness.start → EphemeralPostgres.ensureStarted → sweepStale → FileManager.contentsOfDirectory → getattrlistbulk`. Other workers waited on the same startup lock. The macOS temporary directory held roughly 133,000 entries; Foundation acquired metadata for unrelated names. Later samples show normal test/SQL work. This directly localizes an actual startup blocker, but does not prove that every historical 60-second timeout had the same cause. The sampled full run is diagnostic evidence, not a speed benchmark.

`EphemeralPostgres` now obtains directory names using `opendir/readdir`, selects recognized scratch names, then runs the original cleanup policy. Ownership parsing, live-owner protection, age checks for legacy names, postmaster identity verification, stop behavior, directory de-duplication and removal remain unchanged. Entry bytes become owned Swift strings before the next C call; no pointer escapes. Enumeration errors discard results before cleanup. Invalid UTF-8 is left alone rather than repaired into another path. That defensive branch is statically reviewed but not exercised: APFS rejected the attempted invalid-byte fixture with errno 92.

This is a macOS-only test-cluster helper, not a new storage architecture. Production does not call it. Prewarming was rejected because it would move the same work outside the test clock; skipping global scratch recovery was rejected because it would remove crash-cleanup behavior. The new tests protect Unicode names, regular files, broken links, unrelated/hidden entries, missing directories and a supported 255-byte scratch name. Existing owner/liveness/orphan identity tests remain.

## Focused measurements

The temporary `ScratchScanMeasurementTests.swift` called the **actual helper** with `isAlive` always true and `now = Date.distantPast`, preventing deletion and stopping. It is archived here and removed from ordinary test discovery before final validation. No required CI test was removed.

| Actual helper, frozen 5,000-entry namespace | Individual scan seconds | Median |
| --- | --- | --- |
| Baseline | .027007, .012842084, .010961208 | .012842084 |
| Candidate | .006350958, .005671750, .005610209 | .005671750 |

The focused median reduction is **55.83%**, exceeding the provisional 10% stage objective. These are three small local samples, with baseline group before candidate; they do not establish a percentile or a hosted/full-suite gain. An additional interleaved prototype comparison returned identical complete name sets on the frozen namespace in all three pairs. The actual helper retained empty removal results under its read-only injected guards, and functional cleanup regressions passed.

Actual scans of the busy live temporary directory were 10.239/7.101/7.424 seconds before and .622/.174/.169 seconds after. That namespace changed during collection, so these values are diagnostic observations without an exact same-input ratio. The initial live prototype's equality precondition failed (exit 133); it is preserved and excluded from equivalent-input conclusions. Subsequent live samples explicitly report unequal name sets rather than pretending the input was frozen. No unrelated names or files were deleted to improve timing.

`scan-inputs-retrospective.json` maps every actual-helper case to its `B4APP_SCAN_ROOT`, gives the deterministic frozen namespace recipe, and records its verified inventory digest. This metadata was added retrospectively after review, and is labeled accordingly; it is not a contemporaneous baseline snapshot. The owned namespace was created once and the benchmark calls did not mutate it. `scan-control-inventory.json` is the complete current recipe-verified inventory, and `controlled.py` preserves the actual frozen-root assignment. Live directory inventories are intentionally not shared or treated as equivalent. `comparison.json` reproduces the narrow result.

## Failures and evidence boundaries

All attempts remain in `observations.jsonl` and `console-summaries.json`. The initial live equality assertion failed because entries changed. The first new invalid-byte test failed at fixture creation because the filesystem rejected it. Its replacement initially used an unsupported `b4pgs-114-<suffix>` name; reviewers caught that `b4pgs-` accepts only a PID. The test was corrected to the existing supported `b4pg-114-<suffix>` grammar, without widening the parser. Both failed test attempts remain separate from the final focused green. None was an existing test failure or a reason to weaken a prior assertion.

The unchanged sampled full reference and final warm/cold suites are correctness observations, not equivalent performance samples: sampling, new test population and uncontrolled host activity differ. UTC command bounds, monotonic wall, child CPU, source hashes and library-reported spans are separate. Raw parameterized Swift logs and raw stacks stay at local paths with digests; committed summaries omit identifying sample values. Prototype commands lacking complete wrapper clocks and native Xcode non-child build-service CPU are explicitly outside known resource totals. Unknown hosted dollars and accepted availability are not zero.

## Verification and reuse

The final holdout uses fresh isolated build/cache/config/security roots, disabled shared dependency cache, pinned resolved versions and local manifest caching. Existing verified PostgreSQL binaries and OS/toolchain caches remain; SwiftPM emitted some “from cache” fetch labels despite the flags. This proves the specified fresh roots and full rebuild, not absence of every cache layer; no shared cache was purged. Fresh native checks cover local/beta Debug and prod Release macOS builds with signing disabled. The three preceding iOS Simulator products were reused after checking their digests and unchanged source/config/lock/toolchain identity: `WorkspaceStorage` is absent from their transitive dependency graph. Reused iOS results are labeled separately from fresh builds, not counted as newly executed work. `native-products.json` and `ios-reuse.json` retain those boundaries.

Three read-only reviewers independently examined safety, dependency/performance and measurement. Their findings, the corrected naming test and the retrospective input metadata are recorded in `review.json` and `findings.json`; review agreement is not a probability or substitute for test evidence. The original C01–C15 assessments remain in preceding packets; `cases.csv` covers only new criterion-case obligations.

Rollback is the file-local reversal of `EphemeralPostgres` name enumeration and the two added cleanup tests, preserving prior NIO/B4 work. The controlled comparison exercised the original helper and restored the candidate in a `finally` block. No production rollback or publication was performed. The remaining external step is existing PR/main CI on the exact candidate; no remote write was made to trigger it.
