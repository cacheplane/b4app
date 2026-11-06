## 2026-11-05: Hosted-hub Gate 4 evidence reconciliation

Gate 4 is **passed from the existing 2026-11-03 live evidence**, reconciled on 2026-11-05 (Pacific). The hosted-hub table's “Not run” entry had not been updated after the sign-in and M8c projects recorded their hosted-test checks. This reconciliation performs no new sign-in, pairing, relay turn or deployment.

The requirement in `docs/deployment-architecture.md`, “Verification gates”, is: from a packaged beta Mac app and a TestFlight iPhone, sign in with a passkey against `hub.test.b4.run`, pair, and run a relayed turn. It explicitly delegates to the sign-in and M8c projects' live gates against that hub.

### Evidence mapped to the gate

| Requirement | Existing live evidence |
| --- | --- |
| Hosted test hub and packaged beta Mac | [Physical-iPhone pairing and relay](2026-11-03-m8c-pairing-and-relay-on-a-physical.md) identifies `https://hub.test.b4.run` and `Agent Workspace (Beta).app`, packaged from main `9140cf5` with Developer ID signing. It was not notarized; Gate 4 requires a packaged app, not a notarization check. |
| Physical TestFlight iPhone | The same record identifies the owner's physical iPhone and TestFlight beta 0.1.0 (`2611030054`, from `abb41df` containing main `9140cf5`). [M8c loose ends](2026-11-03-m8c-loose-ends.md) records the later TestFlight beta build `2611030608` used for the passkey checks. |
| Fresh pairing on that hub | In the first record, the Mac's “Pair iPhone…” sheet produced a `test.b4.run` link; the phone's in-app scanner paired it, and `hub.pairStatus` reported `paired` with the relay connected. A Mac-created thread and reply synced to the phone. |
| Completed relayed turn | The owner's phone message “Reply phone” reached the Mac through the relay, ran as turn 2, and completed with “phone”, as recorded in the physical-iPhone run. This is a completed live turn, not just a connected socket or a fixture response. |
| Passkey sign-in on the packaged beta Mac | The later loose-ends record identifies both apps rebuilt from `419b7d8` (main `5882a60` plus D-154), including the packaged Beta Mac and TestFlight build `2611030608`. After adding a passkey with Apple step-up, the Mac logged out and signed back in with the passkey to the same account and device; the relay reconnected. |
| Passkey sign-in on the TestFlight iPhone | In that later record, the phone used the Mac-created passkey, synced through iCloud Keychain, for step-up, then logged out and signed back in with it to the same account, still paired with the Mac. Attempting to add that already-synced credential correctly created no duplicate. |

Both records explicitly identify the beta/test environment. The later session also records the Beta Mac's relay reconnecting after a test-hub deploy. Local Compose sign-in and production-device evidence are not needed to fill this gate.

### Chronology and limits

The first session began with Apple sign-in, then demonstrated fresh pairing, sync and the completed relayed turn. Its “Not exercised” passkey note describes that session alone. The later session closes that gap with passkey sign-in on both devices, same-account/device continuity on the Mac, retained pairing on the phone, and the Mac's relay reconnecting.

The existing records therefore cover the delegated sign-in and M8c live gates on the required hosted hub. They do **not** describe a single new ordered run that starts with both passkey logins and then repeats fresh pairing and the turn; no such rerun is claimed here. The system Camera's later “already paired” response is continuity evidence, while the earlier in-app scanner run is the evidence of a fresh pairing.

The Mac's initial passkey attempt failed because stale Xcode build registrations prevented the beta app's associated-domain lookup. The loose-ends record documents unregistering those products, the subsequent association fetch, and successful passkey sign-in. This closure relies on the successful result and retains that installation caveat.

Gate 4's packaged-app, TestFlight, passkey, pairing and relay requirements are closed by those combined records. Notarization, new passkey creation on the phone when a synced credential already exists, account-method removal/deletion step-up, and later pairing UX refinements are separate checks; this reconciliation makes no new claim about them. Gate 6's external monitoring and paging remain deferred.

Documentation validation: `Scripts/docs-index.sh --check`, `git diff --check`, and `swift format lint --strict --recursive Sources Tests Apps Package.swift`.
