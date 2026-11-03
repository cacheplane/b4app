-- Passkeys are named after the device they were made on (D-169): sign-up and Add a passkey
-- store the device's name as the identity's name. Before, every passkey was stored as "Agent
-- Workspace account", which told the account's passkeys apart from nothing; those names are
-- cleared, so Settings → Account lists such a passkey by its date alone. The device a passkey
-- was made on was not recorded, so it cannot be filled in.
UPDATE user_identities SET name = NULL WHERE kind = 'passkey' AND name = 'Agent Workspace account';
