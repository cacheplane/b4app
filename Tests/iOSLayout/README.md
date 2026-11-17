# iOS navigation and banner regression tests

Run `./Scripts/test-ios-layout.sh` from the repository root. It requires Xcode, XcodeGen, and an iOS 26 iPhone Simulator. It generates its project under `.build/iOSLayout` and keeps an `.xcresult` bundle with screenshots. CI runs it in one job, "iOS layout tests", reported under the required check "iOS navigation and banner regression tests".

The fixture app renders the shipped `WorkspaceRootView` and `SyncBanner` over an in-memory mirror and fake relay. It never accesses the owner's account, Keychain, hub, mirror, or installed app. These are fixture UI checks, not physical-device or live-hub checks.

Three journeys, five app launches (D-244):

| Journey | What it drives |
| --- | --- |
| `testWorkspaceNavigationJourney` | The list with a sync notice, into a thread and Back, the Search sheet; a scrolling list's large and collapsed titles |
| `testHealthyComposerJourney` | No notice when healthy; the home composer's 16 pt gutters; the thread and new-thread composers' 32 pt text inset and picker ink; the "Start in" sheet |
| `testNotificationOpenJourneys` | Opening a notified thread cold and warm, waiting for its sync |

Every layout check confirms the screen's title is drawn (from its own screenshot), that a notice does not cover the title or the navigation buttons, and that the list's controls can be hit. The banner's copy, precedence and timestamps are checked by `SyncBannerContentTests` in the Swift package.

The script fails when xcodebuild fails or when the run executed no test. To run one journey:

```sh
./Scripts/test-ios-layout.sh \
  '-only-testing:WorkspaceLayoutTests/BannerLayoutTests/testWorkspaceNavigationJourney()'
```

To choose a device and result location:

```sh
B4APP_LAYOUT_DESTINATION='platform=iOS Simulator,id=<device UUID>' \
B4APP_LAYOUT_RESULTS=/tmp/banner-layout.xcresult \
  ./Scripts/test-ios-layout.sh
```
