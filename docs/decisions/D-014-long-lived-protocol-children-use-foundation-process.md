## 2026-10-30

- **D-014 Long-lived protocol children use Foundation `Process` (`StreamingProcess`), one-shot commands use swift-subprocess (`CommandRunner`).** swift-subprocess scopes stdin and stdout to a closure, which does not fit a server that outlives any one call. `StreamingProcess` ignores SIGPIPE process-wide so a write to a dead child is an error, not a crash.
