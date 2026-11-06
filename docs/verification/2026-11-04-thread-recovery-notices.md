## 2026-11-04: Archived Codex recovery and single thread notices

The running local app showed both a continuity card and an error card for the same failed Codex resume, with a clipped explanation and a Dismiss link misaligned with the recovery pill. The native session was still present in Codex's archived sessions. A direct `thread/resume` against the installed Codex 0.166.0 reproduced `-32600` with an explicit `codex unarchive <id>` instruction. No live inference ran, no session was unarchived, and no user message was re-sent.

The adapter now distinguishes an archived session, missing thread history, and unrelated resume failures. Explicit checks repair a missing state saved by the old classification and surface recovery failures instead of silently clearing them. The UI reads the coordinator's nested native cause, keeps an archived refusal's draft, and suppresses only errors already explained by the persistent continuity card. The notice shows its explanation once, diagnostic details behind disclosure, and controls on their own aligned row. The row stacks when needed; the scrollable approval region reserves room for continuity controls in the smallest window.

Regression evidence:

- Adapter and remediation regressions first failed with nine assertions: archived and unrelated RPC errors became missing sessions, and archived recovery had no Check again action. They passed after narrowing the mapping.
- Coordinator/model regressions reproduced stale missing continuity, swallowed explicit checks, and nested turn-error details. A further test through the actual `perform(.checkAgain)` button path caught its unconditional dismissal after a failed check; it and an unrelated permission failure first failed with seven assertions.
- Final coordinator/model checks cover repeated unsuccessful recovery, replacing the obsolete missing state, preserving the cached message and draft, and clearing the notice after a simulated external unarchive. The turn count does not increase during checks. These final checks passed in the full suite.
- Real SwiftUI notices rendered at 340 and 640 points, in light and dark. Inspected all four renders; the full explanation wraps above an aligned Check again/Dismiss row. Minimum-window tests first caught the added recovery row overflowing with a long approval request; reserving that row's space in the already scrollable request region fixed the measurements.

Validation:

- Final macOS and iOS Simulator `xcodebuild build` commands passed.
- Strict recursive Swift formatting passed.
- `swift test`: 1,408 tests in 171 suites passed (111.584 s); provider live tests stayed opt-in.
- `swift build`: passed, covering the libraries, coordinator, and CLI.
- `Scripts/docs-index.sh --check` and `git diff --check`: passed.

At the initial code-verification gate the running installed app had not been replaced. Visual renders use the production SwiftUI view; successful unarchive recovery uses the fake Codex runtime and is not claimed as a live integration check.

### Local installation and live UI check

At the owner's subsequent request, packaged the local Release-Local app with the existing Developer ID, local app/coordinator provisioning profiles, and unchanged Keychain-sharing entitlements. Notarization was skipped for this local test package. The signed package passed deep/strict signature verification, and both installed executables matched the package by SHA-256.

Replaced the previously running local bundle in `vigorous-benz-64f0ac/dist/`, retaining its prior bundle in `.b4app-update-6ga1kiab/Previous.app`. Restarted the app and its background coordinator. The installed coordinator helper, pid 70612, answered on the local socket. The prod and beta app/coordinator processes were left running; the research B4 server kept pid 30391 and ready health.

On screen in the installed app, opened the affected testing chat and clicked Check again. The old missing-session card disappeared, and exactly one archived-session notice appeared with the complete unarchive instruction, a Details disclosure, and aligned Check again/Dismiss controls beneath it. Its existing draft remained. No message was sent and the native session was not unarchived. Left testing open after the final background-agent handoff.
