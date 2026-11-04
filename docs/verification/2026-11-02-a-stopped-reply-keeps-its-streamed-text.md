## 2026-11-02: A stopped reply keeps its streamed text (D-088)

Branch `fix/stopped-reply-text`, from main at `3f3cc15`.

- **Automated.** `swift test` passes 852 tests and `swift format lint --strict` is clean. `SessionServiceTests.aStoppedReplyKeepsItsStreamedText` covers two cases, a reply never completed and one completed empty. It failed before the fix: no assistant completion was published, and the item stayed empty.
- **Live, real Codex on a scratch coordinator** (`.build/debug`, its own `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`; the owner's app untouched). A 60-line reply was stopped after 12 s. The turn ended `cancelled`, and its agent message was stored with the 780 characters that had streamed. Before the fix it was stored empty (seen live in the M8c transcript check).
- **Not exercised live.** The phone showing the stopped reply. That needs the owner's app on this build; the phone applies the same `message.completed` event as the Mac.
