## 2026-11-02: The iPhone's thread list toolbar (D-131)

Run in the iPhone 17 Pro Simulator (local flavour, Debug, this branch) against the owner's Local app and Compose hub.

- **The layout:** the list opens under a large "Threads" title, with the filter and compose buttons at the top right and the search field at the bottom (iOS 26's placement). The first thread is where the New thread row used to be.
- **Search:** "b4run" narrowed the list to the three b4run threads, matching regardless of case. Clearing it brought back all seven. The field no longer capitalises what is typed.
- **The filter button:** it opened the project and connection filters. Choosing "B4 Run (Mac)" retitled the list to that project, filled the filter icon, and showed its four threads. "All projects" restored "Threads".
- **Compose:** it opened New thread.
- **Gates:**
  - `swift format lint --strict` is clean.
  - `swift test --filter WorkspaceUITests` passed 273 tests, including `ListSearchTests.theListSearchMatchesShownTitles`, which failed first.
  - Both `xcodebuild` builds (iOS Simulator, macOS) succeeded.
