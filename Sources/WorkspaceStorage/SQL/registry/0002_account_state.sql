-- What the coordinator must remember about an account across restarts (sign-in plan, Task 10).
--
-- "needs_onboarding": the hub said the user has not given a full name yet. A restart restores the
-- account in that state at once, before `/v1/me` answers, so the window never shows the workspace
-- (or the sign-in screen) for an account that still has to onboard; `/v1/me` corrects it.
--
-- "hub_session_left_open": a log-out whose `DELETE /v1/sessions/self` never reached the hub (review
-- focus 3). The token is forgotten on this Mac, but the hub still holds it. The account's next
-- sign-in reports it once ("The last sign-out could not reach the hub; that session was left open
-- there.") and clears it. The sign-in itself ends that session: the hub replaces a reused device's
-- earlier tokens.

ALTER TABLE "accounts" ADD COLUMN "needs_onboarding" boolean NOT NULL DEFAULT false;
ALTER TABLE "accounts" ADD COLUMN "hub_session_left_open" boolean NOT NULL DEFAULT false;
