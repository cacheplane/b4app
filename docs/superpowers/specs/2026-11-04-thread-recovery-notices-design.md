# Thread recovery notices

Approved by the owner on 2026-11-04: one notice per problem, recovery text shown once, and aligned action/Dismiss buttons beneath it using the existing LLA card and pill styles.

The local Codex chat failed after reconnect because its native session was archived. Codex 0.166.0 returned `-32600` with an explicit `codex unarchive <id>` instruction. `CodexAdapter.ensureLoaded` mapped every RPC rejection to `native_session_missing`, and the detail rendered both the persistent continuity notice and the transient error for that same failure.

## Behavior

- Classify a resume rejection as missing only when the response identifies missing thread history. An archived session is `protocol_invalid` with `reason: native_session_archived` and its recovery command. Other errors retain their original code and details.
- Present the archived-session explanation once with Check again after the owner unarchives it. No automatic unarchive, new native session, or re-send.
- A persistent continuity notice covers a matching missing-session or identity failure; suppress only its redundant transient banner. Unrelated failures remain visible.
- Use the existing surface card, typography, spacing, and pill styles. Message first, then a separate action row with Dismiss aligned with the other controls. Wrap controls when needed. Apply the same layout to continuity actions.
- Keep native diagnostics available without repeating the primary explanation as another error message.
- Explicit reconciliation surfaces archived recovery, including for a thread the old adapter incorrectly marked missing. That verified archived response clears the obsolete missing classification. Checking again while it is still archived keeps the recovery notice visible and creates no turn. Read failures remain offline-safe.
- Read turn failures' nested `details.cause` when selecting recovery, since the coordinator wraps native details with its local turn id. A refused archived send restores the composer draft only in its originating thread and account; navigation, deletion, or account changes fence late restoration.
- Expanded diagnostics remain selectable within a scroll region capped at 120 points, so runtime text cannot determine the split view's minimum height.

## Verification

Fixture tests cover archived and missing sessions and unrelated RPC rejection, including no `turn/start` after refusal. UI policy tests cover matching versus unrelated failures. Render real SwiftUI notices in light/dark and narrow widths; run minimum-window checks, Swift build/tests, formatting, and docs checks. Document live evidence separately from fixtures.
