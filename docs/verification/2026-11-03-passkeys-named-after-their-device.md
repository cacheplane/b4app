## 2026-11-03: Passkeys named after their device (D-169)

Branch `blove/passkey-device-names`, from main at `b8f1202`. Hub and docs only; no Swift or wire change (an identity's `name` was already a string or `null`).

| Check | Command | Result |
| --- | --- | --- |
| Rust format | `cd Hub && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `source <(./scripts/test-db.sh) && cargo test --workspace --locked --no-fail-fast`, then `./scripts/test-db.sh --stop` | Pass: 481 tests against PostgreSQL 17.11, 0 failed. New: `accounts.rs` `passkeys_are_named_after_their_device` (a passkey made at sign-up on "Brian's Mac" and one added from "Brian's iPhone" are listed under those names), `me_lists_identities` now expects the device's name, and `b4hub-db` `migrate.rs` `the_passkey_placeholder_name_is_cleared` (0016 clears only a passkey's placeholder, never a device name or an Apple ID's name); `migrate.rs` expects 16 migrations |

Not run live: a passkey made on a device and listed under its name in Settings → Account.
