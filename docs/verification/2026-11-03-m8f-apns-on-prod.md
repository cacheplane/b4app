## 2026-11-03: M8f APNs on prod (`hub.b4.run`)

Target: the prod hub at hub-v0.3.0 (released from `main` at `b023ded`; the production deploy ran migrations to 15 applied, 0 pending, and rolled the service to task definition `b4hub-prod-hub:5`), with the three APNs secrets set per runbook 3a and `INCLUDE_APNS_SECRETS=1`. The prod Mac app was rebuilt from `main` at `d6f8181` (`./Scripts/package.sh`, Developer ID, notarized and stapled), because the one on the build Mac predated sign-in; it found its existing prod enrollment (`blove@cacheplane`) and got a Claude Code connection through its bundled `agent-workspace`. Brian's iPhone ran the prod TestFlight build 0.1.0 (2611031947, `main` at `2338c2e`) and paired by scanning the Mac's QR code. Evidence is the prod hub's CloudWatch log, never a token or payload.

| Time (UTC) | Event |
| --- | --- |
| 16:36:37 | The hub starts with `push sender: apns` |
| 20:33:15 | The iPhone registers its token (`POST /v1/devices/self/push-token`, 204) |
| 20:33:54 | Claude Code asks to run `curl -sI https://example.com`; the approval alert is accepted by Apple (200) and reaches the locked iPhone |
| 20:43:55 | Brian taps the notification, which opens the thread, and answers it there; the turn runs on the Mac and the withdrawal is accepted (200); the notification leaves the lock screen |

- No "Replied" was sent: the thread was open on the Mac, so the reply was read in the same push that finished it, and a notification that would end in the push that sends it is neither sent nor withdrawn (D-143).
- No error in the prod log over the gate.
- Afterwards Brian connected his Apple ID to the prod account (it had no sign-in method, having been enrolled with a code), and the gate's thread was deleted.
