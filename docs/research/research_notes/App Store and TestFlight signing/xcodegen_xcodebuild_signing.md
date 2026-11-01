# Signing, provisioning and distribution for a two-target (macOS + iOS) XcodeGen project driven by xcodebuild (late 2026, Xcode 26.6, XcodeGen 2.46.0)

Local tool versions checked on this machine on 2026-11-01: `xcodebuild -version` reports Xcode 26.6 (17F113), and `xcodegen --version` reports 2.46.0. Quotes attributed to "`xcodebuild -help` (Xcode 26.6)" come from running that command locally. No public URL serves this exact text, so the closest public equivalent is Apple's pointer: "run `xcodebuild` with the `-help` argument" ([Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)).

Repo facts relevant to this research:
- `project.yml` base settings are `CODE_SIGN_STYLE: Automatic`, `CODE_SIGN_IDENTITY: "-"` and `DEVELOPMENT_TEAM: ""`.
- `B4App-macOS` has `entitlements.path: Apps/macOS/B4App/B4App.entitlements` (an empty dict), `ENABLE_APP_SANDBOX: NO` and `ENABLE_HARDENED_RUNTIME: NO`.
- `B4App-iOS` currently declares no `entitlements:` block.
- `Scripts/package.sh` runs `xcodebuild build ... CODE_SIGN_IDENTITY=-`. It then copies `b4app-coordinator` and `agent-workspace` into `Contents/Helpers/` and the PostgreSQL tree into `Contents/SharedSupport/postgres`. It signs each Mach-O, then the helpers, then the app with `--options runtime --timestamp`, and verifies with `codesign --verify --deep --strict`.
- CI (`.github/workflows/ci.yml` lines 64 and 68) passes `CODE_SIGNING_ALLOWED=NO` to both `xcodebuild build` calls.

## Q1. XcodeGen: per-target and per-config signing, entitlements, hardened runtime and sandbox, environment variables, xcconfig injection, helper profiles

### Takeaway
XcodeGen expands `${VAR}` from the environment at generation time. An unset variable is not blanked: the literal `${VAR}` text is left in place. That makes `DEVELOPMENT_TEAM: ${B4APP_TEAM_ID}` workable, but it is subtle.

The more robust pattern is a committed `Signing.xcconfig` attached through `configFiles`. That file does `#include? "Signing.local.xcconfig"`, and the local file is gitignored and carries `DEVELOPMENT_TEAM`. In that case `DEVELOPMENT_TEAM` must be removed from `settings.base` in `project.yml`, because target and project settings in the pbxproj override an xcconfig.

Per-target and per-config signing goes under `targets.<name>.settings.configs.<Debug|Release>`. Entitlements can be a path, or a path plus `properties`, in which case XcodeGen writes the file.

### Cited Findings

**Environment variables**
- The spec says: "You can also use environment variables in your configuration file, by using `${SOME_VARIABLE}` in a string." — [XcodeGen ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- `include` entries accept `enable: ${INCLUDE_ADDITIONAL_YAML}`, which "Dictates whether the specified spec should be included or not. You can also specify it by environment variable." — [XcodeGen ProjectSpec.md#include](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#include)
- Includes are merged additively: dictionaries merge, arrays append, "otherwise replace the existing value with the new value". — [XcodeGen ProjectSpec.md#include](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#include)
- In the source (`SpecFile.swift`, `expand(variables:in:)`), when a `${name}` has no value in the variables map, the code comments "Skip this whole variable for which we don't have a value" and leaves the text unchanged. Expansion applies to both dictionary keys and values, and recurses into arrays and dictionaries. — [XcodeGen Sources/ProjectSpec/SpecFile.swift](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/ProjectSpec/SpecFile.swift)

**Settings structure and config matching**
- `settings` takes `groups`, `base` and `configs`. They are "merged in the following order: `groups`, `base`, `configs`". The spec also says "Don't mix simple maps with `groups`, `base` and `configs`." — [XcodeGen ProjectSpec.md#settings](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#settings)
- Config keys match partially and case-insensitively: "Each key will be matched to any configs that contain the key and is case insensitive". The exception is "if a config name is an exact match to a config it won't be applied to any others." — [XcodeGen ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- The Settings examples in the spec use `CODE_SIGN_IDENTITY`, `PROVISIONING_PROFILE_SPECIFIER` and `CODE_SIGNING_ALLOWED` as ordinary build settings. XcodeGen has no dedicated signing schema beyond build settings and target attributes. — [XcodeGen ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- Target `attributes` are set automatically:
  - "`DevelopmentTeam`: if all configurations have the same `DEVELOPMENT_TEAM` setting"
  - "`ProvisioningStyle`: if all configurations have the same `CODE_SIGN_STYLE` setting"

  — [XcodeGen ProjectSpec.md#target](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#target)

**Entitlements**
- Target `entitlements` is a Plist. "If defined this will generate and write a `.entitlements` file, and use it by setting `CODE_SIGN_ENTITLEMENTS` build setting for every configuration. All properties must be provided". — [XcodeGen ProjectSpec.md#target](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#target)
- A Plist has `path` (required) and `properties`, "a map of all the plist keys and values". The spec's example is `entitlements: {path: App/App.entitlements, properties: {com.apple.security.application-groups: group.com.app}}`. "Plists are created on disk on every generation of the project." — [XcodeGen ProjectSpec.md#plist](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#plist)

**xcconfig files**
- `configFiles` exists at project level and at target level: "`.xcconfig` files per config", e.g. `configFiles: {Debug: debug.xcconfig, Release: release.xcconfig}`. — [XcodeGen ProjectSpec.md#config-files](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#config-files)
- `options.disabledValidations: [missingConfigFiles]` will "Disable checking for the existence of configuration files", which is useful when config files are not available at generation time. — [XcodeGen ProjectSpec.md#options](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#options)
- Apple on missing includes: "If Xcode can't find an included build configuration file, it generates build warnings. To suppress these warnings, add a question mark (?) to the `#include` command", e.g. `#include? "MyOtherConfigFile.xcconfig"`. Includes resolve relative to the including file's directory. — [Apple: Adding a build configuration file to your project](https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project)
- Apple documents conditional settings in xcconfig files, e.g. `OTHER_LDFLAGS[sdk=macos*][arch=x86_64] = -lncurses`, and the `$(inherited)` keyword. — [Apple: Adding a build configuration file to your project](https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project)
- Community pitfall: a `DEVELOPMENT_TEAM` value that remains in `project.pbxproj` overrides the team set through the xcconfig and its optional include, so it has to be removed from the project file. — [Cog Shared.xcconfig](https://forge.losno.co/chris/Cog/src/branch/main/Xcode-config/Shared.xcconfig) (community source)
- `man xcodebuild` (Xcode 26.6) documents the `XCODE_XCCONFIG_FILE` environment variable: "build settings in that file will be loaded and used when building all targets. These settings will override all other settings, including settings passed individually on the command line, and those in the file passed with the -xcconfig option." The command line also accepts `-xcconfig <path>`. — local `man xcodebuild`; Apple's xcodebuild man page is referenced from [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

**Where helper code belongs, and helper profiles**
- Bundle placement table:
  - "help app, helper tool | macOS | `Contents/MacOS/`, `Contents/Helpers/`"
  - "framework, dynamic library | macOS | `Contents/Frameworks/`"

  — [Apple: Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
- Provisioning profiles go in a bundle's `Contents/embedded.provisionprofile`. Apple's example copies `ConfigApp-Dist.provisionprofile` to `ConfigApp.app/Contents/embedded.provisionprofile`. A nonbundled executable that needs a restricted entitlement should be packaged "in an app-like structure". — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- Unrestricted entitlements, which need no profile, include `get-task-allow`, `application-groups`, and the App Sandbox and Hardened Runtime keys. Restricted entitlements need a provisioning profile. — [Apple DTS (Quinn) forum post on distribution signing](https://developer.apple.com/forums/thread/701514), which Apple now points to the official [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

### Inferences

**Recommended YAML.** This keeps the team out of git and keeps CI and forks working. It assumes Xcode-managed signing for Release on both platforms, so archive and export become possible.

```yaml
# project.yml (excerpt)
options:
  disabledValidations: [missingConfigFiles]   # only needed if Signing.xcconfig itself is not committed
configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig
settings:
  base:
    CODE_SIGN_STYLE: Automatic
    # Remove DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY here: values in the pbxproj beat the xcconfig.
targets:
  B4App-macOS:
    entitlements:
      path: Apps/macOS/B4App/B4App.entitlements
      properties: {}            # unsandboxed Developer ID app; hardened runtime is a build setting
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.cacheplane.b4app
        ENABLE_APP_SANDBOX: NO
      configs:
        Debug:
          CODE_SIGN_IDENTITY: "-"            # ad hoc locally, no team needed
          ENABLE_HARDENED_RUNTIME: NO
        Release:
          CODE_SIGN_IDENTITY: "Apple Development"   # export re-signs as Developer ID
          ENABLE_HARDENED_RUNTIME: YES
  B4App-iOS:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.cacheplane.b4app.ios
        "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "Apple Development"
```

```
// Config/Signing.xcconfig (committed)
// Team id comes from a gitignored file or from the command line; empty means "unsigned / ad hoc".
DEVELOPMENT_TEAM =
#include? "Signing.local.xcconfig"
```

```
// Config/Signing.local.xcconfig (gitignored), written once by the owner or by a script
DEVELOPMENT_TEAM = GJJKL34HCT
```

**Alternatives for supplying the team id.**
- Leave the xcconfig team empty and pass `DEVELOPMENT_TEAM="$B4APP_TEAM_ID"` on every `xcodebuild` command line. Command-line settings override project and xcconfig values. This is the least magic option and suits `package.sh`.
- Use `DEVELOPMENT_TEAM: ${B4APP_TEAM_ID}` directly in project.yml. Because XcodeGen leaves an unset variable as the literal `${B4APP_TEAM_ID}`, the pbxproj then contains a build-setting reference. Xcode expands `${...}` and `$(...)` references in build settings, so an undefined name likely resolves to empty. This is an inference about Xcode behavior that I did not verify against Apple docs. Since the project is regenerated, a value is baked in at generation time, which is fine for a gitignored project. The catch: a project generated without the variable and then built later still has the reference, not a team.
- `XCODE_XCCONFIG_FILE` overrides everything, including the command line. That makes it a blunt tool, best suited to CI injection rather than per-developer setup.

**Signing the helpers.** XcodeGen cannot sign the post-build `Contents/Helpers` binaries or the PostgreSQL Mach-Os, because they are added by `package.sh` after the Xcode build. Neither helper uses a restricted entitlement: the macOS entitlements file is empty, and the helpers are plain CLI tools. So no provisioning profile is needed for them, and the "embed a profile for a non-Xcode helper" question only arises if a helper ever needs a restricted entitlement such as keychain-access-groups for a shared Keychain item. In that case Apple's answer is to wrap it in an app-like bundle containing `Contents/embedded.provisionprofile`.

**Placement of the PostgreSQL tree.** `Contents/SharedSupport` is not a location for code in Apple's placement table. `package.sh` signs every Mach-O there explicitly, and Apple warns that `--deep` will not find code placed where data is expected. Notarization and Gatekeeper may tolerate this, but it deviates from the documented layout.
- "Embedding nonstandard code structures in a bundle" covers symlinking code from `Contents/Frameworks` or `Contents/Helpers` into a data tree. The repo's D-041 note says "Helpers accepts only nested code and this tree carries SQL and share files".
- The documented layout would put the PostgreSQL binaries and dylibs in `Contents/Helpers`/`Contents/Frameworks` and symlink them from `SharedSupport/postgres`.

### Gaps
- I did not find an XcodeGen issue or doc saying whether a project-level `configFiles` xcconfig is applied at the project level or the target level for settings precedence. The general Xcode rule is that target pbxproj settings override target xcconfig, which overrides project pbxproj, which overrides project xcconfig. Apple's "Adding a build configuration file" page did not state this ordering explicitly in the text I retrieved.
- `ENABLE_APP_SANDBOX` and `ENABLE_HARDENED_RUNTIME` are real Xcode build settings and the repo uses them. I did not retrieve an Apple build-settings reference page confirming their exact semantics in Xcode 26. One unconfirmed belief: Xcode 15+ derives the sandbox and hardened-runtime entitlements from these settings rather than from the entitlements file.
- I did not verify whether xcodebuild exposes arbitrary process environment variables as build settings. That determines whether an unexpanded `${B4APP_TEAM_ID}` in the pbxproj would pick up an env var at build time.

## Q2. xcodebuild archive and exportArchive: ExportOptions keys, method names, -allowProvisioningUpdates with API keys, automatic registration, certificate choice

### Takeaway
In Xcode 26.6 the valid `method` values are `app-store-connect`, `release-testing`, `enterprise`, `debugging`, `developer-id`, `mac-application` and `validation`. The old names `app-store`, `ad-hoc` and `development` are deprecated aliases.

`destination` is `export` (the default) or `upload`. `-allowProvisioningUpdates` with `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` lets automatic signing create profiles, App IDs and certificates headlessly. Device registration additionally needs `-allowProvisioningDeviceRegistration`.

There is a known bug: cloud-managed Developer ID signing does not work with an API key. So the Mac Developer ID export still needs the Developer ID Application certificate in the local keychain, which `package.sh` already relies on. iOS TestFlight upload via cloud-managed Apple Distribution with an Admin API key does work.

### Cited Findings

**ExportOptions keys** (all quoted from `xcodebuild -help`, Xcode 26.6, local)
- `method`: "Available options: app-store-connect, release-testing, enterprise, debugging, developer-id, mac-application, and validation. ... Defaults to debugging. Additional options include app-store (deprecated: use app-store-connect), ad-hoc (deprecated: use release-testing), and development (deprecated: use debugging)."
- `destination`: "Determines whether the app is exported locally or uploaded to Apple. Options are export or upload. ... Defaults to export."
- `signingStyle`: "manual or automatic. Apps that were automatically signed when archived default to automatic." It continues: "If your archive is manually signed and you choose to automatically sign when distributing, then Xcode will create provisioning profiles and managed cloud signing certificates as necessary, but will not register devices, register app IDs, or modify app ID settings."
- `teamID`: "Defaults to the team used to build the archive."
- `signingCertificate`: "For manual signing only." It accepts the automatic selectors "Apple Development", "Apple Distribution", "Developer ID Application", "iOS Developer", "iOS Distribution", "Mac App Distribution", and "Mac Developer".
- `provisioningProfiles`: "For manual signing only." Keys are "bundle identifiers of executables or their paths relative to the Archive's Products directory"; values are the "provisioning profile name or UUID".
- `installerSigningCertificate`: for manual signing; the selectors are "Developer ID Installer" and "Mac Installer Distribution".
- `manageAppVersionAndBuildNumber`: "Should Xcode manage the app's build number when uploading to App Store Connect? Defaults to YES."
- `testFlightInternalTestingOnly`: "When enabled, this build cannot be distributed via external TestFlight or the App Store."
- Other keys: `uploadSymbols` (defaults to YES), `stripSwiftSymbols`, `iCloudContainerEnvironment` (Development/Production), and `distributionBundleIdentifier`.
- Third-party corroboration of the rename: the deprecated names are mapped to their replacements and marked "deprecated since 15.3". — [bitrise go-xcode exportoptions](https://pkg.go.dev/github.com/bitrise-io/go-xcode/exportoptions) (third party); the Xcode 15.3 release notes I retrieved did not mention it ([Xcode 15.3 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-15_3-release-notes))

**Command-line flags** (quoted from `xcodebuild -help`, Xcode 26.6, local)
- `-allowProvisioningUpdates`: "For automatically signed targets, xcodebuild will create and update profiles, app IDs, and certificates. For manually signed targets, xcodebuild will download missing or updated provisioning profiles. Requires a developer account to have been added in Xcode's Accounts settings or an App Store Connect authentication key to be specified via the -authenticationKeyPath, -authenticationKeyID, and -authenticationKeyIssuerID parameters."
- `-allowProvisioningDeviceRegistration`: "Allow xcodebuild to register your destination device on the developer portal if necessary. This flag only takes effect if -allowProvisioningUpdates is also passed."
- Usage forms: `xcodebuild -exportArchive -archivePath <xcarchivepath> [-exportPath <destinationpath>] -exportOptionsPlist <plistpath>`, and `xcodebuild -exportNotarizedApp -archivePath <xcarchivepath> -exportPath <destinationpath>`.

**Apple's distribution guidance**
- Apple's recommended Mac flow: "1. Run `xcodebuild` with the `archive` action ... 2. Run `xcodebuild` with the `exportArchive` action to export the distribution-signed app from the archive". — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- "Xcode uses cloud-managed signing certificates to automatically code sign your app," and access to them is managed in App Store Connect. — [Apple: Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- The Organizer's preset distribution options are "TestFlight & App Store", "TestFlight Internal Only", "Release Testing" (which "isn't available for apps built for Mac"), "Direct Distribution" (to "notarize a Developer ID app for direct distribution", Mac only), and "Debugging". The custom methods are App Store Connect, Developer ID, and others. App Store Connect and Developer ID offer Upload or Export. — [Apple: Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

**Developer ID cloud signing with an API key**
- Apple DTS, accepted answer, March 2025: "Your issue is a known bug. You can't cloud sign with a Developer ID cert when authenticating with an App Store Connect API key." Also: "If you have a Developer ID certificate installed in Keychain, Xcode selects it to upload instead of accessing the cloud managed Developer ID certificate." The original poster saw a 403 "You haven't been given access to cloud-managed distribution certificates" even with an Admin key, on Xcode 16.2 (FB16835802). The same poster reports that cloud signing via API key works for iOS ("Apple Distribution (Managed)"). — [Apple Developer Forums 776036](https://developer.apple.com/forums/thread/776036)
- Cloud-managed distribution signing via xcodebuild has historically required an Admin-role API key; a non-Admin key yields "Cloud signing permission error". — [Apple Developer Forums 698117](https://developer.apple.com/forums/thread/698117); [Bitrise docs](https://docs.bitrise.io/en/bitrise-platform/integrations/apple-services-connection/about-connecting-to-apple-services) (third party)

### Inferences

**Example ExportOptions plists.**

```xml
<!-- Config/ExportOptions-DeveloperID.plist (macOS). Team comes from the archive (teamID defaults to it). -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
```

```xml
<!-- Config/ExportOptions-AppStore.plist (iOS TestFlight upload) -->
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><true/>
  <key>testFlightInternalTestingOnly</key><true/>   <!-- personal tool: internal testers only -->
  <key>uploadSymbols</key><true/>
</dict></plist>
```

`teamID` can be omitted, since it defaults to the archive's team, so the team id never needs to be in the plist. If it must be explicit, generate the plist in the script with `plutil -replace teamID -string "$B4APP_TEAM_ID" plist`.

**Commands (iOS TestFlight).** The API key `.p8` path and ids come from env vars that point at files outside the repo. Per the repo rules, the key itself must never appear in arguments or logs, so only the path is passed.

```sh
xcodebuild archive -project B4App.xcodeproj -scheme B4App-iOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/B4App-iOS.xcarchive \
  DEVELOPMENT_TEAM="$B4APP_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
xcodebuild -exportArchive -archivePath build/B4App-iOS.xcarchive \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist -exportPath build/export-ios \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
```

**Commands (macOS Developer ID).** `-exportNotarizedApp` later retrieves the notarized result, after notarization through the Organizer or `notarytool`.

```sh
xcodebuild archive -project B4App.xcodeproj -scheme B4App-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/B4App-macOS.xcarchive \
  DEVELOPMENT_TEAM="$B4APP_TEAM_ID" -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/B4App-macOS.xcarchive \
  -exportOptionsPlist Config/ExportOptions-DeveloperID.plist -exportPath build/export-mac \
  -allowProvisioningUpdates
```

**What automatic provisioning can do from the CLI.**
- With `-allowProvisioningUpdates` and an automatically signed target, xcodebuild can register the App ID (e.g. `com.cacheplane.b4app.ios`), create development and distribution profiles, and create certificates.
- It registers devices only with `-allowProvisioningDeviceRegistration`, and only for a connected or destination device.
- An archive that was manually signed and is then exported with `signingStyle=automatic` will not get App IDs or devices registered.
- For the Mac app, development builds need neither a profile nor a device registration as long as no restricted entitlements are used. Developer ID builds without restricted entitlements need no provisioning profile at all.

**How the certificate is chosen.**
- With `signingStyle=automatic`, Xcode prefers a matching certificate in the local keychain, as the DTS reply describes.
- When no local certificate is found and the account or key has access, Xcode falls back to the cloud-managed "Apple Distribution" (iOS) or "Developer ID Application" (Mac) certificate.
- For Developer ID, the API-key path is broken by the known bug. Developer ID cloud signing therefore needs an Apple ID signed into Xcode → Settings → Accounts with cloud-managed Developer ID access, or a local certificate.

### Gaps
- I could not confirm whether FB16835802, the Developer ID cloud signing via API key bug, is fixed in Xcode 26.x. The DTS reply is from March 2025 and names no fix version, and I found no 26.x release note mentioning it.
- I did not find Apple documentation listing which ExportOptions `method` values are valid for a macOS archive versus an iOS archive. The help text only says "The list of options varies based on the type of archive."
- I did not retrieve the exact App Store Connect role requirements from Apple's own documentation for creating cloud-managed certificates with API keys (Admin vs App Manager). The evidence is from forum threads and third-party CI vendor docs.

## Q3. Should macOS packaging switch from "build ad hoc, then re-sign everything" to "archive + exportArchive developer-id"?

### Takeaway
Apple's documentation says to use Xcode export for "a Mac app bundle, possibly containing nested code ... that you build using Xcode". It says to use manual signing for code built outside Xcode.

The b4app bundle adds SwiftPM-built helpers and prebuilt PostgreSQL Mach-Os after the Xcode build. Whatever is copied in after export has to be signed manually and the app re-sealed anyway. Export alone therefore cannot replace the manual signing pass, unless those binaries become part of the Xcode build itself, as Copy Files phases or targets inside the archive.

Recommendation: keep the current manual, inside-out `codesign` pipeline for macOS. It matches Apple's "Sign each code item" procedure. Tighten it in three places:
- Pass `-i com.cacheplane.b4app.<tool>` for the nonbundled helpers.
- Use `ditto` instead of `cp -R`.
- Consider moving the PostgreSQL Mach-Os to documented code locations.

Use archive and export for iOS, where nothing is added after the build.

### Cited Findings
- Apple's decision rule:
  - "If your product is a Mac app bundle, possibly containing nested code such as an app extension, that you build using Xcode, use Xcode to export a distribution-signed app."
  - "If your product isn't an app, but you build it using Xcode, create an Xcode archive, and then manually export distribution-signed code from that archive."
  - "If you build your product using an external build system, such as `make`, add a manual signing step to your build system."

  — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- Modifying an exported app "breaks the seal on its code signature. You re-sign the app before you distribute it." Apple also warns that Xcode may embed a development provisioning profile, which must be replaced with a distribution one. — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- Signing options, per Apple:
  - "If you're re-signing code ... add the `-f` option".
  - "If you're signing for Developer ID distribution, add the `--timestamp` option".
  - "If you're signing a main executable for Developer ID distribution, add the `-o runtime` option".
  - "If you're signing nonbundled code, add the `-i <BundleID>` option", e.g. `com.example.flying-animals.pig-jato`.
  - "Repeat this signing step for every code item ... If you have a complex product with many code items to sign, create a script to automate this process."

  — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- Signing order: "Sign code from the inside out. That is, if A depends on B, sign B before you sign A." — [Apple DTS forum post 701514](https://developer.apple.com/forums/thread/701514)
- On entitlements: "Entitlements only make sense on a main executable" and "Do not apply entitlements to library code." — [Apple DTS forum post 701514](https://developer.apple.com/forums/thread/701514)
- On `--deep`: "Don't pass the `--deep` option to `codesign` when you sign code. This option is helpful in some specific circumstances (for example, in verifying a code signature)". It applies the same options to every item, and "If you put code in a place where `codesign` expects to find data, `codesign --deep` doesn't sign it." — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac); [Quinn, "--deep Considered Harmful"](https://developer.apple.com/forums/thread/129980)
- Quinn's alternative to `--deep`: "sign each code item separately, from the inside out. If your product has lots of nested code, automate this using a script." — [Apple Developer Forums 129980](https://developer.apple.com/forums/thread/129980)
- Copying code: "use `ditto` rather than `cp` because `ditto` preserves symlinks, which are critical to the structure of Mac frameworks." — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- Packaging:
  - "If you can't build and distribute your product using Xcode alone, choose a container format and package your product for distribution ... sign your code for distribution and create a distribution container file, then notarize the container file."
  - For zip files: `ditto -c -k --keepParent <PathToDirectory> <PathToZip>`, and "You can't sign zip archives, but you can sign their contents."
  - For nested containers: "only notarize the outermost container."

  — [Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- Identity naming: "Developer ID Application: <Team ID>". When several identities share a name, sign with the SHA-1 hash from `security find-identity -p codesigning -v`. Don't run `codesign` under `sudo`. — [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

### Inferences
- `package.sh` already follows Apple's manual procedure: inside out, no `--deep` for signing, `--deep` only for verification, `--options runtime --timestamp`, and entitlements only on the app. Switching to archive and export would mean either:
  - (a) exporting, then copying the helpers and PostgreSQL in, and re-signing the app manually, which buys little; or
  - (b) moving the helpers and PostgreSQL into the Xcode build as Copy Files phases with "Code Sign On Copy". XcodeGen supports `copyFiles` build phases on sources and dependencies with `codeSign`. Export would then re-sign them with the app's options, but per-item options such as a distinct `-i` are harder to control.
  
  Either way, Developer ID export via an API key is broken (Q2), so export gives no CI advantage. The marginal benefit of archive and export for the Mac is an `.xcarchive` with dSYMs.
- Concrete tightening for `package.sh`, inferred from the Apple guidance above:
  1. `codesign -f -s "$IDENTITY" --timestamp -o runtime -i com.cacheplane.b4app.coordinator "$APP/Contents/Helpers/b4app-coordinator"`, and likewise `-i com.cacheplane.b4app.agent-workspace`. Without `-i`, a nonbundled tool's identifier defaults to its file name, which weakens its designated requirement.
  2. Replace `cp -R` with `ditto` when assembling the bundle, to preserve the symlinks in the PostgreSQL tree.
  3. dylibs need `--timestamp` but not `-o runtime`, since `-o runtime` matters for main executables. Passing it on dylibs is harmless.
  4. Make sure no Xcode-embedded `embedded.provisionprofile` is left in the app. With `CODE_SIGN_IDENTITY=-` none is embedded today.
- The resulting signing sequence:

  ```sh
  ID="Developer ID Application"   # or the SHA-1 from security find-identity -v -p codesigning
  find "$APP/Contents/SharedSupport/postgres" -type f -print0 | while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O && codesign -f -s "$ID" --timestamp -o runtime "$f"
  done
  for t in b4app-coordinator agent-workspace; do
    codesign -f -s "$ID" --timestamp -o runtime -i "com.cacheplane.b4app.$t" "$APP/Contents/Helpers/$t"
  done
  codesign -f -s "$ID" --timestamp -o runtime --entitlements Apps/macOS/B4App/B4App.entitlements "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "${B4APP_NOTARY_PROFILE:-b4app}" --wait
  xcrun stapler staple "$APP"
  ```

### Gaps
- I did not find Apple documentation that says explicitly whether `Contents/SharedSupport` is acceptable for signed Mach-Os. The placement table lists only `MacOS`, `Helpers` and `Frameworks` for code. I did not retrieve the body of "Embedding nonstandard code structures in a bundle" in full, which covers the symlink approach.
- No 2026-dated DTS post was found that changes the 2022–2025 guidance.

## Q4. Building in CI without secrets

### Takeaway
`CODE_SIGNING_ALLOWED=NO` (already used in CI) skips signing entirely, so a missing `DEVELOPMENT_TEAM` and missing profiles do not matter for `xcodebuild build`.

The risk comes from making `DEVELOPMENT_TEAM` mandatory in a committed file, or from using entitlements that force a profile during `archive`. The `#include?` xcconfig pattern, or command-line `DEVELOPMENT_TEAM=`, keeps forks and CI building with an empty team. The Mac Debug configuration can stay ad hoc (`CODE_SIGN_IDENTITY=-`), which needs no team.

### Cited Findings
- `#include?` suppresses the missing-file warning, so a gitignored `Signing.local.xcconfig` that is absent in CI costs nothing. — [Apple: Adding a build configuration file to your project](https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project)
- XcodeGen can skip validation of missing config files with `disabledValidations: [missingConfigFiles]`, for the case where the referenced xcconfig itself is gitignored. — [XcodeGen ProjectSpec.md#options](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#options)
- An unset `${VAR}` stays literal in XcodeGen output rather than failing generation. — [XcodeGen SpecFile.swift](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/ProjectSpec/SpecFile.swift)
- The CI workflow in this repo already passes `CODE_SIGNING_ALLOWED=NO` to both app builds (`.github/workflows/ci.yml` lines 64 and 68; local repo).
- `-allowProvisioningUpdates` "Requires a developer account to have been added in Xcode's Accounts settings or an App Store Connect authentication key". CI without secrets must therefore never pass it. — `xcodebuild -help`, Xcode 26.6 (local)

### Inferences
- Keep CI exactly as it is: `xcodebuild build ... CODE_SIGNING_ALLOWED=NO`. That holds even if iOS later gains capability entitlements such as `aps-environment`, App Groups or `keychain-access-groups`. With signing disallowed, Xcode does not process entitlements into a signature, and it does not require a profile or team. This is inferred from how `CODE_SIGNING_ALLOWED` works and from the current CI passing with an entitlements file present on the Mac target. I did not find an Apple doc that states it outright.
- For a future release job that has secrets, gate it on the presence of the secrets, e.g. `if: ${{ secrets.ASC_KEY_ID != '' }}`. Write the `.p8` file to `$RUNNER_TEMP` and pass only its path, consistent with the repo rule that secrets never appear in arguments or logs. Also write `Signing.local.xcconfig` from a secret. Forks get none of these, and the job is skipped.
- Do not commit `DEVELOPMENT_TEAM = GJJKL34HCT`. Do not use non-optional `#include`, and do not put `PROVISIONING_PROFILE_SPECIFIER` in base settings. Any of these would make unsigned fork builds noisier or broken once signing is allowed.
- iOS Simulator builds (`-destination 'generic/platform=iOS Simulator'`) sign ad hoc and never need a team, even without `CODE_SIGNING_ALLOWED=NO`. That gives a second safety net for CI. This is inferred, not sourced.

### Gaps
- I found no Apple primary-source statement describing `CODE_SIGNING_ALLOWED=NO` semantics: that it skips the entitlements processing and profile checks. The Xcode build settings reference page was not retrieved.
- I did not verify whether `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO` produces an exportable archive. It almost certainly does not for distribution, and CI should not try.
