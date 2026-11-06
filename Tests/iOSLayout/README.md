# iOS navigation and banner regression tests

Run `./Scripts/test-ios-layout.sh` from the repository root. It needs Xcode, an installed iOS 26 Simulator runtime, and XcodeGen. The script selects an available iPhone (preferring an already booted one), generates its test project under `.build/iOSLayout`, and leaves an `.xcresult` bundle there with screenshots. CI runs it after the app builds.

The fixture app compiles the shipped `WorkspaceRootView` and `SyncBanner` over an in-memory mirror and fake relay. It never accesses the owner's account, Keychain, hub, mirror, or installed app. Its test targets are separate from the shipping app targets. The required scheme retains all 25 UI tests and adds three UIKit-hosted component tests of the actual `SyncBanner`. No UI behavior has moved out of the PR gate.

Coverage includes populated, empty, archived, unmatched-search, and scrolled thread lists; thread detail, the new-thread composer, and its no-ready-runtime fallback; Connect your Mac; sign-in and onboarding; sync failure, stale-sync, relay refusal, account notice, Mac-offline and action-error notices; healthy and recovered states; portrait, landscape, accessibility text, and dark mode. The tests tap a thread and return, use search, and check banner clearing on home and detail. The home checks include the profile, filter, search, and new-thread controls.

Horizontal alignment checks measure the 16 pt page gutter on home and thread connection notices and the home composer. On both composer screens they compare the rendered picker-label ink with the draft text's 32 pt leading edge (16 pt outside plus 16 pt inside the field). Menu labels and plain labels expose different accessibility hit bounds, so those bounds alone cannot prove visible text alignment.

Navigation titles are checked in their rendered screenshots as well as accessibility and geometry. UIKit can report a large title as present even when a top safe-area notice prevents its text from being drawn. List headers must remain below navigation controls as the title expands or collapses.

To target a device or retain results at a chosen location:

```sh
B4APP_LAYOUT_DESTINATION='platform=iOS Simulator,id=<device UUID>' \
B4APP_LAYOUT_RESULTS=/tmp/banner-layout.xcresult \
  ./Scripts/test-ios-layout.sh
```

Fast `SyncBannerContentTests` in the Swift package check banner visibility, copy, refusal/paused precedence, and today/older timestamp formatting with an explicit clock, calendar, and locale. The UIKit component tests check healthy-banner height, actual text pixels, the 16 pt marker inset, and maximum-text wrapping. They do not certify navigation placement, safe areas, keyboard behavior, accessibility hit testing, recovery, or notification catch-up; those remain UI responsibilities. Rendered timestamp geometry still uses the runner's Foundation locale and time zone.

The result gate requires exactly 25 passing UI cases and three passing component cases, with no skipped or failed tests. It checks each target independently, so a component-only run cannot silently satisfy full coverage. When adding tests, update the expected counts in both the script defaults and CI.

Extra arguments go to `xcodebuild`, for example `'-only-testing:WorkspaceLayoutTests/BannerLayoutTests/testListBannerKeepsLargeTitleAndToolbarVisible()'`. Include the parentheses and quote the entire argument. For an intentionally focused run, set `B4APP_LAYOUT_EXPECTED_UI_TESTS=1 B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS=0` for that selector; for all component tests, use `B4APP_LAYOUT_EXPECTED_UI_TESTS=0 B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS=3` with `-only-testing:WorkspaceLayoutComponentTests`. These overrides are for local diagnostics; CI explicitly requires both full targets. The script rejects zero tests and count mismatches. These are fixture layout checks, not a physical-device or live-hub integration gate.


The journey-consolidation baseline also requires the coverage manifest's 62 legacy scenarios and
69 layout checkpoints (131 distinct execution markers) from the actual xcresult activities. A marker
records that an assertion block ran; it does not replace an assertion or prove equivalent fixture
inputs. Duplicate, unknown, and missing markers fail the gate. The original 25 UI methods remain
intact while additive journeys are proved.

For focused local UI diagnostics also set `B4APP_LAYOUT_FOCUSED_COVERAGE=1`; this derives the
required subset from the reviewed method mapping. Both script and result-reader entry points refuse
focused coverage when `CI` is set. CI always requires the full obligation set.
