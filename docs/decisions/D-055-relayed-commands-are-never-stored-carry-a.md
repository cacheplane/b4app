## 2026-11-01 (M8c relay design)

- **D-055 Relayed commands are never stored, carry a deadline the Mac enforces, and are idempotent by phone-minted ids the Mac already stores.**
  - **Deadline.** The hub stamps each command with hub time + 10 s, and the Mac drops one that arrives late by its estimate of the hub's clock, so a frame buffered across a sleep never starts a turn.
  - **Idempotency.** `turn.send` uses the command id as the turn's `operationId`, which `SessionService` already deduplicates durably. `thread.start` uses a phone-minted `threadId` as well. `RelayExecutor` runs each id once at a time.
  - **Lost replies.** A reply that never came is "not confirmed". The phone resends the same id only within 30 s of the tap, and asks the Mac (`turn.lookup`) whether the turn exists, so a lost send is only ever declared by the Mac.
  - **First answer wins** is the Mac's existing `stale_runtime_request`, made true at the runtime by marking a request as being answered before the adapter call.
  - **Holds.** Interrupts and answers are held for an owner seen within 60 s (D-045); sends never are.
  - *Amended by D-076, D-077, D-079:* `turn.lookup` is never held either; a full queue answers `relay_timeout`, not `device_offline`; the Mac's errors are sanitised and a refusal before the turn exists names `blockingTurnId`; the lookup timing is 30 s after the tap, 12 s between attempts, with backoff.
