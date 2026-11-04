## 2026-10-31

- **D-015 One `claude` process per native session, started on `createSession` and kept alive between turns.** The stream-json protocol has no session API: the CLI process is the session. Starting it at creation validates the executable, the `initialize` handshake, and sign-in before a thread row exists; `--session-id <uuid>` fixes the native id up front; after a coordinator restart the next turn spawns with `--resume <uuid>`.
