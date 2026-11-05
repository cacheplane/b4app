## 2026-11-05: Step 5 in the shipped Simulator app, with banner spacing inspected

The owner requested running the actual step 5 scenario in the Simulator and paying attention to banner UI and spacing. Source: `395ed67c561b324a4a0b76c986ba9e016a16024e`, the PR #129 merge used for production TestFlight 2611050442. No shipping implementation changed during this check.

### Setup and scope

- A separate iPhone 17 Pro Simulator, "Step 5 Banner Review", iOS 26.5, ran the shipping `B4App-iOS` Simulator app, local flavour. Its mirror, account, and Keychain were separate from the owner's existing Simulator.
- A temporary `step5-20261105` account on the real local Compose Rust hub used an isolated debug coordinator (`B4APP_DATA_DIR=/tmp/b4app-step5-live/mac`, `B4APP_RUNTIME_DIR=/tmp/b4s5r`), the ordinary fake runtime executable, 18 real synced threads, and a fixture-backed transcript. This tests real HTTP sync and WebSocket relay, not live provider inference.
- The phone enrolled through `http://localhost:18085`, a TCP proxy to the local hub. Closing its listener and active sockets disconnected only this phone; the Mac stayed online. This is a real app transport interruption, not a simulated status assignment or a physical Wi-Fi radio transition. The Mac's network and the owner's accounts were untouched.
- The existing isolated layout harness first passed four focused tests (navigation/Back, expanded/collapsed titles, recovery on home/detail, and search). The separate shipped-app driver then exercised healthy → offline home → thread → Back → scrolling → home recovery → thread outage → recovery → send. The second outage lasted about 75 seconds. The software keyboard was shown during that outage and remained shown after recovery.

### Results

The complete shipped-app scenario passed: `Step5LiveTests.testRealHubStepFive()`, one executed test, zero failures/skips, `/tmp/b4app-step5-live/Run-4.xcresult`. The first attempts corrected test-driver setup assumptions (the no-camera sign-in route and the composer's actual `TextField` accessibility type), and the temporary proxy's connection shutdown ordering. Those attempts are not application failures or successful scenario runs.

| Visual/functional check | Observation |
| --- | --- |
| Home with expanded title/search | Banner begins at y=228 pt, exactly below the navigation bar, and is 35.7 pt high. Profile, filter and search remain hittable. The first row moves from y=228 to y=263.7, exactly the banner's height. |
| Scrolled home | Banner pins at y=116 pt, below the collapsed navigation bar. The Threads title, profile/filter/search controls and bottom new-thread dock remain visible. |
| Enter thread and use Back offline | Passed. Back and the thread menu are above the banner and remain usable. |
| Thread banner spacing | Its actual text is at y=124 pt, with 8 pt vertical padding below the y=116 navigation edge; the banner ends at y=151.7. Its combined accessibility background extends to y=0, but its visible content does not cover navigation. |
| Software keyboard | Banner stays at the top; transcript, reconnect line, composer and pickers fit above the keyboard. No overlap was observed. |
| After recovery | Home's first row returns to y=228; the thread's transcript moves up 35.7 pt. No empty banner slot remains. The bottom reconnect notice disappears and the composer remains anchored above the keyboard. |
| Recovery timing | About 6 seconds on home and 12 seconds after the prolonged thread outage, based on proxy restore events and the final passing UI polls. These are observed lab timings, not an instantaneous-recovery claim or a physical-radio measurement. |
| Send after recovery | Passed through the real relay to the isolated coordinator and fixture runtime; the phone showed the user message and a second fixture reply. |

### Remaining presentation finding

The banner exposes raw `Hub error 0 transport` text. Its single-line limit truncates the useful connection explanation on a normal-width iPhone, leaving text like "Not synced since 07:32: Hub error 0 transport: Cou…". This occurs on both home and detail. Placement and spacing pass this run; the copy/readability still needs polish. The older fixture banner's simpler error string did not reveal how much space the real error prefix consumes.

Eight original screenshots, accessibility trees and timing evidence are saved under `.build/verification/2026-11-05-step5-spacing/`: healthy/offline/scrolled/recovered home, thread offline with software keyboard, recovered thread and post-recovery send. The temporary runner and controllable proxy sources remain under `/tmp/b4app-step5-live/` for inspection. This check does not close the physical iPhone gate.

Cleanup: the scratch Mac left the hub, its coordinator and private PostgreSQL stopped, both devices of the temporary lab account were revoked, the proxy stopped, enrollment-code files were removed, and the dedicated Simulator was shut down. The owner's original Simulator and local hub service remained available.
