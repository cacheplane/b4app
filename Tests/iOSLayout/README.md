# iOS navigation and banner regression tests

Run `./Scripts/test-ios-layout.sh` from the repository root. It requires Xcode, XcodeGen, and an iOS 26 iPhone Simulator. It generates its project under `.build/iOSLayout` and retains an `.xcresult` bundle with screenshots. CI runs it in its own job, beside the app builds.

The fixture app renders the shipped `WorkspaceRootView` and `SyncBanner` over an in-memory mirror and fake relay. Its banner reads an `@Observable` status, as the app's reads `MirrorHost`, and its fake hub greets every link the relay opens and answers its pings, so a runner that stalls the app does not leave a stale banner or "Connecting to the hub…" behind. The tests wait for a screen's title and then for a hittable notice before judging it, since a pushed thread's banner exists in accessibility before it can be hit. It never accesses the owner's account, Keychain, hub, mirror, or installed app. These are fixture UI checks, not physical-device or live-hub integration checks.

The required scheme runs 13 UI journeys and three UIKit-hosted component tests. The journeys cover the 61 legacy launch scenarios that still exist and their 68 layout checkpoints in 41 app launches. The 62nd, an unmatched search typed into the list, went from main with the list's search field (D-201). Four identical initial-state layout blocks share assertions; all custom copy, rendered-ink, geometry, control-hit, search, dismissal, recovery, and notification checks remain. Every behavior stays in the PR gate.

| Journey family | App launches |
| --- | ---: |
| Workspace navigation, search, scrolling | 2 |
| Healthy workspace and composers | 1 |
| Sync copy variants | 4 |
| Secondary notices and dismissal | 9 |
| Connecting notice gutters | 1 |
| Startup and empty-state guards | 6 |
| Landscape | 3 |
| Maximum text and older timestamp | 4 |
| Dark refusal | 3 |
| Recovery | 2 |
| Sign-in and onboarding | 3 |
| Notification cold/warm opening | 2 |
| Notification cancellation | 1 |
| **Total** | **41** |

Home-to-thread, Back, new-thread, and search transitions use real controls. Distinct cold entries remain for all six startup surfaces, sign-in/onboarding, notification roots and cancellation, recovery, no-ready-runtime and no-Mac states. The cold sync/new-thread start preserves its keyboard state. Both cold action-error detail starts remain because a warm refresh can clear the injected error. No fixture reset channel was introduced.

Coverage includes populated, empty, archived and scrolled lists, and the Search sheet opening from the list; detail and new-thread composers; all original sync, account, Mac-offline and action-error variants; portrait, landscape, accessibility text and dark mode. Alignment retains the 16 pt page gutter and 32 pt composer-text inset. Picker alignment measures rendered ink, and navigation titles are checked in rendered screenshots as well as accessibility and geometry.

`UITests/coverage.json` keeps stable historical IDs for the 25 original methods and the 61 scenarios and 68 checkpoints that remain. Each layout marker follows its assertions; each scenario completion follows its remaining custom assertions. Actual xcresult activities must contain every one of the 129 IDs exactly once, in addition to exactly 13 passing UI cases and three passing component cases, with no skipped, failed or expected-failure cases. Markers supplement assertion/input review; they do not prove equivalent inputs by themselves. Missing, duplicate or unknown IDs fail the gate.

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

CI runs the suite as two parallel jobs, the shards of `UITests/shards.json` (`B4APP_LAYOUT_SHARD=1` or `2`; `Scripts/ios_layout_shards.py`). A shard takes its tests, its counts and the checkpoints it owes from the plan, never from the caller, and first checks the whole plan: the shards hold each of the 13 journeys and the component bundle exactly once, and together they owe all 129 IDs. The last shard runs everything the others do not name, so a test placed in no shard runs there and fails the count. The required check "iOS navigation and banner regression tests" passes only when every shard passed. A new journey must be added to the manifest and to one shard. Without `B4APP_LAYOUT_SHARD` the script runs the full suite in one run, as before.

Focused coverage derives the required subset from the reviewed method mapping. Both script and direct result-reader entry points refuse that override when `CI` is set. CI always requires the full contract. Component-only diagnostics use `B4APP_LAYOUT_EXPECTED_UI_TESTS=0 B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS=3` and `-only-testing:WorkspaceLayoutComponentTests`; they cannot satisfy the full gate. New behaviors require updating the manifest and counts while retaining existing obligations.
