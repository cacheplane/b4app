## 2026-11-14: UI waits that look first, and a run on four macOS runners

The checks for D-229. Branch `blove/ci-waits-and-queue`, from `main` 3a32af8.

### Before (run 43612368923 on `main` e04f5f8)

- Waits, from the result bundles: 180 in the smoke suite took 250 s of its 543 s of tests, 175 of them 0.9 to 1.6 s and none under 0.5 s; 36 and 59 in the two layout shards took 46 s and 72 s of 371 s and 466 s. Four smoke waits took over 3 s: two of 15.1 s for a launch window that did not come, and two of 6.1 s and 7.1 s for B4's streamed text.
- Jobs: package 9.7 minutes, app builds 7.4 (macOS 149 s, iOS 105 s, macOS beta 88 s, iOS beta 80 s), layout shards 14.1 and 15.5, smoke 13.7. In that run and #199's, jobs waited 1 to 8.6 minutes for a macOS runner.
- The last 60 merged pull requests: 10 changed only files under `Hub/`, `Infra/` or `docs/`.

### Checks on this checkout

- `./Scripts/test-ios-layout.sh` (the whole suite, this checkout's Simulator) with the new waits: 16 of 16 tests passed, 13 journeys and the 3 component tests, 129 of 129 checkpoints verified. The result bundle holds no "Waiting" activity.
- The smoke suite compiles with the new waits (`xcodebuild build-for-testing` on `WorkspaceSmoke`). It was not run here: it drives the owner's pointer. CI's smoke job is its check.
- `python3 -m unittest discover -s Scripts/tests -p 'test_*.py'`: 47 passed, among them the scope's cases (a path outside the trees, a rename out of a tree, an empty or short list) and the workflow's shape (every macOS job runs unless the scope said `false`; the builds' check reads the four build steps and accepts a skip only with that `false`).
- `actionlint` clean; `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; `Scripts/docs-index.sh --check` passes.

### The first hosted run (43629968947, this branch's first commit 5ddc0f8, all 10 checks passed)

| Job | Waited for a runner | Ran | Its test step: before, now | Its tests alone: before, now |
| --- | --- | --- | --- | --- |
| Smoke | 11.0 min | 13.9 min | 750 to 773 s, 533 s | 543 s, 325 s |
| Layout shard 1 | 2.5 min | 8.7 min | 786 to 797 s, 486 s | 371 s, 222 s |
| Layout shard 2 | 10.2 min | 16.3 min | 865 to 876 s, 917 s | 466 s, 533 s |
| Package | 3.6 min | 15.1 min | | |

- The waits are gone from all three bundles: no "Waiting" activity, where they took 250 s, 46 s and 72 s. Shard 1 verified 54 of 54 checkpoints and shard 2 its 75.
- Smoke: its looks rose from 665 (86 s) to 1,040 (138 s), which is the new waits looking, so the suite's net gain is about 200 s. The launch window did not come in 15 s once (`testCompactDarkRecovery`, as in the run before), not twice.
- Shard 1 fell by more than its waits: its launches took 97 s where they took 154 s and its 1,188 looks 83 s where 1,152 took 124 s, and its build and setup 264 s where they took about 415 s. That is a faster runner, not this change. This change's part is the 46 s.
- Shard 2 did not fall, for two reasons the bundle shows. In `testLandscapeJourney` one `XCUIDevice.shared.orientation = .portrait` took 71.1 s (the other two took 0.1 s and under); the journey passed. And the runner was slower: 1,360 looks took 204 s where 1,295 took 139 s, and 24 launches 172 s where they took 143 s. Without its 72 s of waits the shard would have been that much slower still. The slow orientation change is the stall D-225 met before a launch, here in the journey that must make the change; it is not addressed.
- The builds: iOS 167 s and 122 s in the package job (105 s and 80 s in their own job, after the macOS builds had fetched the packages), macOS 147 s and 120 s in the smoke job (149 s and 88 s).
- `scope` waited 47 s for a Linux runner and ran 4 s, so the macOS jobs asked for runners 51 s after the push.
- Push to result: 27.4 minutes, against 20.8 to 25.9 in the four runs before. Two of the four macOS jobs waited over 10 minutes for a runner. One run shows no gain from asking for four runners; it does not show there is none.

### Not shown here

- That the smoke suite is steady without the second its waits used to spend: one hosted run passed, which does not show it.
- That a pull request of only `docs/` or `Hub/` files skips the macOS jobs and still reports its required checks: no such pull request has run with this workflow yet.
- Why two smoke launches showed no window in 15 s. Not changed.
