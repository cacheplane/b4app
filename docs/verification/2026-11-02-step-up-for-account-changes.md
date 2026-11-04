## 2026-11-02: Step-up for account changes (D-150, resolves D-113)

Built on `blove/xenodochial-morse-e3bed8`.

**Automated**
- Hub, against a throwaway PostgreSQL: `cargo test --workspace --locked`, `cargo fmt --all -- --check`, and `cargo clippy --workspace --all-targets --locked -- -D warnings` pass. New or changed: `a_step_up_grant_is_taken_once_by_its_own_user_and_device` (`b4hub-db`), `add_second_passkey_then_sign_in_with_either`, `a_step_up_and_an_add_belong_to_one_device`, `a_step_up_needs_one_of_the_accounts_own_passkeys`, `remove_last_identity_is_last_identity`, the `delete_me_*` tests, `no_secret_in_logs` (the step-up's challenge, assertion, and grant stay out of the logs), `maintenance_pauses_sign_in_and_account_writes` (`tests/accounts.rs`); `an_apple_only_account_steps_up_with_its_apple_id`, `an_apple_step_up_belongs_to_its_device_and_its_kind`, `a_web_apple_step_up_removes_a_passkey`, `routes_404_without_apple_config` (`tests/apple.rs`); `step_up_types_match_the_hub_types` and the route run in `auth_fixture.rs`, which matches `stepUpRequired` word for word.
- Swift: `swift build`, `swift test`, and `swift format lint --strict` pass. New or changed: `stepUpTypesRoundTrip` (`AuthWireTests`), `stepUpCallsSendTheBearerAndTheirBodies`, `aStepUpRefusalCarriesTheMethods`, and the `B4-Step-Up` header checks (`HTTPHubAPITests`), `anAppleStepUpRedeemsItsHandoffWithTheKeptVerifier` and the passkey step-up in the identities test (`AccountCommandTests`), `anAppleOnlyAccountConfirmsWithAppleNatively` (`MirrorAccountTests`), `aClosedConfirmationSendsNothingAndAStepUpRefusalSaysSo` and `addAPasskey` (`AccountSettingsTests`), and the Connect Apple ID tests (`AppleSignInTests`).
- Seen once each under a loaded machine and not since (three clean reruns each), neither touched by this change: `presence_is_sent_when_the_queue_has_room_again` (`tests/relay.rs`) and `reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown` (`SessionTests`).

**Live gate: pending (the owner's Touch ID).** Not run: the real passkey and Apple sheets need the owner. On a hub built from this branch (migration 14 applied) and the Local app and phone built from it:

1. Settings → Account on the Mac, with a passkey account: **Add a passkey** shows the system passkey sheet first, offering only this account's passkey (and a nearby iPhone or security key), then the registration sheet; the new passkey is listed.
2. **Cancel** the confirmation sheet for Add a passkey, Remove, and Delete account…: nothing changes and no line shows; the Delete sheet stays open.
3. **Remove** the second passkey: confirm sheet, then the row goes. The removed passkey no longer signs in.
4. **Delete account…** on a throwaway account (type the org name, Delete account, confirm): the account is gone at the hub and the Mac is signed out.
5. On the iPhone, the same three changes run Face ID / Touch ID first, through `MirrorAccount`.
6. With Apple enabled (beta, after D-114): an Apple-only account's **Add a passkey** opens Apple's page first (web on the Mac, the native sheet on the phone), then the registration sheet; **Connect Apple ID** on a passkey account asks for the passkey first.
7. `curl -X DELETE -H "Authorization: Bearer <a device token>" <hub>/v1/me` answers `403 step_up_required` with `details.methods`; the hub's log has "a change was refused: it needs a step-up" and no token or grant.
