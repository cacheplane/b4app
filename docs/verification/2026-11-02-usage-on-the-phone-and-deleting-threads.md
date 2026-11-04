## 2026-11-02: Usage on the phone and deleting threads, on screen (D-118, D-119, D-120)

Run on the owner's MacBook Pro from main `ddc8db8`, after #46 and #51 merged.

**What was rebuilt**
- **The Compose hub.** `b4hub:local` was built from `Hub/Dockerfile` with the cached `rust:1.93.1` tag in place of the pinned digest, the same workaround the sign-in gate used. It was restarted with `docker compose up -d --no-build hub`. The hub's ledger shows migrations 1 to 11.
- **The Local app.** `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh` ran in a scratch checkout of `ddc8db8`, because `package.sh` clears `dist/`, which also held the prod app with a running coordinator.
  - Only `Agent Workspace (Local).app` was swapped into `~/repos/b4app/dist`, after the app was quit and its coordinator stopped.
  - The coordinator came up signed in to `blove@cacheplane`, with the relay connected and the store migrated (0007, 0008).
- **The phone.** The local-flavour iOS app (Debug) was installed over the existing app on the iPhone 17 Pro Simulator.
  - It came up at "Connect your Mac". The Mac's `hub.pair` links opened Safari's `/pair` page three times: this Debug build does not open the `local.b4.run` universal link.
  - So the phone paired through "Use an enrollment code" with the code `hub.pair` minted, pasted from the Simulator's pasteboard. It showed the Mac's 7 threads.

**Checks**

| Check | Result |
|---|---|
| Usage on the phone (D-118) | Pass. After `connection inspect` on Codex, the hub's `connectionUsage` row carried the weekly window (90%). The phone's Connections page drew the Codex card's Weekly meter at 90% with "Resets Tue 22:36", and no longer says "Usage shows on your Mac". Claude Code and the B4 cards read "Usage appears after the first turn" and "Token use appears after the first turn", as designed. |
| Delete on the Mac | Pass, through the coordinator's `thread.delete` (the command the Mac's menu and alert send) on a throwaway Codex thread. The Mac's list dropped it. The hub kept the row with `userDeletedAt` set and `deleted_at` null. The phone's list never showed it. Diagnostics' `threadDeletes` was `[]`: the Codex delete was answered. |
| Delete on the iPhone | Pass, on a second throwaway Codex thread. Swiping left showed Pin, Archive and a red Delete. Delete opened `Delete "Delete check (phone)"?` with "It's removed from this app and from Codex. You can't undo this.", Cancel and a red Delete, and the row stayed until Delete was tapped. Then the row left the phone at once. The hub row gained `userDeletedAt`, and the Mac's list dropped it. Diagnostics showed one Codex delete waiting, then `[]` within one sweep: the Mac deleted the runtime's copy after pulling the phone's mark. |

**Not checked**
- **The Mac's own Delete… menu and alert, clicked on screen.** That needs screen control of the owner's Mac. The alert is the same SwiftUI modifier the phone showed.
- **That Codex no longer holds the deleted threads.** Both throwaway threads had no turns, and Codex writes a thread to disk only after its first turn, so `thread/resume` answered "no rollout found" for either. A turn was not spent to prove it, because the owner's Codex weekly window was at 90%. Codex accepted `thread/delete`, and the coordinator recorded it as done.
- **Claude Code's transcript removal and B4's `DELETE`, live.** Both are fixture-tested only.
