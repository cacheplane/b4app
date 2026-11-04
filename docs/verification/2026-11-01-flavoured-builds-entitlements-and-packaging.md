## 2026-11-01: Flavoured builds, entitlements, and packaging (sign-in plan, Task 2)

Run from `blove/sign-in` on macOS 26.5. Nothing was signed with a Developer ID identity, notarized, or uploaded.

| Check | Command | Result |
| --- | --- | --- |
| Project | `./Scripts/generate-project.sh` | Generated; schemes `B4App-macOS`, `B4App-macOS-Beta`, `B4App-iOS`, `B4App-iOS-Beta` |
| Four schemes | `xcodebuild build -scheme <scheme> -destination <platform=macOS or generic/platform=iOS Simulator> CODE_SIGNING_ALLOWED=NO` | Four `** BUILD SUCCEEDED **` |
| Info.plist | `plutil -p` on each built app | Mac local `com.cacheplane.b4app.local`, Mac beta `com.cacheplane.b4app.beta`, iOS local `com.cacheplane.b4app.ios.local`, iOS beta `com.cacheplane.b4app.ios`; `B4AppFlavor` and the `CFBundleURLSchemes` entry agree with each |
| iOS entitlements | Simulator builds signed ad hoc, `*-Simulated.xcent` | Beta: `webcredentials:test.b4.run`, `applinks:test.b4.run`, Sign in with Apple. Local: the same two with `local.b4.run?mode=developer`, no Sign in with Apple |
| Ad hoc packages | `B4APP_FLAVOR=local ./Scripts/package.sh` and `B4APP_FLAVOR=beta ./Scripts/package.sh`, no identity | `Agent Workspace (Local).app` and `(Beta).app` with `Agent-Workspace-Local-<v>.zip` and `-Beta-`; `B4AppFlavor` and the flavoured bundle id in the app and `B4AppCoordinator.app`; LaunchAgent plist and label `com.cacheplane.b4app.<flavour>.coordinator`; CLI identifier `com.cacheplane.b4app.<flavour>.agent-workspace`. The packaged CLI, run with no environment, emits the beta label, so the walk up to its `.app` works |
| Profile check, dry | `B4APP_CHECK_PROFILES_ONLY=1 B4APP_TEAM_ID=<team> B4APP_FLAVOR=<flavour> ./Scripts/package.sh` | Refuses for all three flavours, as intended: prod names the missing `webcredentials:b4.run` in the owner's existing profile; beta and local name the missing profile files, the associated domain, and each keychain group |

Open: a Developer ID package of any flavour. It needs profiles regenerated with Associated Domains (all flavours, app profile) and new App IDs for beta and local (`~/.b4app/signing/{app,coordinator}-{beta,local}.provisionprofile`), so `codesign -d --entitlements -` on a signed local package, listing the associated domain and both keychain groups, is not yet run. The checks that match profile contents against the flavour were exercised only with hand-written profiles, not Apple-issued ones.
