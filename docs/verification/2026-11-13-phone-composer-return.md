## 2026-11-13: phone composer Return and overflow

D-220: a hardware keyboard's Return in the phone's composer sends through the field's `onSubmit` and keeps the focus; the Send button's Return shortcut is gone. Also the phone half of D-219's overflow check. Branch `blove/phone-composer-overflow`, from `main` 1ab90de, rebased on c762e2e.

### Gates

- Overflow, by hand in the layout harness on "B4App Layout 318141754" (iPhone 17 Pro, iOS 26.5): a pasted 13-line draft, a long wrapped draft and the largest accessibility text size each stop the field at three lines and scroll inside it with the caret in view; no text leaves the field's background. No code change was needed for this.
- The focus loss, before the change, with the Simulator panel's Return: an empty draft dropped the keyboard and the next letter went nowhere. Without the Send shortcut, Return dropped it with a draft too; a temporary `onSubmit` showed the field submitting.
- After the change, same harness and keys: empty thread draft, caret kept and the next letter lands; a draft sends; Return while that send is pending does nothing and keeps the caret; the on-screen Return adds a line; the new thread's empty draft keeps the caret.
- After rebasing on `main` c762e2e (#188, the `/` completions, D-214): with `/` typed and `/model` selected, Return opened the model's choices and sent nothing; Return again chose Default, closed the list and kept the caret on an empty draft.
- `.onKeyPress(.return)` instead of `onSubmit`: Return still ended editing.
- `swift format lint --strict` clean; `Scripts/docs-index.sh --check` passes; `swift build` passes; `swift test --filter 'Composer|Slash'` passes on the rebase (26 tests in 13 suites).
- `./Scripts/test-ios-layout.sh`: 16 of 16 passed (13 UI, 3 component), 129 of 129 obligations verified.
- Not covered: XCUITest's `typeKey(.return)` never reaches the field (no send, no submit, with or without the shortcut), so there is no UI test. An iPad's hardware keyboard, Shift-Return and an input method's Return are unchecked.
