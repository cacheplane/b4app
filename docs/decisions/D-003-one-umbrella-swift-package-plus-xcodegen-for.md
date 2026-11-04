## 2026-10-30

- **D-003 One umbrella Swift package plus XcodeGen for the app targets.** SwiftPM cannot build `.app` bundles; Tuist is heavier than needed; hand-edited `pbxproj` files are hostile to agents. The generated `.xcodeproj` is gitignored and produced by `Scripts/generate-project.sh`.
