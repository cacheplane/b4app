## 2026-11-02: Sign-in polish from the live gate (D-132, D-133)

Branch `blove/sign-in-polish`, from main at `b5c0f5b`. Fixes the five minor findings of the sign-in live gate (below): the profile button's name, the added passkey's name, the local flavour's "New here?" line, the enrollment sheet's flash after Pair, and the old LaunchAgent left loaded by adoption. No hub, wire, or fixture change.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass (exit 0) |
| Build | `swift build` | Pass |
| Swift tests | `swift test` (PostgreSQL from the main checkout's `.build/postgres`) | 1212 tests in 154 suites; the new and changed tests pass: `SignInTests.theProfileButtonShowsTheNameOnboardingGave` and `signInViewCopy`, `AccountSettingsTests.addAPasskey`, `ConnectMacTests.theEnrollmentSheetKeepsItsConfirmationWhileClosing`, `LegacyAdoptionTests.jobStateReadsLaunchctlPrint`, `anUnreadableJobIsBootedOutByItsPlist`, `retiringTheOldAgentBootsItOutThenRemovesItsPlist`, `bootOutDecisionFollowsTheProgramPath`. The last full run had 3 issues in two timing tests this change does not touch, `B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting` and `SessionTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown` (the second also in an earlier run, with `MirrorSyncTests` long-poll timeouts and a `MirrorRelayTests` presence check off by 0.23 s); each passed three times run alone, and `PostgresServerTests`, `MirrorSyncTests`, `MirrorRelayTests`, and `SessionTests` passed together (82 tests) |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` (`EnrollView` is compiled only here) |

Not run live: the passkey rename in Passwords, the enrollment sheet's dismissal on a device or Simulator, and the boot-out on a fresh adoption (the owner's install is already adopted). A new account starting with no connections is expected (connections are per account, D-065); recorded in `docs/milestones.md`.
