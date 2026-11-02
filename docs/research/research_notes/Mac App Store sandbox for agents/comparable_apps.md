# How comparable macOS agent and coding GUIs are distributed and how they run agents (as of 2026-11-01)

Two kinds of evidence are used here:
- **Local inspection.** These are `codesign -d --entitlements`, `_MASReceipt` checks, bundle listings, and `strings` run on apps installed on the owner's Mac on 2026-11-01. They are cited as **[Local inspection]** and are primary evidence for the exact versions listed.
- **Web sources**, linked inline.

Anything not confirmed by either is marked UNCONFIRMED or listed under Gaps.

### Per-app fact table

| App | Version checked | Distribution | App Sandbox? | How it runs the agent | Auth source |
|---|---|---|---|---|---|
| **T3 Code** (pingdotgg) | not installed | GitHub Releases, Homebrew cask `t3-code`, winget/scoop, .deb, AUR, Nix, `npx t3@latest`, a hosted web app, and iOS/Android apps. No Mac App Store build. | Not checked (not installed). It is an Electron app outside the MAS, so almost certainly not sandboxed (UNCONFIRMED). | Drives the CLIs the user installed: `codex app-server` over JSON-RPC stdio, plus Claude, Cursor `agent`, Grok, OpenCode, and others | The user's own CLI logins (`codex login`, `claude auth login`, ...) |
| **ChatGPT for macOS** (now includes the former Codex app) | 26.1023.51421, bundle id `com.openai.codex` | Direct download from OpenAI (Developer ID, no MAS receipt) | **No.** `com.apple.security.app-sandbox` = `false` | Bundles its own `codex` binary (`Contents/Resources/codex-cli/bin/codex`, codex-cli 0.165.0-alpha.1.2) and its own `rg` | ChatGPT account |
| **Claude desktop** (Claude Code on desktop) | 4.4212.0 | Direct download (Developer ID, no MAS receipt) | **No** app-sandbox key. Has the `com.apple.security.virtualization` entitlement. | Downloads and manages its own Claude Code builds in `~/Library/Application Support/Claude/claude-code/<ver>` (2.1.308, 2.1.309) and `claude-code-vm/<ver>` | Claude account login in the app |
| **Xcode 26.x** | 26.6 | **Mac App Store** (has a `_MASReceipt`) | **No** app-sandbox key. Apple's own app holds dozens of `com.apple.private.*` entitlements that third parties cannot get. | Downloads its own "Claude Agent" and "Codex" through Settings > Intelligence > Get. Spawns `claude` with `--input-format=stream-json --output-format=stream-json` and Codex with `app-server`. | Separate login inside Xcode (OAuth or API key in Keychain). Overrides `CLAUDE_CONFIG_DIR` and `CODEX_HOME`. Enterprise config via `settings.json` / `config.toml`. |
| **Zed** | 1.26.2 | Direct download (no MAS receipt) | **No** app-sandbox key | Runs ACP adapters it installs itself: `@zed-industries/claude-agent-acp` (vendors a Claude Code CLI) and `codex-acp`. Ignores global installs; `CLAUDE_CODE_EXECUTABLE` can override. | The provider's own login |
| **Warp** | 0.2026.10.21 | Direct download (no MAS receipt) | **No** app-sandbox key | Terminal that spawns the user's own shells, and therefore any CLI on PATH. Its own agent is cloud-backed (UNCONFIRMED in this pass). | Warp account |
| **iTerm2** (comparison) | installed | Direct download | **No** | Spawns the user's login shell | n/a |
| **Conductor** (conductor.build) | not installed | Mac app, direct download (UNCONFIRMED) | Not checked | Runs Claude Code, Codex, and Cursor agents in parallel git worktrees | Reuses the user's existing Claude Code / Codex login (third-party source only) |
| **BBEdit** | not installed | **Both** the Mac App Store and direct download. It left the MAS in 2014 and returned in 2019 after becoming sandboxed in 12.6. | **Yes**, both editions sandboxed since 12.6 | n/a (editor). Precedent for one sandboxed codebase shipped two ways. | n/a |
| **Cursor, Windsurf, Nova, Sculptor, Crystal, Vibe Kanban** | not installed | Not verified in this pass (see Gaps) | Not verified | Not verified | Not verified |
| **Claudia / opcode** | not installed | Not verified | Not verified | Tauri 2 GUI for Claude Code that runs agents under Seatbelt (sandbox-exec) on macOS | User's Claude Code |

## Which apps are on the Mac App Store, which avoid it, and why?

### Takeaway
None of the third-party agent GUIs checked (T3 Code, ChatGPT/Codex, Claude desktop, Zed, Warp, Conductor) ships through the Mac App Store, and none of those inspected is App-Sandboxed. Two of them, ChatGPT/Codex and Claude, come from the agent vendors themselves. The only MAS app here that runs coding agents is Apple's own Xcode, and it is *not* sandboxed. That route is open to Apple's first-party software but not to third parties. No developer statement was found explaining the choice in sandbox terms.

### Cited Findings
- On 2026-11-01, ChatGPT.app 26.1023.51421 has bundle id `com.openai.codex` and team 2DC432GLL2. It has no `_MASReceipt` and an explicit `com.apple.security.app-sandbox = false`. Its entitlements include `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `automation.apple-events`, and `files.user-selected.read-write` — [Local inspection]
- OpenAI merged the standalone Codex desktop app into the ChatGPT desktop app for macOS on July 9, 2026. Chat, Work, and Codex share one window, and the old app became "ChatGPT Classic" — [Addigy support article](https://support.addigy.com/hc/en-us/articles/53439709931155-ChatGPT-and-Codex-Desktop-App-Merger-What-This-Means-for-Your-Fleet); [Daniel Vaughan blog](https://codex.danielvaughan.com/2026/07/17/codex-chatgpt-unified-desktop-app-cli-migration-codex-app-detection-workarounds/); [Daring Fireball](https://daringfireball.net/linked/2026/07/09/todays-the-day-openai-fucked-up-the-chatgpt-mac-app) (secondary sources; the local bundle id `com.openai.codex` on "ChatGPT.app" fits the merger)
- Claude.app 4.4212.0 (team Q6L2SF6YDW) has no `_MASReceipt` and no `app-sandbox` entitlement. Its entitlements include `cs.allow-jit`, `automation.apple-events`, `virtualization`, `device.usb`, and `device.bluetooth` — [Local inspection]
- Zed 1.26.2, Warp 0.2026.10.21, and iTerm2 have no `_MASReceipt` and no `app-sandbox` entitlement — [Local inspection]
- Xcode 26.6 has a `_MASReceipt`, so it is the MAS build. Its entitlements have no `com.apple.security.app-sandbox` key, and they include many private Apple entitlements, for example `com.apple.private.AuthorizationServices`, `com.apple.private.DTServiceHubClient`, and `com.apple.corespotlight.privateindex.unsandboxed` — [Local inspection]
- T3 Code's README lists GitHub Releases, `brew install --cask t3-code`, winget, scoop, .deb, AUR, Nix, and `npx t3@latest`, plus web and mobile apps. It does not mention the Mac App Store — [T3 Code GitHub](https://github.com/pingdotgg/t3code)
- BBEdit left the Mac App Store in 2014 "due to technical and business constraints." It became sandboxed in 12.6 in order to return, and it came back in 2019 — [MacRumors 2019](https://www.macrumors.com/2019/02/25/bbedit-app-sandboxing-mac-app-store-launch-coming); [9to5Mac 2019](https://9to5mac.com/2019/02/25/bbedit-12-6-sandboxing-mac-app-store/); [512 Pixels](https://512pixels.net/2019/04/bbedit-back-on-the-mac-app-store/)
- BBEdit says its MAS version has identical functionality to the direct version, but the MAS edition is subscription-only and needs a newer macOS (2019-era info) — [Barebones MAS FAQ](https://barebones.com/products/bbedit/appstore/faq.html) (summarized by search; a direct fetch of the FAQ returned 404)

### Inferences
- The vendors who control the agents (OpenAI, Anthropic) both chose direct, non-sandboxed distribution for the apps that run their own agents locally. Both apps also need JIT, Apple Events, and virtualization, or run child CLIs that touch arbitrary repos. This is strong precedent that a local-CLI-driving agent GUI does not fit the MAS sandbox.
- Xcode is not a precedent b4app can use. It is in the MAS without the sandbox and with private entitlements. Third-party MAS apps must be sandboxed.
- BBEdit shows the pattern of one sandboxed codebase shipped both through the MAS and directly. That works only because BBEdit could make its core features work under the sandbox.

### Gaps
- No public statement was found from Theo/ping.gg, OpenAI, Anthropic, Zed, Warp, or Conductor explaining why they avoid the MAS.
- Cursor and Windsurf were not installed and were not checked in this pass. From background knowledge (UNVERIFIED) both are VS Code-fork Electron apps sold by direct download, with their agents running in the editor's extension host against the vendor's cloud models.
- Nova (Panic): no result covered its MAS status in this pass.
- Sculptor (Imbue), Crystal, and Vibe Kanban: not researched, because of the time budget.

## For apps that run local agents: user's binary on PATH, bundled binary, or SDK? Where does auth come from?

### Takeaway
The approaches split three ways:
- **User's own CLI on PATH, with the user's own login.** T3 Code and Conductor do this, which is b4app's current model.
- **Vendor-managed bundled or downloaded copy.** ChatGPT/Codex bundles `codex` in the .app. Claude desktop downloads Claude Code into Application Support.
- **Host-managed private copy with its own config dir.** Xcode downloads its own Claude Agent and Codex and isolates them with `CLAUDE_CONFIG_DIR` and `CODEX_HOME`. Zed installs its own ACP adapters and ignores global installs.

Every approach still runs the native CLI protocol: Codex `app-server` JSON-RPC, Claude `stream-json`, or ACP. None reimplements the agent loop on raw provider APIs.

### Cited Findings
- **T3 Code** controls agents "set up on your computer." Each provider authenticates with its own CLI login (`codex login`, `claude auth login`, `agent login`, `grok login`, `opencode auth login`), and the README says it "works with your subscriptions" — [T3 Code GitHub](https://github.com/pingdotgg/t3code)
- T3 Code's server launches `codex app-server` over JSON-RPC on stdio, one per provider session. The Codex CLI must be on PATH and authenticated first. Its desktop build is Electron with an embedded server and a WebSocket UI — [Mintlify T3 Code docs](https://www.mintlify.com/pingdotgg/t3code); [Mintlify desktop guide](https://www.mintlify.com/pingdotgg/t3code/guides/desktop-app) (third-party-hosted docs; the provider list there is older and Codex-only)
- **ChatGPT/Codex app** bundles `Contents/Resources/codex-cli/bin/codex`, which reports `codex-cli 0.165.0-alpha.1.2`. It also bundles `codex-code-mode-host`, `codex-path/rg`, a `codex-package.json` (`"variant": "codex"`, `"target": "aarch64-apple-darwin"`), a `cua_node` helper, and `app.asar`, so it is Electron — [Local inspection]
- **Claude desktop** keeps versioned Claude Code builds in `~/Library/Application Support/Claude/claude-code/2.1.308` and `/2.1.309`, plus `claude-code-vm/2.1.309` — [Local inspection]
- Claude desktop "reads the same settings files as the CLI." It offers local, cloud (Anthropic-managed), and SSH sessions. For SSH it "installs Claude Code on the remote machine automatically," under `~/.claude/remote/` — [Claude Code desktop docs](https://code.claude.com/docs/en/desktop)
- **Xcode 26.3+** supports Anthropic's Claude Agent and OpenAI's Codex, announced in February 2026 and released 2026-02-26 — [Apple Newsroom](https://apple.com/newsroom/2026/02/xcode-26-point-3-unlocks-the-power-of-agentic-coding); [9to5Mac](https://9to5mac.com/2026/02/26/apple-releases-xcode-26-3-with-support-for-agentic-coding/)
- Anthropic says Xcode's Claude integration uses the Claude Agent SDK, "the same harness that powers Claude Code" — [SD Times](https://sdtimes.com/ai/xcode-26-3-adds-agentic-coding-support/); [AlternativeTo](https://alternativeto.net/news/2026/2/xcode-26-3-adds-agentic-coding-with-claude-agent-codex-and-other-ai-tools-via-mcp)
- In Xcode, agents are installed with Settings > Intelligence > Provider > "Get" and update automatically. Xcode 26.5 added "Enterprise Configuration" with `settings.json` (Claude Agent) and `config.toml` (Codex), for Bedrock, Vertex, or Foundry — [DEV Community](https://dev.to/arshtechpro/xcode-263-brings-agentic-coding-claude-and-codex-now-integrated-into-your-ide-1l5p); [Zenn (treastrain)](https://zenn.dev/treastrain/articles/bc9435a36fe498)
- Xcode 26.6's `IDEIntelligenceAgents.framework` contains these strings — [Local inspection, `strings`]:
  - `--input-format=stream-json`, `--output-format=stream-json`, `Found claude at path: %s`
  - `Set CLAUDE_CONFIG_DIR to UserDefaults override path`, `Override CODEX_HOME: %s`, `app-server`, `Please redownload Codex by going to Settings`
  - `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, `APPLE_CLAUDE_CODE_PROXY_PORT`, `ClaudeCodeGateway: Starting OAuth2 Authentication Flow`
  - Keychain-backed "Claude Agent API key" storage, and Codex `SandboxMode`/`SandboxPolicy` types
  - A separate `IDEIntelligenceACP.framework` exists
- **Zed** installs `codex-acp` on first use ("only available to Zed"), always uses that managed copy even when Codex is installed globally, and installs `@zed-industries/claude-agent-acp`, which vendors a Claude Code CLI. `CLAUDE_CODE_EXECUTABLE` overrides the binary — [Zed External Agents docs](https://zed.dev/docs/ai/external-agents); [Zed commit renaming the npm package](https://git.secluded.site/zed/commit/a0303351a8b624d67adf0ea674f46a5a853142a4)
- **Conductor** runs Claude Code, Codex, and Cursor agents in isolated git worktrees — [Conductor](https://www.conductor.build/workflows/run-parallel-codexes). It reuses the Claude Code / Codex login already on the machine and takes no API key — [codepick.dev](https://codepick.dev/en/guides/conductor-build-intro/) (third-party only)
- **Claudia** (a Tauri 2 GUI for Claude Code) runs agents under macOS Seatbelt — [FengNote/claudia fork](https://github.com/FengNote/claudia)

### Inferences
- Answer to "How does this work for T3?" T3 Code is architecturally almost identical to b4app: it spawns the user's own `codex app-server` and `claude` and relies on their existing logins. T3 sidesteps the sandbox question completely by shipping only outside the MAS: GitHub Releases, a Homebrew cask, and npx.
- Xcode shows that even a MAS app avoids the user's PATH binary and the user's `~/.claude` / `~/.codex` state. It downloads its own copy, points it at a private config dir with `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, and runs its own OAuth flow. The `APPLE_CLAUDE_CODE_PROXY_PORT` string suggests Xcode proxies the agent's traffic (UNCONFIRMED). That is the closest design to what a sandbox-friendly b4app would need. But Xcode itself is unsandboxed, so it does not prove the design works under App Sandbox.
- The `strings` "Found claude at path" plus "redownload Codex" suggest Xcode looks up its managed copies (UNCONFIRMED whether it would also pick up a PATH binary). The install directory was not found under `~/Library/Developer/Xcode` on this machine, probably because no agent has been installed here.

### Gaps
- The exact on-disk location of Xcode's downloaded Claude Agent and Codex binaries and config dirs was not found.
- Whether Claude desktop's local Code sessions run the downloaded binary directly or inside the `claude-code-vm` (Virtualization.framework) by default was not confirmed. The docs excerpt read did not say; the rest of the docs page was not read.
- Whether ChatGPT/Codex ever falls back to a user-installed `codex` was not confirmed.

## Does any MAS app execute user-installed command-line tools, and what limits apply?

### Takeaway
A sandboxed MAS app can spawn processes, but every child launched with `Process`/`posix_spawn`/`fork` inherits the parent's sandbox. So a user-installed `codex`/`claude`/`node` run from a MAS app would be confined to the app's container plus whatever files the user explicitly granted. It could not freely reach `~/.codex`, `~/.claude`, the repo tree, or the toolchain. Apple's suggested escape hatch is an unsandboxed helper reached over IPC, and whether App Review accepts that is unresolved. No MAS app was found that runs local coding-agent CLIs.

### Cited Findings
- A sandboxed process's children inherit its sandbox, even without `com.apple.security.inherit` — [Apple Developer Forums 678819](https://developer.apple.com/forums/thread/678819)
- `posix_spawn`, `fork`/`exec`, `NSTask`/`Process` all count as child launches. `NSWorkspace` launches give the target its own sandbox — [Apple Developer Forums 763498](https://developer.apple.com/forums/thread/763498)
- An inheriting child may carry only `app-sandbox` and `inherit`; any other sandbox entitlement aborts it. Inheritance carries static entitlements only, not dynamic grants such as PowerBox file access — [Apple archived "Enabling App Sandbox"](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) (archived doc; older)
- A developer building a PTY terminal for the MAS found that the spawned shell is sandboxed too. Suggested workarounds were an unsandboxed helper over IPC or a socket — [Apple Developer Forums 685544](https://developer.apple.com/forums/thread/685544)
- Whether an unsandboxed XPC service that launches children passes MAS review was left unresolved — [Apple Developer Forums 749725](https://developer.apple.com/forums/thread/749725)
- An app was rejected for requesting a temporary exception to control Terminal through Apple Events. The reviewer said this "won't be possible in a Mac App Store app," and the advice was to distribute outside the MAS — [Apple Developer Forums 9728](https://developer.apple.com/forums/thread/9728). App Review "takes a very dim view" of temporary-exception entitlements — [Apple Developer Forums 663311](https://developer.apple.com/forums/thread/663311)
- "You can't have a normal command-line app in the Mac App Store" — [Apple Developer Forums 92019](https://developer.apple.com/forums/thread/92019)
- A 2026 MAS app (SatRadar, in "terminal mode") hit App Sandbox limits for inter-app IPC:
  - A sandboxed app "can only create POSIX shared memory named `<app group id>/<name>`."
  - It "can only write inside its container."
  - It had to fall back to sending data through the pty.

  — [ghostty-org/ghostty #14744](https://github.com/ghostty-org/ghostty/issues/14744)

### Inferences
- For b4app, a MAS/TestFlight-for-Mac edition that keeps "spawn the user's installed `codex`/`claude`/`node`, bundled PostgreSQL, and a LaunchAgent coordinator" faces these limits:
  - The spawned CLIs would run sandboxed.
  - They could not read the user's `~/.codex` / `~/.claude` logins without user-granted access, and that access does not pass to children as a dynamic grant.
  - They could not run arbitrary build tools across the filesystem.
  - Installing a LaunchAgent from a sandboxed app is restricted to `SMAppService` login items inside the bundle (UNCONFIRMED here; not researched in this pass).
- The precedents point to direct, notarized distribution as the norm. That covers T3 Code, OpenAI, Anthropic, Zed, Warp, iTerm2, and Conductor (UNCONFIRMED for Conductor), and it matches b4app's current D-051 Developer ID plan.
- A MAS edition would probably need to become a "remote client" that talks to a non-MAS coordinator (like the iOS companion) rather than running agents itself. That is an inference, not a documented precedent.

### Gaps
- No MAS terminal emulator that runs a *local* unsandboxed shell was identified. MAS terminals known from background knowledge (Termius, Prompt, Secure ShellFish) are SSH clients (UNVERIFIED in this pass).
- How BBEdit's sandboxed edition runs Unix filters and shell worksheets was not confirmed (`NSUserUnixTask` / `~/Library/Application Scripts` is the documented Apple mechanism for user-installed scripts; not sourced here). The FAQ fetch returned 404.
- No App Review guideline text was fetched directly; the findings above rely on Developer Forums threads.
