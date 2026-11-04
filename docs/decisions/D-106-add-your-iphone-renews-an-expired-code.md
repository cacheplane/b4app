## 2026-11-02 (sign-in build)

- **D-106 Add your iPhone renews an expired code twice by itself, then waits for New code.** `PairingFlow.renewsExpiredCodes` (`Sources/WorkspaceUI/RemoteAccessView.swift`). The hub mints at most 10 codes per user an hour (D-078), so a sheet left open that renewed for ever would start to be refused; twice keeps a code on screen for about 15 minutes. The flow stops, drops its code, and renews nothing once the account changes.
