# CI Under Ten Minutes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A CI run on a pull request or merge group finishes in under 10 minutes, with three iPhone journeys, five macOS smoke tests, the whole Swift package suite, and debug builds of both apps.

**Architecture:** Prune the two XCUITest suites in place; move the two debug app builds into one new macOS job; cache SwiftPM `.build` and Xcode DerivedData from clean main builds only, made reusable by content-derived file timestamps.

**Tech Stack:** GitHub Actions (`actions/cache/restore`, `actions/cache/save`), XcodeGen, xcodebuild, XCTest/XCUITest, Python 3 (stdlib only) for scripts and their `unittest` tests, bash.

**Spec:** `docs/superpowers/specs/2026-11-16-ci-under-ten-minutes-design.md`

## Global Constraints

- Required check names stay exactly: "Package build and tests", "macOS and iOS app builds", "Hub (Rust)", "iOS navigation and banner regression tests". Branch protection is not touched.
- Hub (Rust), lint, B4 runtime and change-scope jobs keep their behaviour; the scope job's `merge_group` branch (D-242) stays.
- Every macOS job keeps `needs: scope` and `if: ${{ !cancelled() && needs.scope.outputs.apple != 'false' }}`.
- Caches: only `push` to `main` saves, and it restores nothing; `pull_request` and `merge_group` restore and never save.
- Beta schemes are not built in CI; `project.yml`'s Beta schemes and `Scripts/package.sh` / `upload-ios.sh` are unchanged.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `actionlint`, `shellcheck` (the lint job's file list) and `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'` pass before every commit that touches their files.
- Decision record: one file `docs/decisions/D-NNN-<slug>.md` (number from `Scripts/docs-index.sh --next` at PR time), amending D-187, D-197, D-225; `Scripts/docs-index.sh --check` passes.

## Review Focus

- A pull request that changes one Swift file restores main's cache: that file and its dependants recompile, nothing is skipped (Task 6 proof).
- XcodeGen regenerating an identical project on each run must not invalidate the restored DerivedData (Task 6 proof shows partial, not full, rebuild; if full, Task 4's DerivedData caches are removed by the spec's two-minute rule).
- A cancelled or failed app build fails "macOS and iOS app builds"; a skipped app-builds job passes it only when the scope said `false` (Task 4 combining-check cases).
- A cancelled or skipped single `ios-layout` job fails "iOS navigation and banner regression tests" unless the scope said `false` (existing combining-check cases keep passing against the single job).
- An empty XCUITest run (all tests filtered out) fails the iOS script (Task 2).

---

### Task 1: Content-derived file timestamps

**Files:**
- Create: `Scripts/restore_mtimes.py`
- Test: `Scripts/tests/test_restore_mtimes.py`

**Interfaces:**
- Produces: `python3 Scripts/restore_mtimes.py [--root DIR]` sets every file listed by `git ls-files -s` (regular files and symlinks skipped if not regular) under DIR (default cwd) to the mtime `mtime_for(blob)`; prints the count. `mtime_for(blob_hex: str) -> int` returns `1_000_000_000 + int(blob_hex[:8], 16) % 2**30`.

- [ ] **Step 1: Write the failing tests** in `Scripts/tests/test_restore_mtimes.py` (`unittest`, a temp git repo made with `git init`, `git add`, `git commit` with `-c user.name=t -c user.email=t@t`):
  - `test_mtime_is_a_function_of_the_blob`: `mtime_for("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391") == 1_000_000_000 + 0xe69de29b % 2**30`.
  - `test_same_content_same_time_across_checkouts`: two clones of one repo, after the script runs in each, `os.stat(f).st_mtime` of one file is equal in both and equals `mtime_for` of its blob.
  - `test_changed_content_changes_the_time`: commit `a.swift` = "1", run, record mtime; change to "2", commit, run: mtime differs.
  - `test_untracked_files_are_left_alone`: an untracked file's mtime is unchanged.
- [ ] **Step 2: Run** `python3 -m unittest Scripts/tests/test_restore_mtimes.py -v` — expect import failure.
- [ ] **Step 3: Implement** `Scripts/restore_mtimes.py` (stdlib; `subprocess.run(["git", "ls-files", "-s", "-z"])`, parse `mode blob stage\tpath`, `os.utime(path, (t, t), follow_symlinks=False)` for mode `100644`/`100755` only). Module docstring says why (cache reuse after checkout; inequality-based rebuild in Swift's build systems).
- [ ] **Step 4: Run** the tests — PASS; run `python3 Scripts/restore_mtimes.py` in the repo — prints a count > 1000 and exits 0.
- [ ] **Step 5: Commit** `ci: content-derived file timestamps for build caches`.

### Task 2: Three iPhone journeys, no coverage contract or shards

**Files:**
- Modify: `Tests/iOSLayout/UITests/BannerJourneys.swift` (keep `testWorkspaceNavigationJourney`, `testHealthyComposerJourney`, `testNotificationOpenJourneys`; delete the other ten and the `id`/`point`/`done` helpers)
- Modify: `Tests/iOSLayout/UITests/BannerLayoutTests.swift` (drop `coverage` and the `covering:` parameter of `checkLayout`; delete helpers no kept journey calls)
- Modify: `Tests/iOSLayout/Harness/LayoutApp.swift` (delete launch screens/notices no kept journey requests: kept ones request screens `list`, `scrolling`, `notification-cold`, `notification-warm`, notices default and `healthy`)
- Modify: `Tests/iOSLayout/project.yml` (remove `WorkspaceLayoutComponentTests` target and from the scheme)
- Delete: `Tests/iOSLayout/UITests/JourneyCoverage.swift`, `coverage.json`, `shards.json`, `Tests/iOSLayout/ComponentTests/`, `Scripts/ios_layout_shards.py`, `Scripts/verify_ios_layout_coverage.py`, `Scripts/verify_ios_layout_results.py`, `Scripts/tests/test_ios_layout_coverage.py`, `Scripts/tests/test_ios_layout_results.py`, `Scripts/tests/test_ios_layout_shards.py`
- Modify: `Scripts/test-ios-layout.sh` (remove the `CI`/focused-coverage guard, the shard block and the verify call; after a passing `xcodebuild test`, write the summary JSON and fail unless `totalTestCount > 0` and `result == "Passed"`, the same inline check `Scripts/test-macos-smoke.sh` uses)
- Modify: `Tests/iOSLayout/README.md` (rewrite: what the three journeys cover, how to run, results location; no counts contract)
- Modify: `Scripts/tests/test_ci_timings.py` only if it imports a deleted script (check with grep)

**Interfaces:**
- Produces: `./Scripts/test-ios-layout.sh [xcodebuild args]` with env `B4APP_LAYOUT_DESTINATION`, `B4APP_LAYOUT_DERIVED_DATA`, `B4APP_LAYOUT_RESULTS` (unchanged names); no `B4APP_LAYOUT_SHARD`, `B4APP_LAYOUT_FOCUSED_COVERAGE`, `B4APP_LAYOUT_EXPECTED_*`.

- [ ] **Step 1: Edit the journeys and helpers** as listed; `checkLayout(_ app:, screen:, hasBanner: Bool = true)` keeps every assertion it makes today except the coverage marker.
- [ ] **Step 2: Delete** the listed files; `grep -rn "JourneyCoverage\|coverage.json\|shards.json\|ios_layout_shards\|verify_ios_layout\|B4APP_LAYOUT_SHARD\|FOCUSED_COVERAGE\|EXPECTED_UI_TESTS" --exclude-dir=.build --exclude-dir=docs .` prints nothing outside `.github/workflows/ci.yml` (Task 4 handles that).
- [ ] **Step 3: Run** `./Scripts/test-ios-layout.sh` locally — expect `** TEST SUCCEEDED **`, 3 tests passed, the summary check exits 0. Then run `./Scripts/test-ios-layout.sh -only-testing:WorkspaceLayoutTests/BannerLayoutTests/testNoSuchTest` — expect non-zero exit (empty run).
- [ ] **Step 4: Run** `swift format lint --strict --recursive Tests/iOSLayout`, `shellcheck Scripts/test-ios-layout.sh`, `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'` — all pass.
- [ ] **Step 5: Commit** `test(ios): three iPhone journeys; drop the coverage contract and shards`.

### Task 3: Five macOS smoke tests

**Files:**
- Modify: `Tests/macOSSmoke/UITests/RecoverySmokeTests.swift` (keep `testDesktopDarkRecovery`; delete the three other one-line tests; `journey(desktop:dark:)` stays)
- Modify: `Tests/macOSSmoke/UITests/B4RuntimeSmokeTests.swift` (keep `testDesktopDarkB4Recovery`; delete `testCompactLightB4Recovery`)
- Modify: `Tests/macOSSmoke/UITests/PaletteSmokeTests.swift` (keep `testPaletteAndSlashByKeyboard`; delete `testPalettePanelDragsSnapsAndKeepsItsShadow`, `testCommandCenterButtonOpensThePaletteOverItself`, and the private helpers only they call, e.g. `luminance`, the screenshot `snap` overload)
- Modify: `Tests/macOSSmoke/UITests/ReadingSmokeTests.swift` (keep `testALongThreadShowsEarlierRowsOnRequest`; delete `testJumpToLatestAndCopyCode`, `testATallFirstMessageOpensAtItsEnd` and helpers only they call)
- Keep: `FixtureLifetimeTests.swift` unchanged
- Modify: `Tests/macOSSmoke/README.md` (describe the five tests; remove the compact-width and 800-point variant instructions that no test uses; keep `B4APP_SMOKE_DESKTOP_WIDTH`)
- Modify: `Tests/macOSSmoke/` harness only where a fixture seed exists solely for a deleted test (leave it if unsure; dead seeds are harmless)

- [ ] **Step 1: Delete** the tests and orphaned helpers. The compiler's unused-private warnings and `grep -n "func " Tests/macOSSmoke/UITests/*.swift` confirm nothing orphaned remains.
- [ ] **Step 2: Build** `mkdir -p .build/macOSSmoke && xcodegen generate --spec Tests/macOSSmoke/project.yml --project .build/macOSSmoke && xcodebuild build-for-testing -project .build/macOSSmoke/WorkspaceSmoke.xcodeproj -scheme WorkspaceSmoke -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/macOSSmoke/DerivedData -quiet` — `** TEST BUILD SUCCEEDED **`. (A full local run drives the owner's desktop; CI runs it in Task 5.)
- [ ] **Step 3: Run** `swift format lint --strict --recursive Tests/macOSSmoke` — pass.
- [ ] **Step 4: Commit** `test(macos): five smoke tests`.

### Task 4: Workflow: one layout job, an app-builds job, caches

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Scripts/tests/test_ci_scope.py`

**Interfaces:**
- Consumes: `Scripts/restore_mtimes.py` (Task 1); `Scripts/test-ios-layout.sh` env (Task 2).
- Produces: jobs in this order: `scope`, `b4-runtime`, `lint`, `package`, `app-builds`, `apps`, `ios-layout`, `ios-layout-result`, `macos-smoke`, `hub`. `app-builds` (name "App builds", `runs-on: macos-26`, outputs `ios-app: ${{ steps.ios-app.outcome }}`, `macos-app: ${{ steps.macos-app.outcome }}`).

- [ ] **Step 1: Update `Scripts/tests/test_ci_scope.py` first** (it should fail against the current workflow):
  - `names` list = the order above.
  - macOS jobs == `["package", "app-builds", "ios-layout", "macos-smoke"]`, each with the scope `needs`/`if` line.
  - `apps`: `needs: [scope, app-builds]\n    if: always()\n`; env `JOBS: ${{ needs.app-builds.result }}`, `IOS: ${{ needs.app-builds.outputs.ios-app }}`, `MACOS: ${{ needs.app-builds.outputs.macos-app }}`; script: skip-pass only when `"$APPLE" = false` and `"$JOBS" = skipped`; then `test "$IOS" = success` and `test "$MACOS" = success`.
  - `app-builds` builds `-scheme B4App-iOS ` and `-scheme B4App-macOS `; no job contains `-Beta`; the macOS step has `if: ${{ !cancelled() }}` so it runs after a failed iOS build.
  - `ios-layout` has no `strategy:`/`matrix`; name "iOS layout tests".
  - Caches: in `package`, `app-builds`, `ios-layout`, `macos-smoke`: a step running `python3 Scripts/restore_mtimes.py` before the first build; an `actions/cache/restore` step with `if: github.event_name != 'push'`; an `actions/cache/save` step with `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` and a key ending `-${{ github.sha }}`; no plain `actions/cache@` step for `.build` or DerivedData.
  - `CombiningCheckTests`: update `test_the_app_builds_check` cases to the single-outcome form (pass: all success; pass: `APPLE=false JOBS=skipped IOS= MACOS=`; fail: each of `IOS`/`MACOS` in `failure`, `cancelled`, `skipped`, empty; fail: `JOBS=skipped` with `APPLE` `true` or empty). `test_the_layout_check` unchanged.
- [ ] **Step 2: Run** `python3 -m unittest Scripts/tests/test_ci_scope.py -v` — FAIL.
- [ ] **Step 3: Edit `ci.yml`:**
  - `package`: remove the XcodeGen, project, `.spm` cache and both iOS build steps and the `outputs:`; replace the `.build` `actions/cache@v4` with restore/save as above (key `spm-${{ runner.os }}-xcode26.6-${{ hashFiles('Package.resolved') }}-${{ github.sha }}`, restore-keys `spm-${{ runner.os }}-xcode26.6-${{ hashFiles('Package.resolved') }}-`); the save step comes after Test with `if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'` (every save step in this task uses that condition).
  - `app-builds` (new): checkout, Xcode 26.6, XcodeGen, `.spm` cache (as today), restore mtimes, restore DerivedData `.build/AppDerivedData` (paths `Build`, `ModuleCache.noindex` under it; key `dd-apps-${{ runner.os }}-xcode26.6-${{ hashFiles('Package.resolved') }}-${{ github.sha }}`), generate project, `B4App-iOS` build (id `ios-app`), `B4App-macOS` build (id `macos-app`, `if: ${{ !cancelled() }}`), both `-derivedDataPath .build/AppDerivedData CODE_SIGNING_ALLOWED=NO -clonedSourcePackagesDirPath .spm`, save DerivedData on push to main.
  - `apps`: as the test says.
  - `ios-layout`: drop the matrix and `B4APP_LAYOUT_SHARD`/`B4APP_LAYOUT_FOCUSED_COVERAGE`; restore mtimes + DerivedData (`.build/DerivedData`, prefix `dd-ios-layout-`) before the tests; artifact name `ios-layout-results`; save on push to main.
  - `ios-layout-result`: the env `SHARDS: ${{ needs.ios-layout.result }}` and step name "Every shard passed" stay (the test reads them); comment updated to say one job.
  - `macos-smoke`: drop the generate-project and two macOS build steps and `outputs:`; restore mtimes + DerivedData (`.build/macOSSmoke/DerivedData`, prefix `dd-macos-smoke-`); save on push to main.
- [ ] **Step 4: Run** `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'` and `actionlint` — PASS.
- [ ] **Step 5: Commit** `ci: app builds in their own job; one layout job; caches saved from main only`.

### Task 5: Decision, docs, pull request

**Files:**
- Create: `docs/decisions/D-NNN-ci-under-ten-minutes.md` (amends D-187, D-197, D-225; lists every removed journey, component test, smoke test, the beta builds, the shard plan and coverage contract; the caches and the timestamp rule; "Verification" says the timing proof follows after merge in a gate record)
- Modify: `README.md` lines 38–44 if they cite removed smoke journeys
- Modify: `AGENTS.md` only where it names removed behaviour (the `test-ios-layout.sh` line stays valid)

- [ ] **Step 1: Write** the decision; run `Scripts/docs-index.sh --next` for the number and `Scripts/docs-index.sh --check` — pass.
- [ ] **Step 2: Run** the full local gate: `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `actionlint`, `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'`.
- [ ] **Step 3: Push** `blove/ci-under-ten` and open the PR (body: what was removed, what remains, that timings come after merge); enable auto-merge (`gh pr merge --auto --squash`), which queues it.
- [ ] **Step 4: Wait for the PR's CI** — all four required checks pass; record each macOS job's time from `python3 Scripts/ci_timings.py` (cold: no main cache exists yet for the new keys).

### Task 6: Prove the caches after merge

**Files:**
- Create: `docs/verification/2026-11-DD-ci-under-ten-minutes.md`

- [ ] **Step 1:** After the merge, the push run on main saves the four caches: `gh cache list --ref refs/heads/main` shows keys with prefixes `spm-`, `dd-apps-`, `dd-ios-layout-`, `dd-macos-smoke-` and the merge SHA.
- [ ] **Step 2:** Open a measurement PR from main that changes one function body in one Swift file under `Sources/WorkspaceUI/` (a real, harmless change, e.g. a comment edit inside a function) plus the gate record skeleton. In each Xcode job's log, the compile tasks name that file and its module's dependants and not unrelated modules (`grep -c "SwiftCompile"` far below a cold build's count, and `grep` finds the changed file). In the package job, `swift build`'s "Compiling" lines likewise.
- [ ] **Step 3:** Re-run the PR's CI once more (two runs). From `Scripts/ci_timings.py`, record per run: wall clock to the last required check and each macOS job's time. Success: both runs under 600 s.
- [ ] **Step 4:** For any job whose cache saved under 120 s against Task 5's cold time, remove that cache (restore/save/mtime steps) in this PR and say so in the gate record.
- [ ] **Step 5:** If a run is over 600 s, the gate record gives the numbers and the next-largest step; nothing else is cut without the owner.
- [ ] **Step 6:** Commit the gate record (`Scripts/docs-index.sh --check` passes), revert the measurement Swift change, and auto-merge.
