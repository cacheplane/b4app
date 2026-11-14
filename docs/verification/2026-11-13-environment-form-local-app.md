## 2026-11-13: environment form in the Local app

D-212's Mac environment form, checked on screen in the Local flavour built from `main` b4171ae (with #188 and #191): `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1` and a Developer ID signature, installed to `/Applications` and the coordinator restarted (`agent-workspace coordinator restart`).

### Gates

- Opening: the "b4app-live-check" heading's hover buttons show New Thread and Edit; Edit opens the form in the main view with the name as a heading, "1 thread", the name field, the one folder tagged "Threads start here", Add folder…, Done and Delete environment….
- Rename: typing "Live check (renamed)" and Return saved it; the heading and the sidebar group took the new name at once.
- Add folder: Add folder… opened the system folder chooser; choosing `~/repos/b4app-release` added it as a second row with Remove, under the first.
- Remove: Remove took the row away, leaving the first folder alone.
- Delete: Delete environment… showed "Delete “Live check (renamed)”?", "Its threads move to “No folder”. Nothing on disk is touched.", Delete Environment and Cancel in place; Cancel put the link back. Nothing was deleted.
- Clearing the name and Return saved the empty name: the heading and the sidebar showed "b4app-live-check" again. The field stays empty while it has focus.
- Done closed the form and returned to the new-thread view.
- Not covered: a failed save (the message under the folders), adding a folder another environment holds, confirming Delete, the phone's sheet, and the CLI (it has no environment command, so the stored state was read only from the app).
