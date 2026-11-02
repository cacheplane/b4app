# Apple Developer setup for sign-in

One-time work in the Apple Developer account that sign-in needs (design `docs/superpowers/specs/2026-11-01-sign-in-design.md`, decisions D-062 to D-067). The team is `GJJKL34HCT`, the team of the certificate `Developer ID Application: Brian Love (GJJKL34HCT)` on the build Mac. Nothing here is automated, and no Apple credential passes through a script or the repository.

Everything happens at [developer.apple.com/account](https://developer.apple.com/account) → **Certificates, IDs & Profiles**, which has four sections in its left column: Certificates, **Identifiers**, Devices, **Profiles**, plus **Keys** further down. Do the steps in order: profiles are made last because they copy whatever the App IDs allow at the time.

## Where the domains go

The portal has no field for a domain. Ticking **Associated Domains** on an App ID only lets that app ask for domains. The domains themselves are written by our build into the app's entitlements (`Scripts/package.sh` adds `webcredentials:b4.run`, `webcredentials:test.b4.run`, or `webcredentials:local.b4.run` per flavour, and the iOS entitlements add `applinks:` too). The other half is the file the domain serves, `https://<domain>/.well-known/apple-app-site-association`, which is already live (section 6). So in the portal you only tick the box.

## 1. App IDs

### Change an existing App ID

1. **Identifiers**. The list shows App IDs by default (the filter at the top right says "App IDs").
2. Click the row whose identifier is the bundle id, for example `com.cacheplane.b4app`.
3. In the **Capabilities** list, tick the capability (for example **Associated Domains**). Associated Domains has no Configure button; the tick is all.
4. **Save** (top right). The portal warns that existing profiles for this App ID become invalid. Click **Confirm**. You regenerate them in section 4.

### Register a new App ID

1. **Identifiers** → the **+** button beside the "Identifiers" heading.
2. Choose **App IDs** → **Continue**.
3. Choose **App** → **Continue**.
4. If the page asks for a platform, pick **macOS** for a Mac id and **iOS** for an iPhone id.
5. **Description**: the description from the table below. **Bundle ID**: choose **Explicit** and type the bundle id exactly.
6. Under **Capabilities**, tick what the table lists.
7. **Continue** → **Register**.

### The App IDs

| Bundle id | Platform | Description | Tick | Action |
| --- | --- | --- | --- | --- |
| `com.cacheplane.b4app` | macOS | Agent Workspace | Associated Domains | change |
| `com.cacheplane.b4app.coordinator` | macOS | Agent Workspace coordinator | nothing new | none |
| `com.cacheplane.b4app.beta` | macOS | Agent Workspace Beta | Associated Domains | new |
| `com.cacheplane.b4app.beta.coordinator` | macOS | Agent Workspace Beta coordinator | nothing | new |
| `com.cacheplane.b4app.local` | macOS | Agent Workspace Local | Associated Domains | new |
| `com.cacheplane.b4app.local.coordinator` | macOS | Agent Workspace Local coordinator | nothing | new |
| `com.cacheplane.b4app.ios` | iOS | Agent Workspace iOS | Associated Domains and Sign in with Apple (see below) | change, or new if it isn't in the list |
| `com.cacheplane.b4app.ios.local` | iOS | Agent Workspace iOS Local | Associated Domains | new |

**Sign in with Apple on `com.cacheplane.b4app.ios`:** tick it, click **Edit** (or **Configure**) beside it, choose **Enable as a primary App ID**, **Save**, then **Save** the App ID and **Confirm**.

Do not tick Sign in with Apple on any Mac id: Apple does not allow it for Developer ID apps, which is why the Mac signs in through the Services ID in section 2.

**Keychain sharing:** the coordinator ids need no capability. Every Developer ID profile already allows the team's keychain groups (`GJJKL34HCT.*`), which covers `…b4app.shared`, `…b4app.beta.shared`, and `…b4app.local.shared`; `package.sh` checks that in each profile. If the capability list shows a Keychain Sharing entry, ticking it does no harm.

## 2. Services ID for the Mac's sign-in

1. **Identifiers** → **+** → **Services IDs** → **Continue**.
2. **Description** `Agent Workspace Mac sign-in`, **Identifier** `com.cacheplane.b4app.signin` → **Continue** → **Register**.
3. Open it again: change the filter at the top right of Identifiers from "App IDs" to **Services IDs**, then click `com.cacheplane.b4app.signin`.
4. Tick **Sign in with Apple** → **Configure**. In the dialog:
   - **Primary App ID**: `com.cacheplane.b4app.ios`.
   - **Domains and Subdomains**: `hub.b4.run,hub.test.b4.run`
   - **Return URLs**: `https://hub.b4.run/v1/auth/apple/callback,https://hub.test.b4.run/v1/auth/apple/callback`
   - **Next** → **Done**.
5. **Continue** → **Save**.

## 3. Sign in with Apple key

1. **Keys** → **+**.
2. **Key Name** `Agent Workspace Sign in with Apple`.
3. Tick **Sign in with Apple** → **Configure** → **Primary App ID** `com.cacheplane.b4app.ios` → **Save**.
4. **Continue** → **Register**.
5. **Download** the `.p8` file. Apple allows one download. Note the **Key ID** on that page.

Keep the `.p8` in your password manager, never in the repository. The hosted hubs take it as environment variables:

| Variable | Value |
| --- | --- |
| `B4HUB_APPLE_TEAM_ID` | `GJJKL34HCT` |
| `B4HUB_APPLE_KEY_ID` | the Key ID from step 5 |
| `B4HUB_APPLE_PRIVATE_KEY` | the full text of the `.p8`, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| `B4HUB_APPLE_AUDIENCES` | `com.cacheplane.b4app.ios,com.cacheplane.b4app.signin` |
| `B4HUB_APPLE_SERVICES_ID` | `com.cacheplane.b4app.signin` |

The local hub (Compose) needs none of these: the local flavour signs in with passkeys only.

## 4. Developer ID profiles for the Mac

Six profiles, one per Mac App ID. For each:

1. **Profiles** → **+**.
2. Under **Distribution**, choose **Developer ID** → **Continue**. If it asks for a profile type, choose **macOS**.
3. **App ID**: pick the App ID from the dropdown → **Continue**.
4. **Certificate**: pick **Developer ID Application** (Brian Love, GJJKL34HCT) → **Continue**.
5. **Provisioning Profile Name**: the name from the table (it becomes the downloaded file's name) → **Generate** → **Download**.

| App ID | Profile name | Save as |
| --- | --- | --- |
| `com.cacheplane.b4app` | `app` | `~/.b4app/signing/app.provisionprofile` |
| `com.cacheplane.b4app.coordinator` | `coordinator` | `~/.b4app/signing/coordinator.provisionprofile` |
| `com.cacheplane.b4app.beta` | `app-beta` | `~/.b4app/signing/app-beta.provisionprofile` |
| `com.cacheplane.b4app.beta.coordinator` | `coordinator-beta` | `~/.b4app/signing/coordinator-beta.provisionprofile` |
| `com.cacheplane.b4app.local` | `app-local` | `~/.b4app/signing/app-local.provisionprofile` |
| `com.cacheplane.b4app.local.coordinator` | `coordinator-local` | `~/.b4app/signing/coordinator-local.provisionprofile` |

The existing `app` profile became invalid when you added Associated Domains in section 1. Either open it in **Profiles**, click **Edit** → **Save** → **Download**, or make a new one as above. The existing `coordinator` profile is still valid; keep it unless the list shows it as invalid.

Move the downloads into place. The portal drops hyphens from the file name (`app-beta` downloads as `appbeta.provisionprofile`), so rename while moving:

```bash
mkdir -p ~/.b4app/signing && cd ~/Downloads && for f in app coordinator app-beta coordinator-beta app-local coordinator-local; do g=${f//-/}; [ -f "$g.provisionprofile" ] && mv "$g.provisionprofile" ~/.b4app/signing/"$f.provisionprofile"; done; ls ~/.b4app/signing
```

Then check each flavour's profiles without building. Each prints any entitlement a profile is missing, or says the profiles are fine:

```bash
B4APP_FLAVOR=local B4APP_TEAM_ID=GJJKL34HCT B4APP_CHECK_PROFILES_ONLY=1 ./Scripts/package.sh
```

```bash
B4APP_FLAVOR=beta B4APP_TEAM_ID=GJJKL34HCT B4APP_CHECK_PROFILES_ONLY=1 ./Scripts/package.sh
```

```bash
B4APP_FLAVOR=prod B4APP_TEAM_ID=GJJKL34HCT B4APP_CHECK_PROFILES_ONLY=1 ./Scripts/package.sh
```

A Developer ID profile lasts 18 years. Renewing the Developer ID certificate means regenerating all six (D-051).

## 5. iOS

No profiles to download. `Scripts/upload-ios.sh` uses automatic cloud-managed signing, which makes the App Store profiles with the new capabilities on the next upload. Local-flavour Simulator builds use Xcode's automatic development signing.

Before the first TestFlight build with sign-in: App Store Connect → the app → **App Privacy** → edit the answers so the app collects **Name**, **Email Address**, and **User ID**, each linked to the user, used for **App Functionality**, not for tracking.

## 6. Already done (2026-11-01)

- Apple: App IDs, the Services ID, and the Sign in with Apple key (Key ID `V9BJVV23LA`) made by the owner. All six Developer ID profiles are in `~/.b4app/signing/` and pass `B4APP_CHECK_PROFILES_ONLY=1` for local, beta, and prod (each expires 2044-10-28). The key's `.p8` sits beside them with mode 600; it belongs in the password manager and the hosted hubs' secret store, never the repository.

- Vercel: `test.b4.run` and `local.b4.run` added to the b4.run project (`dawnai`), with no redirect, and `APPLE_TEAM_ID=GJJKL34HCT` set for production and preview.
- `cacheplane/b4run#1129` merged and deployed the same day. `https://{b4.run,test.b4.run,local.b4.run}/.well-known/apple-app-site-association` each answer 200 `application/json` with that flavour's app ids, and `/pair` and `/app/download` answer 200. Apple's CDN picks the files up within a day.
