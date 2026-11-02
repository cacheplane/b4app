# Apple Developer setup for sign-in

One-time work in the Apple Developer account (team `GJJKL34HCT`, the team of the Developer ID certificate on the build Mac) that sign-in needs (design `docs/superpowers/specs/2026-11-01-sign-in-design.md`, decisions D-062 to D-067). Nothing here is automated; no Apple credential passes through a script or the repository.

All of it is at [developer.apple.com/account](https://developer.apple.com/account) → Certificates, Identifiers & Profiles.

## 1. App IDs

Identifiers → **+** → App IDs → App. Explicit bundle ids, platform as listed. "Change" means edit the existing id and tick the capability.

| Bundle id | Platform | Capabilities | Action |
| --- | --- | --- | --- |
| `com.cacheplane.b4app` | macOS | Associated Domains, Keychain Sharing | change: add Associated Domains |
| `com.cacheplane.b4app.coordinator` | macOS | Keychain Sharing | none |
| `com.cacheplane.b4app.beta` | macOS | Associated Domains, Keychain Sharing | new |
| `com.cacheplane.b4app.beta.coordinator` | macOS | Keychain Sharing | new |
| `com.cacheplane.b4app.local` | macOS | Associated Domains, Keychain Sharing | new |
| `com.cacheplane.b4app.local.coordinator` | macOS | Keychain Sharing | new |
| `com.cacheplane.b4app.ios` | iOS | Associated Domains, Sign in with Apple (**Enable as a primary App ID**) | change, or new if TestFlight's automatic signing never registered it |
| `com.cacheplane.b4app.ios.local` | iOS | Associated Domains | new (Simulator builds of the local flavour) |

Sign in with Apple is not offered for Developer ID Mac apps (Apple's capabilities table), which is why the Mac uses the web flow through a Services ID instead.

## 2. Services ID for the Mac's web sign-in

Identifiers → **+** → Services IDs.

- Description: `Agent Workspace (Mac sign-in)`
- Identifier: `com.cacheplane.b4app.signin`

Then open it, tick **Sign in with Apple**, and **Configure**:

- Primary App ID: `com.cacheplane.b4app.ios` (grouping keeps the Apple user id the same on the Mac and the iPhone)
- Domains and Subdomains: `hub.b4.run`, `hub.test.b4.run`
- Return URLs: `https://hub.b4.run/v1/auth/apple/callback`, `https://hub.test.b4.run/v1/auth/apple/callback`

Save, then Continue → Save.

## 3. Sign in with Apple key

Keys → **+**.

- Key name: `Agent Workspace Sign in with Apple`
- Tick **Sign in with Apple** → Configure → Primary App ID `com.cacheplane.b4app.ios` → Save
- Continue → Register → **Download** the `.p8` file. Apple lets you download it once. Note the **Key ID** shown beside it.

Keep the `.p8` in your password manager, not in the repository. The hosted hubs (the deployment project) take it as environment variables:

| Variable | Value |
| --- | --- |
| `B4HUB_APPLE_TEAM_ID` | `GJJKL34HCT` |
| `B4HUB_APPLE_KEY_ID` | the Key ID from this step |
| `B4HUB_APPLE_PRIVATE_KEY` | the full contents of the `.p8` file, including the `BEGIN`/`END` lines |
| `B4HUB_APPLE_AUDIENCES` | `com.cacheplane.b4app.ios,com.cacheplane.b4app.signin` |
| `B4HUB_APPLE_SERVICES_ID` | `com.cacheplane.b4app.signin` |

The local hub (Compose) does not need any of these: the local flavour has passkeys only.

## 4. Developer ID provisioning profiles (Mac)

Profiles → **+** → Distribution → **Developer ID**, one per Mac App ID, with the Developer ID certificate `Developer ID Application: Brian Love (GJJKL34HCT)`. Save each where `Scripts/package.sh` looks for it:

| App ID | Save as |
| --- | --- |
| `com.cacheplane.b4app` | `~/.b4app/signing/app.provisionprofile` (replaces today's file, which lacks Associated Domains) |
| `com.cacheplane.b4app.coordinator` | `~/.b4app/signing/coordinator.provisionprofile` (regenerate only if the portal marks it invalid) |
| `com.cacheplane.b4app.beta` | `~/.b4app/signing/app-beta.provisionprofile` |
| `com.cacheplane.b4app.beta.coordinator` | `~/.b4app/signing/coordinator-beta.provisionprofile` |
| `com.cacheplane.b4app.local` | `~/.b4app/signing/app-local.provisionprofile` |
| `com.cacheplane.b4app.local.coordinator` | `~/.b4app/signing/coordinator-local.provisionprofile` |

Then check each flavour without building:

```bash
B4APP_FLAVOR=local B4APP_CHECK_PROFILES_ONLY=1 ./Scripts/package.sh
```

```bash
B4APP_FLAVOR=beta B4APP_CHECK_PROFILES_ONLY=1 ./Scripts/package.sh
```

```bash
B4APP_FLAVOR=prod B4APP_CHECK_PROFILES_ONLY=1 ./Scripts/package.sh
```

Each prints any entitlement a profile is missing. A Developer ID profile lasts 18 years; renewing the certificate means regenerating all six (D-051).

## 5. iOS

Nothing to download. `Scripts/upload-ios.sh` uses automatic cloud-managed signing, which creates the App Store profiles with the new capabilities on the next upload. Local-flavour Simulator builds sign with Xcode's automatic development signing.

Before the first TestFlight build with sign-in, update the app's privacy answers in App Store Connect → the app → App Privacy: it now collects Name, Email Address, and User ID, linked to the user, used for App Functionality, not for tracking.

## 6. Already done (2026-11-01)

- Vercel: `test.b4.run` and `local.b4.run` added to the b4.run project (`dawnai`), no redirect; `APPLE_TEAM_ID=GJJKL34HCT` set for production and preview. `cacheplane/b4run#1129` merged and deployed the same day: `https://{b4.run,test.b4.run,local.b4.run}/.well-known/apple-app-site-association` each answer 200 `application/json` with that flavour's app ids, and `/pair` and `/app/download` answer 200. Apple's CDN picks the files up within a day.
