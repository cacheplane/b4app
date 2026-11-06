# iOS navigation and banner regression tests

Run `./Scripts/test-ios-layout.sh` from the repository root. It requires Xcode, XcodeGen, and an iOS 26 iPhone Simulator. It generates its project under `.build/iOSLayout` and retains an `.xcresult` bundle with screenshots. CI runs it after all four app builds.

The fixture app renders the shipped `WorkspaceRootView` and `SyncBanner` over an in-memory mirror and fake relay. It never accesses the owner's account, Keychain, hub, mirror, or installed app. These are fixture UI checks, not physical-device or live-hub integration checks.

The required scheme runs 13 UI journeys and three UIKit-hosted component tests. The journeys cover all 62 legacy launch scenarios and their 69 layout checkpoints in 42 app launches. Four identical initial-state layout blocks share assertions; all custom copy, rendered-ink, geometry, control-hit, search, dismissal, recovery, and notification checks remain. Every behavior stays in the PR gate.

| Journey family | App launches |
| --- | ---: |
| Workspace navigation, search, scrolling | 2 |
| Healthy workspace and composers | 1 |
| Sync copy variants | 4 |
| Secondary notices and dismissal | 9 |
| Connecting notice gutters | 1 |
| Startup and empty-state guards | 7 |
| Landscape | 3 |
| Maximum text and older timestamp | 4 |
| Dark refusal | 3 |
| Recovery | 2 |
| Sign-in and onboarding | 3 |
| Notification cold/warm opening | 2 |
| Notification cancellation | 1 |
| **Total** | **42** |

Home-to-thread, Back, new-thread, and search transitions use real controls. Distinct cold entries remain for all seven startup surfaces, sign-in/onboarding, notification roots and cancellation, recovery, no-ready-runtime and no-Mac states. The cold sync/new-thread start preserves its keyboard state. Both cold action-error detail starts remain because a warm refresh can clear the injected error. No fixture reset channel was introduced.

Coverage includes populated, empty, archived, unmatched-search and scrolled lists; detail and new-thread composers; all original sync, account, Mac-offline and action-error variants; portrait, landscape, accessibility text and dark mode. Alignment retains the 16 pt page gutter and 32 pt composer-text inset. Picker alignment measures rendered ink, and navigation titles are checked in rendered screenshots as well as accessibility and geometry.

`UITests/coverage.json` keeps stable historical IDs for the 25 original methods, 62 scenarios and 69 checkpoints. Each layout marker follows its assertions; each scenario completion follows its remaining custom assertions. Actual xcresult activities must contain every one of the 131 IDs exactly once, in addition to exactly 13 passing UI cases and three passing component cases, with no skipped, failed or expected-failure cases. Markers supplement assertion/input review; they do not prove equivalent inputs by themselves. Missing, duplicate or unknown IDs fail the gate.

Fast Swift-package `SyncBannerContentTests` check copy, visibility, precedence and timestamp formatting. The UIKit component tests render the actual banner and check healthy height, text pixels, inset and maximum-text wrapping. They do not replace navigation, safe-area, keyboard, hit-testing, recovery or notification UI coverage.

To choose a device and result location:

```sh
B4APP_LAYOUT_DESTINATION='platform=iOS Simulator,id=<device UUID>' \
B4APP_LAYOUT_RESULTS=/tmp/banner-layout.xcresult \
  ./Scripts/test-ios-layout.sh
```

Extra arguments go to `xcodebuild`. For a focused local journey:

```sh
B4APP_LAYOUT_FOCUSED_COVERAGE=1 \
B4APP_LAYOUT_EXPECTED_UI_TESTS=1 B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS=0 \
  ./Scripts/test-ios-layout.sh \
  '-only-testing:WorkspaceLayoutTests/BannerLayoutTests/testWorkspaceNavigationJourney()'
```

Focused coverage derives the required subset from the reviewed method mapping. Both script and direct result-reader entry points refuse that override when `CI` is set. CI always requires the full contract. Component-only diagnostics use `B4APP_LAYOUT_EXPECTED_UI_TESTS=0 B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS=3` and `-only-testing:WorkspaceLayoutComponentTests`; they cannot satisfy the full gate. New behaviors require updating the manifest and counts while retaining existing obligations.
