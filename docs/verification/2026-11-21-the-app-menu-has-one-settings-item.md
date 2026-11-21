## 2026-11-21: The app menu has one Settings item (D-268)

- **Before.** The installed Local build (main 8a3440cc with D-265, D-266, D-267), listed through the menu bar: About Agent Workspace, Settings…, Settings…, Services, Hide Agent Workspace, Hide Others, Show All, Quit Agent Workspace.
- **After.** A Local build of this branch: About Agent Workspace, Settings…, Services, Hide Agent Workspace, Hide Others, Show All, Quit Agent Workspace, Quit and Keep Windows. Pressing Settings… opened the Settings window on Account.
- **Build.** `./Scripts/package.sh` (local flavour) built and signed the app; `swift format lint --strict` and `Scripts/docs-index.sh --check` clean. `swift test` was not run: no package source changed, and its tests do not build the Mac app target.
- **Not checked.** ⌘, (the shortcut could not be read without accessibility access, which was not granted); the item while signed out.
