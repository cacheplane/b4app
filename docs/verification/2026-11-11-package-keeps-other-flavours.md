## 2026-11-11: package.sh replaces only its own flavour in dist/

On 2026-11-10 a Local build packaged in `~/repos/b4app` emptied `dist/` (`rm -rf "$DIST"`) and with it the prod and Beta apps. Their coordinators kept running from the deleted bundles, and both LaunchAgents pointed at executables that no longer existed, so a restart or reboot would have left those flavours with no coordinator (restored the same day; `2026-11-11-flaky-tests-and-shared-simulators.md`).

`package.sh` now calls `clear_flavour_outputs` (`Scripts/package-dist.sh`, sourced) in place of emptying `dist/`. It removes only the flavour's app, its zips of any version, and its notarization results. The notarization result is now named per flavour (`notarize<zip suffix>-<version>.json`), since prod's and Beta's shared `notarize-<version>.json`. A version starts with a digit, so prod's patterns never match Beta's or Local's files. `dist/ios*` (from `upload-ios.sh`) is left alone too.

### Gates

- `bats Scripts/tests/package-dist.bats`: 3/3. The two keep-the-others tests failed against a function that did what `package.sh` did before (`rm -rf` and `mkdir`), then passed.
- The function sourced under `/bin/sh`, as `package.sh` runs it: packaging Beta left a prod app and zip in place.
- End to end: an ad hoc Local `package.sh` in a scratch checkout of this branch, with prod and Beta apps, their zips, prod's notarization result, and an older Local zip seeded in `dist/`.
- shellcheck on the new script and test (added to CI's shellcheck list), `Scripts/docs-index.sh --check`.
