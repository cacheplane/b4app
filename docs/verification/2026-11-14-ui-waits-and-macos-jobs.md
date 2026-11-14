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

### Not shown here

- The hosted times with the change, and whether the smoke suite passes without the second its waits used to spend: the pull request's runs.
- That a pull request of only `docs/` or `Hub/` files skips the macOS jobs and still reports its required checks: no such pull request has run with this workflow yet.
- Why two smoke launches showed no window in 15 s. Not changed.
