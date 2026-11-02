-- The web Apple flow changes no account until the app redeems its handoff with the verifier
-- (D-070). Apple's callback only verifies the identity token and records a handoff carrying
-- what the redemption needs: the verified Apple ID, its email and name, the client id, and the
-- authorization code, sealed with `B4HUB_SECRET_KEY` and bound to the handoff's code hash, so
-- the column holds nothing readable. A sign-in's handoff names no account yet (the Apple ID may
-- be new); a link's names the account that began it, which alone may redeem it.
ALTER TABLE auth_handoffs
    ALTER COLUMN org_id DROP NOT NULL,
    ALTER COLUMN user_id DROP NOT NULL,
    ADD COLUMN pending bytea,
    ADD CONSTRAINT auth_handoffs_names_or_carries
        CHECK (pending IS NOT NULL OR org_id IS NOT NULL),
    ADD CONSTRAINT auth_handoffs_account_whole
        CHECK ((org_id IS NULL) = (user_id IS NULL));
