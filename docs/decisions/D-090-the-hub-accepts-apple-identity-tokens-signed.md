## 2026-11-01 (sign-in: Sign in with Apple on the hub)

Built on `blove/sign-in` (Task 13) under provisional numbers, which became D-090 to D-093 because main took D-081 to D-086 while the branch was being built.

- **D-090 The hub accepts Apple identity tokens signed `RS256` (and `ES256`), with the key's own algorithm.** The design said ES256, after Apple's documentation; Apple's key set (`https://appleid.apple.com/auth/keys`, checked 2026-11-01) publishes only RSA keys with `alg` `RS256`. The algorithm comes from the key the token's `kid` names, and a header that claims another is refused. The fake Apple in `Hub/crates/b4hub/tests/apple.rs` signs with both. The client secret stays ES256, as Apple requires for the `.p8` key.
