## 2026-10-31 (M5)

- **D-034 Wake is detected twice: `NSWorkspace.didWakeNotification` in the app and a clock-gap watcher in the coordinator.** `ContinuousClock` keeps counting while the Mac sleeps and `SuspendingClock` does not; a drift over 20 s between two five-second ticks means a wake and triggers `workspace.reconcile`, so a CLI-spawned coordinator with no app also reconciles. Reconciliation asks each runtime about each unresolved turn and re-checks offline connections; it never re-sends.
