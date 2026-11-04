## 2026-11-03: Step-up by code and the 1004 line on the Mac; the packaged coordinator's migrations (D-151, D-171)

Run on the owner's MacBook Pro by the build session alone (no Touch ID; the owner's Mac left cacheplane and came back by operator enrollment codes piped into `hub join`, never printed), after the pairing session confirmed it was not using the Local app, the Compose hub, or the Simulator. Branch `blove/coordinator-resources`, from main at `4c8a88c`.

| Check | Result |
| --- | --- |
| The 1004 line on the Mac | Pass. A throwaway account ("Mac Check", a personal org with a passkey row whose credential is on no device) was joined, and Settings → Account → Delete account… asked for the passkey. The Local app was in the background, so macOS refused to present the sheet ("Told not to present authorization sheet … AuthorizationError", `ASAuthorizationError` 1004), the same failure the sign-in hit on 2026-11-02. The delete sheet showed "The passkey sheet couldn't open. If another passkey request is still on screen, close it, then try again." and offered the enrollment code |
| Step-up by code on the Mac | Pass. A real `enroll` code, typed into the row, stepped up (hub: `method: code`) and the hub "deleted an account" (`204`); the Mac was signed out, its registry no longer listed Mac Check, and the hub held only cacheplane. The Mac then rejoined cacheplane by code on its own device (`01a19d4c…`) with the relay connected |
| Found: the packaged coordinator depended on its build tree (D-171) | Joining Mac Check first failed: the coordinator read `0001_init.sql` from the deleted scratch checkout the package was built in. With that tree gone, the installed package's coordinator, started alone in throwaway data and runtime directories, exited 133: "Fatal error: could not load resource bundle". A package from this branch, with its own build tree hidden, started, created its cluster, migrated the registry, joined a throwaway hub user (creating and migrating an account database), and listed threads, with no fatal error. That package is now the owner's Local app; it started and signed in to cacheplane with the old build path absent |

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Swift tests | `swift test --filter "StorageResourcesTests\|MigratorTests\|AccountRegistryTests"` (and the full suite in CI) | Pass: 12 tests in 2 suites, including the new `StorageResourcesTests` (the bundle is found from a coordinator in `Contents/Helpers/B4AppCoordinator.app` of a packaged layout, and not outside an app) |
| Package | `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY=… ./Scripts/package.sh` | Pass, including the new check that the app carries the migrations |
