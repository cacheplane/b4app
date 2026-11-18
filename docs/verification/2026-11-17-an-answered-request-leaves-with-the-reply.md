## 2026-11-17: an answered request leaves with the reply

D-253, hill climb defect 14. Branch `blove/request-buttons-stay-answered`, cut from `blove/claude-session-allow` (pull requests 225 and 226, not merged when this was written) because it shares the request card's files. One change in `WorkspaceUI` (`WorkspaceModel.respond`, `.answer` and a private `settle`). No coordinator, adapter, wire, hub or mirror change.

### Cause

Read from the code, then reproduced in a test:

- `RuntimeRequestCard` disables its buttons with `model.canAnswer`, which on the Mac is false only while `busy` is set, and `perform` clears `busy` when the call returns.
- `respond` and `answer` discarded the returned request.
- The card left `detail.requests` only in `applyToDetail`, on `runtimeRequestResolved` or `runtimeRequestExpired`.
- `SessionService.requestRespond` publishes the resolved event and then returns; the model reads events from an `AsyncStream` and the reply from the call, with nothing ordering them.

### Tests

`RequestAnswerTests`, on the Mac's model with `ScriptedTransport` and no resolved event emitted:

- `anAnsweredRequestLeavesWithTheReplyBeforeItsEvent` and `answersToAQuestionLeaveWithTheReplyToo` failed before the change (the request was still in the detail after the reply) and pass after.
- `aRequestThatWasNotAnsweredStays` passed before and after: a refused answer and a still-pending reply keep the card, and it can be answered again.

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 525 tests in 68 suites passed.
- `swift test --skip` the same: 1535 tests in 170 suites passed.
- `Scripts/docs-index.sh --check`: passed.

### Untested

- The card on screen: the buttons coming back was never observed in the running app, before or after. The audit read it from the code, and how often the reply beats the event is not measured.
- The phone, which this does not change.
