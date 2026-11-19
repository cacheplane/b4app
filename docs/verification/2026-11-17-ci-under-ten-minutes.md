## 2026-11-17: CI under ten minutes

D-244's post-merge proof, with D-249's changes to the layout job. Measured on #221, a pull request from `main` da8b4cf4 that changed the body of `UsageFormat.fill` in `Sources/WorkspaceUI` (reverted before merge), restoring the caches main's push run 44016917853 saved: `spm-` (694 MB), `dd-apps-` (463 MB), `dd-ios-layout-` (89 MB) and `dd-macos-smoke-` (195 MB).

### The cache rebuilds what changed

- Run 44136611342, attempt 2: the layout build compiled `UsageFormat.swift` and then the `WorkspaceUI` module step, and nothing else; the build took 32 s. With file times from `Scripts/restore_mtimes.py`, a restored DerivedData is reused, not rebuilt.

### Each job's run time

The clean build is main's push run 44016917853, which restores nothing. The cached runs are #221's runs with D-249 in place.

| Job | Clean | Cached, run 1 | Cached, run 2 |
|---|---|---|---|
| Package build and tests | 13:45 | 5:47 | 7:39 |
| iOS layout tests | 12:12 (D-244's layout) | 7:09 | 13:53 |
| macOS recovery smoke tests | 7:52 | 6:04 | 5:01 |
| App builds | 5:48 | 2:17 | 3:19 |
| Hub (Rust), Ubuntu | 4:53 | 5:01 | 5:19 |

Run 1 is 44203552125 attempt 1; run 2 is its attempt 2, on the same commit. Every macOS job was under ten minutes in run 1; in run 2 the layout job took 13:53, so D-244's second condition held in one run of two.

Run 2's layout job was slow on a slow runner, not on a cold Simulator: xcodebuild took 2:52 to start before the build and 1:39 before the tests, against seconds elsewhere, and the five tests' app launches took 4:16, against 2:44 for the whole test step in run 1. The Simulator had finished booting before the tests began ("Device already booted"), so a warm-up would not have shortened it. Every job in run 2 ran slower than in run 1 (package 7:39 against 5:47, app builds 3:19 against 2:17).

The layout job before D-249, on the same cache: 14:04 (44136611342), then 11:56 with the build during the boot (44152599350), then 13:17 building for no device (44198847451; its verbose log showed xcodebuild's startup at 2:43 and package resolution at 3:05 beside the booting Simulator, against 8 s and 28 s in "App builds"), then 7:09 with the pins.

### Wall clock: not met

D-244's first condition, under ten minutes from the first job's start to the last required check, was not met, and the cause is waiting for runners, not the jobs. GitHub flagged macOS arm64 capacity as constrained all day, and its annotation was on every macOS job:

- Run 1: first job started 00:02:29, last required check 00:44:27, 42 minutes. The macOS jobs waited 11 to 20 minutes for a runner, and the two Ubuntu combining checks waited 23 and 25.
- Run 2: no job started for 13 minutes after the run was created, Ubuntu included; first job started 00:58:00, last required check 02:00:17, 62 minutes. The layout job's combining check waited 22 minutes for an Ubuntu runner.
- Twice a macOS job was never given a runner and was cancelled ("The job was not acquired by Runner of type hosted even after multiple attempts"; 44136611342 attempt 1, 44152599350 attempt 1).

With no waiting, the longest path is the scope job, the layout job and its combining check: about 7½ minutes.

### Caches kept

D-244 removes a cache that saves under two minutes. Package saves about eight minutes and the app builds about three and a half. The layout job's clean time was D-244's layout, so its cache is not compared on equal terms; it is kept. The smoke job saved 1:48 to 4:21 across three cached runs (3:31, 5:57, 6:04) against one cold run of 7:52; the owner kept it (D-249).
