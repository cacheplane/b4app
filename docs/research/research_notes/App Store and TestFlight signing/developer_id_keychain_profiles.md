# Developer ID app + LaunchAgent helper sharing a data-protection keychain access group (late 2026)

Scope: `com.cacheplane.b4app` (team `GJJKL34HCT`), notarized Developer ID distribution, with a coordinator helper that is today a bare Mach-O at `Contents/Helpers/b4app-coordinator`, run as a per-user LaunchAgent in the Aqua session. Both must read and write the same generic-password items with `kSecUseDataProtectionKeychain`.

Method note: Apple's documentation pages were read from their DocC JSON (`https://developer.apple.com/tutorials/data/documentation/<path>.json`) because the HTML pages render client-side. The citations give the human-readable URL. Developer Forums posts by Quinn "The Eskimo!" (Apple DTS) are labelled **[DTS forum]**. They are Apple staff but not formal documentation. Anything else is labelled **[secondary]**.

## 1. Which entitlements grant a data-protection keychain access group, their formats, the default group, sharing between app and helper, and app groups (including the macOS 15 and 2025 changes)

### Takeaway
On macOS the data-protection keychain access-group list is built from three entitlements, in this order: `keychain-access-groups`, then `com.apple.application-identifier`, then `com.apple.security.application-groups`. The first entry is the default group for `SecItemAdd`. `keychain-access-groups` is a restricted entitlement that a provisioning profile must authorize. The simplest robust plan is for both the app and the helper to claim the same explicit `keychain-access-groups` value, for example `GJJKL34HCT.com.cacheplane.b4app.shared`, listed first in both, with each authorized by its own Developer ID profile. App groups can act as keychain access groups on macOS only when they are `group.`-style, registered, and profile-authorized, which has been possible since February 2025. Apple DTS has said it has not tested this, so it is the riskier path.

### Cited Findings
- "macOS builds the list of data protection keychain access groups available to your program from its code signing entitlements… These entitlements must be authorized by a provisioning profile. Your program needs an app-like bundle structure in which to embed that profile. This is standard for app and app extensions but not for command-line tools." — [TN3137: On Mac keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- Library code gets no keychain access of its own: "its data protection keychain access is determined by the entitlements of the host process's main executable." — [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- The access-group list is "the concatenation of the following items, evaluated in this order":
  1. Keychain access groups (`keychain-access-groups`, an array of strings).
  2. Application identifier. Xcode adds "the `application-identifier` entitlement (or the `com.apple.application-identifier` entitlement in macOS) … formed as the team identifier (team ID) plus the bundle identifier (bundle ID)."
  3. Application groups. "You can use app group names as keychain access group names, without adding them to the Keychain access groups entitlement."
  — [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- Default group: "The system considers the first item in the list of access groups to be the app's default access group… An app group can't ever be the default, because the app ID is always present and appears earlier in the list… the first keychain access group, if any, that you specify in the corresponding capability becomes the app's default access group. If you don't specify any keychain access groups, then the app ID is the default." — [Sharing access to keychain items…](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- "If you don't specify any access group when adding an item, keychain services applies your app's default access group". A query that omits `kSecAttrAccessGroup` "matches any of your app's groups". Specifying a group the app doesn't belong to makes `SecItemAdd` fail with `errSecMissingEntitlement`, and an empty-string group is invalid. — [Sharing access to keychain items…](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps); [errSecMissingEntitlement](https://developer.apple.com/documentation/security/errsecmissingentitlement)
- Format: "Xcode automatically prefixes keychain groups with your team ID". The example is `$(teamID).com.example.SharedItems`. Your app ID group (`$(teamID).com.example.AppOne`) can be shared with "another app signed by the same Apple Developer team… using the Keychain Access Groups Entitlement." — [Sharing access to keychain items…](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- A real distribution-signed macOS example of the expanded values (no `$(…)` variables in the signature) — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac):
  - `com.apple.application-identifier` = `[Team ID].com.example…App`
  - `com.apple.developer.team-identifier` = `[Team ID]`
  - `keychain-access-groups` = `[[Team ID].com.example…SharedKeychain]`
- On macOS the App ID entitlement is `com.apple.application-identifier`, not `application-identifier`. A Mac Catalyst app uses both. — [TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- Profiles allowlist entitlements, sometimes with wildcards. In TN3125's example, the profile's `keychain-access-groups` value `SKMME9E2Y8.*` "means that the app can claim any keychain access group with the `SKMME9E2Y8.` prefix. Wildcards don't make sense in the app's code signature." — [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- On macOS these are unrestricted, so no profile is needed: `com.apple.security.get-task-allow`, `com.apple.security.application-groups`, the App Sandbox entitlements, and the Hardened Runtime entitlements. "In contrast, restricted entitlements must be authorized by a provisioning profile… the fact that the `keychain-access-groups` entitlement must be authorized by a profile means that other developers can't impersonate your app in order to steal its keychain items." — [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- The App Groups entitlement format is `group.<group name>`, or on macOS also `<team identifier>.<group name>` ("You don't need to register app groups that use this format"). "App groups that you register in your Apple Developer profile also act as keychain access groups." — [App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
- "You can also use an app group, which has an identifier that starts with the `group.` prefix, as a Keychain Access Group." With the macOS `<Team ID>.<group name>` form, "macOS checks that the code signature of processes that try to access the app group container contains the same `Developer-Team-ID`" (container access, not keychain). — [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- **[DTS forum]** "App Groups: macOS vs iOS: Working Towards Harmony" (rewritten 2025-04-16, last revised 2025-08-12):
  - The App Groups entitlement "is not restricted on macOS".
  - "Starting in Feb 2025, iOS-style app group IDs are fully supported on macOS for all product types". It is now possible to create a Mac profile that authorizes a `group.` ID.
  - Since June 2025, the Developer website automatically adds `TEAM_ID.*` to the app-group IDs authorized by a Mac profile when the App ID has the App Groups capability.
  - Historically app groups as keychain access groups "didn't work on macOS because the App Groups entitlement is unrestricted there. However, with the Feb 2025 changes it should now be possible to use an iOS-style app group ID as a keychain access group on macOS." Quinn adds: "I say 'should' because I've not actually tried it."
  - "Standard keychain access groups are protected the same way on all platforms, using the restricted Keychain Access Groups entitlement."
  — [Apple Developer Forums thread 721701](https://developer.apple.com/forums/thread/721701)
- **[DTS forum]** macOS 15 introduced app group container protection. To access a group container without a prompt, the app must claim the group and meet at least one criterion: Mac App Store, TestFlight on macOS 15.1+, a group ID that starts with the app's Team ID, or a claim "authorised by a provisioning profile embedded in the app". Otherwise the user is prompted, and consent lasts only for that app instance. This concerns containers, not keychain items. — [thread 721701](https://developer.apple.com/forums/thread/721701)
- **[DTS forum, via search summary]** Keychain access groups derived from an app group are tied to the team rather than to the App ID prefix, so they survive an App ID prefix change. A macOS app can use one only if a provisioning profile validates all of its entitlement claims. — [thread 706128](https://developer.apple.com/forums/thread/706128). I read this only through a search-result summary because the page did not render for me.

### Inferences
- Recommended entitlement set for both executables, written out expanded:
  - `com.apple.application-identifier` = `GJJKL34HCT.<bundle id>`
  - `com.apple.developer.team-identifier` = `GJJKL34HCT`
  - `keychain-access-groups` = `[ "GJJKL34HCT.com.cacheplane.b4app.shared" ]`
  - Use the same single string in both executables and put it first, so it is the default group in both. Also pass `kSecAttrAccessGroup` explicitly on every add and query, so the code does not depend on ordering or pick up the app's private App ID group.
  - Alternatively, use the app's own App ID group `GJJKL34HCT.com.cacheplane.b4app` as the shared group, which the sharing doc permits. A dedicated `.shared` string reads more clearly and does not tie the items to the app's bundle ID.
- `$(AppIdentifierPrefix)` is an Xcode build-setting expansion (team ID plus a dot). A hand-rolled `codesign` step outside Xcode, as in this repo's package script, must write the literal `GJJKL34HCT.` value into the entitlements plist. The expanded examples in the distribution-signing doc support this reading.
- The `group.`-style app-group route works in principle since February 2025 but is untested by Apple DTS, and it would also grant group-container and IPC semantics. Prefer `keychain-access-groups`. Team-prefixed `GJJKL34HCT.foo` app groups are unregistered and unauthorized, so they should not be relied on as keychain access groups.

### Gaps
- I found no Apple statement on exactly which `keychain-access-groups` values a Mac **Developer ID** profile allowlists (`GJJKL34HCT.*` wildcard or specific groups). TN3125's wildcard example is from an iOS development profile. After creating the profile, verify with `security cms -D -i … | plutil -extract Entitlements xml1 -o - -`.
- I found no first-hand Apple confirmation that a profile-authorized `group.` app group works as a keychain access group in a Developer ID Mac app on macOS 26.

## 2. Developer ID provisioning profiles: creating them, Xcode automatic signing, validity and expiry, and the certificate relationship

### Takeaway
Keychain Sharing and App Groups are both supported for Developer ID Mac profiles. Each needs an explicit App ID with the capability enabled and a Developer ID distribution profile. Developer ID profiles made after 2017-02-22 last 18 years. Gatekeeper checks them at every launch, and **an expired Developer ID profile stops the app from launching**. An expired Developer ID certificate does not stop an app that was signed while the certificate was valid.

### Cited Findings
- The macOS supported-capabilities table marks both "Keychain sharing" and "App groups" as available in all three columns (ADP, Developer ID, Apple Developer). "Hardened runtime" is also supported for Developer ID. — [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/). This comes from the page's HTML table; the check icons carry `alt="yes"`.
- "macOS supports provisioning profiles for both App Store and Developer ID distribution. Some entitlements are not supported by Developer ID profiles." — [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- "Developer ID and In-House (Enterprise) distribution profiles have the `ProvisionsAllDevices` property". Every profile has an `ExpirationDate`, "typically not more than a year. The exception here is Developer ID profiles, which have an expiration date far in the future." — [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- Expiry rules for apps with a Developer ID profile — [Developer ID certificates (Account Help)](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), which `https://developer.apple.com/support/developer-id/` redirects to:
  - The profile "is also evaluated, both at app installation time and at every app launch."
  - "Developer ID provisioning profiles generated after February 22, 2017, are valid for 18 years from the creation date, regardless of the expiration date of your Developer ID certificate."
  - "As long as your Developer ID certificate was valid when you compiled your app, then users can download and run your app, even after the expiration date of the certificate. However, if your Developer ID provisioning profile expires, the app will no longer launch."
  - "Any Developer ID app signed with a certificate that has been revoked can no longer be installed nor launch if it's already installed."
  - If Apple Developer Program membership lapses, existing Developer ID apps still run, but new certificates require membership.
- The same page covers certificate creation: up to five Developer ID Application certificates. "Required role: Account Holder" (cloud-managed certificates are also available to admins with that role). Path: Certificates → + → Software → Developer ID → Developer ID Application. — [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- **[secondary]** The 2017 incident: profiles created before 2017-02-22 were tied to the certificate's expiry, which broke launches of shipping apps (for example PDFpen 8.3.1 and 1Password) until new builds shipped. — [Michael Tsai blog](https://mjtsai.com/blog/2017/02/18/fixing-and-explaining-pdfpen-8-3-1s-crash-on-launch/); [Many Tricks blog](https://manytricks.com/blog/?p=4431)
- Xcode automatic signing registers the App ID and creates and embeds a profile when a profile-requiring capability is added. The daemon doc uses this to "force Xcode to register your App ID and generate an initial provisioning profile". The profile Xcode embeds during a normal build is a development profile: "Replace it with a distribution provisioning profile." — [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement); [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- For a Mac app bundle with nested code built in Xcode, Apple says to "use Xcode to export a distribution-signed app" (Organizer, or `xcodebuild -exportArchive`). For non-app products, copy them out of the archive and sign manually. Run `xcodebuild -help` for the export options keys. — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- For a manual profile: "Create the profile on the developer website… Make sure to choose a profile type that matches your distribution channel (Mac App Store or Developer ID)." — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- **[secondary, user report]** Portal flow: Profiles → + → Distribution → Developer ID → choose the App ID → choose the Developer ID Application certificate. — [Apple Developer Forums thread 700341](https://developer.apple.com/forums/thread/700341)
- **[secondary]** `xcodebuild -exportArchive` with `method` `developer-id` can fail with "No profiles for '<bundle id>' were found" when the profile or certificate pairing is wrong. Choosing the newest certificate per profile fixed it. — [Apple Developer Forums thread 688626](https://developer.apple.com/forums/thread/688626). `-allowProvisioningUpdates` lets xcodebuild create or fetch signing assets. — [TestDevLab blog](https://testdevlab.com/blog/xcode-provisioning-profile-automation-for-ci)

### Inferences
- Portal steps for the owner (an Account Holder or Admin):
  1. Make sure a Developer ID Application certificate exists. Only the Account Holder can create one. D-039 already has it.
  2. Under Identifiers, register an explicit App ID for `com.cacheplane.b4app` and enable **Keychain Sharing**. Add **App Groups** only if the `group.` route is chosen.
  3. Register a second explicit App ID for the helper's bundle, for example `com.cacheplane.b4app.coordinator`, with Keychain Sharing enabled.
  4. Under Profiles, create a Distribution → **Developer ID** profile for each App ID, select the Developer ID Application certificate, and download each `.provisionprofile`.
- Because a launch fails hard once the profile expires, store the profile's `ExpirationDate` (about 18 years out) in `docs/compatibility.md` and check it in CI.
- The 18-year profile validity is independent of the five-year certificate. Renewing the certificate means regenerating the profile with the new certificate, so the next build embeds a profile that lists it. That is an inference: a profile lists its certificates, per TN3125's five criteria.

### Gaps
- I found no Apple documentation confirming that Xcode 26 automatic signing creates and manages *Developer ID* distribution profiles during Organizer or `-exportArchive` with `method=developer-id` and `-allowProvisioningUpdates`. Developer reports suggest it does for app targets, but this research did not confirm it. Assume manual profiles for the SwiftPM-built helper in any case.
- The Account Help page specific to creating a Developer ID profile returned 404 at `/help/account/provisioning-profiles/create-a-developer-id-provisioning-profile/`. The help navigation lists only development, ad hoc, App Store Connect, and DriverKit profile pages. I found no current official step list.

## 3. Embedding: profile paths, minimum wrapper Info.plist, signing order, one App ID per bundle, and LaunchAgent paths

### Takeaway
macOS looks for the profile at `<Bundle>.app/Contents/embedded.provisionprofile`. A bare Mach-O cannot hold one, so the coordinator must become an app-like bundle with its own App ID and profile: Apple's example gives each restricted-entitlement bundle its own profile. Sign inside-out, nested wrapper first, then the outer app. launchd can point straight at `Wrapper.app/Contents/MacOS/<exe>`.

### Cited Findings
- "macOS expects to find the profile at `MyApp.app/Contents/embedded.provisionprofile`." "A standalone executable can't claim a restricted entitlement because there's no place to embed the provisioning profile… wrap it in an app-like structure." — [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- Placement table: "provisioning profile | macOS | `Contents/embedded.provisionprofile`". "help app, helper tool | macOS | `Contents/MacOS/`, `Contents/Helpers/`". Login items go in `Contents/Library/LoginItems/` and privileged helpers in `Contents/Library/LaunchServices/`. — [Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
- The wrapper recipe — [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement):
  - Build an Xcode macOS App target and set the bundle ID correctly, "because your provisioning profile is tied to your App ID".
  - Keep "Automatically manage signing", remove App Sandbox, and add Hardened Runtime "which you'll need to notarize".
  - Delete the app-specific Info.plist keys (`NSPrincipalClass`, `NSMainStoryboardFile`, `NSSupportsSuddenTermination`, `NSSupportsAutomaticTermination`, `CFBundleIconFile`) and supply a `main.swift`.
  - Resulting layout: `X.app/Contents/{Info.plist, MacOS/X, PkgInfo, _CodeSignature/CodeResources, embedded.provisionprofile}`.
  - The launchd plist's `Program` is `…/X.app/Contents/MacOS/X`.
  - "If you're using an alternative build system, like a makefile, update it to create a structure that matches the one created by Xcode."
- Its sample logs its own entitlements with `SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation` → `kSecCodeInfoEntitlementsDict` to confirm the setup. The development-signed output shows `com.apple.application-identifier`, `com.apple.developer.team-identifier`, and `com.apple.security.get-task-allow`. — [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
- Separate profiles per bundle: "the configuration app and its share extension use a keychain access group to share secrets… The app and the share extension each have their own profile." The profiles are copied to `ConfigApp.app/Contents/embedded.provisionprofile` and `ConfigApp.app/Contents/PlugIns/Share.appex/Contents/embedded.provisionprofile`. — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- "Sign code from the inside out. That is, if component `A` depends on component `B`, sign `B` before you sign `A`." Use `ditto` rather than `cp`. Don't apply entitlements to library code. For non-bundled code use `-i <BundleID>`. `codesign --deep` only signs nested code in expected locations. — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- `SMAppService.agent(plistName:)` (macOS 13+) requires the plist to be in the calling app's `Contents/Library/LaunchAgents` directory. — [agent(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:))

### Inferences
- Target layout:
  - `B4App.app/Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator`
  - `B4App.app/Contents/Helpers/B4AppCoordinator.app/Contents/Info.plist`
  - `B4App.app/Contents/Helpers/B4AppCoordinator.app/Contents/embedded.provisionprofile`
  - A nested app is a "help app", which the placement table allows in `Contents/Helpers/`.
- Minimum wrapper `Info.plist`, inferred from the Xcode-template-minus-app-keys recipe:
  - `CFBundleIdentifier` = `com.cacheplane.b4app.coordinator`, which must match its App ID.
  - `CFBundleExecutable` = `b4app-coordinator`.
  - `CFBundlePackageType` = `APPL`.
  - `CFBundleName`, `CFBundleShortVersionString`, `CFBundleVersion`, `CFBundleInfoDictionaryVersion`, `LSMinimumSystemVersion`.
  - `LSUIElement` = `true` (or `LSBackgroundOnly`), so the helper never shows a Dock icon if Launch Services opens it. Apple's daemon recipe does not mention `LSUIElement`; this is precaution, not requirement.
- Signing order:
  1. Wrapper executable and bundle, with the coordinator entitlements and `-o runtime --timestamp`.
  2. Any other nested code.
  3. The outer `B4App.app`, with app entitlements and without `--deep`.
  4. Then notarize and staple.
- The helper needs its own App ID and profile. A profile's `com.apple.application-identifier` must equal the signed code's, and each bundle embeds exactly one profile. The helper cannot reuse the app's profile unless it claimed the app's own App ID. TN3125 says "Most profiles apply to a single App ID", and Apple's example gives the appex its own profile. Sharing works through the common `keychain-access-groups` string, not a common profile.
- The LaunchAgent's `ProgramArguments[0]` (or `Program`) can point at `…/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator`. That is exactly what Apple's daemon example does. With `SMAppService`, the plist moves to `B4App.app/Contents/Library/LaunchAgents/` and `BundleProgram` gives the path relative to the outer app.

### Gaps
- I found no Apple page that lists the minimum Info.plist keys for a non-Xcode-built wrapper, or that says whether `LSUIElement` matters for a launchd-launched wrapper.
- I did not verify whether AMFI requires the wrapper's `CFBundleIdentifier` to equal the code-signing identifier, or only the entitlement App ID. Keep all three identical.

## 4. Notarization: are profile-authorized entitlements allowed, codesign specifics, verification, and AMFI behaviour when entitlements are not authorized

### Takeaway
Developer ID profiles exist precisely so that notarized Developer ID apps can use restricted entitlements such as Keychain Sharing. The signing is ordinary `codesign -s "Developer ID Application" -f --timestamp -o runtime --entitlements …` after the profile has been copied into the bundle. A process that claims an entitlement its profile does not authorize is killed by the trusted-execution system at launch (SIGKILL). The system log shows `amfid`, `taskgated-helper`, and AppleMobileFileIntegrity entries.

### Cited Findings
- Applications signed with Developer ID and notarized "can also take advantage of advanced capabilities such as CloudKit and push notifications" via a Developer ID provisioning profile. — [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- The Hardened Runtime is needed to notarize. The daemon recipe says to add it. — [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
- Codesign flags (`-s`, `-f`, `--entitlements`, `--timestamp` for Developer ID, `-o runtime` for a main executable, `-i` for non-bundled code) and the entitlements file format ("standard XML format with LF line endings, no comments, and no byte-order mark"). Usually drop `com.apple.security.get-task-allow` for distribution. — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac); **[DTS forum]** [thread 701514](https://developer.apple.com/forums/thread/701514)
- Verify claimed entitlements with `codesign -d --entitlements - --xml X.app | plutil -convert xml1 -o - -`. — [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- Decode a profile with `security cms -D -i Profile.provisionprofile -o payload.plist`. Read fields with `plutil -extract Entitlements.<key> raw -o - payload.plist` and `plutil -extract ExpirationDate raw …`. A profile ties together App ID, certificates, entitlements allowlist, devices, and expiry. — [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- **[DTS forum]** "Resolving Trusted Execution Problems" — [thread 706442](https://developer.apple.com/forums/thread/706442):
  - "The app's executable might claim restricted entitlements that aren't authorised by a provisioning profile." Such an app "will be killed by the trusted execution system". From Terminal this shows as `zsh: killed …`. The user sees "The application … can't be opened."
  - Diagnose with `syspolicy_check distribution MyApp.app`.
  - Stream the log: `log stream --predicate "sender == 'AppleMobileFileIntegrity' or sender == 'AppleSystemPolicy' or process == 'amfid' or process == 'taskgated-helper' or process == 'syspolicyd'"`. Search for `amfi`, `taskgated`, and `ProvisioningProfiles`.
  - Optionally run `sudo sysctl -w security.mac.amfi.verbose_logging=1`.
  - A code-signing kill on launch appears as `EXC_CRASH (SIGKILL (Code Signature Invalid))`. The post does not tie that exact report to unauthorized entitlements.
- Without a profile, or with a group the app isn't entitled to, `SecItemAdd` returns `errSecMissingEntitlement` (-34018). — [errSecMissingEntitlement](https://developer.apple.com/documentation/security/errsecmissingentitlement)

### Inferences
- These two failure modes differ:
  - **Over-claiming**: the signature claims `keychain-access-groups` and the profile is missing, or it doesn't authorize the group, or it is expired. The process is SIGKILLed at exec, so a LaunchAgent would crash-loop under `KeepAlive`.
  - **Under-claiming**: no `keychain-access-groups` entitlement at all. The process runs, and data-protection keychain calls fail with -34018.
  - Build CI checks for both.
- Checks to add to the release script:
  - `codesign -d --entitlements - --xml` on both the outer app and the wrapper.
  - `security cms -D -i Contents/embedded.provisionprofile` on both, confirming that the claimed `keychain-access-groups` and `com.apple.application-identifier` are covered by the profile's `Entitlements`.
  - Confirm `ExpirationDate` is far in the future.
  - `codesign --verify --strict --deep`.
  - `syspolicy_check distribution` after stapling.

### Gaps
- I found no Apple-published exact log strings for the unauthorized-entitlement case in macOS 26 (wording such as "Restricted entitlements not validated" or "no eligible provisioning profiles found" is unverified here). Capture them empirically.
- I found no statement that the notary service itself rejects unauthorized entitlements. The documented enforcement is at launch.

## 5. Migrating items from the file-based keychain to the data-protection keychain

### Takeaway
There is no move API. Apple's guidance is get-then-add: read the legacy item, without `kSecUseDataProtectionKeychain`, add it to the data-protection keychain in the shared group, then optionally delete the legacy copy. Reading a legacy item can raise the file-based keychain's ACL prompt when the reading code is not on the item's ACL, which can happen after the code identity changes.

### Cited Findings
- "Programs that read existing items in a file-based keychain must target the file-based keychain. If you find yourself in this situation, consider migrating items to the data protection keychain as you update your app." The SecItem API "defaults to targeting the file-based keychain". — [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- The file-based keychain uses ACLs (`SecAccess`). The data-protection keychain uses access groups plus optional `SecAccessControl`. — [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- Apple says it is "highly recommended that you set the value of this key to `true` for all keychain operations… Use it unless you specifically need access to items previously stored in a legacy keychain in macOS." `kSecUseDataProtectionKeychain` is available on macOS 10.15+. — [kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- **[DTS forum, via search summaries]** These threads were read only through search-result summaries:
  - There is no easy way to move items between implementations; fetch the item and add it to the new location.
  - Private keys are hard to move because they are often non-extractable, and extracting them can trigger an authorization alert.
  - A common confusion is switching code to the data-protection flag and not finding items created earlier in the file-based keychain.
  - [thread 733767](https://developer.apple.com/forums/thread/733767)
- **[DTS forum, via search summaries]** The proposed pattern is to check the data-protection keychain first, fall back to the file-based keychain, copy over, and optionally delete the original. Quinn confirms that data-protection queries don't see file-based items, and that you should use the data-protection keychain if you can. — [thread 697317](https://developer.apple.com/forums/thread/697317); also [thread 765467](https://developer.apple.com/forums/thread/765467)
- macOS 26.4 and later: "A keychain file might reference a protected entropy file" in `/var/db/SystemKeys`. This is a backup concern for the file-based keychain, added to TN3137 on 2026-09-24. — [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

### Inferences
- Migration in the coordinator, which is the process that owns secrets:
  1. Query the data-protection keychain in `GJJKL34HCT.com.cacheplane.b4app.shared`.
  2. On `errSecItemNotFound`, query the file-based keychain for the same service and account.
  3. On a hit, `SecItemAdd` to the data-protection keychain with `kSecAttrAccessGroup` and an accessibility class such as `kSecAttrAccessibleAfterFirstUnlock`, so the helper can read at login without UI.
  4. Delete the legacy item only after the add succeeds.
  5. Make it idempotent and run it once per item.
- Prompts are likely if the legacy items were created by a differently signed binary, for example a pre-wrapper bare Mach-O signed with a different identifier, because the file-based ACL trusts specific code. In that case the user sees a "wants to use your confidential information" prompt once per item, and "Always Allow" is optional since the item is deleted afterwards. This is an inference from the ACL model, not Apple text.

### Gaps
- I found no Apple doc page dedicated to file-based-to-data-protection migration. Guidance is from DTS forum posts, and I read those via search summaries only.

## 6. Keeping a non-profile path (unsigned `swift build`, tests) on the file-based keychain, and runtime detection

### Takeaway
`SecTaskCopyValueForEntitlement` is public on macOS and can read the process's own `keychain-access-groups` entitlement at runtime. Use it to decide between data-protection and file-based storage. Apple documents the API but gives no recommendation for or against this pattern. An explicit build-time or config switch, with a -34018 fallback, is the more predictable design.

### Cited Findings
- `SecTaskCopyValueForEntitlement(_:_:_:)` "Returns the value of a single entitlement for the represented task". It is available on macOS and Mac Catalyst. "An empty return value may indicate an error, or it may indicate that the entitlement is simply not present." — [SecTaskCopyValueForEntitlement](https://developer.apple.com/documentation/security/sectaskcopyvalueforentitlement(_:_:_:))
- An alternative self-inspection is Apple's own sample: `SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation`, then read `kSecCodeInfoEntitlementsDict`. — [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
- Without the entitlement, a data-protection `SecItemAdd` naming the group returns `errSecMissingEntitlement` (-34018). — [errSecMissingEntitlement](https://developer.apple.com/documentation/security/errsecmissingentitlement)
- The data-protection keychain is unavailable outside a user login context, for example in a launchd daemon. "This command-line tool will only work when run from a user context because, regardless of the packaging, the data protection keychain is only available in that context." — [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- Library code inherits the host process's entitlements. — [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

### Inferences
- An unsigned or ad-hoc `swift build` binary, and the `swift test` runner (`xctest`), have no `keychain-access-groups`. They can never use the data-protection keychain on macOS, so the file-based path, or an in-memory or test secret store, must remain for them.
- Suggested selection order in `WorkspaceSecrets`:
  1. Use an explicit override (environment or config) if one is set.
  2. Otherwise, if `SecTaskCreateFromSelf` plus `SecTaskCopyValueForEntitlement(task, "keychain-access-groups")` returns an array containing the expected group, use the data-protection keychain with that group.
  3. Otherwise use the file-based keychain.
  4. Log which backend was chosen, without secrets.
  - Treat -34018 from a data-protection call as a configuration error, not a reason to silently fall back. A silent fallback would fork secrets between two stores.
- The LaunchAgent runs in the Aqua session, which is a user login context, so it qualifies. An SSH session or a LaunchDaemon would not.
- Because the app and the coordinator would both claim the same group, the CLI (`agent-workspace`) should go through the coordinator for secrets rather than touching the keychain directly. A bare CLI binary cannot reach the data-protection keychain.

### Gaps
- I found no Apple statement recommending or discouraging entitlement self-inspection to choose a keychain backend.
- I did not confirm whether `SecTaskCopyValueForEntitlement` is fully reliable for the calling process under the Hardened Runtime on macOS 26. It is documented and has been public on macOS for a long time, but test it in the packaged build.
