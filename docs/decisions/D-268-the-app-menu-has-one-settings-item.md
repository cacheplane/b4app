## 2026-11-21 (the app menu's Settings item)

- **D-268 The Mac's app menu has one Settings… item, the one the `Settings` scene brings; the `CommandGroup(replacing: .appSettings)` that drew a second is gone.** The group was added with the gated root (dc368310) to disable Settings… while nobody is signed in. On the owner's Mac (macOS 26.5) it did not replace the scene's item: the menu listed About, Settings…, Settings…, Services. Found in the 2026-11-20 smoke test.
  - **Signed out.** The scene's item stays enabled. The Settings window already draws its signed-out page when `settingsAvailable` is false and closes on sign-out, so nothing of an account shows through it.
  - **Left out.** Disabling the item while signed out (it would need the scene's own item to be replaceable, which it was not here).
  - **Tests.** None automated: the package's tests do not build the Mac app target and there is no macOS UI test target. Checked on screen (the gate record).
