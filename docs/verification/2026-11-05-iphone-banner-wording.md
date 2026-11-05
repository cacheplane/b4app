## 2026-11-05: iPhone sync banner wording

The owner requested simpler banner wording, a pull request merged after green checks, and a new production TestFlight build for a physical iPhone retest. This follows the padding cleanup in PR #134 and the physical step 5 pass on build 2611050442.

### Behavior

- Before the first successful sync: “Not synced yet. Retrying…”. Afterward: “Last synced [time]. Retrying…”, including the date for an earlier day.
- A refused relay asks “Log out, then sign in to reconnect.” It takes precedence over a transient sync error and does not promise an automatic retry.
- A mirror that cannot be opened says “Sync paused. Check Diagnostics.” The app passes its existing store-error state to the banner; no retry or account lifecycle behavior changes.
- Raw transport/server errors remain in the mirror's stored sync status and Diagnostics. The banner no longer includes them or forces a single line; text can wrap with Dynamic Type.
- The existing 16 pt gutter, navigation placement, and composer/control spacing are retained.

### Verification

Four focused UI regressions failed against the previous implementation with the expected old copy: raw transport errors, the previous stale-sync wording, the longer sign-in instruction, and a paused mirror described as a transient sync failure. Result: `/tmp/b4app-banner-copy-red2.xcresult` (four tests, four expected failures). A first attempt selected zero tests and was rejected by the runner; it is not regression evidence.

The permanent fixture harness renders the shipped iOS banner and shared workspace shell. Five new cases cover initial sync failure, a server failure after success, an earlier day's timestamp at maximum accessibility text size, refused access, and an unreadable mirror, each on Home and thread detail. The full matrix now contains 23 tests.

| Check | Result |
| --- | --- |
| `swift build` | Pass |
| Complete `swift test` | Pass: 1,403 tests in 169 suites, 81.544 seconds |
| Shipping iOS Simulator app build | Pass |
| Strict Swift format, documentation structure and diff checks | Pass |
| Independent code review | No actionable findings |
| Complete iPhone layout matrix | Pass: 23 tests, zero failures/skips, 566.696 seconds |
| Screenshot inspection | Home/detail, retry/refusal/paused, and older timestamp at maximum Dynamic Type: banner readable, below navigation, with controls available |

The complete result bundle is `/tmp/b4app-banner-copy-matrix.xcresult`; exported screenshots are under `.build/verification/2026-11-05-banner-wording/`. This is an isolated fixture UI gate, not a new physical iPhone or live-provider test. The new TestFlight build requires the owner's on-device retest.
