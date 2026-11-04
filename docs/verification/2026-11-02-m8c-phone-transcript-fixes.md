## 2026-11-02: M8c phone transcript fixes (D-087)

Branch `fix/m8c-transcript`, from main at `3151915`.

- **Automated.** `swift test` passes 851 tests, `swift format lint --strict` is clean, and the iOS and macOS app builds pass. Each new test fails without its fix and passes with it: `MirrorModelTests.reloadingTheOpenThreadMidReplyKeepsTheLiveText` and `SendStateTests.aConfirmedStartWhosePlaceholderExpiredStaysStarted`. `anUnconfirmedStartWhoseReadFailsShowsNotConfirmed` pins the unchanged spec case.
- **Live, iPhone 17 Pro Simulator** against the Compose hub and the owner's Mac app (both on main `3151915`), with a real Codex turn:
  - **Reopen mid-reply.** A 60-line reply was streaming. Going back and reopening the thread showed the reply from its first line, still growing. Before, the text started over from the next delta.
  - **Stop.** After a Stop mid-reply, the transcript ended at "Turn stopped." with no blank space past it.
  - **Opening a thread.** A long thread opens at its latest message (before, at its first), and a short thread still starts at the top.
- **Not exercised live.** A confirmed start whose row is more than 2 minutes late; it needs the Mac's sync held back. It is fixture-tested.
- **Seen, then fixed in D-088.** A Codex reply stopped mid-stream was stored on the Mac with empty text, so the partial reply disappeared on both the Mac and the phone after a Stop.
