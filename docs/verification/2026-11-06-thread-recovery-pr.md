## 2026-11-06: Thread recovery integration and PR validation

Continued the recovery-notice work from the installed local build onto current main, including the coordinator's deleted-thread publication fences, UI padding changes, notification opening, and widget catch-up work. The code and installation evidence from November 4 and 5 remain in their original gate records.

The initial integration run required synchronizing model fixtures with a fresh snapshot before opening directly seeded threads. It also encountered the notification test's clock-registration race, which current main already fixes. The recovery model test passed after those integration updates.

Final review identified a missing context fence when an archived refusal restores a draft. A controllable fixture response delays rejection until the test changes selection, forgets the thread, or forgets the account. All three cases failed before the fix. Restoration now requires the original account generation, selected thread, open detail, and an undeleted origin. Coverage also confirms that the other thread's saved draft stays empty.

- Focused recovery, delayed-response race, and notification-opening checks passed: 15 tests in 3 suites (28.179 s).
- Final review found no remaining important issues after the context fence was added.

Final validation on main `785983b` plus this change:

- `swift build` passed.
- `swift test --no-parallel` passed all 1,432 tests in 175 suites (343.545 s), including the expanded-details sizing checks and the three delayed-draft cases.
- Two default-parallel runs failed with timing issues: the first had six mirror-sync timeouts; the repeat had seven mirror-sync timeouts, a runtime-version fixture timeout (two assertions), and a relay-presence clock tolerance failure. No mirror implementation or tests are changed here. The isolated mirror-sync suite passed all 23 tests (0.665 s). The serial pass establishes correctness in that execution mode; it does not establish that default-parallel execution is reliable on this host.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `git diff --check`, and `Scripts/docs-index.sh --check` passed.
- Two fresh macOS Release-Local native-build attempts stalled before app compilation in Xcode's compiler capability probes and were canceled. A stack sample showed `clang::driver::Command::Print` blocked in `write`; running the same probe directly completed successfully. The previously installed, signed layout fix remains in place. The added context fence and updated-main integration have not been installed from this checkout.
- The independent iOS Simulator build also stalled at the compiler capability probe before app compilation and was canceled. Both native builds and the default-parallel test run require fresh CI verification; the pull request is kept in draft for that reason.

The original session remains archived. No user message was resent, no live inference was initiated, and the original session was not unarchived during this continuation. A fresh live expanded-notice check remains pending because the installed app currently has no transient error to expand; the fixture rendering and minimum-size checks passed.
