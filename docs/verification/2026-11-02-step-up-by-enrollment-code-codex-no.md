## 2026-11-02: Step-up by enrollment code (D-151), Codex "no rollout found" (D-152), and the 1004 line

Branch `blove/step-up-code`, from main at `5882a60`. Fixture gates only; nothing here has run live.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass (exit 0) |
| Build | `swift build` | Pass |
| Swift tests | `swift test` (PostgreSQL from the main checkout's `.build/postgres`) | 1300 tests in 161 suites; the new and changed tests pass (`AccountCommandTests.anEnrollmentCodeConfirmsADelete`, `MirrorAccountTests.anEnrollmentCodeConfirmsAChange`, `AccountSettingsTests.aClosedConfirmationOffersAnEnrollmentCode`, `anEnrollmentCodeConfirmsRemovingAndAdding`, `aPasskeySheetThatCannotOpenIsOneLine`, `SignInTests.aPasskeySheetThatCannotOpenSaysWhy`, `everySystemCancelOfAnAssertionMeansNoPasskey`, `AuthWireTests.stepUpCodeRoundTripsAndNeverDescribesTheCode`, `HTTPHubAPITests.stepUpCallsSendTheBearerAndTheirBodies`, `CodexDeleteTests.noRolloutFoundIsAlreadyGone`). The full run had 2 issues, both in `HubSyncTests.joinPushesTheBacklogAndMarksItSynced` (the timing flake the sign-in gate recorded); it passed three times alone |
| Rust format | `cd Hub && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `source <(./scripts/test-db.sh) && cargo test --workspace --locked --no-fail-fast`, then `./scripts/test-db.sh --stop` | Pass: 464 tests against PostgreSQL 17.11, 0 failed. New: `accounts.rs` `an_operator_code_steps_up_once_on_its_own_device`, `a_step_up_code_is_the_callers_own_operator_code`, `step_up_codes_count_with_the_sign_in_finishes`; `auth_fixture.rs` decodes `stepUpCode` and sends it to the route; `b4hub-db` `an_operator_code_is_taken_once_by_its_own_user`, `migrate.rs` expects 15 migrations; `maintenance_pauses_sign_in_and_account_writes` and `no_secret_in_logs` cover the new route |
| Apps | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` and `-scheme B4App-macOS -destination 'platform=macOS'`, `CODE_SIGNING_ALLOWED=NO` | Two `** BUILD SUCCEEDED **` (the code field's iPhone keyboard modifier compiles only there) |

Not run live: a code step-up against a running hub, and Settings → Account's code row on screen. The Codex fix matches what codex-cli 0.166.0 answered live during the thread cleanup (four `thread/delete` calls, each `-32600 no rollout found for thread id …`; none of the ids among Codex's 383 threads).
