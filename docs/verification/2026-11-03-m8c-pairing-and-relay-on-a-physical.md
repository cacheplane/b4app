## 2026-11-03: M8c pairing and relay on a physical iPhone (beta flavour, test hub)

The owner's iPhone, with TestFlight beta build 0.1.0 (2611030054). It was uploaded from #63's branch (`abb41df`, which contains main `9140cf5`) by `B4APP_FLAVOR=beta ./Scripts/upload-ios.sh`, and reached the Internal group. The Mac is `Agent Workspace (Beta).app`, packaged from main `9140cf5` (`B4APP_FLAVOR=beta`, Developer ID, not notarized) beside the prod and Local apps, against `https://hub.test.b4.run`.

- **Sign-in:** the Beta Mac signed in with Apple, creating a new account ("Brian's Org").
- **Pairing:** "Pair iPhone…" showed `https://test.b4.run/pair#c=…`, and the phone's **Scan the code** read it with the camera and paired. The Mac's `hub.pairStatus` reported `paired` ("iPhone"), with its relay connected.
- **Sync:** a Codex thread started on the Mac, "Pairing check", replied "paired" and synced to the phone.
- **Relay:** a message the owner sent from the phone ("Reply phone") reached the Mac through the relay, ran as turn 2, and completed with "phone".
- **Found and fixed on the way: `test.b4.run` had no DNS record.** The Vercel project `b4-run` lists the domain, and `*.b4.run` is a wildcard ALIAS. But `hub.test.b4.run` makes `test.b4.run` an empty non-terminal, which a wildcard never covers. So passkeys and universal links had no association file for the beta flavour. An explicit `test` ALIAS to `cname.vercel-dns-016.com.` (Vercel DNS, team cacheplane) fixed it. `https://test.b4.run/.well-known/apple-app-site-association` and Apple's CDN (`app-site-association.cdn-apple.com/a/v1/test.b4.run`) now serve the beta file (`webcredentials` for `com.cacheplane.b4app.beta` and the iPhone app; `applinks` `/pair`).
- **Also seen:** the earlier beta build 2611022211 predated the "Scan the code" landing, so its sign-in screen offered only Apple and a passkey. A deploy to the single-task test hub answered `503` for about three minutes, and the Mac's relay reconnected by itself afterwards.
- **Not exercised:** the iPhone Camera app opening the pair link; a passkey on the beta Mac or iPhone.
