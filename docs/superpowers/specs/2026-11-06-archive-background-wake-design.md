# Archive changes wake the phone

The owner requested a fix, a PR merged on green, and a production TestFlight build to retest archiving from the Mac. Phone tests on 2611061754 showed archived test threads remained in the widget while the app was backgrounded. They eventually cleared after opening B4. The hub currently sends alerts and withdrawals, but an archive-only update produces neither. The widget reads its local App Group mirror and cannot fetch the missing change.

## Chosen behavior

A successfully applied `threads.archived` update, in either direction, requests one silent mirror refresh per eligible other phone per committed upload batch. An eligible phone belongs to the same user and organisation, has a live session, is not revoked, and has a registered push token. The uploading phone is excluded because it already applied its local edit. Duplicate uploads, rejected or losing updates, and unrelated metadata edits cause no refresh. Multiple archive writes in a batch cause one refresh per recipient. An alert or withdrawal already destined for that phone in the same transaction covers its refresh, avoiding an extra wake.

The refresh works for quiet threads with no notification ledger entry. Implementing only archive-related notification withdrawals would miss those threads; giving the widget its own network credentials and sync loop would unnecessarily duplicate account ownership. Keep the existing mirror and phone catch-up architecture.

## Flow and compatibility

The transaction collects whether an archive-column update actually applied, selects eligible recipients, and returns refresh messages alongside alerts and withdrawals. The route sends them only after commit. No database migration, new HTTP route, or visible notification is needed.

Use a distinct redacted `Refresh` recipient and sender message. Its payload is `{"aps":{"content-available":1},"refresh":true}`, without titles, thread ids, notification keys, alerts, sounds, or badges. APNs uses background type, priority 5, the existing 15-minute background lifetime, and one constant `mirror-refresh` collapse id. The spool sender carries the same payload plus its Simulator bundle key. Existing retry and dead-token handling applies.

The existing iOS delegate refreshes on every received background notification, including this additive payload. It resumes the account-owned mirror sync, waits for end-of-feed catch-up, reloads the widget, reconciles notifications and the badge, then parks the mirror. Keep that implementation and its budget. Extend the shared Rust/Swift payload fixture to prove a refresh has no navigation or withdrawal semantics.

Apple controls background delivery and widget scheduling; delivery may be delayed or throttled. This change provides the missing wake request and does not promise immediate widget rendering. Reference: [Apple background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).

## Verification and release

First reproduce the missing route delivery in a failing PostgreSQL integration test. Cover archive and unarchive, multiple writes, replay deduplication, refusal/lost writes, an unrelated column, recipient session/revocation/user isolation, uploading-phone exclusion, and overlap with alerts/withdrawals. Verify fake HTTP/2 APNs headers, payload, collapse id and spool output. Check the shared fixture on Swift and Rust and exercise file-backed mirror archive filtering.

Run the required Swift build/tests/format, hub tests/format/clippy, native builds and documentation checks. Obtain independent design, plan and code review. Merge only with green CI. Deploy the exact tested hub merge image to test then production through the existing attested workflow, without bypassing any production gate. Upload the clean merged production iOS build and verify Apple reports it ready in TestFlight. A TestFlight-only release would leave the server gap unchanged.

Physical retest: with the new build and hub, display a disposable quiet thread in the widget, background B4, archive that thread on the Mac, and check its widget removal without opening B4. Record actual device latency and settings separately from fixture results. Keep the earlier J failure and subsequent K/L/M passes distinct.
