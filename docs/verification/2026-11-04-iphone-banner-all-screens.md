## 2026-11-04: iPhone notices preserve navigation on every workspace surface

### Owner report and reproduction

The owner reported production TestFlight build 2611050250 looked good in a thread but still failed on the threads list / home page, and requested testing all implementations. That build came from PR #126; its upload is recorded in `2026-11-04-iphone-sync-recovery-testflight.md`.

The shipped shell and banner reproduced a blank large "Threads" title on the iPhone 17 Pro Simulator, iOS 26.5. UIKit still exposed the title's accessibility element and correct bounds. A screenshot of that element contained no title pixels. Moving the safe-area inset onto the List, or using a native top safe-area bar, also left the title blank; the healthy control rendered it. The screenshot assertion failed against the previous implementation (`/tmp/b4app-layout-red3.xcresult`: one test, one failure, foreground fraction 0).

### Correction and permanent regression gate

- Home sync, account, Mac-offline, and action-error notices now share a native pinned List section header below the navigation bar. The list retains its large title, search, profile and filter controls, and bottom new-thread dock. Connect your Mac retains its own top inset; detail uses inline navigation titles, including the new-thread composer and no-ready-runtime fallback.
- `SyncBanner` moved unchanged into its own app source file so the isolated fixture target compiles the shipped implementation. The harness uses the shipped `WorkspaceRootView`, an in-memory mirror, fake relay/socket/API, in-memory preferences and secrets, and a separate bundle id. It never uses the owner's data, account, Keychain, installed app, or live hub.
- `Scripts/test-ios-layout.sh` generates a separate test project under `.build/iOSLayout`. Its 13 UI tests check rendered navigation titles, banner/control geometry and hittability, thread navigation and Back, search, scrolling, secondary-notice dismissal, and sync-banner removal on both home and detail. A fixture-only recovery button changes sync status deterministically; it does not claim a live network recovery.
- The matrix covers populated, empty, archived, unmatched-search and long lists; thread detail; the new-thread composer and no-ready-runtime fallback; Connect your Mac; sign-in with/without a camera and onboarding. Notices include initial/stale sync failure, relay refusal, account notice, Mac offline and action error, including secondary notices both alone and combined with sync failure. It exercises portrait, landscape, maximum accessibility text, dark appearance, healthy state and recovered state.
- CI's app job runs the gate and retains `.xcresult` screenshots, accessibility trees and test results. The script explicitly rejects zero executed tests, even when `xcodebuild` returns success. An intentionally nonexistent selector exercised that guard and exited unsuccessfully as required.

### Verification on current main

The follow-up was rebased onto `origin/main` at `55ce1c4`, including PR #128's profile/search header, new-thread dock and composer. The fixture seeds a real mirror project/folder and ready runtime for that composer, and separately exercises its no-ready fallback.

| Check | Result |
| --- | --- |
| Full iPhone Simulator UI matrix | Pass: 13 tests, zero failures/skips; `/tmp/b4app-layout-current-main.xcresult` |
| Earlier UI matrix before the main rebase | Pass: 13 tests; `/tmp/b4app-layout-matrix4.xcresult` |
| Clean `swift build` | Pass |
| Clean `swift test` | Pass: 1,399 tests in 169 suites |
| Opt-in macOS UI rendering (`SnapshotTests`) | Pass: 12 tests in two suites, light and dark outputs |
| Shipping iOS Simulator app build | `BUILD SUCCEEDED` |
| Shipping macOS app build (signing disabled) | `BUILD SUCCEEDED` |
| Strict Swift format, shellcheck, actionlint, docs-index, diff checks | Pass |
| Independent review of layout, coverage and rebase | No actionable findings remaining |

The initial incremental Swift test link used stale objects with old runtime API signatures after the main rebase. Removing only the generated macOS debug products and rebuilding resolved it; the complete clean build/test run above then passed. The test runner emitted existing SwiftNIO event-loop shutdown warnings while passing; no hub or account was changed.

Representative current-main screenshots were visually inspected for home, the new-thread composer, and Connect your Mac. Full screenshots and accessibility trees remain in the result bundle; macOS rendering outputs are under `/tmp/b4app-banner-mac-current`. These are local verification artifacts, not committed images.

### Physical retest pending

This follow-up has not been uploaded to TestFlight. After merge and a new production build, repeat step 5 from both the home list and a thread: disable connectivity, use search/filter and Back, enter and leave a thread, restore connectivity, and confirm navigation remains available and the sync banner clears after successful sync. The owner has confirmed the thread layout on 2611050250, but has not yet separately reported the recovery timing on that build. Notification checks remain open.
