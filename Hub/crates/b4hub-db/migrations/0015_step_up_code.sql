-- Step-up with an operator's enrollment code (D-151, adding to D-150): an account whose only
-- passkey is gone from the user's keychain cannot assert with it, so the operator mints a code
-- (`b4hub enroll`) and the user types it to confirm a change. `0014_step_up.sql` is not edited,
-- since databases may already hold it.
--
-- Only an operator's code counts (`created_by_device_id IS NULL`), never a pairing code a Mac
-- minted; the grant it earns is the same two-minute, single-use grant, recorded as `code`.
ALTER TABLE step_up_grants DROP CONSTRAINT step_up_grants_method_check;
ALTER TABLE step_up_grants ADD CONSTRAINT step_up_grants_method_check
    CHECK (method IN ('passkey', 'apple', 'code'));
