## 2026-11-04: Production TestFlight build for notices on every iPhone workspace surface

- The owner explicitly approved merging PR #129 on green and uploading the new production TestFlight build. All four checks passed: Workflow and shell lint, Package build and tests, macOS and iOS app builds, and Hub (Rust). The first Rust attempt failed the existing `the_change_listener_survives_a_dropped_connection` assertion; rerunning that job on the unchanged revision passed. No Rust implementation or tests were changed.
- CI ran all 13 layout UI tests on iPhone 17 Pro, iOS 26.4.1, with zero failures or skips. The earlier local matrix passed on iOS 26.5. The CI run retained the `ios-layout-results` artifact. See `2026-11-04-iphone-banner-all-screens.md` for coverage and the title-rendering regression.
- PR #129 merged at `395ed67c561b324a4a0b76c986ba9e016a16024e` on 2026-11-04 at 20:41:35 PST. The merged tree exactly matched approved PR head `a717b5d92f17506d9288eb7a564ba44f2cdbe8d1`.
- A clean checkout of that exact merged commit produced production version 0.1.0 (2611050442) through `Scripts/upload-ios.sh`. Archiving, distribution export/signing, app and widget entitlement checks, App Store Connect validation, and upload succeeded. Validation and upload reported no errors. The exported app's Info.plist confirms `B4AppFlavor=prod`, bundle id `com.cacheplane.b4app.ios`, version 0.1.0, and build 2611050442.
- App Store Connect confirms build 2611050442 is `VALID`, with internal state `IN_BETA_TESTING`; uploaded date 2026-11-04 at 20:46:56 PST. It is ready for internal production TestFlight testing.

### Physical iPhone step 5 retest

Install 2611050442. Begin on the threads list / home page, disable Wi-Fi and cellular connectivity, and verify the title, profile, filter and search controls remain available while the sync notice is shown. Open a thread and use Back to return to the list. Restore connectivity and confirm the notice clears promptly after successful sync on both home and detail; then send a message. Record any remaining overlap or persistent banner and its approximate duration.

The owner confirmed the thread layout on 2611050250 but found the home-page failure. On 2026-11-05, following the 2611050442 retest instructions, the owner reported step 5 worked and recovery took "a few seconds tops". Step 5 is owner-reported passed; see `2026-11-05-iphone-step5-physical-retest.md`. Notification checks remain open.
