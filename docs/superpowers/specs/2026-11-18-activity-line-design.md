# The activity line: design

Date: 2026-11-18. Second of the two designs for the transcript; the first is
`2026-11-17-streaming-text-foundation-design.md` (D-252), which this one builds on.

## Intent

The owner's words: "collapsed tool/subagent/activity work that is not distracting, is summarized to
a single line, and clearly indicates that the agent is still working." And, on the two densities:
"Let's remove dense from influencing the chat UI, and let's not have multiple view options. I want
dense as the default. When you expand, this is where drawing and showing progress is necessary." On
the cards normal density draws for each tool: "remove the single cards, its noise and big and
unnecessary."

So there is one transcript. A turn's work is one quiet line. Opening the line is where the work is
drawn: one row per step, a sub-agent as a line of its own that opens the same way, and a step's
output one level further in.

The owner approved a clickable mockup of this on 2026-11-18 ("looks right"). It is kept, uncommitted,
at `.superpowers/brainstorm/20990-1795024005/content/activity-line.html`; the sketches below are it
in text.

## What exists today

- `DenseTranscript` (`Sources/WorkspaceUI/DenseTranscript.swift`) projects a thread's `DisplayItem`
  and `Turn` rows into entries. `build` is the dense projection (D-223): message, one steps line,
  answer. `plain` is normal density: every item in order, each tool a `ToolCard`, plus a running
  line (D-239).
- The dense steps line names the newest in-progress step while the turn runs and counts when it
  ends. It has no working mark and no time.
- `TranscriptView` takes `dense: Bool` from `WorkspaceModel.denseThread`, which reads the synced
  density setting.
- Sub-agents have no presentation. Claude Code sends each sub-agent frame with
  `parent_tool_use_id`; `ClaudeEvents` uses it only to keep a sub-agent's task tools out of the
  session's list, and writes every other sub-agent frame (tool uses, text, thinking) as an ordinary
  item of the turn. Codex's `collabAgentToolCall` is one counted step.
- A `DisplayItem` has `createdAt` and no end time. A `Turn` has `createdAt` and `updatedAt`.

## Goals

1. One transcript on the Mac and the phone. The density setting no longer changes it.
2. A turn's work is one line. Closed, it is the only thing drawn for the work.
3. While the turn runs, the line shows that it is running at a glance: a turning mark, what is open,
   and a clock.
4. Opened, each step is one row with its own state. A sub-agent is a row that opens to its own
   steps. A step opens to its output.
5. No tool cards anywhere.

## Non-goals

- Announcing changes to VoiceOver (the hill climb's defect 9). Rows still carry labels.
- The failed step's name or reason on the closed line.
- Command output while a command runs (Codex's output deltas are still dropped).
- Durations for steps read from history.
- The thread list and the composer: the density setting keeps doing what it does there.
- Syntax colouring in output.

## Anti-goals

- A count that ticks up while the turn runs (D-223's research: it says nothing about what the agent
  is doing).
- Anything moving, or reading as running, on a turn that is not running.
- The closed line changing height or wrapping.
- A sub-agent's messages drawn as if they were the agent's reply to the owner.
- A token arriving re-running the projection (the streaming foundation's rule; its test stays).

## Approaches

Where the two missing facts (a step's parent, a step's end) come from:

1. **Views only.** One projection and the new rows; sub-agent steps stay flat; no step durations.
   No adapter, store or sync change. Ships the look, not sub-agents.
2. **Fields in the item's payload (chosen).** The adapter writes the parent call's native id into a
   sub-agent item's payload, and the session service stamps an end time when a step completes. The
   payload is JSON that already syncs, so there is no migration and no hub deploy, and the phone
   gets both.
3. **Columns on the item.** A parent column and an end column: migrations on the coordinator, the
   hub and the mirror, a hub deploy, and the sync fixtures in both languages. Queryable, and nothing
   queries it.

The owner approved the look and left the how; 2 is the writer's pick, built in the order of 1 first.
Old threads have neither field: their sub-agent steps stay flat and their steps show no duration.

## The design

### One transcript

- `TranscriptView`, `TranscriptContent` and everything under them lose `dense`. `DenseTranscript.plain`
  and `WorkspaceModel.denseThread` are deleted. `ToolCard` is deleted, and `CollapsibleCard` with it
  if nothing else uses it. `RunningLineRow` and `StepsLineRow` become one row.
- The density setting stays in `ViewSettings` and keeps driving the Mac's sidebar rows
  (`tightQuietRows`) and composer (`denseComposer`). On the Mac the switch's description drops the
  thread clause: "Tighter rows for the threads that don't need you, and a composer without its
  pickers." On the phone the switch now does nothing, so it is removed there; the Display page goes
  from the phone's page list since it holds nothing else.
- The setting's default stays `normal`. The owner's "dense as the default" is read as the
  transcript's form, which is now the only one; the sidebar and composer do not change for anyone
  (the writer's call, for the owner to correct).
- The name `DenseTranscript` no longer says what it is. Renaming it is left to the builder, as a
  mechanical last step if at all.

### The line

One row per turn, after the user's message and before the turn's messages (D-223 call 9), one line
high, muted small type, cut at its tail.

```
running    ◌ swift test --filter SyncTests                      0:42  Show
no step    ◌ Working                                            0:03
waiting      Waiting for you                                    1:10  Show
stopping   ◌ Stopping                                           1:15  Show
ended        6 steps, 1 failed · 1m 12s                               Show
```

- **Words while running.** D-223 call 1 unchanged: the newest in-progress counted step's name, cut
  at 120 characters; "Working" when none is open; "Waiting for you" when the turn waits for the
  owner; and new, "Stopping" when the turn's status is `stopping`. The step named is a top-level
  one: when a sub-agent is open the line names the sub-agent, not the step inside it, so several
  sub-agents working at once do not make the line jump between their steps.
- **The mark.** `ThreadMark`'s working mark at the line's start for `submitting`, `running` and
  `stopping`. None for "Waiting for you" (the request below is what asks; D-239). It is still under
  Reduce Motion, as it already is.
- **The clock.** Time since the turn's `createdAt`, as `m:ss` (`h:mm:ss` past an hour), updated once
  a second by the row alone (a `TimelineView` or its like inside the row; the transcript and the
  projection do not re-run for it). The clock still counts under Reduce Motion: it is text.
- **Always there while the turn runs.** A running turn has the line from the moment the turn exists,
  whether or not there is anything to fold and whether or not a reply is streaming. This replaces
  D-239's "only where neither exists" and D-246's rule about a list with no step in progress: the
  line is the one place that says the turn is running. `Show` is drawn only when there is something
  to open.
- **Ended.** D-223's words (`4 steps`, `1 step`, `4 steps, 1 failed`, `… 1 declined`, `Show working`)
  with ` · ` and the turn's duration after a count. Only "N failed" is in the danger colour. No
  mark, no clock. A turn that ended with nothing to fold has no line, as today. A sub-agent call is
  one step in the count; the steps inside it are not counted on the turn's line.
- **Durations** are written `8s`, `48s`, `1m 12s`, `1h 4m`. Under a second is `1s`. The turn's is
  `updatedAt − createdAt` once it is terminal. `WorkspaceDatabase.updateTurn` sets `updatedAt` on
  every change, so the builder audits every caller that can change a terminal turn. If none does,
  `updatedAt` is the end. If one does, the end is instead the latest time among the turn's items
  (`endedAt` where present, else `createdAt`), which can read a little short; no column is added
  for it (the writer's call). A turn with no usable end has no duration.
- A turn whose outcome is unknown (`reconciling`) is drawn as ended, without a duration (D-223
  call 8). A history group (no turn) has a count and no duration.
- While the turn runs its messages and its plan row are drawn after the line (D-223 call 2, D-243),
  and fold when it ends. Unchanged.

### Opened: step rows

Opening the line draws the turn's folded items after it, in sequence order, indented under a thin
rule on the left.

```
◌ Agent: find the slow query                                    0:42  Hide
│ ✓ Read Sources/Coordinator/HubSync/Push.swift                   1s
│ ✓ rg "hubSeq" Sources                                           2s
│ ◌ Agent: find the slow query · 3 steps                        0:31  Hide
│ │ ✓ Read Hub/crates/b4hub-db/src/changes.rs                     1s
│ │ ✓ rg "ORDER BY hub_seq"                                       1s
│ │ ◌ cargo test changes::pull_pages                            0:24
│ ✕ swift test --filter SyncTests                                18s
```

- **A step row** is one line: a mark, the title (`DenseTranscript.title(of:)`, mono for a command or
  a path as the card's title is today, cut at its tail), and the time at the right.
  - Marks: a check for `completed`; the working mark for `inProgress` in a running turn; a cross in
    the danger colour, with the title in it, for `failed`; a muted dash for `declined`, and for a
    step left open by a turn that is no longer running (D-223 call 5, D-234).
  - Time: a running step counts from its `createdAt` like the line's clock; a finished one shows
    its duration when the payload has `endedAt`; otherwise nothing.
- **A step's output.** Pressing the row draws what `ToolCard` draws in its body today
  (`ToolEvidence.detail`: working directory, input, output, exit code, changes and diffs, the raw
  cut), under the row, indented, with no border or card. Copy stays wherever it is today. A step
  with nothing to show (no input, output, change or raw text) is not a control.
- **The other folded items** stand where they were written: an interim message as its text, drawn
  by the markdown views; reasoning as a one-line row reading "Thought" that opens to its text; a
  plan row as `TaskListRow`; any other working row as a step row with no time.
- **Open state** lives in `TranscriptFolds`, which already holds the open turns: it now holds open
  ids at every level (turn group, sub-agent item, step item), reset when another thread is shown.
  Nothing is stored. Opening or closing at any level holds the view as D-223 call 7 does. No
  animation, as today.
- **Accessibility.** Each row is one element: its state in words, then its title, then its time
  ("Running, swift test, 24 seconds"). An openable row is a button whose value is expanded or
  collapsed.

### Sub-agents

- **The field.** An item written for a sub-agent frame carries `payload.parentNativeItemId`: the
  native id of the tool call that started the sub-agent. The projection makes an item a child of
  the item in the same thread whose `nativeItemId` equals it. A child whose parent is not among the
  thread's items is drawn where it stands, as today.
- **Claude Code.** Every item `ClaudeEvents` writes from a frame with a non-null
  `parent_tool_use_id` (tool use, tool result, text, thinking) gets the field. A sub-agent's text
  and thinking are therefore inside the sub-agent row and are never the turn's answer or an interim
  message of the turn. A completed write replaces an item's whole payload
  (`WorkspaceDatabase.upsertDisplayItem`), so the adapter keeps the parent id with its per-tool
  state and writes it on every write of that item: started, completed, failed and declined. The
  session service does not merge old payload fields into a new write. A sub-agent's streamed text deltas are not sent to `MessageStreamStore` as a
  reply; the builder decides whether they are dropped until the completed item or streamed into the
  child row, the first being acceptable.
- **The row.** A step row whose title is `Agent: <description>` (the call's `input.description`;
  "Agent" alone without one) followed by ` · N steps` counting its counted children, with `Show` when
  it has children. Its mark and time are the call's own. Opened, its children are drawn as step
  rows one level in, then the call's own output (the sub-agent's result) as a step's output is. A
  sub-agent inside a sub-agent nests the same way; past four levels children are drawn at the
  fourth.
- **Which calls are sub-agents.** Any item with children is drawn as a sub-agent row. A Claude Code
  tool use named `Task` or `Agent`, and Codex's `collabAgentToolCall`, get the `Agent:` title even
  with no children. Codex reports nothing inside a sub-agent, so there the row has nothing to open
  but its own output. B4 has no sub-agent event and is unchanged.
- **History and reconcile.** Claude Code keeps a sub-agent's lines in the session's sub-agent
  folder, not in the session's transcript, and the history import does not read them. So a thread
  read only from history shows the sub-agent call with no children. The builder must confirm with a
  test that a reconcile after a live turn keeps the live child rows in place (D-243's merge rule
  for live rows history does not name) and neither drops nor duplicates them.
- **Not observed.** No fixture sends sub-agent frames (defect 11), and their shape here is read from
  the adapter and Claude Code's stream format, not from a run. The plan must start the Claude Code
  part by recording a real run with one sub-agent (`B4APP_LIVE_CLAUDE`, opt-in) and building the
  fixture from it; if the shape differs from the above, the builder follows the recording and
  records the difference. That includes whether the partial `stream_event` frames carry the parent
  id: if they do not, a child's started row has no parent until its completed frame, and the row is
  held back until then rather than drawn at the top level and moved. The recording blocks part 3
  only; parts 1, 2 and 4 do not wait for it. If no recording can be made, part 3 is not built on
  the guessed shape.

### The end time

`SessionService` adds `endedAt` (a `Timestamp`) to an item's payload when it writes the item for a
`.toolCompleted` event, in the one place tool items are written (`environmentItem`). The completed
write replaces the payload, and the stamp is part of that write. The row's `createdAt` is kept by
`upsertDisplayItem`, so it is the start. A reconcile keeps a live row's payload
(`mergeSnapshotItems` rewrites only snapshot rows), so the stamp and the parent field survive one; a
test pins that. Items imported from history get no `endedAt`.

### Order of building

1. One transcript: the projection, the line with its mark and clock, step rows, output under a
   step, the density setting's retreat, the cards deleted. Views and projection only.
2. `endedAt` and step durations.
3. The Claude Code recording and fixture, the parent field, the tree, the sub-agent row.
4. The `Agent:` title for Codex's call.

Each is shippable alone.

## Testing

- **Projection** (`DenseTranscriptTests`, extended): the tree from parent fields; an orphan child; a
  child in another turn than its parent (drawn under the parent); nesting past the cap; the
  sub-agent's text never chosen as the answer; counts that leave children out; every line-word case
  in a table, including "Stopping" and a running turn with only a streaming reply.
- **Formatting**: clock and duration strings at the boundaries (0, 59 s, 60 s, 3,599 s, an hour).
- **Views** (hosted, as `DenseTranscriptViewTests`): opening a turn, a sub-agent and a step each
  hold the view; a closed running line is one line high at the narrowest phone width; the clock's
  tick does not re-run the projection (the existing projection counter); nothing animates on an
  ended turn.
- **Normal density's tests**: about thirty uses of `plain` and the `dense:` parameter across the
  suites. Cases that pin behaviour both densities shared (scroll, the window of rows, streaming) are
  kept against the one transcript; cases that pin normal density's own drawing are deleted with it.
- **Adapters and coordinator**: the Claude Code fixture for the parent field, live and through a
  reconcile; a session test for `endedAt`. The sync fixtures are untouched: the payload is opaque
  to them.
- **Captures**: the running line, an opened turn with a sub-agent, an opened step, the ended line,
  light and dark, Mac and phone, replacing the normal-density captures.
- **Not coverable here**: the mark's motion and the clock in the running app, VoiceOver, a phone in
  the hand, and a live Codex sub-agent.

## Records

A new decision amends D-223 (dense is the transcript; the line's time), D-239 and D-246 (when the
running line is drawn), D-218 and D-208 (what the density setting covers), and closes the hill
climb's defect 11 where Claude Code is concerned. `AGENTS.md`'s Layout bullet on density,
`docs/milestones.md` and the gate record follow.

## Left to the builder

File and type names; how the row keeps its one-second clock; the exact indent and rule; whether
`DenseTranscript` is renamed; how a sub-agent's streamed deltas are handled before its item
completes; the layout of a step's output without the card.
