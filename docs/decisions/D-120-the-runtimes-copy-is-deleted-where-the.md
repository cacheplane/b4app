## 2026-11-02 (deleting threads)

- **D-120 The runtime's copy is deleted where the runtime can, and retried until it is.** The owner: "IF their api/cli supports deletion, we do it and honor it as best as we can."
  - **Per runtime.** Codex: `thread/delete { threadId }`. B4: `DELETE /threads/:id`. Claude Code has no delete command. Like the Claude desktop app, b4app removes the session's transcript `<sessionId>.jsonl` and its subagent folder `<sessionId>/` from the one project folder under `$CLAUDE_CONFIG_DIR/projects` (else `~/.claude/projects`; Claude's auth status names it when known). An id that isn't `^[A-Za-z0-9_-]+$` is refused, and nothing outside that session is touched.
  - **Outcomes.** These are recorded in a local-only table, `threadDeletes`:
    - **Done.** The runtime deleted it, or says it's gone; a B4 `404` counts.
    - **Unsupported, which is final.** Codex method-not-found, a B4 `405`, a disabled or missing connection, or a connection now signed in as another identity.
    - **Waiting.** Any thrown error. It is retried after 30 seconds, doubling to at most an hour, by a sweep at coordinator start and every 60 seconds.
  - **Running turns and the phone.** `thread.delete` answers as soon as the thread is marked and announced; the rest runs in the background, in the same step the sweep runs for a delete pulled from the phone. That step first interrupts a running turn through its adapter and waits up to 10 seconds. A turn still unresolved after that, or one already `reconciling` (say, after a restart), is ended locally as cancelled, so a deleted thread never stays in the Quit dialog or keeps its folder locked. Then the runtime's copy is deleted.
  - **Diagnostics** counts deletes waiting and not supported, by runtime, without thread titles.
