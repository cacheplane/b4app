# Shipping a non-sandboxed developer-tool Mac app through TestFlight for Mac or the Mac App Store (late 2026)

Context: b4app (com.cacheplane.b4app, team GJJKL34HCT) is signed with Developer ID, notarized, uses the hardened runtime, and is not sandboxed. It spawns user-installed `codex`, `claude` and `node` from PATH, ~/.nvm, Homebrew and ~/.local/bin, in the user's git repos, and those CLIs read ~/.codex and ~/.claude. It also bundles and runs PostgreSQL 17 (initdb, pg_ctl, postgres), writes a per-user LaunchAgent plist into ~/Library/LaunchAgents, serves a Unix socket in $TMPDIR to the `agent-workspace` CLI, and keeps secrets in the keychain.

Source note: most of the hard technical detail comes from Apple Developer Forums posts by Apple DTS engineers, mainly Quinn "The Eskimo!". These are Apple staff posts but not formal documentation, and Quinn repeatedly says he does not speak for App Review. Labels used: **[Apple doc]**, **[Apple DTS forum]**, **[Apple release note, quoted by a forum user]**, **[secondary]**.

## Q1. Is App Sandbox mandatory for the Mac App Store and for TestFlight for Mac? Can a Developer ID app use TestFlight?

### Takeaway
Yes. Every Mac App Store app must be sandboxed, and every executable in the bundle needs the sandbox entitlement. TestFlight for Mac takes the same App Store Connect upload: Mac App Store distribution signing, an embedded provisioning profile, and the restricted entitlements that profile authorises. I found no mechanism, through WWDC26 or late 2026, for sending a Developer ID–signed, non-sandboxed Mac app through TestFlight. In practice TestFlight for Mac is a pre-release channel for a Mac App Store build only.

### Cited Findings
- **[Apple doc]** App Review Guideline 2.4.5(i): Mac App Store apps "must be appropriately sandboxed, and follow macOS File System Documentation." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **[Apple doc]** The other 2.4.5 clauses that bear on b4app:
  - 2.4.5(ii): apps "must be self-contained, single app installation bundles and cannot install code or resources in shared locations."
  - 2.4.5(iii): apps "may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app."
  - 2.4.5(iv): apps "may not download or install standalone apps, kexts, additional code, or resources to add functionality."
  - 2.4.5(v): no root escalation or setuid.
  - 2.4.5(vii): updates only through the Mac App Store.
  — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **[Apple doc]** Guideline 2.5.2: apps "may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps." The only carve-out is for limited educational code-teaching apps. — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **[Apple doc]** The guidelines page has no separate rules for "TestFlight for Mac"; TestFlight is covered generally under 2.2. — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **[Apple DTS forum]** On sandboxing: "Your Mac App Store apps must be signed with the App Sandbox Entitlement." Nested executables typically carry `com.apple.security.app-sandbox` plus `com.apple.security.inherit`. — [TestFlight, Provisioning Profiles, and the Mac App Store (Quinn, 2023-07-17, rev. 2023-08-17)](https://developer.apple.com/forums/thread/733942)
- **[Apple DTS forum]** On the profile: "To submit an app to TestFlight, it must have a provisioning profile." Without one the upload fails with ITMS-90889 ("Main bundles are expected to have provisioning profiles in order to be eligible for TestFlight"). The fix is a **Mac App Store distribution** provisioning profile. — [same thread](https://developer.apple.com/forums/thread/733942)
- **[Apple doc / WWDC]** "Native Mac apps require a provisioning profile to be distributed with TestFlight on Mac." — [WWDC21 "Meet TestFlight on Mac" (10170)](https://developer.apple.com/videos/play/wwdc2021/10170/)
- **[Apple DTS forum]** TestFlight requires the restricted entitlements `com.apple.application-identifier` and `com.apple.developer.team-identifier`. The distribution profile does not authorise them on a local machine, so one build cannot be both TestFlight-acceptable and locally runnable ("you can't omit those entitlements because they're required by TestFlight"). — [Testflight entitlements break local version (Quinn, Dec 2024)](https://developer.apple.com/forums/thread/769758)
- **[Apple DTS forum]** App Store Connect ingestion rejects any executable in the bundle that lacks the sandbox entitlement: ITMS-90296 "App sandbox not enabled." It often flags nested XPC services, helpers and login items. — [App Sandbox not enabled thread](https://developer.apple.com/forums/thread/41400); [ITMS-90296 pkg thread](https://developer.apple.com/forums/thread/768361)
- **[Apple doc]** Apple's helper-tool article walks the App Store Connect export path and checks that the tool is signed with "Apple Distribution", the Mac App Store identity, not Developer ID. — [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- **[secondary]** Real cross-platform projects keep two entitlement files and two build pipelines. Example: a sandboxed MAS/TestFlight build next to a sandbox-disabled Developer ID, notarized and Homebrew build. — [PolyPilot PR #541](https://github.com/PureWeen/PolyPilot/pull/541); [Electron MAS submission guide](https://ayakael.net/mirrors/electron/raw/commit/0615fadeadc9de97b51ff4931ab1ea4400b7f42d/docs/tutorial/mac-app-store-submission-guide.md)
- **[Apple DTS forum]** Temporary-exception entitlements are fine outside the MAS: "For macOS you can ship an app via the Mac App Store or ... independently using Developer ID signing. The former involves App Review, and their temporary exception entitlement policy, the latter does not." — [Quinn, Jul 2022](https://developer.apple.com/forums/thread/709333)

### Inferences
- TestFlight for Mac is not a distribution channel for Developer ID builds. Getting the Mac app into TestFlight means building a sandboxed, Apple Distribution–signed, profile-embedded variant that would also pass Mac App Store ingestion.
- Option (a) works with no new constraints: TestFlight and the App Store serve only the iOS companion, and the Mac app stays on Developer ID plus notarization.
- Guideline 2.4.5(vii) bans other update mechanisms, so a MAS variant could not ship a Sparkle-style updater. Developer ID and MAS would be two separately versioned products.

### Gaps
- I found no Apple page that says in one sentence "TestFlight for Mac requires App Sandbox." The requirement is inferred from three things: TestFlight builds go through the same App Store Connect ingestion, which enforces ITMS-90296; they need a Mac App Store distribution profile; and Quinn says TestFlight requires the App Store restricted entitlements.
- I found no WWDC25 or WWDC26 announcement letting Developer ID apps use TestFlight. Searches returned only 2021 coverage. Absence of evidence, not a confirmed statement.

## Q2. In the sandbox, can the app or its children run user-installed executables (Homebrew, ~/.nvm node) and read ~/.codex, ~/.claude or the user's repos?

### Takeaway
Effectively no, for b4app's use case. Children inherit the app's sandbox. A sandboxed app can execute only what is inside its static sandbox (its own bundle, system locations, /Applications). There is **no** dynamic sandbox extension, not even an open panel, that grants permission to *execute* a file elsewhere. Children also cannot reach ~/.codex or ~/.claude without temporary-exception entitlements, which App Review typically rejects. Repo access would need user-selected folders with security-scoped bookmarks. Apple DTS's stated recommendation for running developer tools is not to sandbox.

### Cited Findings
- **[Apple DTS forum]** Inheritance: "when a sandboxed app runs a command-line tool like this, the tool inherits the app's sandbox." — [Running Developer Tools from a Sandboxed App (Quinn, Feb 2024)](https://developer.apple.com/forums/thread/746478)
- **[Apple DTS forum]** Execute permission, from the same thread:
  - Running a tool under `/Applications/Xcode.app/...` "works because `/Applications` is in the sandbox's built-in allowlist. This is part of your static sandbox."
  - "For normal files you can dynamically extend your sandbox ... by presenting a standard open panel. However, this doesn't work for executable access. There is currently no way to get a dynamic sandbox extension that grants executable access."
  — [same thread](https://developer.apple.com/forums/thread/746478)
- **[Apple DTS forum]** Robustness, from the same thread: a complex tool (the Swift compiler is the example) "might do things that don't work in the sandbox. Moreover, it's possible that this behaviour might change over time." `xcrun` refuses to run at all in a sandbox ("xcrun: error: cannot be used within an App Sandbox"). — [same thread](https://developer.apple.com/forums/thread/746478)
- **[Apple DTS forum]** Recommendation: "The only approach I'm prepared to actively recommend is to not sandbox your app." If you must sandbox, the options are:
  - Only use tools within the static sandbox.
  - Embed the tool. That is feasible only for open-source tools with compatible licences; it grows the app, and "You can only run that version of the tool, which might not be the version that the user wants."
  — [same thread](https://developer.apple.com/forums/thread/746478)
- **[Apple doc]** An embedded helper must be signed with exactly `com.apple.security.app-sandbox` and `com.apple.security.inherit`, and placed in `Contents/MacOS` or a similar standard location. `get-task-allow` "is incompatible with the `com.apple.security.inherit` entitlement." Apple warns: "Adding other entitlements to the tool can cause problems. If the tool immediately crashes with a code signing error ... check that the tool is signed with just these two entitlements." — [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- **[Apple DTS forum]** A child signed with app-sandbox but without inherit crashes in `_libsecinit_appsandbox` while trying to set up a new sandbox. Unsigned or third-party binaries simply inherit the parent's sandbox. To run a separately sandboxed app, launch it with NSWorkspace instead of as a child. — [Resolving App Sandbox Inheritance Problems](https://developer.apple.com/forums/thread/706390); [How are child processes sandboxed?](https://developer.apple.com/forums/thread/123873)
- **[Apple DTS forum]** Mac App Store apps need every bundled piece of code sandboxed. Inheritance does not apply when a bundled tool is launched from Terminal rather than as the app's child. — [Open files in a Sandboxed command-line app](https://developer.apple.com/forums/thread/13901)
- **[Apple doc]** Guideline 2.5.2: apps "may not read or write data outside the designated container area." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **[Apple DTS forum]** Dot-folders such as `~/.ssh` can technically be opened with `com.apple.security.temporary-exception.files.home-relative-path.read-write` = `/.ssh/`. Quinn treats that as acceptable only outside the Mac App Store. — [Access dot folder file from macOS app with App Sandbox (Jul 2022)](https://developer.apple.com/forums/thread/709333)
- **[secondary]** A home-relative-path read-write exception was rejected in review ("one or more temporary entitlement exceptions requested for this app are not appropriate and will not be granted"). Switching to absolute-path was rejected for the same reason. — [zenn.dev post (Japanese developer)](https://zenn.dev/kyome/articles/f5a7b9224c7fda)

### Inferences
- `/opt/homebrew/bin/codex`, `~/.nvm/versions/node/*/bin/node` and `~/.local/bin/claude` are all outside the static sandbox. A sandboxed b4app could not exec them, and no user consent flow changes that.
- Embedding `codex` and `claude` is not viable:
  - Licensing and redistribution would be needed.
  - The tools self-update, and 2.4.5(iv) and 2.5.2 forbid downloading code that changes functionality.
  - The tools would read and write ~/.codex and ~/.claude, which the inherited sandbox denies. They would see the app's container as `$HOME` instead, which breaks the user's existing login state.
- Repos chosen through NSOpenPanel and stored as security-scoped bookmarks would be readable and writable by inherited children, since children inherit the parent's extensions. But the agent CLIs also spawn `git`, shells and arbitrary build tools, and many of those live outside the static sandbox. Anything the agent tries to run from Homebrew or the user's toolchain would fail.

### Gaps
- No Apple primary doc lists the exact static allowlist of executable paths in the macOS 26 sandbox profile. The `/Applications` allowance comes from Quinn's post.
- I found no source confirming whether security-scoped bookmark extensions propagate to inherited children in all cases. Widely assumed, not verified in this pass.

## Q3. Temporary-exception entitlements: what they allow and App Review's stance

### Takeaway
Temporary exceptions are public API that grant specific holes: file paths (home-relative or absolute, read-only or read-write), global Mach lookup or registration, shared preference domains, Apple events, IOKit user clients, and audio-unit hosting. Apple DTS says App Review "typically reject[s]" them now that security-scoped bookmarks exist. Each one must be justified in App Store Connect. None of them grants execute permission on arbitrary user binaries.

### Cited Findings
- **[Apple doc, archived]** The keys and what each enables:
  - `files.home-relative-path.read-only` and `.read-write`: "Enables read/write access to the specified files or subdirectories in the user's home directory."
  - `files.absolute-path.read-only` and `.read-write`: the same for absolute paths.
  - `mach-lookup.global-name`: "Enables lookup of one or more global Mach services."
  - `mach-register.global-name`, `shared-preference.read-only` and `.read-write`, `apple-events`, `iokit-user-client-class`, `audio-unit-host`.
  - Path strings must start with `/`; directory paths must end with `/`.
  — [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- **[Apple doc, archived]** If you use one, "identify the entitlement and corresponding issue number in the App Sandbox Entitlement Usage Information section" of App Store Connect and "explain why your app needs the exception." — [same page](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- **[Apple DTS forum]** Quinn on "temporary": the name reflects that "App Review allowed folks to use them while we built out critical App Sandbox infrastructure", for example before security-scoped bookmarks existed. "From the perspective of the App Store, these temporary exception entitlements should no be longer necessary and any use of them is carefully examined by App Review ... my experience is that they typically reject folks using temporary exception entitlements." — [thread 709333 (Jul 2022)](https://developer.apple.com/forums/thread/709333)
- **[Apple DTS forum]** "From a purely technical perspective, temporary exception entitlements are public API and we don't expect them to go away. If you're sandboxing an app that you don't plan to ship via the Mac App Store, it's absolutely fine to use them." — [same thread](https://developer.apple.com/forums/thread/709333)
- **[secondary]** A real Resolution Center rejection of `home-relative-path.read-write` cited guideline 2.4.5(i). — [zenn.dev](https://zenn.dev/kyome/articles/f5a7b9224c7fda)

### Inferences
- A MAS variant that asked for read-write on `/.codex/`, `/.claude/` and `/Library/LaunchAgents/` would very likely be rejected. Even if accepted, those exceptions would not solve the executable problem in Q2.

### Gaps
- App Review publishes no formal policy text on temporary exceptions. The evidence is DTS opinion plus anecdotal rejections.
- The temporary-exception doc is an archived page; I did not find a current DocC replacement that restates App Review guidance.

## Q4. Can a sandboxed app run a bundled PostgreSQL? Shared memory, semaphores, Unix sockets, bundled executables

### Takeaway
Not as shipped today. PostgreSQL always creates a small **System V** shared memory segment to interlock the data directory, on every Unix and regardless of `shared_memory_type`. The macOS sandbox denies SysV shm creation, so `initdb` and `postgres` fail with `shmget ... Operation not permitted`. On macOS, PostgreSQL also defaults to SysV semaphores. POSIX shm and semaphores are allowed in a sandbox only when their names are prefixed `<app group id>/` and fit in 31 characters, which PostgreSQL's naming does not do. Unix domain sockets must live in the app group container, not in $TMPDIR. Every bundled binary (initdb, pg_ctl, postgres) would also need app-sandbox and inherit entitlements. Running PostgreSQL in the sandbox would mean patching it, with no upstream fix as of the latest source found (Sept 2025).

### Cited Findings
- **[secondary, PostgreSQL mailing list]** Walther, 2025-09-09:
  - "System V shared memory segments are used by PostgreSQL to provide a lock on the data directory, as explained in sysv_shmem.c."
  - "the Darwin sandbox doesn't allow creating System V shared memory segments."
  - The resulting error is `FATAL: could not create shared memory segment: Operation not permitted DETAIL: Failed system call was shmget(key=..., size=56, 03600).`
  — [pgsql-bugs: PostgreSQL fails to start inside Nix' darwin sandbox](https://www.postgresql.org/message-id/a90b5411-705f-4286-bd81-a26c520a6cfb%40technowledgy.de)
- **[secondary, PostgreSQL committer]** Thomas Munro, 2025-09-10:
  - The "tiny 'interlocking' memory segment" is used "on all Unixen without an alternative."
  - "The next problem will be System V semaphores." He posted a futex-based semaphore patch for macOS and noted "you could presumably already use the more wasteful named POSIX semaphores."
  - Ways to replace the SysV interlock (file lock, AF_UNIX socket, named pipe) were only "off the cuff ideas."
  — [pgsql-bugs reply](https://www.postgresql.org/message-id/CA%2BhUKGJoOCA5PmhqU5P8gWe2Am%3DO-f0ubDjUed2kPuLRWe-UEg%40mail.gmail.com)
- **[Apple doc]** The App Groups entitlement table:
  - POSIX semaphores and POSIX shared memory: "The service identifer has the format `<group identifier>/<unique name>`", limited to `PSEMNAMLEN` and `PSHMNAMLEN` characters respectively.
  - Unix domain sockets: "The path to the socket needs to be in your app group container, and the name of the socket is limited to `SOCK_MAXADDRLEN` characters."
  - Mach and XPC service names: `<group identifier>.<unique name>`.
  - "In macOS, use app groups to enable IPC communication between two sandboxed apps, or between a sandboxed app and a nonsandboxed app."
  — [App Groups Entitlement](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.security.application-groups.md)
- **[Apple DTS forum]** The POSIX name cap is 31 characters (`PSEMNAMLEN`), so keep the group ID short. A name like `SKMME9E2Y8.grp/shm` works. — [sem_t in sandbox app](https://developer.apple.com/forums/thread/756420); [Is opening Shared memory allowed in services having App Sandbox Entitlement](https://developer.apple.com/forums/thread/719897)
- **[Apple DTS forum]** A third-party library in a sandboxed app hit `Sandbox: deny(1) ipc-posix-shm-write-create` because its shm names lacked the group prefix. — [Crash using OpenMP library in a sandboxed app](https://developer.apple.com/forums/thread/751241)
- **[secondary]** LMDB in a sandboxed app hit the same POSIX semaphore prefix problem: the names were `/MDB...`, and the library had little support for custom prefixes. — [mimir issue #101](https://github.com/GregoryConrad/mimir/issues/101)
- **[secondary]** An open Claude Code issue reports SysV shm and sysctl refused with EPERM inside its macOS sandbox. The reporter's workaround was to exclude the PostgreSQL-dependent command from the sandbox. — [claudeissues.com #91555](https://claudeissues.com/issue/91555-bug-macos-sandbox-system-v-shared-memory-and-sysctl-calls-are-refused-with-eperm)
- **[Apple doc]** Each bundled executable must be signed with exactly app-sandbox plus inherit, and ingestion flags any unsandboxed executable (ITMS-90296). — [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app); [thread 41400](https://developer.apple.com/forums/thread/41400)

### Inferences
- A sandboxed PostgreSQL would need all of the following:
  - A patched postmaster that drops or replaces the SysV interlock.
  - POSIX semaphores, compiled with `USE_NAMED_POSIX_SEMAPHORES`, with names rewritten to `<group id>/...`. PostgreSQL's per-semaphore naming would struggle under the 31-character cap.
  - `shared_memory_type=mmap` (anonymous mmap is not a named IPC object) and `dynamic_shared_memory_type=mmap`, with files under the data dir.
  - `unix_socket_directories` pointing inside the app group container. The 104-byte socket path limit already noted in AGENTS.md gets tighter, since `~/Library/Group Containers/<TEAMID>.<name>/` is long.
  - Every binary re-signed with app-sandbox and inherit, with the dlopen of the bundled libpq staying inside the bundle.
- The SysV patch alone means maintaining a PostgreSQL fork, for no gain outside the MAS variant.
- The realistic MAS-variant alternative is not to run PostgreSQL at all and use SQLite (the iOS mirror already uses GRDB/SQLite). That diverges from the coordinator's storage layer (decision record: `Sources/WorkspaceStorage` is PostgreSQL-only).

### Gaps
- No Apple doc explicitly states "System V IPC is denied in App Sandbox". The evidence is empirical (Nix's Darwin sandbox, which uses the same Seatbelt mechanism, and Claude Code's sandbox) rather than an App Sandbox–specific test. App Sandbox is built on the same sandbox kernel extension, but I did not find a test of `shmget` inside an App Sandbox–entitled app specifically.
- I did not verify whether PostgreSQL 18 or later (2025–2026) merged Munro's futex semaphores or removed the SysV interlock.

## Q5. SMAppService launch agents and writing ~/Library/LaunchAgents from a sandboxed app

### Takeaway
A sandboxed app can register a launch agent only through `SMAppService.agent(plistName:)`, with the plist inside its own bundle at `Contents/Library/LaunchAgents`. Since macOS 14.2 the agent executable **must itself be sandboxed** if the app is ("sandbox required" from BTM). To share an app group, which is needed for IPC, the agent must sit in an app-like wrapper with its own provisioning profile. The user can disable it in System Settings > Login Items. Writing ~/Library/LaunchAgents directly is outside the container. It is forbidden by 2.4.5(ii) ("cannot install code or resources in shared locations") and 2.5.2, and would need a temporary exception App Review would not grant.

### Cited Findings
- **[Apple doc]** "The property list name must correspond to a property list in the calling app's `Contents/Library/LaunchAgents` directory." Available on macOS 13 and later. — [SMAppService.agent(plistName:)](https://developer.apple.com/tutorials/data/documentation/servicemanagement/smappservice/agent(plistname:).md)
- **[Apple release note, quoted by a forum user]** macOS 14.2 release notes: "Requirements for agents and daemons registered with SMAppService have changed to prevent sandbox escapes. The target executable must be sandboxed if the main app is sandboxed. A small sandboxed trampoline tool can be written to execute scripts and unsandboxed or system tools. (113037504)". The failure logs show `backgroundtaskmanagementd` reporting "error: sandbox required" and "Register of <private> rejected by BTM", with `SMAppServiceErrorDomain Code=1 "Operation not permitted"`. — [Can not register LaunchAgents on macOS 14.2.1 (Dec 2023)](https://developer.apple.com/forums/thread/743395)
- **[Apple DTS forum]** Quinn, Jun 2026, on a sandboxed app talking to its launch agent:
  - "XPC is our preferred IPC mechanism."
  - "The XPC named endpoint published by your launchd agent must have a name that's 'within' the app group."
  - "Both programs must claim access to that app group via an entitlement. That entitlements should be authorised by a provisioning profile."
  - "The requirement for a provisioning profile is why you need to embed the agent in an app-like wrapper."
  — [Sandboxed App <> Launch Agent - how to communicate? (Jun 2026)](https://developer.apple.com/forums/thread/835003)
- **[secondary, community accepted answer, same thread]** "you must setup an app group. No option there." Also: "Your app needs to gracefully handle when the user disables the launch agent." — [thread 835003](https://developer.apple.com/forums/thread/835003)
- **[Apple doc]** Guideline 2.4.5(ii): apps "cannot install code or resources in shared locations." 2.4.5(iii): no code that runs at login "without consent", and no processes that keep running after quit "without consent." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### Inferences
- In a MAS variant, b4app's current approach of the app writing a plist into ~/Library/LaunchAgents must be replaced by SMAppService with a bundled plist. The earlier SMAppService.agent design would be the starting point.
- The coordinator (b4app-coordinator) would have to be sandboxed itself, wrapped as an app-like bundle with its own bundle ID and profile, and given the app group. It would inherit every Q2 and Q4 restriction directly: no exec of user CLIs, no SysV shm. The 14.2 release note's "sandboxed trampoline" escape hatch only runs things the sandbox already permits, and Apple does not mean it for MAS escape.
- A continuously running agent needs explicit user consent and a visible on/off control, plus graceful handling when the user disables it (2.4.5(iii)).

### Gaps
- No Apple doc or App Review statement explicitly says whether MAS apps may ship SMAppService agents. Developers in thread 835003 asked and got no definitive answer. Many MAS apps do ship login items (SMAppService.loginItem / mainApp), but I found no primary source on agent approval rates.

## Q6. Can a command-line tool outside the app connect to the app's Unix socket in an app group container?

### Takeaway
Apple says app groups are meant for IPC "between a sandboxed app and a nonsandboxed app", and a sandboxed app's Unix sockets must live in the group container. So a non-sandboxed `agent-workspace` CLI connecting to `~/Library/Group Containers/<group>/x.sock` is the intended pattern. On macOS 15 and later, app group container protection can prompt the user when a process without an authorised claim to the group touches the container. The CLI would need the App Groups entitlement authorised by a provisioning profile, which means an app-like wrapper. A bare Homebrew-installed or `swift build` CLI binary may trigger a consent prompt or be denied.

### Cited Findings
- **[Apple doc]** "In macOS, use app groups to enable IPC communication between two sandboxed apps, or between a sandboxed app and a nonsandboxed app." For Unix sockets: "The path to the socket needs to be in your app group container." — [App Groups Entitlement](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.security.application-groups.md)
- **[Apple DTS forum]** macOS 15 app group container protection. To access a group container without user intervention, an app must claim the group in its App Groups entitlement, locate the container with `containerURL(forSecurityApplicationGroupIdentifier:)`, and meet one of these criteria:
  - (A) deployed via the Mac App Store
  - (B) deployed via TestFlight on macOS 15.1 or later
  - (C) the app group ID starts with the Team ID
  - (D) the claim is authorised by an embedded provisioning profile

  "If your app doesn't follow these rules, the system prompts the user to approve its access to the container. If granted, that consent applies only for the duration of that app instance." — [App Groups: macOS vs iOS: Working Towards Harmony (Quinn, rev. through 2025-08-12)](https://developer.apple.com/forums/thread/721701)
- **[Apple DTS forum]** Non-sandboxed code: claiming the app group used to be unnecessary, but that "was true prior to macOS 15 ... the most important thing, access to the app group container, requires the entitlement because of app group container protection." Standalone executables that need the entitlement should be wrapped in an app-like structure. — [thread 721701](https://developer.apple.com/forums/thread/721701)
- **[Apple DTS forum]** Since Feb 2025 (Xcode 16.3), iOS-style `group.` IDs are fully supported on macOS: "If you're writing new code that uses app groups, use an iOS-style app group ID." MAS submission checks that group IDs start with the Team ID or are assigned to the team. Mixing `TEAM_ID.*` and `group.` styles has been supported since Jun 2025. — [thread 721701](https://developer.apple.com/forums/thread/721701)
- **[Apple DTS forum]** You still can't get a Mac provisioning profile that authorises an iOS-style group for some product types (Jan 2025 report). Migrating between container styles on macOS 15 needs user approval. — [MacOS App Group Container Protection](https://developer.apple.com/forums/thread/773094)

### Inferences
- With a Team-ID-prefixed group (`GJJKL34HCT.<name>`), criterion (C) may let the signed `agent-workspace` CLI reach the container without a prompt, if it claims the group in its entitlements. Without a profile, that claim is "validation-required" rather than enforced, per Quinn. A CLI built locally with `swift build` (ad hoc signed, no entitlement) would most likely trigger the protection prompt, attributed to the responsible process such as Terminal.
- In the MAS variant, the socket path moves from $TMPDIR to the group container. Both the sandboxed app's container path and the group path are long, which makes the 104-byte `sun_path` limit tighter.
- Option (a) keeps $TMPDIR sockets and avoids all of this.

### Gaps
- I found no Apple source that specifically tests a non-sandboxed, non-bundled CLI `connect()`ing to a Unix socket inside a protected group container on macOS 15 or 26. Whether `connect()` on an existing socket path counts as container access for the protection prompt is unverified.
- How TCC attributes such prompts (the CLI binary versus Terminal as responsible process) was not documented in the sources found.

## Q7. Guidelines 2.4.5 and 2.5.x for apps that download or run code or spawn processes; developer-tool precedents in the MAS

### Takeaway
2.5.2 forbids executing code that "introduces or changes features or functionality of the app, including other apps". 2.4.5(iv) forbids downloading code to add functionality. 2.4.5(iii) forbids background processes after quit without consent. An agent workspace whose core function is to drive user-installed, self-updating AI CLIs that run arbitrary shell commands in user repos fits these badly. Precedents show developer tools either leave the MAS, ship reduced sandboxed editions, or move CLIs out of the MAS bundle. I found no precedent of a MAS app that executes arbitrary user-installed toolchains.

### Cited Findings
- **[Apple doc]** 2.5.2 text (see Q1). 2.5.4: "Multitasking apps may only use background services for their intended purposes." 4.7: apps may offer software not embedded in the binary only in narrow categories (HTML5/JS mini apps and games, streaming games, chatbots, plug-ins, emulators). 4.7.2: apps "may not extend or expose native platform APIs or technologies to the software without prior permission from Apple." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **[Apple DTS forum]** For running developer tools from a sandboxed app, "The only approach I'm prepared to actively recommend is to not sandbox your app." — [thread 746478](https://developer.apple.com/forums/thread/746478)
- **[secondary]** BBEdit is a text editor with heavy CLI integration:
  - It left the MAS for nearly five years over sandboxing.
  - It returned in 2019 as BBEdit 12.6, after being sandboxed.
  - Earlier MAS versions omitted the command-line tools "to comply with Apple's submission guidelines", and users had to install them separately.
  — [MacRumors 2019-04-04](https://www.macrumors.com/2019/04/04/bbedit-returns-to-mac-app-store); [9to5Mac 2019-02-25](https://9to5mac.com/2019/02/25/bbedit-12-6-sandboxing-mac-app-store/); [Michael Tsai blog 2019-02-27](https://mjtsai.com/blog/2019/02/27/bbedit-12-6-to-return-to-the-mac-app-store); [BBEdit 12.6 release notes](https://barebones.com/support/bbedit/notes-12.6.html)
- **[secondary]** A developer claims BBEdit sandboxes only the main app, not its embedded CLI tools. Unconfirmed. — [Embedding automation command line tool into an AppStore app](https://developer.apple.com/forums/thread/771117)
- **[secondary]** A 2014 cocoa-dev reply: a sandboxed app directing Terminal to run arbitrary commands would be a major sandbox hole. Advice was to distribute outside the MAS or build an in-app terminal emulator. Opinion, not policy. — [cocoa-dev, Dec 2014](https://lists.apple.com/archives/cocoa-dev/2014/Dec/msg00045.html)
- **[secondary]** CodeRunner 4 is a multi-language code runner in the MAS. A user comment reports an "App Sandbox" error from `xcrun` when running Python, which is consistent with Quinn's xcrun note. — [CodeRunner 4 App Store listing](https://apps.apple.com/cl/app/id955297617)
- **[secondary]** Vendors who dual-ship document reduced functionality in the MAS edition due to "sandboxing restrictions and limitations". Example: Fade In. — [Fade In KB](https://www.fadeinpro.com/kb/content/2/33/en/differences-between-the-mac-app-store-and-non_app-store-versions.html); [ibl.ai: macOS Builds MAS vs Developer ID](https://ibl.ai/developer/os/macos-builds.md)

### Inferences
- Even a technically working sandboxed b4app would face a 2.5.2 review risk. Its function is to run external agents (`codex`, `claude`) that themselves download updates and run arbitrary code. Review outcome is not predictable from public sources.
- The precedents (BBEdit, CodeRunner, Fade In) support a "reduced MAS edition" model. For b4app, a MAS edition stripped of local CLI execution and local PostgreSQL would basically be a remote client: the M8b remote-workspace mode talking to the hub, or to a Developer ID Mac running the coordinator.

### Gaps
- I did not find authoritative entitlement dumps for current MAS terminal or SSH apps (e.g. Prompt, Secure ShellFish, CodeEdit) or for Xcode-adjacent MAS tools. CodeEdit's MAS plans are in a GitHub discussion I did not read: [CodeEdit #849](https://github.com/orgs/CodeEditApp/discussions/849).
- I found no public App Review statement about AI-agent apps that drive local CLIs.

## Recommendation and cost of each option (synthesis; inferences, sourced above)

### Takeaway
**Option (a)** is the realistic choice: Mac on Developer ID plus notarization, TestFlight and App Store for the iOS companion only. Nothing in the Mac app's architecture is compatible with the Mac App Store sandbox without large rewrites. **Option (b)** is viable only as a feature-reduced "remote client" edition with no local runtimes and no PostgreSQL, maintained as a second product. **Option (c)** would break the product's core function: executing user-installed CLIs is impossible in the sandbox, and DTS recommends against it.

### Cited Findings
- **Option (a): Developer ID plus notarization for Mac; TestFlight/App Store for iOS only.**
  - Cost: none beyond what exists today (D-039 signing pipeline).
  - Temporary exceptions and other sandbox concepts are irrelevant to Developer ID — [Quinn, thread 709333](https://developer.apple.com/forums/thread/709333).
  - Developer ID apps have no sandbox requirement — [Electron MAS guide (secondary)](https://ayakael.net/mirrors/electron/raw/commit/0615fadeadc9de97b51ff4931ab1ea4400b7f42d/docs/tutorial/mac-app-store-submission-guide.md).
  - Mac beta distribution would use notarized DMG/zip builds plus an updater, not TestFlight.
- **Option (b): a separate sandboxed MAS/TestFlight variant.** It needs a second signing pipeline: Apple Distribution identity, Mac App Store profile, and the restricted entitlements that make TestFlight builds unrunnable locally — [thread 733942](https://developer.apple.com/forums/thread/733942); [thread 769758](https://developer.apple.com/forums/thread/769758). It must also drop or replace:
  - user-CLI exec — [thread 746478](https://developer.apple.com/forums/thread/746478)
  - PostgreSQL's SysV interlock and semaphores — [pgsql-bugs](https://www.postgresql.org/message-id/CA%2BhUKGJoOCA5PmhqU5P8gWe2Am%3DO-f0ubDjUed2kPuLRWe-UEg%40mail.gmail.com)
  - ~/Library/LaunchAgents writes, in favour of a sandboxed SMAppService agent in an app-like wrapper — [release note via 743395](https://developer.apple.com/forums/thread/743395); [thread 835003](https://developer.apple.com/forums/thread/835003)
  - $TMPDIR sockets, in favour of group-container sockets — [App Groups Entitlement](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.security.application-groups.md)

  No self-updater is allowed — [2.4.5(vii)](https://developer.apple.com/app-store/review/guidelines/).
- **Option (c): sandbox the whole Mac app.** It has every cost of (b) and also removes the Developer ID product's core capability. Apple DTS: "The only approach I'm prepared to actively recommend is to not sandbox your app." — [thread 746478](https://developer.apple.com/forums/thread/746478)

### Inferences
- **Cost of (b) for b4app in concrete terms.**
  - A new build configuration in `project.yml` and new entitlements: app-sandbox, app group, network client, user-selected read-write, keychain access group.
  - A storage backend that is not PostgreSQL in the MAS edition, or a PostgreSQL fork.
  - A sandboxed coordinator wrapper bundle, or no coordinator.
  - A different `agent-workspace` CLI story: the CLI would need an app group claim and profile, or would not be supported.
  - Dropping the local Codex, Claude and B4 adapters in that edition, since they rely on user CLIs.

  What is left, a remote-workspace client over the hub (M8b), is close to what the iOS companion already does. A Mac Catalyst or "Designed for iPad" build of the iOS companion could reach Mac testers through TestFlight for Mac. TestFlight for Mac supports iOS apps on Apple silicon Macs — [App Store Connect Help: TestFlight overview](https://developer-mdn.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview); [Test iPhone and iPad apps on Macs with Apple silicon](https://developer-mdn.apple.com/help/app-store-connect/test-a-beta-version/test-iphone-and-ipad-apps-on-macs-with-apple-silicon). That may be the cheapest form of (b).
- If the owner wants Mac TestFlight convenience, the low-cost path is the iOS companion on Apple silicon Macs via TestFlight, or a Catalyst build of WorkspaceUI. The full local-runtime Mac app stays Developer ID only.
- Things to record if (a) is chosen: a decision in `docs/decisions.md` that the Mac app is not sandboxed and not MAS-distributed, with the reasons above (user-CLI exec, SysV IPC, LaunchAgent writes, $TMPDIR socket). Also a note that TestFlight covers the iOS target only.

### Gaps
- macOS 26-specific sandbox changes: I found no source describing App Sandbox, SMAppService or app group container changes new in macOS 26 beyond the macOS 15 and 15.1 container protection and the Feb and Jun 2025 app-group ID changes. Treat macOS 15 rules as current, unverified for 26.
- I did not verify the exact current behaviour of "Designed for iPad" or Catalyst TestFlight builds for this app's specific frameworks.
