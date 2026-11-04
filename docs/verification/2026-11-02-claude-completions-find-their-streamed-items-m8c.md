## 2026-11-02: Claude completions find their streamed items; M8c device checks

Branch `fix/claude-block-ids`.

- **Found live with D-088.** A Claude Code reply showed twice, on the Mac and the phone. Claude Code sends each content block in its own `assistant` frame. `ClaudeTurnTracker` named a completed block by its position in that frame (`msg#0`), not its stream index (`msg#1` after a thinking block at `msg#0`). So the text completed onto the thinking item, which lost its reasoning card, and the streamed text item stayed empty. Before D-088 that empty item was invisible; D-088 then stored its streamed text at the turn's end, so the text showed twice. Each completion now takes the first unfinished streamed block of its type for that message, falling back to the frame position when nothing streamed. `ClaudeTurnTrackerTests.completionsGoToTheItemsTheStreamStarted` covers it and fails without the fix.
- **Keep the Mac awake: off** (M8c, open until now). Run on the owner's Local app with `settings.update`, as the Settings toggle does. With `keepAwake: false`, the coordinator released its "Agent Workspace keeps this Mac reachable from your phone" assertion, and `hub status` showed `awake      not held`. Turning it back on took the assertion again. Other coordinators on the same Mac hold assertions of their own.
- **Answer from both** (M8c, "Already answered"). In the iPhone 17 Pro Simulator against the Compose hub, on a real Claude Code tool permission:
  1. The hub container was paused, and the phone tapped Allow once.
  2. The Mac answered with `request respond --accept`.
  3. The hub was unpaused.

  The hub logged `request.respond` → `stale_runtime_request`, and the command ran once. The phone showed no "Already answered": the Mac's "resolved" event reaches the phone before the refused answer on the same ordered link, so the card is gone first. The copy can only show if that event is lost. The user still sees the right outcome: the card disappears and the result arrives.
