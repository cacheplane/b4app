## 2026-11-04: Production TestFlight build for iPhone sync recovery

- The owner approved merging PR #126 on green and uploading the production iPhone build. All four PR checks passed: Workflow and shell lint, Package build and tests, macOS and iOS app builds, and Hub (Rust). The PR merged at `a033994a1f7c66767934a14577fc9d9b3d347c10` on 2026-11-04 at 18:50 PST.
- `B4APP_FLAVOR=prod ./Scripts/upload-ios.sh` built 0.1.0 (2611050250) from a clean checkout of that exact merged commit. The archive, distribution export, app/widget entitlement checks, App Store Connect validation, and upload succeeded. Apple reported the upload successful with no errors at 18:55 PST. The signed app's Info.plist confirms `B4AppFlavor=prod`, bundle id `com.cacheplane.b4app.ios`, and build 2611050250.
- App Store Connect reports build 2611050250 as `VALID` and its internal state as `IN_BETA_TESTING`. The production build is available for internal TestFlight testing; Apple's uploaded-date field is 2026-11-04 at 18:56:10 PST.

### Physical iPhone retest still open

Install 2611050250 from TestFlight and repeat step 5: with an existing thread open, disable the phone's network; navigate Back to the thread list and into a thread while the sync banner is visible; restore connectivity; confirm the banner clears promptly after sync recovers and a new message succeeds. Record any persistent notice, its approximate duration, and the local time.

The owner passed account/history, phone sends, live streaming, and background catch-up on the previous build, 2611050013. That build exposed the navigation overlap and delayed sync recovery; see `2026-11-04-iphone-sync-recovery.md`.

On build 2611050250 the owner reported that the banner looks good in a thread but still fails on the threads list / home page, and requested testing every implementation. The follow-up reproduction, correction, and automated screen matrix are recorded in `2026-11-04-iphone-banner-all-screens.md`. The owner has not separately reported the recovered banner's duration or notification checks. The follow-up layout correction requires a newer build.
