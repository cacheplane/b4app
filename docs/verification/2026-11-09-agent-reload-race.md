## 2026-11-09: The app's LaunchAgent repair waits for the old job to leave (D-042)

Found while moving the Local app from a worktree's `dist/` to `/Applications`: `Agent Workspace --register-agent` rewrote `~/Library/LaunchAgents/com.cacheplane.b4app.local.coordinator.plist` to the new program but answered `failed(...)`, and launchd no longer listed the job, so no coordinator ran until it was bootstrapped by hand. The same "Bootstrap failed: 5: Input/output error" came twice that day from a `launchctl bootout` followed a couple of seconds later by `bootstrap`; a bootstrap a few seconds after that succeeded each time.

**Cause.** `LaunchAgentControl.install` ran `bootout` and then `bootstrap` at once. `bootout` returns while the old coordinator is still stopping (it shuts its PostgreSQL down in order), launchd keeps listing the job until it has, and a bootstrap sent meanwhile is refused with 5. The plist was already rewritten, so the app saw a failure and the agent stayed unloaded.

**Fix.** After `bootout`, `install` polls `launchctl print` until the job is gone (every 200 ms, at most 30 s), then bootstraps; past the limit it bootstraps anyway and reports launchd's answer. `launchctl` is injected as `LegacyAdoption.Launchctl`, the seam the legacy boot-out already uses.

| Check | Result |
| --- | --- |
| A job still listed for three `print`s after `bootout` | Pass (`LaunchAgentInstallTests.installWaitsForTheOldJobToLeaveBeforeBootstrap`): bootstrap only after the job is gone. Without the wait the test fails with the same "Bootstrap failed: 5". |
| A job that never leaves | Pass (`aJobThatNeverLeavesReportsTheRefusal`): bootstrap is tried after the limit and launchd's refusal is reported. |
| Live, the failing case again | Pass. The Local agent was pointed at the worktree's copy and loaded (stale), the fixed build copied to `/Applications`, and `/Applications/Agent Workspace (Local).app/Contents/MacOS/Agent Workspace --register-agent` answered `agent: enabled` in 1.7 s with the job running the `/Applications` coordinator. The app then reconnected to the Compose hub (`/v1/me` 200, relay link open). |
