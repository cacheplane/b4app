# Approval choices: design

Hill climb defect 8 (R07.1, a hard gate): a request card offers only what the runtime will honour, and a question that allows several answers takes several.

## Why

The card shows "Allow once", "Allow for session" and "Deny" for every runtime. What the second button does today:

| Runtime | What is sent | What it does |
|---|---|---|
| Codex 0.166.0 | `acceptForSession` | Real: later matching prompts in the session are not asked (schema: "session-scoped approval cache"; for file changes, "future changes to the same files"). |
| Claude Code 2.1.282 | a plain allow (D-018) | Same as "Allow once". The next use asks again. |
| B4 | `always`, or `once` when the prompt said `allowAlways: false` (D-021) | Lasting, not session-scoped: B4 keeps the grant itself, and reuses it across processes. A server with no permission layer refuses it (`UnsupportedAlways`). |

So the label is wrong on two of three runtimes: on Claude Code it promises more than happens, and on B4 it promises less. `AskUserQuestion`'s `multiSelect` reaches the card and is ignored: the card draws a single-choice picker.

## Goals

- A card never offers a choice the runtime will not apply, and its label says what the choice does.
- The same holds for an answer that does not come from the card: the CLI's accept-for-session flag and a phone's relayed answer.
- A `multiSelect` question takes several answers.
- Step 2: "Allow for session" works on Claude Code.

## Not goals

- Codex's other decisions (`acceptWithExecpolicyAmendment`, network policy rules) and its `cancel`.
- Writing rules to Claude Code's settings files (D-018's objection stands).
- Showing or revoking grants already given.
- Defect 14 (the Mac's buttons coming back briefly).

## Approaches

1. **Honest only.** Adapters say what wider grant a request has; the card offers it only then. Claude Code gets two buttons.
2. **Honest, then real on Claude Code.** Approach 1, then a session rule on Claude Code through `updatedPermissions`. **Chosen by the owner.**
3. **Relabel only.** Keep the button everywhere with a per-runtime label. Rejected: Claude Code would show two buttons that do the same thing.

## Step 1: honest choices, and multi-select

**The request says its wider grant.** Each adapter sets `allowScope` in the request's payload (`payload.request.allowScope`), beside the fields it already sets:

- absent: the request can be allowed once or denied, nothing wider.
- `"session"`: Codex command and file-change approvals, new and legacy.
- `"always"`: B4, when the prompt's `allowAlways` is true.
- Claude Code: absent in step 1.

`allowScope` is read by a pure type in `WorkspaceUI` (`RequestChoices`, tested without SwiftUI, as `TaskListDisplay` is) that gives the card its buttons:

| `allowScope` | Buttons |
|---|---|
| absent | Allow once · Deny |
| `session` | Allow once · Allow for session · Deny |
| `always` | Allow once · Always allow · Deny |

The wire decision stays `allow_always` for both wider buttons; only the label and its accessibility label differ. The phone draws the same card from the synced payload.

**An answer the runtime cannot apply is refused, not narrowed.** `SessionService` refuses `allow_always` on a request with no `allowScope` (`unsupportedCapability`, naming the runtime), before the adapter is called. This covers the CLI flag and a relayed phone answer. The adapters' silent narrowing goes: Claude Code no longer sends a plain allow for `allow_always`, and B4 no longer turns it into `once`. The CLI's help says the flag applies only where the request offers it.

**Multi-select.** A question with `multiSelect: true` draws its options as toggles; the answer is the chosen labels in option order. The wire already carries a list per question, and the Claude adapter already joins a list with ", ". A single-choice question keeps its picker. "Submit answers" is enabled as it is now: when any question has an answer.

**Amends** D-018 (the button is no longer offered on Claude Code in step 1) and D-021 (no narrowing to `once`).

## Step 2: "Allow for session" on Claude Code

Claude Code's `can_use_tool` request carries `permission_suggestions`, and its allow answer accepts `updatedPermissions`, each with a `destination` that may be `"session"` (read from 2.1.282's bundled schema; `session` keeps the rule in the process, not in a settings file).

- When a request's suggestions include an allow rule, the adapter sets `allowScope: "session"` and keeps the rule's text for the card (`allowRule`, for example `Bash(ls:*)`), which the card shows under the command so the reader sees how far the grant reaches.
- `allow_always` answers with the allow plus those rules as `updatedPermissions`, each with `destination: "session"` whatever destination the suggestion named. Nothing is written to disk.
- No usable suggestion: `allowScope` stays absent, as in step 1.

**Gate before building:** a live recording on the real CLI (real inference, already authorised for Claude Code) that shows the suggestion's shape, that an allow with a session rule is accepted, and that the next matching use in the session is not asked. If any of the three fails, step 2 stops and step 1 stands. A process restarted with `--resume` loses session rules; that is what "for session" will mean here, and the record will say so.

## Tests

- Per adapter (fixtures): the `allowScope` each request kind carries, and B4 with `allowAlways` false.
- `SessionService`: `allow_always` on a request with no scope is refused and the adapter is not called; with a scope it goes through.
- `RequestChoices`: the three button sets, their labels and accessibility labels; a multi-select question's answer in option order.
- Step 2: `fake-claude.py` sends a suggestion; the answer carries the session rule; a request with no suggestion has no scope.
- Live: the step 2 recording. Codex and B4 live stay Untested unless the owner asks.

## Delivery

Two pull requests: step 1 with the multi-select fix, then step 2 after its recording. One decision each, numbered when each pull request opens.

## Left to the builder

- Where `SessionService` reads the scope (the stored request's payload) and the exact error text.
- The toggles' layout on the Mac and the phone.
- Whether `RequestChoices` also owns the card's title.
