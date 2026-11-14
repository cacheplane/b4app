## 2026-11-14: the layout shards on hosted runners, and a wait that gave up on a stalled runner

The first hosted measurement D-225 left to this record, and the cause of the first failure on `main` after it. Branch `blove/ci-shard-wait`, from `main` 5edf935.

### The shards' times

Three `ci.yml` runs with the two shards, all on 2026-11-14 (UTC), against the single layout job's median of 23.2 minutes (D-225):

| Run | Commit | Shard 1: waited, ran | Shard 2: waited, ran | Push to result |
| --- | --- | --- | --- | --- |
| 43561687844 | #198's head a2190cd | 12.6 min, 14.7 min | 5.0 min, 15.2 min | 27.4 min, passed |
| 43563885132 | `main` c15be6d | 0.0 min, 12.3 min (failed) | 0.4 min, 15.7 min | 16.2 min, failed |
| 43564176982 | `blove/ci-flakes` d1f90a6 | 12.2 min, 11.9 min | 9.4 min, 16.5 min | 25.9 min, passed |

- A shard that passed ran for 11.9 to 16.5 minutes, of which the test step was 13.6 and 14.3 in the two shards of the first run. That is the "near 14 minutes" D-225 expected.
- The time from push to a green run did not fall: 27.4 and 25.9 minutes, against a median of 27.6 before. In both, a shard waited 12 minutes for a macOS runner while other runs (another branch's among them) held runners. The one run whose jobs all started within a minute ended in 16.2 minutes, and it is the failed one.
- So the split shortens the layout job and has not yet shortened a green run. Whether it does depends on how often five macOS jobs find runners at once; three runs do not show that either way.
- In the two green runs shard 1 verified 54 of 54 checkpoints (4 journeys and the 3 component tests) and shard 2 verified 75 of 75 (9 journeys): 129 in all. In the failed run shard 2 verified its 75 and the combining job failed with shard 1.

### The failure on `main` (run 43563885132, shard 1)

- Seen: `BannerLayoutTests.testSecondaryNoticeJourneys` failed with "account-notice is missing or obscured" on the journey's fifth launch. The failure's own dump of the app shows `account-notice` on screen at 0, 203.7, 402 by 67 pt, with its text and its Dismiss button.
- What the result bundle shows: the journey's launches took 5.2 s, 3.1 s, 5.7 s, 11.2 s and 11.2 s, so the runner was slowing down. After the fifth, `waitForVisible` looked for the notice twice. The first look took 5.1 s and found nothing; the second began 5.1 s into the 10 s wait, took 18.4 s, and found nothing; the wait had then passed its deadline and returned. On the first launch of the same journey the same look took 0.13 s.
- Cause: a look is a snapshot of the app's accessibility tree, and one that takes 18 s reports the app as it was when it began. The wait counted that time against its deadline, so it ended after two looks without looking at the app as it then was.
- Not caused by the split: shard 1 runs its four journeys in the order the single job ran them, and the same commit's tests passed in #198's run an hour earlier. Nothing here shows why the runner stalled.
- Change: `waitForVisible` looks once more after the deadline. The element must still be drawn and hittable, and a missing element still fails; a slow look no longer ends the wait on its own. No timeout or tolerance changed.

### Checks

- `B4APP_LAYOUT_SHARD=1 ./Scripts/test-ios-layout.sh` with the change, on this checkout's Simulator: 4 journeys and the 3 component tests passed, 54 of 54 checkpoints, `testSecondaryNoticeJourneys` among them. It is also shard 1's first local run; D-225 had run only shard 2.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; `Scripts/docs-index.sh --check` passes.
- Not reproduced: the stall itself. The change is argued from the one result bundle; a run on a runner that stalls the same way is what would show it.
- Not addressed: `RecoverySmokeTests.testCompactDarkRecovery`, which failed once in D-225's sample with a bare assertion and has not failed in these three runs.
