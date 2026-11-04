## 2026-11-01: Coordinator robustness (D-052)

- `HubSyncTests.aKeychainPromptIsReportedAndTheTokenIsReadOncePerRun`: with the secret store's read held open (an unanswered prompt), `hub status` answers and names the Keychain wait; after release the push drains and later pushes and the pull reuse the one read.
- `KeychainCallTests`: a Keychain call made from the main actor runs off it, and its error reaches the caller.
- `PostgresServerTests.replacesAPostmasterFromAnotherInstall` and `aPostmasterRunningAnotherBinaryIsNotThisInstalls`: a server whose binary was written after it started, or that runs another file, is stopped and replaced; this install's own server is still adopted.
- `ReasonLineTimeTests`: a reply up to a minute old, or a few seconds in the future, reads "Replied just now".
- Manual, scratch coordinator with the fake Codex: `turn send <id> please hang around --no-wait` returned in 0.05 s and the stored message was "please hang around".
