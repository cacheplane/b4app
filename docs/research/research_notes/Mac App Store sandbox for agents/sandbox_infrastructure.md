# Sandbox infrastructure: local database, background service, and CLI IPC under App Sandbox (MAS / TestFlight for Mac)

Researched 2026-11-01. "Documented" means Apple or PostgreSQL documentation, release notes, or an Apple DTS engineer's forum post. "Reported" means developer forum posts, issue trackers, or blogs. Forum posts show only month and year.

## PostgreSQL in App Sandbox: does it fail, why, and has anyone shipped it?

### Takeaway
Stock PostgreSQL does not run under App Sandbox. It fails on System V IPC at two points: `initdb`/postmaster's always-on small SysV shared-memory "interlock" segment (`shmget`), and the SysV semaphores PostgreSQL uses on macOS (`semctl ... Operation not permitted`). Apple DTS said in Feb 2026 that SysV IPC "doesn't have a good story" in the sandbox, and that POSIX IPC works if the names are app-group-prefixed. Getting there means patching PostgreSQL: remove the SysV interlock, switch to named POSIX semaphores with app-group names, and rename or avoid POSIX DSM segments. I found no evidence that anyone has shipped PostgreSQL inside a sandboxed or MAS app.

### Cited Findings
- **Feb 2026 failure report.** A developer compiling Postgres 18 from source and sandboxing it got `FATAL: semctl(65596, 16, SETVAL, 536) failed: Operation not permitted`. They said "I have tried passing flags to initdb to use POSIX semaphores but it always wants to use sysv." (reported, Feb 2026) — [Apple Developer Forums: Postgres in Sandboxed App](https://developer.apple.com/forums/thread/816782)
- **Apple DTS answer in the same thread (Quinn "The Eskimo!", Feb 2026, documented/DTS):** "System V IPC is a compatibility API an macOS. We recommend against using it in new code. Given that, it shouldn't come as a big surprise that it doesn't have a good story regarding the App Sandbox. The alternative, Posix IPC, works in the App Sandbox as long as you conform to the naming guidelines described in App Groups Entitlement." His three steps: sign the executables with an app-group claim, configure the library to use POSIX IPC, and use names authorised by that group. He said he had no expertise in Postgres itself. No one in the thread reported success. — [Apple Developer Forums 816782](https://developer.apple.com/forums/thread/816782)
- **POSIX semaphore names in a sandboxed app** must take the form `GGG/NNN`, where GGG is an app group ID (reported, from a forum search snippet; I did not fetch the page because a bot-check blocked it). — [Apple Developer Forums: sem_t in sandbox app](https://developer.apple.com/forums/thread/756420)
- **PostgreSQL docs (v17), documented:** "By default, PostgreSQL allocates a very small amount of System V shared memory, as well as a much larger amount of anonymous mmap shared memory... a significant number of semaphores, which can be either System V or POSIX style, are created at server startup. Currently, POSIX semaphores are used on Linux and FreeBSD systems while other platforms use System V semaphores." So macOS defaults to SysV semaphores. — [PostgreSQL 17: Managing Kernel Resources](https://www.postgresql.org/docs/17/kernel-resources.html)
- **pgsql-bugs thread, Sep 2025 (Darwin/Nix sandbox, which is a Seatbelt profile like App Sandbox):** "the Darwin sandbox doesn't allow creating System V shared memory segments." `initdb` fails with `FATAL: could not create shared memory segment: Operation not permitted`, `DETAIL: Failed system call was shmget(key=80109247, size=56, 03600)`. The SysV segment is "used by PostgreSQL to provide a lock on the data directory, as explained in sysv_shmem.c." Thomas Munro (PostgreSQL committer) replied: "The next problem will be System V semaphores. I posted a patch that uses macOS futexes to implement semaphores... But you could presumably already use the more wasteful named POSIX semaphores." On the interlock segment: "we use on all Unixen without an alternative, I agree that it would be nice to get rid of it". He floated replacements (file locks, binding a dummy AF_UNIX socket under pgdata) that are not implemented. — [pgsql-bugs, T. Munro, 2025-09-10](https://www.postgresql.org/message-id/CA%2BhUKGJoOCA5PmhqU5P8gWe2Am%3DO-f0ubDjUed2kPuLRWe-UEg%40mail.gmail.com)
- **Generic sandbox finding (reported):** shared memory calls in a sandboxed app were blocked because they rely on System V IPC underneath. — [Xojo forum: Shared memory & App Sandbox](https://forum.xojo.com/t/shared-memory-app-sandbox/46405)
- **Seatbelt sandbox tool maintainers (reported):** they declined an opt-in SysV IPC grant because it widens what sandboxed code can reach. Their stated need was met by running Postgres outside the sandbox and connecting to it. They proposed a narrow rule for POSIX shm names matching `^/PostgreSQL\.` (the names Postgres uses for POSIX dynamic shared memory). — [navikt/cplt PR #761](https://github.com/navikt/cplt/pull/761)
- **Child processes of a sandboxed app (reported, Apple engineer advice):** sign the child with both `com.apple.security.app-sandbox` and `com.apple.security.inherit` so it inherits the parent's sandbox. With only `app-sandbox`, the child gets a new sandbox. So bundled `postgres`/`initdb` spawned by a sandboxed coordinator would themselves run sandboxed. — [Apple Developer Forums: sem_t in sandbox app (search snippet)](https://developer.apple.com/forums/thread/756420); also [Twocanoes, 2019](https://twocanoes.com/adding-a-command-line-tool-helper-to-a-mac-app-store-app/)
- **`temporary-exception` entitlements (reported):** forum commenters say "temporary exceptions = app store rejection." This is community opinion, not an Apple statement. — [Apple Developer Forums 665646](https://developer.apple.com/forums/thread/665646)
- **PGlite (embedded Postgres as WASM):** single user and single connection. It runs in browsers, Node, Bun, and Deno, and has no native Swift SDK. — [electric-sql/pglite](https://github.com/electric-sql/pglite); 2026 comparison noting single connection and up-front WASM memory reservation — [DEV Community, Embedded Postgres in 2026](https://dev.to/jules_sarah_0718e958f0d24/embedded-postgres-in-2026-pglite-embedded-postgres-and-tinbase-compared-31pe)
- **Wasmer SDK PR #526** adds a Swift client running PostgreSQL (WASM) on iOS. It is limited to one client per session and in-memory database files, and makes no claims about physical devices or persistence. — [wasmerio/wasmer-sdk PR #526](https://github.com/wasmerio/wasmer-sdk/pull/526)
- **Rust crate pglite-oxide** wraps PGlite (PostgreSQL 17.5) for embedded use. — [docs.rs pglite-oxide](https://docs.rs/crate/pglite-oxide/0.5.0)
- **Postgres.app history (old, 2012):** at launch Heroku said it would ship on the Mac App Store pending Apple approval. An old README said an XPC service managed the postgres processes. Today it is direct-download only. I found no stated reason. — [InfoWorld 2012](https://www.infoworld.com/article/2170523/heroku-releases-mac-compatible-postgres-for-devs.html); [old fork README](https://github.com/reilost/PostgresApp)

### Inferences
- **What patching Postgres would take for App Sandbox** (from the above plus my knowledge of the source; not verified by a build):
  - (a) Remove or replace the unconditional SysV interlock segment in `sysv_shmem.c`. `shared_memory_type=mmap`, the default, does not remove it.
  - (b) Build with named POSIX semaphores (`USE_NAMED_POSIX_SEMAPHORES` / `PREFERRED_SEMAPHORES=NAMED_POSIX` in the platform template). Patch the name generator so names are `<app-group-id>/<name>` and stay within the short POSIX name limit.
  - (c) Set `dynamic_shared_memory_type=mmap` (files under `pg_dynshmem`) instead of `posix`, or patch the `/PostgreSQL.%u` names to carry the app-group prefix.
  - (d) Sign every Postgres binary with `app-sandbox` plus `inherit`, or give it its own sandbox and app group.

  That is a maintained fork of PostgreSQL. Munro's futex-semaphore patch was not merged as of Sep 2025.
- Named POSIX semaphores leak when a crashed postmaster leaves them behind. That cleanup becomes b4app's problem.
- Even with the patch, guideline 2.5.2 (below) would accept running bundled `postgres` binaries, since they are part of the bundle. But the result is an unsupported configuration with no precedent I could find.
- The likely reason Postgres.app is direct-download is the SysV IPC restriction above, plus the need to run a long-lived server, which collides with 2.4.5(iii). This is inference; Postgres.app has not said so.
- PGlite's single connection rules it out as a drop-in replacement for a coordinator database serving the app, the CLI, and hub sync concurrently. It is also WASM-in-JS, not Swift-native.
- **App groups do not fix SysV.** App group membership authorises POSIX IPC names, Mach/XPC names, and a shared container. Nothing documented grants SysV `shmget`/`semget` in the sandbox.

### Gaps
- No primary source says why Postgres.app left or never reached the MAS.
- I found no shipped sandboxed or MAS app that embeds a PostgreSQL server, and no public patch set for "Postgres with app-group-prefixed named POSIX semaphores".
- I did not fetch Apple's App Groups entitlement page; it returned an empty page. The exact POSIX name format and length limit for macOS sandboxed apps rests on the forum snippet (`GGG/NNN`) and DTS's pointer to that page.
- I did not verify whether `com.apple.security.temporary-exception.sbpl` allowing `ipc-sysv-shm`/`ipc-sysv-sem` would technically work, or whether App Review ever accepts it. Community reports say temporary exceptions get rejected.

## SQLite/GRDB as the sandboxed database

### Takeaway
SQLite is the standard store for sandboxed Mac apps. It needs no SysV IPC, because WAL uses an mmap'd `-shm` file next to the database. It works in the app container, or in an app group container when several processes (app, login item, sandboxed CLI) share one database. The caveats are about cross-process coordination, not the sandbox.

### Cited Findings
- The GRDB "Sharing a Database" guide has moved to the DocC site. I did not fetch its content this session. — [GRDB SharingADatabase (moved notice)](https://github.com/groue/GRDB.swift/blob/master/Documentation/SharingADatabase.md) → [Swift Package Index: Database Sharing](https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/databasesharing)
- **macOS 15 group container rules (documented, DTS post last updated 2025-08-12).** For an app to access an app group container without prompting the user, it must:
  - list the group in the App Groups entitlement;
  - locate the container with `containerURL(forSecurityApplicationGroupIdentifier:)`;
  - meet one of: deployed via the Mac App Store; via TestFlight on macOS 15.1 or later; group ID starts with the Team ID; or the group claim is authorised by an embedded provisioning profile.

  "If your app doesn't follow these rules, the system prompts the user." — [DTS: App Groups: macOS vs iOS: Working Towards Harmony](https://developer.apple.com/forums/thread/721701)
- Apple release notes say app group containers in `~/Library/Group Containers` are protected by System Integrity Protection starting in macOS 15. — [Apple Developer Forums 756701](https://developer.apple.com/forums/thread/756701); [Michael Tsai, Group Container Names in Sequoia](https://mjtsai.com/blog/2024/09/11/group-container-names-in-sequoia/)

### Inferences
- **Caveats for a shared WAL database in a group container.** These come from my prior knowledge of the GRDB guide and SQLite docs; verify against the linked DocC page.
  - Use WAL with a `DatabasePool` in every process.
  - Set a busy timeout, or handle `SQLITE_BUSY`, since cross-process writers contend.
  - GRDB `ValueObservation` does not see writes from other processes. Change notification must come through IPC, such as Darwin notifications or the coordinator socket.
  - The well-known `0xdead10cc` termination applies to iOS apps holding SQLite locks in a shared container while suspended. It does not apply to the Mac.
  - All processes must be on the same machine. WAL does not work over network file systems.
- b4app already has a GRDB SQLite mirror (`Sources/WorkspaceMirror`) on iOS. Under MAS the Mac coordinator would need a SQLite store too, either a port of `WorkspaceStorage` or a reuse of the mirror schema. The architectural choice is whether only the coordinator opens the DB (simplest; the others go through the socket/XPC) or several processes do.
- **Simplest MAS-compatible design:** the database lives in the coordinator's container or group container, the coordinator is the only process that opens it, and every other process goes through IPC. This avoids multi-process SQLite locking entirely.

### Gaps
- I did not fetch GRDB's current DocC sharing guide to quote its exact recommendations.

## Background service: LaunchAgent vs SMAppService login item / agent / XPC in a sandboxed MAS app

### Takeaway
A sandboxed MAS app cannot write a plist into `~/Library/LaunchAgents`. That is outside its container, and guidelines 2.4.5(ii) and 2.5.2 forbid it. The path DTS describes as App Store compatible is a sandboxed login item registered with `SMAppService.loginItem(identifier:)` (helper in `Contents/Library/LoginItems`), sharing an app group with the app and talking over XPC with a group-prefixed Mach name. Since macOS 14.2, `SMAppService.agent(plistName:)` from a sandboxed app is permitted only if the agent executable is itself sandboxed. Whether App Review accepts SMAppService agents, as opposed to login items, is not documented. Any auto-launch needs user consent under 2.4.5(iii).

### Cited Findings
- **Guideline 2.4.5 (documented, current page):**
  - (i) Apps "must be appropriately sandboxed."
  - (ii) Apps "must be self-contained, single app installation bundles and cannot install code or resources in shared locations."
  - (iii) Apps "may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app."
  - (iv) Apps "may not download or install standalone apps, kexts, additional code, or resources to add functionality."
  - (v) Apps may not "request escalation to root privileges or use setuid."
  - (vii) Updates go only through the MAS.

  — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **Guideline 2.5.2 (documented):** "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **DTS (Quinn), reported via search snippet, 2022–2023:** "The only approach that's compatible with the App Store is a sandboxed login item, as installed by [Service Management]... if you're planning to deploy via the Mac App Store using a launchd agent is not an option." Login items are not relaunched by the system if they crash. — [Apple Developer Forums 706112: Automatically restarting a Mac App Store sandboxed app](https://developer.apple.com/forums/thread/706112)
- **macOS 14.2 release note (documented, quoted in forum, Dec 2023):** "Requirements for agents and daemons registered with SMAppService have changed to prevent sandbox escapes. The target executable must be sandboxed if the main app is sandboxed. A small sandboxed trampoline tool can be written to execute scripts and unsandboxed or system tools. (113037504)". The failure shows up as `SMAppServiceErrorDomain Code=1 "Operation not permitted"`, with `smd`/BTM logging `error: sandbox required`. — [Apple Developer Forums 743395](https://developer.apple.com/forums/thread/743395)
- **DTS (Quinn), Jan–Feb 2024, on LaunchAgents and XPC with sandboxing:**
  - On installing a LaunchAgent: "Yes. Use `SMAppService` for this."
  - "If you plan to ship with sandboxing enabled, add an app group to your app and your agent and then make the XPC service name an immediate child of the app group name."
  - "If the client is sandboxed then there is a very specific constraints on the XPC endpoint name: It must be an immediate child of an app group of which the client is a member."
  - "Notarising implies that you're distributing the app directly, which means not on the Mac App Store. That means that sandboxing is optional."
  - "`Contents/Library/LaunchServices/` is meant for tools installed with `SMJobBless`."

  — [Apple Developer Forums 745009](https://developer.apple.com/forums/thread/745009)
- **SMAppService history:** introduced in macOS 13, replacing `SMJobBless` and `SMLoginItemSetEnabled`. Agent plists go in `Contents/Library/LaunchAgents` and login items in `Contents/Library/LoginItems` (blog, 2022). — [theevilbit: SMAppService quick notes](https://theevilbit.github.io/posts/smappservice/)
- **Silent login-item failure (reported):** registration showed "registered" but the item never launched. DTS traced it to Developer ID and App Store builds sharing bundle IDs, so `launchctl` associated the wrong build. — search snippet, [Apple Developer Forums 727785](https://developer.apple.com/forums/thread/727785)

### Inferences
- b4app's current D-042 design (the app writes a plist into `~/Library/LaunchAgents`, plus an unsandboxed helper app) violates 2.5.2 and 2.4.5(ii) and is technically impossible from a sandboxed app.
- **MAS-compatible replacement:** keep `B4AppCoordinator.app` but move it to `Contents/Library/LoginItems/`, sandbox it with its own entitlements and an app group shared with the main app, and register it with `SMAppService.loginItem(identifier:)` only after explicit user consent (2.4.5(iii)), such as a "Keep coordinator running in background / at login" toggle.
- **Alternative without login-at-launch:** an XPC service in `Contents/XPCServices` lives only while the app runs. That satisfies 2.4.5(iii) trivially but cannot serve the CLI when the app is closed.
- `SMAppService.agent(plistName:)` with a sandboxed agent is technically allowed post-14.2. DTS's "only a sandboxed login item" statement predates or ignores that, so treat agents in MAS as untested territory.
- **App Review would likely scrutinize a coordinator** that keeps running after the app quits and spawns Codex, Claude, or Node child processes, under 2.4.5(iii) "without consent" and 2.5.2 "execute code". Bundled executables are fine. Running user-installed tools (codex, claude, node from Homebrew) from a sandboxed process is a separate problem: a sandboxed child cannot exec arbitrary paths outside its container without user-selected access, and anything it runs inherits or needs a sandbox. That belongs in an adjacent research area, but it matters for whether the coordinator can launch agent runtimes at all.
- No automatic crash relaunch for login items means the app or CLI must handle a missing coordinator. b4app already spawns the coordinator on demand from the CLI, but a sandboxed CLI would not be able to do that.

### Gaps
- I found no Apple documentation or App Review statement saying whether `SMAppService.agent` or `.daemon` is acceptable for MAS submissions. Daemons are clearly out under 2.4.5(v) if they need root. Agents are unclear.
- I found no current (2025–2026) DTS post re-confirming the "sandboxed login item only" rule after the 14.2 change.

## IPC: Unix socket in an app group container, XPC Mach names, CLIs (Homebrew or bundled)

### Takeaway
A Unix domain socket created by a sandboxed process inside its app group container works for same-team sandboxed peers in that group. The 104-byte `sun_path` limit is the practical constraint; `~/Library/Group Containers/<group-id>/x.sock` usually fits, while a path under the sandboxed `$TMPDIR` inside `~/Library/Containers/...` often does not. An unsandboxed CLI (Homebrew or notarized) can reportedly connect to a socket in a sandboxed app's container. On macOS 15+ it may trigger the TCC prompt "Terminal would like to access data from other apps". A CLI shipped inside a MAS app must be sandboxed (`app-sandbox` + `inherit`), and such a tool cannot run from Terminal. BBEdit's MAS edition historically shipped its CLI tools as a separate installer. XPC Mach services work for sandboxed clients only when the name is an immediate child of a shared app group ID.

### Cited Findings
- **Socket path limit (DTS Quinn, Jun 2024, documented):** "The ultimate limit is 253 bytes, which is SOCK_MAXADDRLEN minus the two byte header... However, sockaddr_un is defined such that sun_path is 104. This artificially limits the length. Network framework inherits that artificial limit." If a shorter path is not possible, use BSD sockets directly (bug r. 125081070). — [Apple Developer Forums 756756](https://developer.apple.com/forums/thread/756756)
- **Same thread (reported, Jun 2024):** a sandboxed Mac app acting as server over a Unix socket "located in the containers folder when sandboxed" talked to a separately developed Go command-line client. The client failed with `invalid argument` until the path was shortened, because "with Sandboxing enabled, the home container path became very long." Once fixed, the unsandboxed external CLI could connect to a socket in the sandboxed app's container. — [Apple Developer Forums 756756](https://developer.apple.com/forums/thread/756756)
- **Socket in a group container (reported, older thread):** sandboxed processes cannot connect to arbitrary Unix sockets, but same-team processes sharing an app group can, if "the listener creates the UNIX domain socket within the app group's container." — [Apple Developer Forums 133543](https://developer.apple.com/forums/thread/133543)
- **XPC naming (DTS, 2024, documented):** for sandboxed clients the XPC endpoint name "must be an immediate child of an app group of which the client is a member", for example `<group-id>.coordinator`. — [Apple Developer Forums 745009](https://developer.apple.com/forums/thread/745009)
- **Group container protection (documented, DTS 2025-08-12):** prompts are avoided only for MAS-deployed apps, TestFlight builds on macOS 15.1+, Team-ID-prefixed groups, or profile-authorised claims. Consent from a prompt "applies only for the duration of that app instance." — [Apple Developer Forums 721701](https://developer.apple.com/forums/thread/721701)
- **Unsandboxed processes and TCC (reported, 2025–2026 issue trackers):**
  - Unsandboxed processes touching other apps' Containers or Group Containers trigger "X would like to access data from other apps". — [cmux #5146](https://github.com/manaflow-ai/cmux/issues/5146)
  - The prompt names "Terminal" because a CLI run in a terminal inherits Terminal's TCC identity; it fires once per container. — [hermes-webui #1485](https://github.com/nesquena/hermes-webui/issues/1485)
  - Binaries whose path changes per version re-prompt. — [anthropics/claude-code #63130](https://github.com/anthropics/claude-code/issues/63130)
  - The user-side workaround is giving Full Disk Access to the terminal. — [tongfamily 2025](https://tongfamily.com/2025/04/11/mac-annoying-would-like-to-access-data-from-other-apps/)
- **CLI bundled in a MAS app:**
  - "Shipping to the Mac App Store requires a sandboxed app, and all bundled executables must be sandboxed as well" (reported). — [Adam Wulf 2023](https://adamwulf.me/2023/04/embedded-command-line-tool-in-mac-app-store-app/)
  - A bundled tool must be signed with exactly `app-sandbox` + `inherit`. Per a quoted Apple DTS engineer, it can run only when launched by its sandboxed parent; run from Terminal it fails because there is no sandbox to inherit (2019). — [Twocanoes 2019](https://twocanoes.com/adding-a-command-line-tool-helper-to-a-mac-app-store-app/)
  - A sandboxed tool started from Terminal "is immediately terminated with a sandbox initialization error"; DTS suggested packaging a CLI as an app-like bundle so the sandbox sets up coherently (reported). — [Apple Developer Forums 771117](https://developer.apple.com/forums/thread/771117)
  - Installing a CLI symlink into `/usr/local/bin` from a sandboxed app is restricted. One suggestion is to let users download and install the tool themselves. — [Apple Developer Forums 130092](https://developer.apple.com/forums/thread/130092)
- **BBEdit (old, 2019–2020):** BBEdit 12.6 (Feb 2019) became sandboxed for the MAS. Its MAS edition did not include the command-line tools, "in order to comply with Apple's submission guidelines." Bare Bones offered separate installers for the tools for MAS customers. Later notes say BBEdit uses OS privilege-escalation support to install the CLI tools on 10.14.1+. — [BBEdit 12.6 release notes](https://barebones.com/support/bbedit/notes-12.6.html); [MacRumors 2019](https://www.macrumors.com/2019/04/04/bbedit-returns-to-mac-app-store); [512pixels 2019](https://512pixels.net/2019/04/bbedit-back-on-the-mac-app-store/). One forum poster claims BBEdit sandboxes only the main app and not its embedded tools (unverified). — [Apple Developer Forums 771117](https://developer.apple.com/forums/thread/771117)

### Inferences
- **Path budget.** `/Users/<user>/Library/Group Containers/<group-id>/c.sock` is 47 + len(user) + len(group-id) bytes. For `group.com.cacheplane.b4app` (26 characters) and a 12-character username that is about 85 bytes, under 104. A long username or a long group ID can still overflow it, so keep the socket name very short and fail clearly when the limit is hit. The sandboxed app's `$TMPDIR` is `~/Library/Containers/<bundle-id>/Data/tmp/...`, which is longer and riskier. The current "socket in $TMPDIR" choice should move to the group container root.
- **Recommended split:**
  - App ↔ coordinator: XPC with Mach name `<group-id>.coordinator`, or the group-container socket.
  - External CLI ↔ coordinator: the group-container Unix socket.
  - Use a Team-ID-prefixed group ID (`<TEAMID>.com.cacheplane.b4app`) or a profile-authorised iOS-style ID, so the sandboxed app and helper never prompt.
- **CLI distribution.** The `agent-workspace` CLI cannot usefully ship inside the MAS bundle as a Terminal-usable tool. It should be distributed separately (Homebrew or notarized pkg, unsandboxed) and connect to the group-container socket. Expect the CLI, and therefore its terminal, to get a TCC "access data from other apps" prompt on macOS 15+. Whether that prompt applies to `connect()` on a socket, as opposed to reading files, is not confirmed. Then the CLI must not spawn the coordinator itself; it can only ask the user to open the app, or launch it with `open -b`.
- **Trust check.** The sandboxed coordinator should verify the peer of every socket connection (`getpeereid`/`LOCAL_PEERPID` plus code-signing checks via `SecCode`), because the group container is reachable by unsandboxed same-user processes.
- **Mach names.** XPC via a Mach name in the app group works between sandboxed members. An unsandboxed CLI can look up any Mach name in the user session, but the sandboxed listener must still be launchd-registered, by a login item or by an agent plist with `MachServices`.

### Gaps
- No Apple source says whether macOS 15's group-container protection gates `connect()` on a Unix socket inside a group container for an unsandboxed process. The Jun 2024 success report predates Sequoia and used the app container, not a group container.
- I found nothing current (2025–2026) on how BBEdit, VS Code, or Sublime ship CLI tools with MAS editions. VS Code and Sublime are not on the MAS. BBEdit's MAS-era info dates from 2019.
- Whether a sandboxed listener needs `com.apple.security.network.server` for an AF_UNIX socket in its own container is unclear. The 2024 OP added both network entitlements but did not isolate which ones were needed.

## TestFlight for Mac: requirements beyond the sandbox

### Takeaway
TestFlight for Mac needs an App Store–distribution-signed, sandboxed build with a provisioning profile embedded in the main bundle. Each nested executable that claims restricted entitlements (iOS-style app group, keychain access groups, iCloud, and so on) needs its own App ID and profile. Profiles do not "piggyback". On macOS 15.1+, TestFlight builds get the same app-group container access as MAS builds.

### Cited Findings
- **DTS (documented):** a Mac app needs a profile only if it uses a restricted entitlement. But "to submit an app to TestFlight, it must have a provisioning profile." Nested executables that use only unrestricted entitlements (`app-sandbox`, `inherit`) need no profile. Otherwise nested code cannot "piggyback" off the app's profile and needs its own profile with its own unique App ID. — [Apple Developer Forums 733942: TestFlight, Provisioning Profiles, and the Mac App Store](https://developer.apple.com/forums/thread/733942)
- **Validation error (reported):** "Main bundles are expected to have provisioning profiles in order to be eligible for TestFlight." — [Apple Developer Forums 702892](https://developer.apple.com/forums/thread/702892)
- **WWDC21 "Meet TestFlight on Mac":** Xcode's automatic signing creates and embeds the profile; manual signing must add it explicitly. — [WWDC21 10170](https://developer.apple.com/wwdc21/10170)
- **Profile stripping (reported):** TestFlight or the App Store re-sign the app, and an embedded profile can be stripped or relocated at install. — [Apple Developer Forums 767609](https://developer.apple.com/forums/thread/767609)
- **App group IDs at submission (documented, DTS):**
  - Submission "checks that your app group IDs make sense", meaning they start with the Team ID or are assigned to the team.
  - Mac profiles for App IDs with App Groups automatically include `TEAM_ID.*`.
  - Since 21 Feb 2025, Mac profiles can authorise iOS-style `group.` IDs.
  - TestFlight builds on macOS 15.1+ get prompt-free group container access.

  — [Apple Developer Forums 721701](https://developer.apple.com/forums/thread/721701)
- **Sharing bundle IDs between Developer ID and App Store builds** caused a login item to bind to the wrong build (reported, DTS diagnosis). — [Apple Developer Forums 727785](https://developer.apple.com/forums/thread/727785)
- **MAS apps do not need notarization;** the App Store performs equivalent checks (DTS, 2024). — [Apple Developer Forums 745009](https://developer.apple.com/forums/thread/745009)

### Inferences
- **What b4app would need:**
  - A Mac App Store distribution certificate and "Mac App Store" profiles for the main app and for `B4AppCoordinator`. The coordinator needs its own App ID, because it claims a keychain access group and, if iOS-style, the app group, both restricted.
  - Distinct bundle IDs from the Developer ID builds (for example a `.mas` suffix, or keep D-051's Developer ID build on separate IDs) to avoid launchd/BTM confusion.
  - The login item at `Contents/Library/LoginItems`.
  - Every bundled binary, including any PostgreSQL binaries if kept, signed with `app-sandbox` (and `inherit` where spawned).
  - Upload via Xcode/Transporter/`altool`, consistent with D-051's iOS TestFlight flow.
- D-051's "data-protection keychain access group shared between app and coordinator" carries over. Keychain access groups are profile-authorised on macOS, so both bundles' MAS profiles must list the group.

### Gaps
- I found no Apple documentation specific to login items in TestFlight for Mac, such as whether `SMAppService` registration behaves differently for TestFlight-installed builds.
