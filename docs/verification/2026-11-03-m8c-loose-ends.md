## 2026-11-03: M8c loose ends (Already answered, Camera pair link, beta passkeys)

Branch `blove/drop-already-answered`.

- **"Already answered" dropped (D-154).** The owner chose to drop the copy over a "Your Mac answered first" notice. Fixture: `SendStateTests.aStaleAnswerClearsQuietly`, `MirrorModelTests.theMacAnsweringFirstTakesTheCardAwayQuietly`. Full `swift test`: 1293 tests. Two failures outside the change passed when re-run alone: `B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting` and `LifecycleTests.reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown`.
- **The iPhone Camera app opening a pair link.** The owner's iPhone (TestFlight beta 2611030054, already paired and connected) and the Beta Mac app (`9140cf5`) on `https://hub.test.b4.run`. Before the run, `https://test.b4.run/.well-known/apple-app-site-association` and Apple's CDN copy (`app-site-association.cdn-apple.com/a/v1/test.b4.run`) both served `applinks` for `GJJKL34HCT.com.cacheplane.b4app.ios` on `/pair`, and `webcredentials` for that app and `GJJKL34HCT.com.cacheplane.b4app.beta`.
  1. On the Mac: Settings → Remote access → Pair iPhone….
  2. The owner scanned the code with the system Camera and tapped its banner. Agent Workspace opened (`onContinueUserActivity`) with the pairing offer.
  3. Pair answered "This iPhone is already paired" (`merge_refused`, `same_account`, D-098), and the phone stayed paired.

  Pass. The owner expected a paired phone's offer to say "already paired" before the tap. By design it cannot: nothing is sent until Pair (D-066, D-110), and the code does not tell the phone which account it belongs to. Knowing up front needs a hub check that does not spend the code; the owner made that a separate task.
- **Rebuilt for the step-up.** The test hub serves D-150's step-up, and both earlier beta builds predated it. With the owner's go-ahead, both were rebuilt from this branch (`419b7d8`, main `5882a60` plus the D-154 change):
  - The Beta Mac app: `B4APP_FLAVOR=beta B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY=… ./Scripts/package.sh`, swapped into `~/repos/b4app/dist` with its coordinator booted out first. It came back with the same device and account, and the relay connected.
  - The iPhone app: TestFlight beta 0.1.0 (2611030608), by `B4APP_FLAVOR=beta ./Scripts/upload-ios.sh`.
- **A passkey on the Beta Mac app.** The first try failed. The Apple step-up passed and the hub's `passkeys/begin` answered 200, but the system passkey request ended without a sheet.
  - `sudo swcutil show` had a `webcredentials` entry for the Local app (`local.b4.run`, approved) and none for `com.cacheplane.b4app.beta`. In six hours of `swcd` logs, test.b4.run's association file was never fetched.
  - The app's signature and its embedded `app-beta` profile were correct (`webcredentials:test.b4.run`; the profile allows `associated-domains: *`), and so was the site's file.
  - The cause: LaunchServices had seven bundles registered for `com.cacheplane.b4app.beta`. Six were Xcode `Debug-Beta`/`Release-Beta` products in DerivedData folders (other worktrees, scratchpads, CI evidence), signed without the entitlement. `swcd` evidently read one of those for the bundle id, so it saw no associated domain.
  - The fix: `lsregister -u` on the six build products, then `lsregister -f` on the `dist` app. `swcd` synced and fetched `test.b4.run` from Apple's CDN within a second.
  - The second try passed: Settings → Account → Add passkey, the Apple step-up, then the macOS sheet saved the passkey. Log out, then Sign in with passkey, signed back in to the same account (`u-tvedt5h6@o-cxzqzfmn`, same device), and the relay reconnected.
  - Anyone building beta or prod in Xcode on the Mac they run the packaged app on can hit this again. Unregister the build products, or keep Xcode's products out of LaunchServices.
- **A passkey on the iPhone (build 2611030608).** Settings → Account → Add passkey asked for the Mac's passkey, which iCloud Keychain had synced, for the step-up, and that passed. The add then said "This device already has a passkey for this account." and made nothing: the hub lists the account's passkeys in `excludeCredentials`, and the phone already holds the synced one (a known limitation in `docs/milestones.md`). The phone then logged out and signed back in with that passkey, to the same account, still paired with the Mac. Pass.
- During the session, a deploy of the test hub stopped its only task at 05:51Z and served 503 until 05:53:20Z. The Beta Mac's relay reconnected by itself at 05:53:30Z.
