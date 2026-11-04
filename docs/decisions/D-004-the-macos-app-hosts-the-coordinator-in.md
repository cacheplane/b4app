## 2026-10-30

- **D-004 The macOS app hosts the coordinator in-process when none is running; the CLI spawns the standalone executable.** Both paths use the same library, lock, and socket, so GUI and CLI always share one coordinator. A LaunchAgent via `SMAppService` replaces in-process hosting in M6 when the bundle layout exists.
