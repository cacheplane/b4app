## 2026-11-17: Claude Code task tools, confirmed in the installed build

D-247's two fixes, which its own record left untested in the running app. The Local build was packaged from `main` 7f0482ff (Developer ID signed, not notarized), installed, and driven through its CLI on Claude Code 2.1.282 with the owner's plan sign-in. Real inference, at the owner's request.

### Live

- **The task tools, with nothing set by hand.** A thread with no folder, asked for a two-task list: the session had the tools, and the turn wrote one `taskList` item (Alpha in progress, Beta pending). On the build before D-247 the same request was answered with "no task list tool".
- **After `coordinator restart`, with no history read first.** A turn that updated both earlier tasks wrote its item live (Alpha completed, Beta in progress). On the build before D-247 this turn wrote none.
- **Reconcile.** `thread show --reconcile` left two items, one per turn.

### Untested

- The row in the app's window, at either density, and VoiceOver.
- `TodoWrite` live: 2.1.282 does not offer it.
- A failed task tool and a stopped turn.
