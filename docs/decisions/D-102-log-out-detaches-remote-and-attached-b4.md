## 2026-11-02 (sign-in build)

- **D-102 Log out detaches remote and attached B4 runs instead of cancelling them.** `SessionService.interruptLocalTurns`. Only Codex, Claude, and managed local B4 turns are interrupted. A remote or attached B4 run goes on on its server, as `workspace.stopLocalWork` already treats it, because the adapter rule forbids an implicit cancel of work on another server. The refusal still lists such runs (`local: false`), and the confirmation adds "1 remote B4 run keeps going on its server."; with only such runs the button reads "Log out".
