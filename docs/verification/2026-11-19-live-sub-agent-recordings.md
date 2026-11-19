## 2026-11-19: live sub-agent recordings, Claude Code and Codex

What the activity line (D-255) meets from the real runtimes. Seven turns were run by the controller with the owner's logins, outside the test suite (which stays fixture-only), in a scratch folder holding two small Swift files. Claude Code 2.1.282 was driven with the adapter's launch arguments except `--setting-sources project`; codex-cli 0.166.0 through `codex app-server` with the adapter's `initialize`, `thread/start` and `turn/start`. Nothing in the app was changed.

### Recorded

- `Tests/ClaudeAdapterTests/Fixtures/subagent-foreground-text.jsonl` (44 frames): one agent asked to write text between its tools.
- `Tests/ClaudeAdapterTests/Fixtures/subagent-background-parallel.jsonl` (80 frames): two agents started in one message, kept open through three results.
- `Tests/ClaudeAdapterTests/Fixtures/subagent-nested.jsonl` (44 frames): an agent that starts an agent.
- `Tests/ClaudeAdapterTests/Fixtures/subagent-background-stopped.jsonl` (53 frames): an interrupt sent while a background agent worked.
- `Tests/ClaudeAdapterTests/Fixtures/background-shell-wake.jsonl` (36 frames): a shell command run in the background, no agent.
- `Tests/CodexAdapterTests/Fixtures/subagent-run.jsonl` (30 notifications): one Codex sub-agent the parent waits for.
- `Tests/CodexAdapterTests/Fixtures/subagent-not-awaited.jsonl` (24 notifications): one the parent does not wait for.

The scrub replaced the folder with `/work/proj` and the task output folder with `/work/tasks`, the session id with `session-1`, cut the `init` frame to eight fields, the result to fourteen, and dropped signatures, thinking text, usage, the `initialize` answer, rate-limit and lifecycle frames, and every Codex notification but thread, turn and item ones. A search for the owner's name, home paths, email addresses, organisation and account fields found none. `ClaudeSubAgentRecordingTests` and `CodexSubAgentRecordingTests` hold the shapes below.

### What Claude Code sends

- An agent runs in the foreground only when the call says `run_in_background: false`. The two runs that left the field out ran in the background, the single-agent stop run among them.
- A background agent's call gets its result at once, the text `Async agent launched successfully…`. The turn's `result` frame comes while the agent works. Its steps, text and thinking follow that frame, each naming the call. Its end is `task_updated` (with `end_time`) and `task_notification` naming the call; no second tool result is sent.
- Claude Code then starts a turn itself for each hand-back: an `init` frame, a reply, a `result`, and no user frame. The parallel run ended with three results for one message. The sent turn's result carries `user_message_uuid`; each wake-up turn's carries `origin` with `kind` `task-notification` and no uuid.
- A foreground agent's text and thinking are not sent; only its prompt, tool uses and results. A background agent's are.
- An agent started by an agent names the first agent's call. The inner agent's own steps are not sent.
- An interrupt after the turn's result kills the background agent (`task_updated` `killed`, `task_notification` `stopped`) and sends no `result`.
- A background shell command that ends after the turn wakes Claude Code the same way: `task_notification`, an `init` frame, a reply and a second `result`. The turns it starts itself are not only for agents.
- `task_started` carries the agent's full prompt, `is_backgrounded` and `spawn_depth`.
- On disk the main transcript holds no agent step. Each agent has `<session>/subagents/agent-<id>.jsonl`, every line stamped with a time, and `agent-<id>.meta.json` with `toolUseId`, `spawnDepth`, `parentAgentId` for a nested one and `stoppedByUser`. The inner agent's steps are there too.

### What the adapter and the session service do with it (read by replaying the recordings through `ClaudeTurnTracker`, and from `SessionService.environment`)

- The background agent's row closes as completed with the launch note as its output, while the agent works.
- Every event after the turn's `result` carries no turn id; the session service stores those items with no turn, and the transcript draws them in the group of the item before. The thread's state is finished throughout.
- The turns Claude Code starts itself have no turn row: no running line, no duration, no finished state of their own, and their `turn.finished` changes no row.
- One child result that arrived after the `result` frame lost its parent (`tool.completed` for the first agent's `wc`), since the tracker's uses are cleared at the turn's end.
- Not run in the app: these are read from a replay and the code, not seen on screen.

### What Codex sends

- The sub-agent is a thread of its own. The parent thread gets two `subAgentActivity` items (`kind` `started` and `completed`, `agentThreadId`, `agentPath`, `startedAtMs`) and one `collabAgentToolCall` whose `tool` is `wait` and whose `prompt` is null.
- The agent's messages and commands are `item/*` notifications on the agent's thread id, inside its own `turn/started` and `turn/completed`.
- When the parent does not wait, its turn completes while the agent works (31 seconds longer in the recording). The agent's turn names the parent's as `rootTurnId`. The `completed` activity item then arrives on the parent thread, naming the turn that already ended. No turn is started on the parent thread afterwards (`wake_on_agent_messages` is listed as under development and off).
- The app knows no `subAgentActivity` type, and draws the wait call as the agent (D-255 took its title from a prompt it does not carry). Items of a thread the coordinator has no row for are dropped, so the agent's steps are not drawn. Whether the agent's thread later appears in the sidebar through the thread listing was not checked.

### Not checked

- Any of this on screen in the running app.
- A foreground agent stopped mid-step (the stop run went to the background).
- Codex with two agents, a nested agent, or a stop.
- Whether `--setting-sources user,project,local` (the app's own) changes any of it.
