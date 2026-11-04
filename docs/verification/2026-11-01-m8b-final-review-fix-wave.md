## 2026-11-01: M8b final-review fix wave (fixture gates)

Run from `feat/m8b-organisation` at `446c8c0` (six commits over `6baea96`: read marks wait for the thread to be on screen; `0004` backfills `readTurnId` and indexes `runtimeRequests("threadId", "state")`; the phone's push is capped at 8 MiB and unsent edits of one column collapse; an advisory lock orders local writes against pulled batches; a router test waits for its events; README and D-048/D-049). `Hub/` was not touched, so the Rust gates were not rerun. The live gate below is still pending.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 526 tests in 89 suites in 37.7 s, no issues on the first run |
| Project | `./Scripts/generate-project.sh` | Regenerated |
| macOS app | `xcodebuild build ... -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iOS app | `xcodebuild build ... -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
