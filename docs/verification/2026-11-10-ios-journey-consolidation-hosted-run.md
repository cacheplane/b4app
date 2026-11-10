## 2026-11-10: iOS journey consolidation, first hosted run beside the 25-test suite

One hosted run of the 13 journeys and three component tests, and one of main's 25 tests started three minutes apart on the same runner image and Simulator (iPhone 17 Pro, iOS 26.4.1). One pair of runs is one sample; runner speed alone moved the 25-test job between 851 and 1246 s in earlier runs.

| | Journeys (this pull request, `7cd5819`) | 25 tests (main's suite, pull request 169) |
|---|---|---|
| Run and job | 42863478320, job 129995492408 | 42863703048, job 129996294330 |
| Result | 16 passed, 0 failed, 0 skipped; `B4_UI_OBLIGATIONS` required 131, verified 131 | 25 passed, 0 failed, 0 skipped |
| Tests, first start to last finish | 835 s | 1122 s |
| Simulator boot step | 32 s (the script's part 31 s, Simulator was shut down) | none; the wrapper boots it |
| Test step | 1193 s | 1519 s |
| Job | 1275 s | 1569 s |

- **Difference.** 287 s less in the tests and 294 s less for the job in this pair.
- **Earlier failure.** Run 42765752032 failed after 84 s in "Begin iOS Simulator boot": `simctl list` exceeded the script's 60 s limit on a cold runner. The listing now has 300 s and the step 7 minutes; in this run the whole script took 31 s.
- **Not covered.** The full journey suite has not completed on the owner's Mac since main was merged in; the one attempt failed to launch the test runner under load from other work (Mach error -308). The other macOS jobs of both runs had not finished when this was written.
