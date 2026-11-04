## 2026-11-03: The LaunchAgent boot-out against the real launchctl (D-133)

Branch `blove/launchctl-live-test`, from main at `4c8a88c`. A new opt-in suite, `Tests/CoordinatorTests/LegacyAdoptionLiveTests.swift`, runs `LegacyAdoption.bootOutLegacyJob` against the real `launchctl` with `B4APP_LIVE_LAUNCHCTL=1`. Each test bootstraps a throwaway job (`/bin/sleep 600` under `com.cacheplane.b4app.test.legacy-bootout.<random>`, never the legacy label) into this user's GUI domain and boots it out at the end. The legacy plist the identity rule reads is written in a temporary home. Run on the owner's MacBook Pro; no other job was touched, and `launchctl list` showed no test job left afterwards.

| Check | Result |
| --- | --- |
| A loaded job is booted out | Pass (`aLoadedJobIsBootedOut`): `launchctl print` exit 0, then `bootout`, then the job is gone |
| A job whose `print` times out is still booted out (the sign-in gate's case) | Pass (`aJobWhosePrintTimesOutIsStillBootedOut`): `print` answers a timeout, the real `bootout` still runs and the job is gone |
| An unknown job that is not loaded is not a failure | Pass (`anUnknownJobThatIsNotLoadedIsNotAFailure`): the real `bootout` answers 3 ("No such process"), read as nothing to do |
| Without the variable | The suite is skipped (CI never sets it) |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift`: pass |

Not run: a full fresh adoption of a pre-flavour install.
