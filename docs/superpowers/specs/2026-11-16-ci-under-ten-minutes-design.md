# CI under ten minutes: fewer UI journeys, one build per job

## Intent

A full CI run on a pull request (and on a merge-queue group, D-242) should take under 10 minutes wall clock and still give broad assurance that what merges can ship: the package builds and its tests pass, the iOS and macOS apps build, and a handful of real UI journeys work end to end on each platform. Today a run takes about 18 minutes and holds four macOS runners (the organisation gets five at once), which, with the merge queue running CI a second time, makes landing pull requests slow.

The owner's direction: rely on a few broad smoke and integration tests rather than exhaustive layout checks. Keep two or three iPhone journeys (option A) and prune the macOS smoke tests the same way.

## Where the time goes today (main, run 43902475887, PR #216's run)

| Job | Compile | Tests | App builds | Total |
|---|---|---|---|---|
| iOS layout shard 1 / 2 | ~8 min each | ~8 min each | none | 17.6 / 17.1 min |
| macOS smoke | ~3.5 min | ~7 min (13 tests) | 6 min (macOS + beta) | 16 min |
| Package build and tests | 2 min build, 3.3 min to start the tests' PostgreSQL (includes building the tests) | 4.3 min | 4.6 min (iOS + beta) | 15.7 min |

Every macOS job compiles the Swift code from nothing: CI caches the SwiftPM checkouts (`.spm`, `.build`) but not Xcode's DerivedData.

## Goals

- Wall clock from first job start to the last required check: under 10 minutes for a new pull request restoring main's caches, on each of two hosted runs (D-232 showed one run is too noisy to judge), recorded in the decision.
- Each of the four macOS jobs shorter than 10 minutes.
- Still in every run: format lint, the whole Swift package test suite, the Hub, lint and B4 runtime jobs as they are; a debug build of the iOS app and the macOS app; three iPhone UI journeys; about five macOS smoke tests through the real coordinator.

## Non-goals

- Changing the Hub (Rust), lint, B4 runtime or change-scope jobs.
- Changing the Swift package tests (`swift test`); their content stays.
- Running UI tests only in the merge queue (option 3, set aside).
- Live provider tests (still opt-in, never in CI).

## Anti-goals

- A run that is fast because something stopped being checked without anyone deciding it: every removed test and build is named here and in the decision record.
- New flakes: a pruned suite that fails one run in ten is worse than today.
- A cache that can make a run pass on stale code: build caches may only speed up a build, never stand in for one.

## Approaches considered

1. **Prune tests only.** Fewer journeys and smoke tests, drop the beta builds. Smallest change, but each job still compiles from scratch (~8 min in the iOS job, ~11 min in the package job), so runs land around 11–13 minutes. Misses the goal.
2. **Prune, regroup the builds, and cache (chosen).** Below.
3. **UI tests only in the merge queue.** Fast pull requests, but a broken journey is found only once queued. Can be layered on later.

The owner chose 2, with the app builds in a job of their own (four macOS runners per run, as today) rather than appended to the UI jobs, and restored file timestamps so the build caches work.

## Design

### iPhone journeys (one job, no shards)

- Keep three journeys in `Tests/iOSLayout/UITests/BannerJourneys.swift`: `testWorkspaceNavigationJourney` (launch, home → thread → back, search), `testHealthyComposerJourney` (detail and new-thread composers), `testNotificationOpenJourneys` (cold and warm notification opening). Delete the other ten journeys and the three UIKit component tests (`Tests/iOSLayout/ComponentTests`; `SyncBannerContentTests` in the package already checks the banner's copy and precedence).
- Remove the journey-coverage contract (D-187) and the shard plan (D-225): `coverage.json`, `shards.json`, `JourneyCoverage.swift`, `Scripts/ios_layout_shards.py`, `Scripts/verify_ios_layout_coverage.py`, `Scripts/verify_ios_layout_results.py`, their tests in `Scripts/tests/`, and the shard/coverage variables in `Scripts/test-ios-layout.sh`. The pass condition becomes xcodebuild's own: the scheme's tests ran and passed, and the run is not empty (the script fails on zero tests, as the smoke script does).
- Helpers in `BannerLayoutTests.swift` and the harness (`Tests/iOSLayout/Harness/LayoutApp.swift`) that only the deleted journeys used are removed with them.
- CI: one `ios-layout` job (no matrix). The required check keeps its name, "iOS navigation and banner regression tests", so branch protection does not change; the `ios-layout-result` job reports it as now (one job instead of a matrix).

### macOS smoke tests

Keep five tests:

- `RecoverySmokeTests.testDesktopDarkRecovery` (one of the four recovery variants)
- `B4RuntimeSmokeTests.testDesktopDarkB4Recovery` (one of the two real-B4 journeys)
- `PaletteSmokeTests.testPaletteAndSlashByKeyboard`
- `ReadingSmokeTests.testALongThreadShowsEarlierRowsOnRequest`
- `FixtureLifetimeTests.testHostExitsWhenItsOwnerPipeCloses`

Delete the other eight tests (three recovery variants, the compact/light B4 journey, the palette drag/shadow and command-centre tests, jump-to-latest/copy-code and tall-first-message). The compact width is then not exercised by a UI test; the package's `RecoveryCompressionTests` and `DetailMinimumSizeTests` still cover compression. Shared helpers stay where a kept test uses them.

### App builds (their own job)

- Drop the beta builds (`B4App-iOS-Beta`, `B4App-macOS-Beta`) from CI. A beta build differs from the default only in `Config/Flavor-*.xcconfig` values; `./Scripts/package.sh` and `upload-ios.sh` still build beta at release.
- One new macOS job, "App builds", runs `./Scripts/generate-project.sh` and then the debug `B4App-iOS` (generic iOS Simulator) and `B4App-macOS` builds in one DerivedData, beside the test jobs. It replaces the build steps in the package and smoke jobs. Moving the builds into the UI jobs was considered and rejected: D-232 measured that an app build shares no compiled modules with a fixture project's build of the same package, so it would add its full time to those jobs. A run holds four macOS runners, as today, each for much less time.
- The "macOS and iOS app builds" required check keeps its name and still fails unless both builds succeeded; it reads the new job's step outcomes.

### Package job

Without the iOS builds it is format lint, build, start PostgreSQL (which builds the test targets), and test: about 11 minutes. The build cache below is what brings it under 10.

### Build caches

- **What is cached.** The package job's SwiftPM `.build` (as now) and each Xcode job's DerivedData build products (not logs or result bundles).
- **Timestamps.** `actions/checkout` gives every file the checkout time, so a restored build sees every source as changed and rebuilds it. Each cached job first sets each tracked file's modification time from its content: a fixed epoch plus a number taken from the file's git blob id (`git ls-files -s`), by a short script in `Scripts/` tested in `Scripts/tests/`. Unchanged content always gets the same time on every checkout, with no git history needed (the checkouts stay shallow); changed content gets a different time. Swift's build systems rebuild a file whose recorded modification time differs from the current one in either direction, so a file a pull request changed is always rebuilt. (Builder's call, in place of "the last commit's time", which needs the full history in every job.)
- **Who saves.** Only pushes to main save, under a key with the commit SHA; pull requests and merge groups restore the newest main cache (restore keys on OS, Xcode version, job) and never save, so they cannot evict main's caches from the 10 GB limit.
- **The guard against staleness.** Pushes to main restore nothing: they build from clean, run every test, and then save. A stale cache can therefore affect pull request and queue runs only, and main itself is always proven from a clean build within one merge.
- **First proof.** On the implementation pull request, one commit changes a single Swift file's body; its run's build log must show that file recompiled (and its dependants), and not the whole package. Recorded in the decision.
- A cache that does not save at least two minutes in its job across the measured runs is removed.

### Measurement and record

- Each step lands as its own commit on one branch, and the hosted run times before and after are recorded in the decision (as D-232's timing work did, using `Scripts/ci_timings.py`).
- One decision record (number taken at PR time) amends D-187, D-197 and D-225 and lists every removed test and build. `Tests/iOSLayout/README.md` and `Tests/macOSSmoke/README.md` are rewritten to describe what is left. `docs/milestones.md` is updated where it cites the old counts.

## Left to the builder

- Exact DerivedData paths to cache.
- If the run is still over 10 minutes after the above, report the numbers and the next-largest step before cutting anything else.
