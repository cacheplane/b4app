## 2026-11-14: CI's layout build during the boot, rebalanced shards, and where a run's time goes

The checks for D-232, and the record of a review of the delivery paths against a fixed rubric. Branch `blove/ci-cd-optimization-f1bf66`, from `main` 9bb7c97. Verdict at the end: **incomplete**. The first candidate (E2 to E4) had one hosted run, 43678912064, in "The first hosted run" below; E2 failed its rule there and was reverted. The second candidate (E3 and E4) had one too, 43684652276; E4 cost runner time on both and was reverted at the owner's word. What remains is E3, the timing tool and the checks' shell tests, on D-229's workflow. No improvement is claimed.

The comparison was fixed before any candidate result was read: `docs/research/2026-11-14-ci-delivery/manifest.json` (scope, obligations, gates, thresholds, decision rules, exclusions, and five dated amendments). The raw rows are `observations.json` beside it, written by `Scripts/ci_timings.py collect`; every hosted figure below can be recomputed from it with `summarize` and `steps`, except the three marked "from logs", which come from job logs and result bundles that GitHub keeps for the runs named.

### Scope

- Measured and changed: `ci.yml`, from a push to a pull request or to `main` to the required checks' results. This is the path that runs dozens of times a day.
- Read and not changed: the hub's release (`hub-image.yml` builds once per architecture and attests; `hub-release.yml` adds tags to that digest after verifying the attestation, deploys behind the `production` approval, then publishes the chart) and the Mac and iOS releases (`Scripts/release-mac.sh`, `Scripts/upload-ios.sh`, run by the owner on the Mac that holds the identities). None was run: each publishes, and `release-mac.sh --dry-run` was not needed for a change that touches none of them.
- Nothing was published, deployed, purged or re-run. The branch was pushed and pull request 206 opened at the owner's word, which ran CI on it. Read-only calls to GitHub listed runs, jobs, logs, caches and eight result bundles.

### The path and its clocks

```
push ─ scope (Linux) ─┬─ package: build, tests, iOS app build ───────────┐
                      ├─ smoke: fixture build, tests, 2 macOS app builds ─┼─ "macOS and iOS app builds" (Linux)
                      ├─ layout shard 1: boot ∥ fixture build, tests, ────┤
                      │                  beta iOS app build               ├─ "iOS navigation and banner
                      └─ layout shard 2: boot ∥ fixture build, tests ─────┘    regression tests" (Linux)
push ─ lint, B4 runtime, hub (Linux, beside the above)
```

Each macOS job waits for one of the organisation's 5 runners. A run's span is the scope job and its wait, then the slowest of (a macOS job's wait plus its run), then a combining job and its wait.

Baseline, 85 runs created 2026-11-13T01:34Z to 2026-11-15T04:07Z (all of them, with every attempt; none left out):

| Clock | Value |
| --- | --- |
| First attempts | 85: 30 passed, 47 failed, 8 cancelled |
| Runs with a re-run | 8, of which 5 passed in the end |
| Span of a first attempt that passed | median 24.7 min, 14.9 to 45.7 |
| Wait for a macOS runner (372 jobs that started) | median 4 s, 75th percentile 264 s, 90th 585 s, longest 1,435 s; 8 more were cancelled while waiting |
| Wait after the last macOS job (a Linux runner for a 3 s job) | over 60 s in 6 first attempts; longest 232 s |
| Wait before the macOS jobs are created (the scope job, since D-229) | 51, 53 and 186 s in the three runs that had it and were measured for this |
| Runner time | 4,879 macOS minutes and 513 Linux minutes over the 85 runs' attempts; a green first attempt used a median 56.5 macOS minutes. The price is not observable from here and is not estimated. |

47 of the 85 first attempts failed, most on one work-in-progress branch (D-225 measured the same branch); a span of passing runs says nothing about those. Whether a merged change is installed or adopted is not in any of these clocks: CI publishes nothing.

The four green first attempts with D-229's workflow, seconds each macOS job ran:

| Run | Package | Smoke | Shard 1 | Shard 2 | Longest |
| --- | --- | --- | --- | --- | --- |
| 43629968947 | 905 | 836 | 522 | 975 | shard 2 |
| 43671966677 | 960 | 816 | 618 | 694 | package |
| 43673503907 | 817 | 842 | 708 | 865 | shard 2 |
| 43675337568 | 840 | 823 | 742 | 1,015 | shard 2 |

Inside those jobs (from logs): a shard waited 68 to 165 s for `simctl bootstatus` before it began to compile (15 shard logs of 8 runs), then built the fixture for 148 to 407 s, then tested for 264 to 683 s. The package job built both iOS apps for 232 to 314 s after its tests, each for `arm64` and `x86_64`. The package's `.build` cache (665 MB, saved 2026-11-05 and never replaced, since its key is the lock file) restores the dependencies; the package's own modules are compiled every run.

### Experiments

| | Hypothesis | Evidence | Decision |
| --- | --- | --- | --- |
| E1 | An app build in the DerivedData of the UI fixture that built the same package reuses its modules | Local, 8 builds: the same SwiftCompile tasks either way (macOS 186 and 186; iOS 116 and 116) | Rejected by its rule (at most half the tasks). Nothing changed. |
| E2 | The fixture can build while the Simulator boots | Local: the whole suite through the new script, 16 of 16 tests, 129 of 129 checkpoints; the boot had finished when the build ended. Hosted, one run: its rule is not met (below) | Rejected by its hosted rule on the one run there is, and reverted at the owner's word: the script, its tests and the workflow step are D-229's again |
| E3 | Moving `testSyncCopyJourneys` to shard 1 balances the shards | The four runs' result bundles (from logs): journey sums 222 to 287 s and 291 to 533 s before; 299 to 363 s and 246 to 456 s after; the larger shard's median 430 to 390 s. Local: both shards pass, 70 and 59 checkpoints. Hosted, one run: 268 and 401 s, where the old plan would have had 207 and 462 s | Kept. The journey was chosen and judged on the same four runs; in one of them the larger sum rises (300 to 345 s) |
| E4 | The beta iOS build in shard 1 shortens the package job without making a shard the longest | Local: the combining check's shell on 14 failing outcomes, four mutations killed. Hosted, one run: the output arrived (`IOS: success/success`); the build took 209 s and shard 1 was the longest job | Its rule was met, and it was reverted at the owner's word after the second run: 209 and 191 s for the build against 92 to 135 s, and the longest job no shorter in either run |

Replaying the four baseline runs with E2 to E4 (arithmetic on the baseline, not a measurement): the longest job's median falls from 967 s to about 840 s if the overlap saves the whole boot wait, and to about 910 s if it saves nothing, with run 43673503907 slower than before in that case. The smoke job, 816 to 842 s and not touched, is then the longest. The manifest's thresholds were 10% off the longest job and 5% off a run's macOS runner time; on this arithmetic the first is met only if most of the boot wait is saved, and the second probably is not (about 4.5% at the median wait). Neither is claimed.

### Checks on this checkout

- `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'`: 58 passed. New among them: the layout script, run for real against fake `xcodebuild`, `xcrun` and `xcodegen`, builds, then waits for the boot, then tests; runs no test when the boot does not finish (its exit status) or the build fails; gives the build and the test run the same shard and caller arguments, for the first shard and the last; and refuses under `CI` with no Simulator named. The workflow's shape: each of the four schemes is built once, for the destination it always had; shard 1's build step cannot fail its job.
- The two combining checks' shell, cut from `ci.yml` and run by `bash -e -o pipefail`: "macOS and iOS app builds" passes on four successes (also when the jobs' tests failed) and on three skipped jobs with the scope's `false`, and fails on each of 14 others: any build failed, cancelled, skipped or empty; skipped jobs without the `false`; a `false` with a job that ran or was cancelled. "iOS navigation and banner regression tests" fails on 6. Four weakenings of that shell (a non-empty outcome accepted; the `false` accepted alone; a shard result other than failure accepted; a skip accepted without the `false`) each failed a test, and the file was restored.
- `./Scripts/test-ios-layout.sh` with the first version of the script: 16 of 16 tests, 129 of 129 checkpoints.
- `actionlint` clean; `shellcheck Scripts/test-ios-layout.sh` clean; `Scripts/docs-index.sh --check` passes.
- After the last change to the script and the plan (commit eed8748): `B4APP_LAYOUT_SHARD=1 ./Scripts/test-ios-layout.sh` passed 5 journeys and the 3 component tests with 70 of 70 checkpoints, and shard 2 passed 8 journeys with 59 of 59: 129 in all, with the Simulator already booted before both. An earlier pair of shard runs verified the same counts, but its second run ended with status 127 after its results were verified, because the script file was edited while that run was reading it; that run is not counted.
- Not run here: the macOS smoke suite (it drives the owner's pointer; this change does not touch it), `swift test` and the app builds as CI runs them (no Swift source changed; the eight local builds of E1 built all four schemes at this branch's base).

### Review

The review was of the first candidate (E2 to E4). E2 and E4 have since been reverted, and the findings about them (F1, F4, F5, F6, F8, F10) are kept as the record of it.

Three read-only reviewers were given the manifest, the diff and the evidence under neutral names, separately: dependencies and performance; gate integrity and recovery; measurement and test reliability. None found a way for a required check to pass falsely. What they found, and what was done:

| | Finding | Rubric | Severity | Kind | Decision |
| --- | --- | --- | --- | --- | --- |
| F1 | A failed beta iOS build in shard 1 failed the shard's job, and so the layout tests' required check too | C09.1 | S3 | regression in the candidate | Fixed: the build steps do not fail the job; the builds' check reads the step's outcome. Tested by the shell tests and the workflow-shape test |
| F2 | `ci_timings.py` counted a job cancelled while waiting as having run (10 rows; one run's macOS time overstated by 1,802 s) and gave a re-run's carried-over job a negative run time | C02.1 | S2 | new tool | Fixed, with a test for each shape; the observations were regenerated |
| F3 | The evidence's queue figures (327 jobs, 75th percentile 194 s) did not match the committed rows | C02.2 | S2 | record | Restated from the committed file: 372 jobs, 264 s. The earlier figures came from a draft of the tool with the F2 error |
| F4 | The first test may now start the moment the boot finishes; the baseline had 148 to 407 s of idle Simulator before it, and one local pass on a 10-core Mac says nothing about a 3-core runner | C08.3 | S2 | closed by the revert | One hosted run: the wait after the build was 9 and 7 s, and all 16 tests passed on the first attempt with no repetition in either result bundle. E2 is reverted, so the question no longer arises |
| F5 | The beta build loses the first iOS build's warm module cache (it was 28 to 48 s shorter as the second build) | C03.3 | S2 | confirmed | Hosted, one run: 209 s in shard 1, against 92 to 135 s as the package job's second build in the baseline. The fixture's DerivedData did not make it cheap; the first iOS build took 207 s on that run's package runner |
| F6 | Shard 1 can now be the longest job in a slow run, and a shard 1 that times out fails the builds' check | C04.1 | S2 | candidate | Its limit is 35 minutes; the slowest green shard 1 in the rows plus the new work is about 1,450 s. Hosted, one run: shard 1 was the longest job, 1,083 s, 209 s of it the beta build. Accepted, to be watched |
| F7 | The layout script's tests did not pass shard or caller arguments, and the check tests took the first `run:` of a job | C08.2 | S3 | test gap | Fixed: the arguments are compared between the build and the test run; the step is found by name |
| F8 | With an empty Simulator id the script would skip the wait | C09.2 | S1 | candidate | Fixed: under `CI` it refuses |
| F9 | The smoke job is the floor (its two macOS builds run after its tests); thresholds unlikely to be met | C03.2 | S2 | finding | Recorded above; not addressed in this change |
| F10 | Whether a re-run of failed jobs keeps an earlier attempt's `ios-beta` output | C13.2 | S1 | open | Unknown. If it does, the kept value is that commit's own successful build |

The reviewers' reading agrees with the tests; that is not a measurement, and their agreement is not counted as one.

### Rubric

One status per check for the changed path (`ci.yml`, the candidate). "Untested" means the evidence it needs does not exist yet.

| Check | Status | Basis |
| --- | --- | --- |
| C01.1 outcome and scope defined | Pass | manifest; the workflow |
| C01.2 coverage preserved (required) | Pass | workflow-shape tests: four schemes, same destinations, both shards, the partition check, 129 checkpoints locally |
| C01.3 authority for amendments | Pass | no obligation amended; the `x86_64` Simulator slice and larger runners are left to the owner |
| C02.1 clocks from named boundaries (required) | Pass | `ci_timings.py` and its tests; F2 fixed |
| C02.2 every outcome and attempt counted (required) | Pass | the 85-run table; failed, cancelled and re-run attempts are in it |
| C02.3 inputs, cache state and runner recorded (required) | Pass | manifest; local and hosted figures are never compared with each other |
| C03.1 dependency graph | Pass | the diagram above, from the workflow and the scripts |
| C03.2 critical path measured | Pass | the four-run table; F9 |
| C03.3 serialization removed and re-measured (required) | Pass | removed, and re-measured on one hosted run: build and wait took 380 and 368 s before the first test, against a baseline median of 323 s for wait and build. No saving was shown, so the removal was reverted and nothing is claimed from it |
| C04.1 shards balanced on measurements | Pass | two hosted runs: journey sums 268 and 401 s, then 278 and 408 s (207 and 462 s, then 221 and 465 s on the old plan); shard 2 is still the longer job |
| C04.2 runner class and capacity | Pass | unchanged: four macOS jobs, standard runners |
| C04.3 limited capacity and concurrent requests | Untested | not exercised; `cancel-in-progress` per ref is unchanged |
| C05.1 exact source and inputs | Pass | unchanged: the event's commit, the lock files, Xcode 26.6 |
| C05.2 dependency and toolchain changes | Untested | no cache key or resolution step changed; no such case was run |
| C05.3 reproducibility claims | Not applicable | none is made; CI publishes no artifact |
| C06.1 caches classified | Pass | manifest; unchanged |
| C06.2 cold and partial caches | Untested | needs a purge or a lock change; excluded in the manifest |
| C06.3 cache trust | Pass | unchanged; no secret is cached |
| C07.1 selection through the real graph | Pass | `ci_scope.py` unchanged and tested |
| C07.2 uncertain input falls back to everything | Pass | its tests: empty, short or foreign lists run everything |
| C07.3 selected work compared with the full run | Untested | no docs-only pull request has run on the scoped workflow (open since D-229) |
| C08.1 tests and checks preserved (required) | Pass | no test, assertion or timeout of a test changed |
| C08.2 sharding keeps every test (required) | Pass | the partition check; both shards locally: 70 and 59 of 129 |
| C08.3 first-attempt reliability | Not applicable | F4 was about E2, which is reverted; the tests start as they did in D-229 |
| C09.1 the check reads explicit outcomes (required) | Pass | the shell tests; F1 fixed |
| C09.2 failures are not swallowed (required) | Pass | the script tests: a failed build or boot ends it with its status |
| C09.3 injected failures are refused (required) | Pass | 20 failing outcomes and four mutations, locally, with no publication |
| C10.1 to C10.3 artifact identity and promotion | Not applicable | this path builds to verify and publishes nothing; result bundles are kept 7 days as before |
| C11.1, C11.3 signing | Not applicable | CI builds unsigned (`CODE_SIGNING_ALLOWED=NO`) |
| C11.2 privilege boundaries | Pass | the combining jobs keep `permissions: {}`; no permission changed |
| C12.1 to C12.3 publication | Not applicable | nothing is published by this path |
| C13.1 which requests supersede | Pass | unchanged: a newer push to a ref cancels the older run; nothing here mutates a release |
| C13.2 repeated operations | Not applicable | F10 was about E4's job output, which is reverted |
| C13.3 older runs and channel pointers | Not applicable | no pointer is moved by this path |
| C14.1 logs, timings, identities | Pass | the script prints each phase's time; result bundles as before |
| C14.2 bounded retries | Pass | none added; none is automatic |
| C14.3 rollback | Pass | reverting this branch's commits; no external state. Not exercised |
| C15.1 cost | Pass | runner minutes by class; currency unknown and said so |
| C15.2 maintainability | Pass | one script, one plan file, one moved step; the review |
| C15.3 final integrated candidate and holdout (required) | Untested | one hosted run of the candidate that remains (43684652276, green; "The second hosted run"); no holdout, which is a pull request this work did not write |

Required checks: 10 pass, 0 fail, 1 untested (C15.3). Assessed 10 of 11 (91%); verified passing 10 of 11 (91%). The release paths were read and are unchanged; every check for them is untested here, since none was run.

### The first hosted run

Run 43678912064, pull request 206, commit 4ba2c3d, first attempt, green: all ten checks passed. One run; the manifest claims no span from fewer than five and no reliability from fewer than three. Read with `Scripts/ci_timings.py`, the two shards' logs and result bundles, and the builds' check's log.

| | Package | Smoke | Shard 1 | Shard 2 | Longest | macOS runner time |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline, four runs | 817 to 960 s | 816 to 842 s | 522 to 742 s | 694 to 1,015 s | 865 to 1,015 s, median 967 s | 3,088 to 3,420 s, median 3,235 s |
| 43678912064 | 1,005 s | 781 s | 1,083 s | 924 s | 1,083 s (shard 1) | 3,793 s |

The longest job is 12% longer than the baseline's median and longer than in any of the four runs; the macOS runner time is 17% more. The thresholds asked for 10% and 5% less. The run's span was 21.9 minutes with waits for a macOS runner of 32 to 45 s (the baseline's green first attempts: median 24.7 minutes, with their own waits); that is one span and is not compared.

- **This run's runners were slow in steps this change does not touch.** In the package job, "Build" took 151 s (baseline 80 to 132), "Start the tests' PostgreSQL" 249 s (152 to 181), "Test" 268 s (231 to 259) and the first iOS build 207 s (140 to 179): together 875 s against 630 to 722 s. The smoke job, on another runner, was faster than any baseline run (781 s). So part of what follows is the runners and one run cannot say how much.
- **E4, the output.** "Every app build passed" printed `scope: apple=true; jobs: success/success/success; iOS builds: success/success; macOS builds: success/success`. Shard 1's `ios-beta` output reached the check with shard 2 leaving it empty. E4's rule is met.
- **E4, the cost.** The beta build took 209 s in shard 1; as the package job's second iOS build it took 92 to 135 s. The package job without it still ran 1,005 s. F5 is confirmed and larger than the 28 to 48 s expected.
- **E2, the phases.** Shard 1: build 371 s, wait for the Simulator 9 s, tests 341 s. Shard 2: build 361 s, wait 7 s, tests 457 s. The boot did finish during the build. In 15 baseline shard logs the wait was 67 to 165 s (median 96) and the build after it 147 to 406 s (median 216): wait and build together 216 to 571 s, median 323 s. Here they took 380 and 368 s. The build beside a booting Simulator took about as long as the baseline's wait and build one after the other, on runners that were slow that run. The steps were 778 s (shard 1, with the moved journey's 61 s) and 874 s (shard 2), against 486 to 694 s and 649 to 961 s. E2's hosted rule, a step shorter than its baseline by at least half the boot wait, is not met on this run.
- **F4, the first tests.** 8 of 8 tests passed in each shard, with no repetition of any test in either result bundle; the first journeys took 26 s (`testConnectionNoticeJourney`) and 66 s (`testEntryRootJourneys`), inside their baseline ranges. One run of three.
- **E3, the balance.** Journey sums 268 s (shard 1) and 401 s (shard 2). With `testSyncCopyJourneys` (61 s) still in shard 2 they would have been 207 and 462 s.
- **Not seen.** A re-run of failed jobs (F10), a failed beta build in shard 1 on a hosted run, a docs-only pull request, a holdout.

### The second hosted run

Run 43684652276, pull request 206, commit 46abf6e (E2 reverted; E3 and E4), first attempt, green: all ten checks passed. The same sources as the first.

| | Package | Smoke | Shard 1 | Shard 2 | Longest | macOS runner time |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline, four runs | 817 to 960 s | 816 to 842 s | 522 to 742 s | 694 to 1,015 s | 865 to 1,015 s, median 967 s | 3,088 to 3,420 s, median 3,235 s |
| 43678912064 (E2, E3, E4) | 1,005 s | 781 s | 1,083 s | 924 s | 1,083 s (shard 1) | 3,793 s |
| 43684652276 (E3, E4) | 644 s | 576 s | 950 s | 985 s | 985 s (shard 2) | 3,155 s |

The longest job is 2% longer than the baseline's median and the macOS runner time 2.5% less; the thresholds asked for 10% and 5% less. The span was 20.5 minutes, with waits for a macOS runner of 14 to 265 s.

- **This run's runners were fast in steps this change does not touch.** The package job's four untouched steps took 570 s (baseline 630 to 722 s; the first run 875 s) and the smoke job's tests 324 s (523 to 551 s). The runners differ from run to run by more than anything changed here.
- **The shards did not share that.** With D-229's order back: shard 1 waited 101 s for the boot, built for 259 s and tested for 322 s; shard 2 105 s, 248 s and 556 s. Wait and build took 360 and 353 s, against 380 and 368 s with E2 on the first run and a baseline median of 323 s. The two orders are not told apart by these two runs; E2 stays reverted by its rule.
- **E3.** Journey sums 278 s (shard 1) and 408 s (shard 2); with `testSyncCopyJourneys` (57 s) in shard 2 they would have been 221 and 465 s. All 16 tests passed with no repetition. Shard 2's tests took 556 s for 408 s of journeys and shard 1's 322 s for 278 s.
- **E4.** The output arrived again (`iOS builds: success/success`). The beta build took 191 s in shard 1. Without it shard 1 would have run about 760 s and the package job, with it at the baseline's 92 to 135 s, about 740 to 780 s: shard 2 is the longest either way, and the move cost about 55 to 100 s of runner time.

### Verdict: incomplete

E2 and E4 are reverted: `.github/workflows/ci.yml`, `Scripts/test-ios-layout.sh` and its tests are `main`'s (9bb7c97). The branch changes the shard plan (E3), adds `Scripts/ci_timings.py` and its tests, and adds the combining checks' shell tests, now against `main`'s two-job form of the builds' check. Findings F1, F4, F5, F6, F8 and F10 were about E2 or E4 and no longer arise. Local after the reverts: 55 script tests pass, `actionlint` is clean, `Scripts/docs-index.sh --check` passes.

No required check fails and no S3 or S4 finding is open. One required check is untested, C15.3: there is no holdout, and the plan with `main`'s workflow has not run hosted as such (the second run had the same plan with E4). No improvement is claimed, and on the two hosted runs none is shown: neither threshold was met in either.

What is left:

- E3 held on both runs (journey sums 268 and 401 s, then 278 and 408 s), and shard 2 is still the longer shard: its step outside the journeys is what makes it so, and the plan cannot move that.
- The runners differ from run to run by more than any change tried here. A further change to this path needs several runs each side before it is judged.
- For the owner: the `x86_64` Simulator slice of the two iOS app builds, and larger runners. Still open: the docs-only path, the holdout.

To undo: revert this branch's commits. Nothing outside the repository changed.
