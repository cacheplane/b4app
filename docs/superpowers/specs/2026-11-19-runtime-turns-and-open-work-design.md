# Runtime turns and open work: design

Date: 2026-11-19. Follows the activity line (D-255). Evidence: `docs/verification/2026-11-19-live-sub-agent-recordings.md` and the seven fixtures it names.

## Why

The app assumes a turn begins when the owner sends a message and that a thread's work is over when that turn ends. The live recordings show neither holds:

- Claude Code 2.1.282 runs most sub-agents in the background. The turn's result comes while they work; their steps follow it.
- Claude Code then starts turns itself, with no user message, for each agent that hands back and for a background shell command that ends.
- A Codex sub-agent is a thread of its own and can outlive the parent's turn. Its steps arrive under a thread id the coordinator has no row for.

Today the result is: the agent's row closes as completed with a launch note as its output, the thread reads finished and the phone is told "Replied" while agents work, the late steps and the wake-up replies have no turn, and a Codex agent's steps are dropped.

## What the owner decided

- Approach B, in full: the runtime's own turns get turn rows, and work that outlasts a turn is a fact of its own, synced to the hub and the phone. Not approach A (holding the owner's turn open in the adapter).
- The reason: the owner can send a message while a background agent works, as in Claude Code itself.

Everything below this line is the controller's proposal unless marked as decided.

## Goals

1. A thread reads as working for as long as anything it started is working, on the Mac, the phone, the widget and the badge.
2. Every turn the runtime runs has a turn row, whoever started it.
3. An agent's row is running until the agent ends, and its steps stand under it whichever turn is active when they arrive.
4. The owner can send while background agents work, and can stop them when no turn is running.
5. One notification when the thread has something new and has come to rest; none while agents work.
6. Codex sub-agents are drawn like Claude's: one agent row, its steps under it.

## Non-goals

- The four earlier rough edges (the window cut in a large opened turn, the agent's prompt as its first block, durations after a reconcile, history linking from Claude's `subagents/` files). They are separate changes; this design leaves room for them and does not need them.
- Scheduled wake-ups, loops and monitors. They are expected to be runtime turns like the shell wake and to be covered by goal 2, but none was recorded.
- Codex `wake_on_agent_messages` (listed as under development, off). Goal 2 covers it if it ships as a `turn/started` nobody sent.
- B4. Its adapter showed no turn of this kind.

## Anti-goals

- A thread that says finished, or a "Replied" push, while an agent it started is working.
- A step drawn under the wrong agent or the wrong turn. Where a link is not exact, the step is drawn unlinked.
- A turn that can never end. Nothing here holds a turn open.

## Approaches considered

- **A. Hold the owner's turn open in the adapter until its agents end, folding the wake-up turns into it.** No store, hub or phone change, one turn per message. It blocks sending while an agent works, covers agents only (not the shell wake), and makes the app's turn disagree with the runtime's.
- **B. Runtime turns and open work (chosen by the owner).** Turn rows for the runtime's own turns, and a synced count of agents still running. Faithful to the runtime and lets the owner send in between. It touches the protocol, the coordinator store, the hub, the phone's mirror and the notification rule.
- **C. Drawing only.** The line shows running while an agent row has no end. The thread state and the push stay wrong. Rejected.
- **A mix** (A for agents, turn rows for other wakes) was offered and declined in favour of B.

## The model

### Open work

`Turn` gains `openWork: Int`, the number of agents this turn started that have not ended. It is 0 by default and decoded leniently (absent or null reads as 0).

- The session service is its only writer. It recounts when an agent item of the turn starts or ends: the turn's display items whose payload has `agent: true` and whose status is `inProgress`. It writes only when the number changes.
- It counts foreground agents too. While the turn runs that changes nothing, since a running turn is already working.
- Writing it moves the turn's `updatedAt`, on purpose: the line's duration then runs to the last agent's end, and the hub sees a fresh change.

`ThreadActivity` gains `openWork`, the sum over the thread's turns, decoded leniently. `Attention.state(of:)` gains one rule, placed after "latest outcome failed" and before "unread is finished": open work above zero is `working`. Approve, reply and failed still win.

### Runtime turns

A turn row the session service inserts when the runtime acknowledges a turn nobody sent:

- The trigger is a `turn.acknowledged` event whose payload says `origin: "runtime"`, on a known thread, with a native turn id that matches no row. The adapter sets it only for a turn it did not send. Without it the event is a sent turn's acknowledgement, as today.
- If the owner's own turn is still `submitting` when a runtime turn is acknowledged, both rows exist for a moment; events find their turn by native id, and the owner's turn is acknowledged by its own frame.
- The row has `operationId` `runtime:<nativeTurnId>` (the column is unique and required on the Mac and the phone), status `running`, submission `acknowledged`, and no user message.
- From there it is an ordinary turn: state changes, items, the finish, requests, sync and notification all follow the existing paths.
- A send is refused while a runtime turn is active, with the same `turn_active` refusal as any active turn. Between turns it is allowed.

No new event kind is needed. The Claude tracker makes a turn id and emits the acknowledgement for a wake-up turn (below). Codex's `turn/started` already becomes `turn.acknowledged`; the Codex adapter marks it `runtime` when it has no `turn/start` of its own outstanding or unacknowledged on that thread.

### An agent's life

An adapter-neutral contract, read by the session service and the transcript:

- An agent's item carries `agent: true` in its payload, and a `title`.
- It is `inProgress` from its start to the agent's real end. The adapter then completes it with status `completed`, `failed` or `stopped` (a new item status, for an agent killed by a stop) and its report as `output`. `stopped` is a payload string, like the other statuses; it is drawn with the unfinished mark and the word "Stopped".
- Every item the agent produces carries `parentNativeItemId` naming the agent's item, and the native turn id of the turn that started the agent, whichever turn is active when it arrives.

An agent's own messages are rows under it, in both runtimes, and its last text message is also its `output`.

Open agents are closed as `stopped`, and the count returns to 0, in three places: the adapter, when a session's process exits or the adapter itself restarts or drops the session (the Claude restart path reports no exit today, so it must emit the closes itself); and the coordinator at start-up, for open work on a thread with no live session.

## Claude Code

In `ClaudeTurnTracker`:

- **Launch note.** A tool result whose frame has `tool_use_result.isAsync` true does not close the Agent row. The call is recorded as an open agent, with the turn that started it.
- **End.** `task_notification` naming the call closes the row: `completed` → `completed`, `stopped` → `stopped`, anything else → `failed`. The output is the agent's last text message if one was sent, else the notification's `summary`. A notification for a call that is not an open agent (a shell task) produces nothing.
- **Foreground agents** close at their tool result, as today.
- **Late frames.** A frame with `parent_tool_use_id` takes its turn id from the open agent it names, not from the active turn. The tracker's record of an agent's uses, parents and turn is kept for the life of the session, not cleared at a turn's end or at the agent's: the stopped recording has child frames after the agent's notification. This also fixes the child result that lost its parent.
- **Whose turn.** A turn the owner sent opens with the replayed user frame carrying the uuid the adapter sent, and its first stream event and first assistant frame carry that uuid as `user_message_uuid`; later frames and the result do not. A wake-up turn has no replayed frame and its first frames carry no uuid (recorded). So a turn's owner is decided at its first top-level frame after `init`: the replayed frame or a frame naming the sent uuid makes it the sent turn; a first stream or assistant frame naming none makes it a runtime turn. The `init` frame's own event waits for that decision.
- **Runtime turns.** Decided that way, a runtime turn gets a new uuid and an acknowledgement marked `runtime`, then the held `turn.state_changed`. Its result finishes it. With no send outstanding, the decision is immediate at `init`.
- **Acknowledging a send.** Only the replayed frame or a frame naming its uuid, never a parented frame or a wake-up turn's.
- **A send that meets a wake-up turn.** How Claude Code orders the two was not recorded. The plan records it as the first step of the Claude change (it gates that change only, not the coordinator's); the rule above is built against that recording.
- **Stop.** The adapter gains `stopOpenWork(ref)`: for Claude, the same `interrupt` control request, which the recording shows kills a background agent and sends no result. The rows close through their `task_notification`.
- **A send that would restart the process** (changed directories, a cleared model or permission, entering bypass) is refused while the session has open agents, with reason `open_work` and a message naming what to do: wait, or stop the agents. A restart would kill them.

## Codex

In the Codex adapter:

- **The agent row.** A `subAgentActivity` item of kind `started` starts an agent item whose native id is `agent:<agentThreadId>`, with `agent: true` and the last part of `agentPath` as its title. The item of kind `completed` completes that same item; neither is a row of its own.
- **The child thread.** The adapter keeps, per agent thread id, the parent thread, the agent item and the root turn (`rootTurnId` on the child's `turn/started`). The child's `item/*` notifications are re-addressed: the parent's thread id, the root turn's id, and `parentNativeItemId` naming the agent item. The child's message deltas are dropped (an agent's text is not streamed, as with Claude), and its `turn/started` and `turn/completed` produce no turn event.
- **End.** The `completed` activity item closes the agent. A child `turn/completed` with `interrupted` or `failed` closes it as `stopped` or `failed` if it is still open.
- **The wait call.** `collabAgentToolCall` with `tool` `wait` is an ordinary step, titled "Wait for agents", no longer the agent.
- **Stop.** `stopOpenWork` sends `turn/interrupt` for each open child thread's turn.
- **A child whose parent is unknown** (no `started` activity seen) is dropped, as today, and logged.

## Coordinator

- Stop means the whole thread. `turn.interrupt` interrupts the active turn if there is one and calls `stopOpenWork` if the thread has open work; either alone is enough for it to proceed. With neither, it answers "No turn is active", as today.
- The event projection resolves an item's turn by its native turn id first, as today; the adapters now supply the right one for late items, so the "active turn" fallback is no longer reached by them.
- Reconcile at start-up closes open work as described above.

## Hub

- Migration `0023`: `ALTER TABLE "turns" ADD COLUMN "openWork" integer`. `"openWork"` joins the turn `TableSpec`.
- **Notification (open question for the owner, see the end).** The rule is by thread, not by turn: in the parallel recording the first wake-up turn completes while the other agent still works. A `failed` turn notifies regardless.
- **Bands and badge.** The same order as the Swift rule: a failed latest turn is `failed` and counts, open work or not; otherwise a thread with open work on any turn is `working` and is not counted as unread until it rests.
- Fixtures: `attention.json` gains threads with open work (latest turn completed and unread, completed and read, failed); `push.json` turns gain an `openWork` key and the suppressed case. Both suites are updated together.

## Coordinator store and phone

- Coordinator migration `0016`: `ALTER TABLE "turns" ADD COLUMN "openWork" integer NOT NULL DEFAULT 0`, unclocked (the Mac is its only writer). The change log carries it without further work.
- Mirror schema 11: `openWork INTEGER`, nullable, because an insert from an older Mac sets undeclared columns to null.
- `threadWithActivity` on the Mac (PostgreSQL) and the phone (SQLite) sums `openWork` into `ThreadActivity`.
- The widget and the notification backstop read the state through the same rule and need no change of their own.

## Transcript and composer

```
Find out why the sync is slow.                      (the owner's message)
◐ Agent: find the slow query          0:42  Show    (turn ended, agent still running)
I started an agent to look at the query. I'll report when it is back.

6 steps · 1m 12s                            Show    (the same line, once the agent ended)
I started an agent to look at the query. I'll report when it is back.
The page query sorts without the index; the fix is one line.     (the wake-up turn's answer)
```

- A terminal turn with open work draws its line as running: the mark turns, the running agent is named, the clock counts from the turn's start. When open work reaches zero the line shows its count and duration.
- While a turn has open work, every top-level message of it stays visible, as for a running turn.
- An agent row is running while its item is `inProgress` and its turn has open work, even though the turn is terminal. Its `inProgress` children are running too. Any other `inProgress` step of a terminal turn is still drawn as unfinished.
- A `stopped` agent is drawn as the existing stopped mark.
- A runtime turn is a group of its own with no message above it: its line if it did any work or is running, then its answer. A wake-up turn that only replies is just the reply.
- **Composer.** With no active turn the owner can send, whether or not there is open work. While there is open work and no active turn, a Stop control stands beside Send; it stops the agents. With an active turn the composer is as today.

## What is left to the builder

- The exact names (`openWork`, `stopOpenWork`, `stopped`), as long as the wire fixtures agree in both languages.
- Where the tracker keeps open agents, and how the Codex adapter keys its child threads.
- The Stop control's placement within the composer, following the existing Stop button's look.

## Order of work

Five changes, each shippable alone, in this order:

1. The field and the state rule: protocol, coordinator store, hub (migration, bands, notification rule, fixtures), mirror. Nothing writes the field yet.
2. Coordinator: runtime turn rows, the open-work count, stop with no turn, the start-up close.
3. Claude adapter, against the five Claude fixtures, plus the recording of a send that meets a wake-up turn.
4. Codex adapter, against the two Codex fixtures.
5. Transcript and composer.

## Tests the plan must hold

- The parallel recording, through the tracker and a session service with a store: three turn rows (one sent, two runtime), both agent rows running past the first result and completed at their notifications, every child under its agent and in the first turn, open work 2 → 1 → 0.
- The stopped recording: the agent row `stopped`, open work 0, no turn left active.
- The shell-wake recording: one runtime turn, no agent row, open work never above 0.
- The not-awaited Codex recording: the agent row running past the parent's `turn/completed`, its three items under it, completed at the activity item.
- Hub: the notification cases of whichever rule the owner picks, replayed from the parallel recording's order of changes.
- The stopped recording's child frames after the notification keep their parent and turn.
- A send that would restart Claude during open work is refused with `open_work`.
- A send during open work is accepted; a send during a runtime turn is refused with `turn_active`.
- An old Mac's turn insert (no `openWork`) applies on a schema-11 mirror and reads as 0.

## Open question for the owner: when the phone is told

While a thread has open work, a completed turn sends nothing. What ends the silence?

- **At rest (proposed).** One "Replied" when the thread comes to rest: its latest turn is completed and its open work is zero, whichever happens last. A Codex agent nobody waited for then notifies when it ends. For Claude, an agent's end is followed at once by a wake-up turn, so the tracker emits that turn's acknowledgement before the agent's close (it holds a `completed` notification's close until the next frame, two seconds at most); the hub then sees a running turn and waits for it. A stop by the owner sends nothing.
- **Next turn only.** Nothing is sent for open work ending; the next completed turn at rest notifies. Simpler, no holding in the tracker, but a Codex agent nobody waited for ends silently (the badge still counts it).

## Not known

- How Claude Code orders a user message that arrives while a wake-up turn is starting.
- Whether the app's own setting sources (`user,project,local`) change any recorded shape.
- Whether a Codex agent's thread appears in the sidebar through the thread listing.
- Codex with two agents, a nested agent, or a stop; a foreground Claude agent stopped mid-step.
