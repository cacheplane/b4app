## 2026-11-09 (iPhone thread list search)

- **D-201 The iPhone's thread list drops its own search field; the search button opens the Search sheet; amends D-131.** The owner asked for the room the list's pull-down search field took above the threads. D-131 had made search the system field (`.searchable`, a navigation-bar drawer) that narrowed the list itself.
  - **No field above the list.** The list starts under the large title (and any notice), with no search drawer between them.
  - **The magnifying glass in the navigation bar stays** and opens the Search sheet (`SearchPalette`, the iPhone's form of the Mac's ⌘K palette): its own field, at most eight threads by shown title, live before archived, and a tap opens the thread. This restores the sheet D-131 replaced; the Mac's palette is unchanged.
  - **The list no longer filters by text.** `WorkspaceModel.listSearch` and `listSearchPresented` are gone, with the list's "No matching threads." line. The project and connection filters are unchanged.
