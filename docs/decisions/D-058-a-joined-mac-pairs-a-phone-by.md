## 2026-11-01 (M8c relay design)

- **D-058 A joined Mac pairs a phone by QR code.**
  - **Code.** `POST /v1/pairing-codes` mints a five-minute, single-use enrollment code for the Mac's own user (10 an hour).
  - **Mac.** The "Remote access" Settings page shows it as a `b4app://pair?hub=…&code=…` QR code, beside "Keep the Mac awake".
  - **Phone.** It scans the code (or opens the same link, which is how the Simulator is tested) and always asks before enrolling.
  - **Secret handling.** The code is a credential shown on purpose, like a typed enrollment code: it is never logged or stored, and lives only in the sheet. It is the one exception to keeping secrets out of UI state. The owner's direction, as part of M8c.
  - *Amended by D-078:* the code is withdrawn when its Mac is revoked, the parser validates the code before upper-casing it, and D-066 later replaces the `b4app://pair` link with an `https` one.
