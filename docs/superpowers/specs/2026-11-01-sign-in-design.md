# Sign-in: Apple ID and passkeys, accounts, build flavours, and the hosted hubs

Date: 2026-11-01. Owner: Brian Love. Status: draft for the owner's approval.

This document designs the sign-in screen that gates the Mac and iPhone apps. It also covers the hub identity work behind it (the roadmap's M8d, narrowed), the per-account local store on the Mac, and the build flavours and the hubs they talk to. Deploying the hosted hubs is the owner's separate project. It builds on `2026-10-31-m8-hub-design.md` (the account model), `2026-11-01-sidebar-profile-settings-design.md` (D-053, the profile menu and Log out), and `2026-11-01-m8c-relay-design.md` (D-054 to D-059, the relay and pairing by QR code), whose content holds unless a section below says otherwise. Research: `docs/research/reports/Mac App Store sandbox for agents.md` (new, with this design) and `docs/research/reports/App Store and TestFlight signing.md` (D-051). Mockups: `2026-11-01-sign-in/` (`sign-in.html`, `onboarding.html`, `pairing.html`; the right-hand panel of `onboarding.html` is superseded by `pairing.html`).

## Intent

Today the hub knows a person only through a one-time enrollment code an operator mints on the hub, and after Log out the app stays usable and says "Not signed in". The owner wants a real product front door: download the Mac app from b4.run (or the iPhone app from the App Store), sign in or sign up with an Apple ID or a passkey from the system password manager, and land in the app. Nothing in the app is reachable without signing in, and Log out returns to that screen. The hub becomes a hosted service at b4.run with a separate test hub for TestFlight; deploying those is a separate project, and this one builds everything that runs on them.

The owner's direction, in his words where it matters:

- "After logout we go back to the login screen ... Simple centered options to login with Apple ID or passkey. I mean a passkey with the builtin password manager on the os. The login screen gates the whole app. You can sign up with either apple id or passkey."
- Audience: "For testing and initial development, it will be just me. However, we will want to build and launch the apps for download from b4.run, and then eventually in the app store."
- Builds: App Store and the b4.run download use "prod db and the prod hub on b4.run domain"; TestFlight uses "a special db and hub for testing"; local uses "a local db and hub". Apple ID and passkeys everywhere, except "For local, just passkeys is fine."
- After the sandbox research: "let's remove the mac store + testflight plans for the macOS app. We will still have builds for the app store + testflight for the iOS app. macOS is installed like codex and claude - download or homebrew."
- Accounts: "they get their own private place. we won't require an org name in the sign up, so we'll call it something generic like "Brian's Org"."
- Passkey sign-up asks for nothing: "just use the passkey to auth them, then dump them into the onboarding flow, which at first will collect their full name and phone number (which we'll eventually validate)."
- The logo on the sign-in screen is the b4.run wordmark, "not the LLA logo".
- A phone with no Mac gets "a button to "capture QR code" ... which opens the camera so they can capture the QR code from their mac", "a link to download (tapping it copies it), and docs for help (opens in safari overlay)." Scanning the code with the system Camera "we want it to open the b4.run app and pair."
- The Mac "should support multi-user db persistence locally. I should be able to sign in and out of an account and pick up exactly where I left off, even if I sign into another account."
- Log out with work running: "I think we want to exit as cleanly as possible."
- Standing up the prod and test hubs was first in scope, then moved out: "Let's not focus on building and deploying the cloud infrastructure and hubs. I'm going to tackle that in a separate thread."

## Goals

1. One sign-in screen, the same on both apps: the b4.run wordmark, a heading, one sentence, "Continue with Apple", "Continue with a passkey", centred. Each button signs in an existing account or creates a new one.
2. The hub verifies Sign in with Apple identity tokens and WebAuthn passkey ceremonies itself, creates users and a private org per user, and issues device tokens without an enrollment code.
3. Onboarding after sign-up: full name and phone number, then the app.
4. The Mac keeps one local database per account and switches between them on sign-in, so signing out and back in (as the same or another account) resumes exactly where that account left off.
5. A clean Log out on both apps that returns to the sign-in screen.
6. Pairing a phone by scanning the Mac's QR code, from the app's scanner or the system Camera, which also signs the phone in.
7. Four build flavours with their hubs baked in, and the b4.run site serving the files passkeys and pairing links need. Deploying the hosted hubs is a separate project (below).

## Non-goals

- A Mac App Store or TestFlight-for-Mac build. Both require App Sandbox, which cannot run the user's own agents (see "Mac distribution" below).
- Enterprise sign-in (OIDC, SAML, SCIM), invitations, shared orgs, roles, and org management. Every account is one user in one private org.
- Email or password sign-in, the CLI device grant, and refresh-token families from the M8 design's long-run model. Device tokens stay as they are.
- Phone number verification (stored now, verified later).
- Multiple accounts signed in at once on one device. One account is active at a time; the Mac remembers the others' data.
- Running agents on a hosted hub or anywhere but the user's Mac.
- Deploying the hosted hubs (hosting, databases, domains, deploy workflows); the owner's separate project.

## Anti-goals

- A sign-in screen with a hub URL field, an org field, a username, or a choice between "Sign in" and "Sign up".
- Any path where a secret (Apple identity token, authorization code, WebAuthn response, pairing code, device token, Apple client secret) reaches a log line, a JSON result other than the one hop it must take, or persisted UI state.
- Losing or mixing a Mac account's threads when another account signs in.
- Log out that leaves a turn half-run or a server orphaned without the user having been told.
- Eyebrows, uppercase labels, gradients, or a second accent colour on these screens (the LLA rules hold; the b4.run wordmark is the only brand change).

## Mac distribution (amends D-051)

The research (`Mac App Store sandbox for agents.md`) settles that a sandboxed Mac app cannot run the user's installed `codex`, `claude`, or `node`. No file grant adds execute permission, and children inherit the sandbox with `HOME` moved into the container, so `~/.codex` and `~/.claude` are empty. It also cannot run the bundled PostgreSQL (System V IPC is denied) or write the LaunchAgent. T3 Code, ChatGPT/Codex, Claude desktop, Zed, Warp, and Conductor all ship outside the store, unsandboxed, for these reasons. Xcode runs agents from the store only because Apple exempts it. So:

- **Mac:** notarized Developer ID builds only, downloaded from b4.run or installed with a Homebrew cask. No Mac App Store build and no TestFlight for Mac, now or planned.
- **iPhone:** App Store and TestFlight, as D-051 set up.

## Build flavours and hubs

A flavour is a compile-time setting (an `.xcconfig` per flavour, plus a `B4APP_FLAVOR` Swift compilation condition for the Swift package targets). It fixes the hub URL, the website domain, the passkey relying-party id, whether Apple sign-in is offered, and every identifier that lets two flavours live side by side on one Mac.

| | prod | beta | local |
| --- | --- | --- | --- |
| iPhone build | App Store | TestFlight | Xcode, Debug |
| Mac build | b4.run download, Homebrew cask | b4.run beta download (notarized) | `package.sh` or Xcode on the owner's Mac |
| Hub | `https://hub.b4.run` | `https://hub.test.b4.run` | `http://localhost:8080` (Compose) |
| Site domain (passkey RP id, pair links) | `b4.run` | `test.b4.run` | `local.b4.run` |
| Sign in with Apple | yes | yes | no (button hidden) |
| Mac bundle id | `com.cacheplane.b4app` | `com.cacheplane.b4app.beta` | `com.cacheplane.b4app.local` |
| iPhone bundle id | `com.cacheplane.b4app.ios` | the same (TestFlight ships the App Store id) | `com.cacheplane.b4app.ios.local` |
| Mac data directory | `~/Library/Application Support/b4app` | `…/b4app-beta` | `…/b4app-local` |
| Runtime dir, LaunchAgent label, coordinator id, URL scheme, keychain group | `b4app`, `com.cacheplane.b4app.coordinator`, `b4app` | `.beta` / `b4app-beta` suffixes | `.local` / `b4app-local` suffixes |
| Window badge | none | "Test hub" | "Local hub" |

*My calls:* the names "beta" and "local", the `test.b4.run` and `local.b4.run` subdomains, and per-flavour relying-party ids so a test passkey never appears when signing in to prod. The iPhone TestFlight build is the App Store build pointed at the test hub, so it must use the App Store bundle id; it is a separate archive with the beta configuration, never promoted to the store. The Mac beta flavour exists so TestFlight testers have a Mac on the test hub.

**Why the local flavour still needs a real domain.** A passkey belongs to a domain, and the OS lets an app use it only when `https://<domain>/.well-known/apple-app-site-association` lists the app, fetched through Apple's CDN (Developer ID builds cannot use the associated-domains developer mode, which needs a development-signed app). The hub that verifies the passkey can run anywhere, including `localhost`, because WebAuthn checks the origin (`https://local.b4.run`) and the relying-party hash inside the signed data, not the server's address. So `local.b4.run` serves only that file; nothing else runs there.

**The CLI.** `agent-workspace` is built per flavour like the app and reads the same flavour's paths. The Homebrew cask links the prod one. `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` still override for tests.

**The owner's current install.** Today's packaged app is `com.cacheplane.b4app`, with data in `b4app`, a link to the localhost hub, and its hub token in D-051's keychain group `<team>.com.cacheplane.b4app.shared`. It becomes the **local** flavour, seamlessly (*my call*; it keeps the owner's threads with the hub they synced to and needs no new enrollment code):

- On the first launch of a local-flavour build, if `b4app-local` does not exist and `b4app`'s hub link points at `localhost`, the coordinator moves the `b4app` data directory to `b4app-local`, after booting out the old LaunchAgent and stopping its cluster through the existing identity checks.
- The local flavour's app and coordinator also claim the legacy group `<team>.com.cacheplane.b4app.shared` (their Developer ID profiles authorise `<team>.*`), read the hub token from it once, store it in `…local.shared`, and delete the old item.
- The hub's migration marks every existing user as onboarded (`onboarded_at = created_at`, `full_name = display_name`) and leaves existing orgs non-personal, so `blove` in `cacheplane` goes straight to the workspace and keeps its org name.
- A prod-flavour build adopts the legacy `workspace` database only when its hub link's URL is the prod hub's; it never adopts a `localhost` link, so launching prod first leaves the owner's data for the local build to move.

**The local iPhone flavour is Simulator-only** (*my call*): its hub is `http://localhost:8080`, which on a device would be the phone itself. A physical iPhone uses the beta (TestFlight) flavour against the test hub.

## Entitlements and the Apple Developer account

Owner's tasks (the builder prepares exact steps, the owner does them in the portal; no Apple credential passes through a script):

- **App IDs** for the five bundle ids above plus each Mac coordinator id, with **Associated Domains** (all) and **Sign in with Apple** (`com.cacheplane.b4app.ios` only; it is a primary App ID). Keychain Sharing stays as D-051 set it, per flavour group (`<team>.com.cacheplane.b4app.shared`, `…beta.shared`, `…local.shared`).
- **A Services ID** (`com.cacheplane.b4app.signin`, *my call*) for the Mac's web flow, grouped with the iOS App ID so the Apple user id (`sub`) is the same on both, with return URLs `https://hub.b4.run/v1/auth/apple/callback` and `https://hub.test.b4.run/v1/auth/apple/callback`.
- **A Sign in with Apple key** (`.p8`), whose key id, team id, and contents go into the hosted hubs' secrets, never the repository.
- **Provisioning profiles** regenerated to carry the new capabilities: Developer ID profiles for the Mac app and coordinator per flavour (Associated Domains is supported for Developer ID; Sign in with Apple is not, which is why the Mac uses the web flow), and App Store profiles for iOS, which `upload-ios.sh`'s cloud-managed signing creates.

Entitlements:

- Mac app: `com.apple.developer.associated-domains` = `webcredentials:<site domain>`. `Scripts/package.sh` adds it to the entitlements it generates (D-051) and checks the profile authorises it. The coordinator needs none of this: it never presents a credential sheet.
- iPhone app: `webcredentials:<site domain>`, `applinks:<site domain>` (for `/pair`), and, outside local, `com.apple.developer.applesignin` = `Default`.
- The local iPhone flavour runs only in the Simulator, signed with a development profile, so it may add `?mode=developer` to its associated domains.

## The sign-in screen

`SignInView` in `WorkspaceUI`, shared by both apps (`sign-in.html`):

- Fills the window or screen on `LLA.Color.bg`, content centred in a 300 pt column (214 pt on the phone): the b4.run wordmark (30 pt high), "Agent Workspace" in the title style, one muted sentence ("Your Codex, Claude, and B4 threads, on your Mac and your phone."), then two full-width pills: **Continue with Apple** (ink fill, white Apple logo) and **Continue with a passkey** (`surface` fill, `rule` border, a person-with-key glyph). Under them, small muted: "New here? Either one creates your account." and, on the Mac, "By continuing you agree to the terms and privacy policy." with the two links in the accent colour opening `https://<site>/app/terms` and `/app/privacy`.
- Flavour badge: a quiet `ghost` line at the bottom, "Test hub" or "Local hub"; nothing for prod.
- The local flavour hides Continue with Apple.
- While a ceremony runs, both buttons are disabled and the pressed one reads "Signing in…". A failure shows one danger-coloured line under the buttons (a cancelled sheet shows nothing).
- The b4.run wordmark is vendored from `~/repos/b4run` (`apps/web/public/brand/identity/logos/wordmark-ink.svg` and `wordmark-white.svg` for dark mode) into `Sources/WorkspaceUI/Resources/Brand/` with a comment naming the source, drawn by the existing brand SVG reader. The guideline's clear space (one dot diameter) is kept. The rest of the app keeps the LLA mark.
- The Apple button is our own pill following Apple's custom-button rules (the Apple logo asset, the "Continue with Apple" title, black fill, minimum size), not `SignInWithAppleButton`, so both buttons match and the Mac's web flow can use it too.

**Root gating.** Each app's root shows `SignInView` while the account state is `signedOut`, the onboarding screen while it is `needsOnboarding`, and the workspace otherwise. Nothing else (Settings, the menu bar's New Thread, ⌘K) is reachable while signed out; the Mac's menu commands that need a workspace are disabled. The Mac app shows the screen whenever the coordinator reports no active account, including when the coordinator is running in the background with nobody signed in. A coordinator that cannot be reached shows the existing coordinator-unavailable state, not the sign-in screen.

### Continue with a passkey

One button signs in or signs up (*my call*, matching the owner's "simple"):

1. The client asks the hub for a ceremony (`POST /v1/auth/passkey/begin`). The answer holds a `ceremonyId`, assertion options (no allow-list, so the OS offers any passkey for this relying party), and registration options for a new user (a fresh random user handle, `user.name` = "Agent Workspace account", `user.displayName` the same, `residentKey: required`, `userVerification: required`, attestation `none`).
2. The client runs the assertion with `ASAuthorizationPlatformPublicKeyCredentialProvider`, preferring immediately available credentials. If the person picks a passkey, the client sends the assertion to `POST /v1/auth/passkey/finish` and is signed in.
3. If the OS reports no passkey for this domain, the client first asks, in place on the sign-in screen: "No passkey for b4.run on this device. Create a new account?" with **Create account** and **Cancel** (*my call*; a passkey kept on another device or in a password manager that does not serve this one would otherwise silently make a second, empty account). On Create account it runs the registration with the same ceremony and sends the attestation to the same finish route, which creates the user, the org, and the device, and answers `needsOnboarding: true`.
4. After onboarding the client updates the passkey's name in the password manager to the person's full name with `ASCredentialUpdater` (iOS 26 / macOS 26), so the Passwords app shows "Brian Love" instead of the placeholder.

### Continue with Apple

- **iPhone:** the native sheet (`ASAuthorizationAppleIDProvider`, scopes full name and email, with a nonce from the hub's ceremony). The app sends the identity token, the authorization code, and the name Apple returns (first time only) to `POST /v1/auth/apple/native`.
- **Mac:** Developer ID apps cannot use the native flow, so the app opens `https://<hub>/v1/auth/apple/start?ceremony=<id>` in an `ASWebAuthenticationSession` with callback scheme `b4app` (per flavour). The hub redirects to Apple's authorize page with the Services ID, `response_mode=form_post`, and the ceremony's `state` and `nonce`. Apple posts back to `/v1/auth/apple/callback`; the hub exchanges the code, verifies the identity token, and redirects to `b4app://auth?handoff=<one-time code>`. The app hands that code (with the ceremony's verifier, so an intercepted custom-scheme URL is useless) to `POST /v1/auth/handoff` and is signed in.

On the Mac every hub call in these flows goes through the coordinator (new commands below), so the device token never enters the app process; only the ceremony UI runs in the app. On the iPhone, `MirrorHost` makes the calls directly, as it does for enrollment today.

## Onboarding

`OnboardingView` in `WorkspaceUI` (`onboarding.html`, left panel): "Welcome", "Two things before you start.", **Full name** (prefilled from Apple's name when Apple gave one, editable), **Phone number** (`textContentType(.telephoneNumber)`, stored as typed after trimming; a light check of 7 to 20 digits with an optional leading `+`), the hint "We'll use it to confirm it's you.", **Continue**, and "Not you? Log out".

Continue sends `PUT /v1/me/profile`, which stores both, sets `onboarded_at`, and renames the private org from its placeholder to "<first word of the full name>'s Org" (just "My Org" if that is empty). The Mac then shows "Add your iPhone" once (below); the phone goes to its thread list or to "Connect your Mac".

A user who quits mid-onboarding sees onboarding again at the next launch (the hub's `/v1/me` says `onboarded: false`).

## Pairing by QR code (amends D-058)

M8c's pairing stays: `POST /v1/pairing-codes` mints a 5-minute single-use code for the caller's user and org, and the phone redeems it with `POST /v1/enroll`. This design changes what the QR code holds and where it is shown, and lets it sign a phone in:

- **The link.** The QR code and the shareable link are `https://<site domain>/pair#c=<code>` instead of `b4app://pair?hub=…&code=…`. The site domain implies the hub, so the link carries no URL. The code sits after `#`, so it never reaches a web server's log. The iPhone app claims `/pair` through `applinks`, so the system Camera opens the app straight into pairing; without the app, the b4.run page says what it is and links to the App Store (TestFlight for `test.b4.run`). The in-app scanner reads the same link. `b4app://` stays for M8f's thread links and the Mac's Apple callback.
- **The Mac.** "Add your iPhone" (`pairing.html`, left) shows once after a new account finishes onboarding (Done skips it), and from M8c's "Remote access" Settings page as before: heading, one sentence, the QR code, "Works for 5 minutes · New code", Done, and "No iPhone app yet? It's on the App Store." It closes itself with "Paired with <name>" through M8c's `hub.pairStatus`.
- **The phone with no Mac** (`pairing.html`, middle): the thread list is replaced by "Connect your Mac" whenever the account has no `macos` device (signed out or not): "Your threads run on your Mac. Install Agent Workspace there, sign in, and scan the code it shows.", a primary **Scan the code** button (camera scanner; hidden without a camera), **Copy download link** (copies `https://<site>/app/download`, then reads "Copied" for two seconds), and **Help** (opens `https://<site>/app/help/iphone` in an `SFSafariViewController` sheet). The sidebar and profile menu stay.
- **What a scan does**, after M8c's one confirmation ("Pair this iPhone with Brian's Mac?"):
  - signed out: enrolls the phone into the code's account, which signs it in;
  - signed in to the same account: "This iPhone is already paired" (M8c);
  - signed in to a different account with no `macos` device (a phone-only account): merges that account into the code's account, so the person never lands in an empty account again (*my call*). In one transaction the hub moves the phone-only account's Apple and passkey identities to the code's user, revokes the phone's old device, enrolls it under the code's account, and deletes the phone-only user and its personal org (it holds no synced rows: only a Mac writes threads). The redemption route takes the phone's current token for this (`POST /v1/enroll` with an optional `Authorization` header; a token whose account has a `macos` device is refused with `merge_refused`);
  - signed in to a different account that has a Mac: asks "Switch to <org name>? You'll be signed out of <other org name>." and does so on confirm.

## Log out

**iPhone:** unchanged from D-053 (`MirrorLogOut`: stop syncing, revoke the device, forget the token, empty the mirror), except that it returns to the sign-in screen instead of the Connect screen. The phone holds only a copy of the hub's rows, so nothing is lost.

**Mac** (`pairing.html`, right), from the profile menu, a confirmation titled "Log out of <org name>?" whose message lists any running turns and servers. With work running the buttons are **Stop and log out** and **Cancel**. Then, in order:

1. Interrupt every running turn through `SessionService` and wait up to 10 s for each runtime to acknowledge; stop the local servers `LocalServerService` owns for this account (its existing identity-checked stop).
2. Flush drafts, then push the unsynced change log once, waiting at most 10 s. Whatever is left stays in the account's database and uploads at the next sign-in.
3. End the session on the hub (`DELETE /v1/sessions/self`, below): the token is deleted, the **device is kept**, so signing back in reuses the device id and sync continues from its cursor. `hub leave`'s revoke stays available as "Remove this Mac from your account" on the Remote access page.
4. Forget the token in the Keychain, stop `HubSync`, close the account's database pool, and report `signedOut`. The coordinator keeps running with no account loaded; the window shows the sign-in screen.

## The Mac's accounts

**One database per account** in the existing PostgreSQL cluster (D-041), named `workspace_<16 lowercase hex characters>` from a random id the coordinator assigns at first sign-in. A small registry database, `registry`, holds one table:

| column | meaning |
| --- | --- |
| `id` | the local account id (the database suffix) |
| `hub_user_id`, `hub_url` | which hub user this is; unique together |
| `device_id` | this Mac's device on that hub (reused at every sign-in) |
| `database` | the database name |
| `display_name`, `org_name` | for the profile button and the switch confirmation |
| `token_ref` | the Keychain reference of the current session's token, or null while signed out |
| `last_signed_in_at`, `active` | at most one row is active |

The account's own database keeps everything it has today, including its `hubLink` row, so `HubSync`, `HubPull`, and the change log need no change beyond being started per account. Codex and Claude logins, runtime detection, and executable lookup belong to the Mac and are shared by every account. UI state the app keeps outside the store (selection, window layout) is keyed by the local account id.

**Signing in** on the Mac: the coordinator runs the hub call, finds or creates the registry row by `(hub_url, hub_user_id)`, creates and migrates the database if new, stores the token, sets the row active, opens the pool, starts `HubSync` for it, and publishes `account.changed`. A sign-in sends the row's `device_id` when it has one, and the hub reuses that device if it belongs to the same user, has platform `macos`, and is not revoked; otherwise it creates a new device.

**The existing database** (`workspace`) is adopted, not copied: at the first launch of this version, if the registry is empty and `workspace` has a `hubLink`, the coordinator registers it as an account using that link's device and stored token (the user id comes from `GET /v1/me`), so a joined Mac starts signed in with no sign-in screen. If `workspace` has no link, it is registered at the first sign-in as that account's database (the threads made before sign-in existed go to the first account). Its name stays `workspace`.

**Signed out:** every coordinator command that reads or writes the store answers a new error `signed_out` ("Nobody is signed in. Sign in from the Agent Workspace app."). `system.*`, `diagnostics.read` (with an account section), `account.*`, `coordinator.*`, and runtime detection still work. The CLI prints that message and exits 4 for thread, turn, project, draft, server, and hub commands.

**`agent-workspace hub join`** stays as the operator path for a hub with sign-up closed (on-prem, or the owner's local hub before it has a passkey): it creates the account row exactly as a sign-in would. `hub leave` revokes the device and signs out. `hub status` reports the active account.

## The hub

### Data

Migration `0005_accounts.sql` (numbered after M8c's `0004_relay.sql`; if this lands first it takes `0004` and M8c renumbers):

- `users`: `email` becomes nullable; add `full_name text`, `phone text`, `onboarded_at timestamptz`, `deleted_at timestamptz`. `username` stays required and unique per org; sign-up generates `u-<8 random base32 characters>`.
- `orgs`: add `personal boolean NOT NULL DEFAULT false` and `owner_user_id uuid`; the slug is generated (`o-<8 random>`), never shown.
- `user_identities` (no row-level security, looked up before the tenant is known, like `device_tokens`): `id`, `org_id`, `user_id`, `kind` (`apple` or `passkey`), `created_at`, `last_used_at`, and for `apple`: `apple_sub` (unique), `apple_email`, `apple_refresh_token_enc` (the refresh token from the code exchange, encrypted with `B4HUB_SECRET_KEY`, kept so account deletion can revoke it); for `passkey`: `credential_id bytea` (unique), `passkey` (webauthn-rs's serialised `Passkey`, which holds the public key, counter, and backup flags), `user_handle bytea`, `name` (for the list in Settings).
- `auth_ceremonies` (no row-level security): `id`, `kind`, `state jsonb` (webauthn-rs's registration and authentication state, the Apple nonce and verifier hash), `expires_at` (5 minutes), `used_at`. Stored in the database rather than in memory so any hub instance can finish a ceremony another began. Expired rows are pruned with the change log.
- `auth_handoffs` (no row-level security): `code_hash`, `ceremony_id`, `user_id`, `org_id`, `expires_at` (2 minutes), `used_at`.
- `devices` and `device_tokens` unchanged; a session is a token row.

### Routes

All under `/v1`, JSON, B4's error envelope, `deny_unknown_fields`. Every route that creates a device takes `{ deviceName, platform, deviceId? }` and answers the enrollment shape plus `needsOnboarding`: `{ deviceId, token, org: {slug, name}, user: {username, displayName}, needsOnboarding }`.

| Route | Auth | Does |
| --- | --- | --- |
| `GET /auth/config` | none | `{ passkeys: {rpId}, apple: {native: bool, web: bool}, signup: "open" \| "closed" }`, so a client hides what the hub does not offer |
| `POST /auth/passkey/begin` | none | creates a ceremony; answers `ceremonyId`, `authentication` and `registration` options (registration omitted when sign-up is closed) |
| `POST /auth/passkey/finish` | none | `{ ceremonyId, assertion? \| attestation?, device }`; verifies, then signs in or creates user, personal org, identity, device, token |
| `POST /auth/apple/native` | none | `{ ceremonyId, identityToken, authorizationCode, fullName?, device }`; verifies the token, exchanges the code, then signs in or signs up |
| `GET /auth/apple/start` | none | `?ceremony=&verifierHash=` (the ceremony made by `POST /auth/apple/begin`); 302 to Apple |
| `POST /auth/apple/begin` | none | creates an Apple ceremony; answers `ceremonyId`, `nonce` (the native flow passes its SHA-256 to Apple) |
| `POST /auth/apple/callback` | Apple's form post | verifies `state`, exchanges the code, verifies the token, records a handoff, 302 to `<scheme>://auth?handoff=` |
| `POST /auth/handoff` | none | `{ handoff, verifier, device }`; single use |
| `PUT /me/profile` | device | `{ fullName, phone }`; sets `onboarded_at`, renames the personal org |
| `GET /me` | device | gains `user.fullName`, `onboarded`, `identities: [{id, kind, name, createdAt, lastUsedAt}]` |
| `POST /me/passkeys/begin`, `POST /me/passkeys/finish` | device | adds a passkey to the signed-in user |
| `POST /me/apple` | device | links an Apple ID (native token, or a handoff from the web flow) |
| `DELETE /me/identities/{id}` | device | unlinks, refused while it is the last one (`last_identity`) |
| `DELETE /sessions/self` | device | deletes this token, keeps the device (Log out) |
| `DELETE /me` | device | deletes the account (below) |

- **Apple verification:** ES256 against Apple's JWKS (`https://appleid.apple.com/auth/keys`, cached, refetched on an unknown `kid`), `iss = https://appleid.apple.com`, `aud` in `B4HUB_APPLE_AUDIENCES` (the iOS bundle id and the Services ID), `exp`, and the ceremony's nonce. The code exchange uses a client secret JWT the hub signs with the `.p8` key (`B4HUB_APPLE_TEAM_ID`, `B4HUB_APPLE_KEY_ID`, `B4HUB_APPLE_PRIVATE_KEY`). The user is found by `sub`; a new `sub` signs up. Apple's email is stored but never used to merge accounts.
- **WebAuthn:** `webauthn-rs` with `B4HUB_WEBAUTHN_RP_ID` (the site domain) and origin `https://<rp id>`. Sign-in uses discoverable authentication (the `conditional-ui` feature) and finds the user by credential id; the counter and backup state are updated on each use.
- **Sign-up policy:** `B4HUB_SIGNUP=open|closed`, default `closed` so an on-prem hub never grows accounts by accident; prod, test, and the local Compose `.env.example` set `open`. With it closed, a new Apple `sub` or a registration answers `signup_closed`.
- **Account deletion** (App Store guideline 5.1.1(v)): revokes each Apple refresh token at Apple's `/auth/revoke`, deletes the user's tokens, identities, devices, and, for a personal org, every tenant row of that org, then the org and user, in one transaction after the revoke calls. The iPhone offers it in Settings → Account ("Delete account…", with a typed confirmation of the org name); the Mac offers the same and then drops that account's local database and registry row.
- **Existing users:** the migration sets `onboarded_at = created_at` and `full_name = display_name` for every existing user and leaves existing orgs with `personal = false`, so enrolled users keep working unchanged.
- **Rate limits** (in memory per process, M8c's mechanism): `begin` routes 20 per IP per minute; `finish`, `native`, `handoff` 10 per IP per minute; answering `rate_limited`.
- **Errors** added to the table and to Swift's `ErrorCode`: `signup_closed`, `merge_refused`, `ceremony_expired`, `credential_rejected` (any failed verification, deliberately vague), `last_identity`, `signed_out` (coordinator only).
- **Secrets:** none of the request bodies above, the client secret, the refresh tokens, or `B4HUB_SECRET_KEY` appear in a log line; the hub's existing redaction tests extend to them.
- `b4hub seed` keeps working for the Compose stack; `b4hub enroll` stays as the operator fallback.

### Linking and Settings → Account

A new Settings page, **Account** (both apps), shows the full name, phone, org name, and the sign-in methods ("Apple ID · added 1 Nov", "Passkey · Brian Love · added 1 Nov") with **Add a passkey**, **Connect Apple ID** (when there is none), **Remove** on each method (disabled for the last one), and **Delete account…** at the bottom in the danger style. An account made with Apple adds a passkey here, and the reverse; signing in with either then reaches the same account. The owner's existing local account (`blove`, joined by enrollment code) adds its first passkey here.

## The coordinator and the protocol

New commands (protocol-additive; the CLI gets matching `account` subcommands only for `status` and `logout`):

- `account.status` → `{ state: "signedOut" | "needsOnboarding" | "signedIn", account?: {id, displayName, orgName, hubURL} , known: [{id, displayName, orgName, lastSignedInAt}] }`.
- `account.passkeyBegin` → the hub's begin answer (no secret in it); `account.passkeyFinish { ceremonyId, assertion | attestation }`; `account.appleStart` → `{ url, callbackScheme }`; `account.appleFinish { handoff }` (the verifier never leaves the coordinator); `account.completeProfile { fullName, phone }`; `account.logout { stopWork: bool }` → refuses with `work_running` and the list when work runs and `stopWork` is false; `account.identities`, `account.addPasskeyBegin/Finish`, `account.removeIdentity`, `account.delete`.
- Event `account.changed` with the new `account.status` result.

The WebAuthn responses and the Apple handoff cross the local socket once, to the coordinator, and are never logged or stored; this is the same narrow exception D-058 records for the pairing code.

`WorkspaceModel` gains `accountState` and drives the root view from it; `account` (D-053's profile button) reads from it. The iPhone's `MirrorHost` exposes the same state from its own calls, so `WorkspaceUI` stays transport-neutral (it never imports `WorkspaceMirror`).

## The website (`~/repos/b4run`, Vercel)

Changes in the b4.run repository, deployed by its existing Vercel project, with `test.b4.run` and `local.b4.run` added as domains of the same project (*my call*):

- `/.well-known/apple-app-site-association`, served per host by a route handler as `application/json` with no redirect: `webcredentials.apps` lists the flavour's Mac and iPhone app ids (`<team>.<bundle id>`), and `applinks` maps `/pair` to the iPhone app (not on `local.b4.run`'s Mac-only entry beyond what the local iPhone flavour needs).
- `/pair`: a static page that reads nothing from the fragment, says "Open this on your iPhone with Agent Workspace installed", and links to the App Store (TestFlight on `test.b4.run`). It stays at the root so the QR link is short.
- Everything else for the app lives under `/app/`, because `/privacy` is already B4's live privacy policy and `/docs` is B4's framework documentation (*my call*): `/app/download` (the notarized zip and the Homebrew line; the beta zip on `test.b4.run`), `/app/terms`, `/app/privacy`, and `/app/help/iphone` (pairing help). The sign-in screen, the phone's Help and Copy download link, and App Store Connect point at these. Copy for terms and privacy is the owner's; the builder adds placeholders marked as drafts.

## Releases: the download and the Homebrew cask

*My call:* the notarized Mac zips are attached to GitHub Releases on the public `cacheplane/b4app` repository (tags `mac-v<version>` for prod and `mac-v<version>-beta` for beta), and a new public tap, `cacheplane/homebrew-tap`, carries `Casks/agent-workspace.rb` pointing at the prod zip with its SHA-256 and linking the bundled `agent-workspace`. A `release-mac.yml` workflow is not in scope: the owner's Mac holds the Developer ID identity and the notary profile (D-039), so `Scripts/release-mac.sh` packages, notarizes, creates the release with `gh release create`, and opens a pull request on the tap updating the version and hash. `/app/download` links the latest release's asset through GitHub's `releases/latest/download/` URL.

## The hosted hubs (a separate project)

Standing up the prod and test hubs (hosting, databases, domains, TLS, deploys, backups, secrets) is the owner's separate thread, not this project. This design depends on it only through these facts, which that project provides:

- `https://hub.b4.run` and `https://hub.test.b4.run` serve this repository's `Hub/` image with its migrations applied, reachable over HTTPS with long-lived connections (M8c's WebSockets, 25 s long-polls, PostgreSQL `LISTEN/NOTIFY`).
- Each sets `B4HUB_SIGNUP=open`, `B4HUB_WEBAUTHN_RP_ID` (`b4.run` or `test.b4.run`), `B4HUB_PUBLIC_URL`, `B4HUB_SECRET_KEY`, and the `B4HUB_APPLE_*` values from the owner's Sign in with Apple key, and lists `/v1/auth/apple/callback` as reachable for Apple's form post.

Until those hubs exist, this project is built and verified against the local hub (Compose) with passkeys, and the Apple flows against the hub's test doubles; the prod and beta flavours compile and point at the URLs above.

## Privacy declarations

The iPhone app now collects a name, a phone number, an email (from Apple), and a user id, so `PrivacyInfo.xcprivacy` changes from "no data collected" (D-051) to declaring those as linked to the user, used for app functionality, not for tracking. The owner updates the App Store Connect privacy answers to match before the first build with sign-in goes to TestFlight.

## Visual identity

LLA throughout (`2026-10-31-lla-visual-system-design.md`): Hanken Grotesk, ink and muted text, one cobalt accent used only for links and focus, pills for buttons, no eyebrows, no uppercase, no gradients. The b4.run wordmark appears only on the sign-in screen. Dark mode uses `wordmark-white.svg` and the existing dark tokens; the Apple pill inverts to white with a black logo in dark mode, as Apple's guidelines allow.

## Testing

- **Hub:** black-box tests over a loopback listener, as today. WebAuthn with a software authenticator (`webauthn-authenticator-rs` or fixed fixtures generated once); Apple with a test JWKS and a fake token endpoint the hub is pointed at by `B4HUB_APPLE_BASE_URL` (test-only). Cases: sign-up and sign-in by each method, closed sign-up, expired and reused ceremonies and handoffs, linking and the last-identity refusal, device reuse, session end versus revoke, deletion removing every tenant row, RLS still isolating two personal orgs, redaction.
- **Coordinator:** fake hub (`HubAPI` fake) for the account lifecycle: adopt the old database, sign in creates a database, switch accounts preserves each one's threads, log out with work running refuses then stops, `signed_out` on store commands.
- **UI:** snapshot-free view tests that the root shows the right screen per state; the existing accessibility identifiers convention for the new controls.
- **Live, opt-in, never in CI:** `B4APP_LIVE_HUB_URL` against the test hub for a real passkey ceremony is manual (it needs a person and a device); the verification record says so.

## Phases (for the plan)

1. Flavours: xcconfigs, bundle ids, per-flavour paths and labels, the local-flavour data move, `package.sh` and `upload-ios.sh` per flavour.
2. Hub identity: migration, passkey routes, profile, sessions, sign-up policy, Account routes, deletion (Apple pieces stubbed behind config).
3. Mac accounts: registry, per-account databases, adoption, `account.*` commands, `signed_out`, log out, CLI.
4. Screens: sign-in, onboarding, Account settings, gating on both apps; passkeys end to end against the local hub with `local.b4.run`'s file live.
5. Website: association files, `/pair`, `/app/download`, `/app/terms`, `/app/privacy`, `/app/help/iphone`, the `test.b4.run` and `local.b4.run` domains on the existing Vercel project.
6. Sign in with Apple: native on iOS, web flow on the Mac, code exchange, revoke on deletion.
7. Releases: `Scripts/release-mac.sh`, the tap, and the cask.
8. Pairing changes: the `https` link, universal links, "Add your iPhone" after onboarding, "Connect your Mac", account switching on scan. Depends on M8c's pairing route; if M8c is not built yet this phase builds that route as M8c specifies with the amendments above.

## Decisions to record

Numbers are assigned at commit from `main`'s highest (D-059 merged, D-060 in an open PR, so these start at D-061 and are re-checked before merging):

- Mac distribution is Developer ID download and Homebrew only; no Mac App Store or TestFlight for Mac (amends D-051), with the sandbox research.
- Build flavours prod, beta, local with their hubs, domains, and identifiers.
- Accounts: sign-in by Apple ID or passkey, one private org per user, sign-up policy, Apple via the web flow on the Mac.
- The Mac keeps one database per account and adopts the existing one; Log out ends the session and keeps the device.
- Pairing links are `https` universal links on the site domain and sign a phone in (amends D-058).

## Left to the builder

- Exact copy beyond what is quoted here, error messages, and the docs page's text.
- The software-authenticator choice for hub tests, and crate versions (pinned exactly, per the hub's conventions).
- Whether `ASCredentialUpdater`'s rename runs only after onboarding or also after a name change in Settings.
- How the registry database is migrated (its own tiny migration list in `WorkspaceStorage`).
- Layout details within the mockups, the scanner's framing, and the iPad layout.
