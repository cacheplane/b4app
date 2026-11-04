## 2026-10-31 (visual system)

- **D-037 The mark is drawn from the vendored outlined SVGs, never typed.** `LLAMark` reads `viewBox` and the path data (`M L H V Q C Z`) at runtime and fills even-odd, so the snow stays cut from the A as the brand page requires. The app icon is the brand's icon tile rasterised by `Scripts/make-app-icon.swift` into `Apps/Shared/Assets.xcassets` for both targets (10% margin on macOS, ink-filled square on iOS); the small icon serves the 16 px sizes.
