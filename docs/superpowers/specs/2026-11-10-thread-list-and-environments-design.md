# Thread list and environments: design

Date: 2026-11-10. Status: draft for the owner's approval. Nothing here is built.

## Intent

The owner runs many agent threads at once and wants to know, at a glance, which ones need them. Today the sidebar is organised around projects the owner has to think about. This design removes that thinking:

- You start a thread and either pick a folder or don't. You never have to create or name anything first.
- The sidebar shows what needs you at the top and tucks everything else away.
- A second arrangement groups threads by where they work, for when you want stable positions.

The owner's words for the bar: "as compact, readable, and understandable as possible, maximizing the ability of a human to glance at it and fully understand the state of their agents", and "clear, obvious, minimal, clean, and kinda beautiful".

## Goals

- Start a thread with a folder, a new folder, or no folder, on the Mac and the phone.
- One row per thread, one mark per row, readable in under a second.
- A thread leaves the top of the list the moment it is answered or read.
- Everything on a strict 4 pt grid, following Apple's guidelines and the LLA brand.
- View settings sync through the hub; where a device cannot show a setting, a named fallback applies.

## Non-goals

- Any UI for viewing an environment's files or folders.
- The service that cleans up temporary folders and worktrees. That is a separate design; this one only leaves it what it needs (see "Temporary folders").
- Changes to B4 projects. They stay a separate feature (Settings → B4 projects, the runtime picker) and keep that name.
- Redesigning the permission and model pickers beyond removing their chevrons.
- New pinning behaviour (see "Builder's calls").

## Anti-goals

- The user is asked to create, name, or choose an "environment" before they can start a thread.
- Colour or motion that competes for attention when nothing needs the user.
- b4.run's surfaces or type leaking into the app. Only the lime, on the working mark, comes from b4.run.
- A modal sheet for editing an environment on the Mac.

## Constraints

- LLA brand: surfaces, ink, greys, Hanken Grotesk, spacing 4/8/12/16/24/40, radii 8/12/16/999, no uppercase. The owner has knowingly bent three LLA rules for this list: motion on several rows (orbit, shimmer, ping, arrival trace), one gradient (the shimmer and the trace), and a soft shadow on the palette only.
- The titles of act-level rows use weight 500. Only 400 and 600 are bundled today; 500 must be added to the bundle.
- `WorkspaceUI` talks only to `WorkspaceClient`; the UI never touches files or processes (AGENTS.md).
- No backwards compatibility is needed: the owner is the only user, so old surfaces are replaced outright.
- Material decisions get `docs/decisions/D-NNN-*.md` files when the pull request opens. This design amends at least D-048 (bands, projects), D-053 (row content), and D-036 (one accent).

## Terms

- **Environment**: what the code calls a project today (`Project`, `ProjectFolder`). One or more folders that threads work in. Renamed everywhere the user or the CLI sees it, and in the data model, the hub, and the sync fixtures. "B4 project" is unrelated and unchanged.
- **Act level**: needs approval, needs a reply, or failed.
- **Top list**: act-level threads plus finished-and-unread threads.
- **Lower list**: working and quiet threads.

## Thread states and marks

Six states, in display order. The first four form the top list.

| State | Meaning | Title | Mark (12 pt box, viewBox 0 0 12 12) | Colour |
|---|---|---|---|---|
| Approve | an approval request is pending | 500 | dot r 2.25 inside a ring r 4.75, stroke 1.5; a second ring pulses outward (1.25 s ease-out, scale .5 → 1.3, fading) until the thread is opened | ink |
| Reply | the agent asked a question or needs input | 500 | filled dot r 4 | ink |
| Failed | the latest turn ended in failure | 500 | cross, two strokes 2.6→9.4, width 1.8, round caps | LLA danger (`#962E1F` light, `#E07A6A` dark) |
| Finished | latest turn done and not yet read | 400 | filled dot r 2.5 | ink |
| Working | latest turn still running | 400, faint shimmer | track ring r 3.25 stroke 1.5 at 22% ink; arc r 3.25 stroke 1.75, dash 6.4/14, round caps, one turn per 1.4 s linear | arc lime `#B4CE37` in both modes |
| Quiet | nothing to do | 400, muted | none | — |

Rules behind the table (from the aviation alerting research):

- Levels are defined by what the human must do, not by what the agent is doing.
- Shape carries the meaning; colour only reinforces it. The list must read correctly in greyscale.
- One meaning per colour: red is failure, lime is "an agent is running". Nothing else is coloured.
- Text never blinks. Marks may move.
- Opening a thread acknowledges it (the approve pulse stops) but does not clear it; it leaves the top list only when answered or, for finished, read.
- A failed thread keeps its cross after being read, until it is retried or archived. The badge and notifications do not follow it: once read, a failure stops counting in `needsYouCount` and its notification is withdrawn, as today. The list can therefore show a cross while the badge is clear; that is intended, and the hub's badge rules do not change.

Working shimmer: the title is drawn with a gradient of dimmed ink (ink mixed 78% over the surface) with a band of full ink at the centre, twice the title's width, sweeping once per 4 s ease-in-out. Brightness only; the text is never invisible.

Quiet fade: quiet titles use the muted colour, stepping down in opacity with age from 1.0 to a floor of .72 (steps drawn: 1, .9, .82, .76, .72). The exact age thresholds are the builder's.

Order within the top list: approve, reply, failed, finished; inside each, newest activity first. Lower list: working first, then quiet, newest first.

Arrival: when a thread enters the top list its row slides in (12 pt up, about .5 s, ease-out) and gets a traced border for about 10 s: a point of light laps the row's rounded edge twice (about 3.5 s in all), over a .5 pt inset hairline at 30% ink that then fades out. One thread traces at a time; later arrivals queue or skip the lap (builder's call).

With Reduce Motion on: no slide, no lap, no shimmer, no pulse; the orbit becomes a still ring with a lime arc, and the arrival shows the hairline only.

Approve and reply are one band today (`needsInput`, any pending request). The builder splits it by the kind of pending request: approval requests give Approve, anything else that waits on the user gives Reply; Approve wins when both are pending. Failed is new: a terminal latest turn whose outcome is a failure. Which `TurnOutcome` values count as failure is listed under "Questions the builder may meet".

## The row and the grid

All measurements are points on a 4 pt grid.

- Sidebar: 240 wide, a floating panel inset 8 from the window, radius 16.
- Top bar 44 high; profile footer 56 high (unchanged from today).
- Row: 28 high, no gap between rows. The row's fill (selection, hover) spans x 8–232 with radius 8. Text starts at x 16. The mark's 12 pt box sits at x 212–224, with 8 between title and mark. Titles truncate with an ellipsis.
- Type: Hanken Grotesk 13/16.
- No eyebrows, no rules, no runtime mark, no second line. Sections are separated by space only: 24 between the top list and the lower list, 8 between groups in the grouped arrangement.
- Selection is the raised surface fill.

On the phone, rows keep the system's 44 pt minimum height and Dynamic Type; the marks, order, weights and motion are the same.

## Sidebar chrome

Mac top bar, left to right: traffic lights, flexible space, view options, search, new thread (in ink; the others muted), sidebar toggle. The "New thread" and "Search" rows that head the list today are removed, as is "New Project…". When the sidebar is hidden, search and new thread appear in the main view's toolbar. The profile footer is unchanged.

Phone: a "New thread" composer docked at the bottom of the list; view options and search as icons in the navigation bar.

## Two arrangements

Chosen in the view-options menu:

```
Arrange
  Needs you first
  By environment
Threads that don't need you
  Small / Tiny / Collapsed / Hidden
Show archived
Connections
  (today's connection filter, unchanged)
```

The phone's project filter is removed; "By environment" replaces it. With "Show archived" on, archived threads appear as their own block at the very bottom of the list, after a 24 pt gap, in both arrangements.

### Needs you first (the default)

Top list, a 24 pt gap, then the lower list drawn according to the "threads that don't need you" setting:

- **Small**: 28 pt rows as above.
- **Tiny**: 20 pt rows, 11 pt type, marks at 8 pt. Mac only.
- **Collapsed**: one row, "9 more, 2 working" (count of stowed threads; the working part and the orbit mark only when something is running). Clicking it opens the lower list in place; it closes again when the pointer or focus leaves the sidebar.
- **Hidden**: nothing below the top list, except one muted line pinned to the bottom of the list, just above the profile footer, while agents are running: "2 working" with the orbit. It is absent when nothing is running. Clicking it shows those working threads in place.

Collapsed and Hidden stow working threads along with quiet ones.

### By environment

One heading per environment, then its threads in the same state order as above (top-list states first, then working, then quiet). Threads with no folder gather under a final "No folder" heading.

- Heading: a 28 pt row, the environment's name at 12 pt, weight 500, muted.
- Group order is stable and does not re-sort as thread states change. The builder picks the stable key (suggested: name, with "No folder" last).
- Hovering a heading (Mac, this arrangement only) turns it ink and shows a collapse chevron beside the name and two icon buttons at the right: new thread here (opens the composer with this environment preselected) and edit. "No folder" has only the new-thread button, which preselects "No folder".
- An environment with no live threads has no heading here; it stays in the composer's palette.
- Phone: tapping a heading collapses or expands the group; a long press offers "New thread here" and "Edit".
- A collapsed group shows, in the mark position, the mark of its most urgent thread, so a collapsed group never hides that something needs the user.
- The "threads that don't need you" setting does not apply in this arrangement; the menu shows it disabled.

## Starting a thread

The new-thread view centres a heading ("Let's get started") and the composer, horizontally and vertically, in the main view. Under the composer's text field is today's row of pickers, redrawn as plain muted 12 pt words with no chevrons; each gets the raised fill and ink text on hover. Leading: where the thread starts. Trailing: permission, then runtime · model.

The place picker's label is the environment's name alone, or "No folder". It shows the place used last on this device; on a fresh install, "No folder". Clicking it (Mac) opens a palette:

- The main view (not the sidebar) is veiled: the window colour at 60% with an 8 pt blur, fading in over .18 s.
- The palette is 420 wide, radius 14, centred on the main view, with a hairline edge and one soft shadow. It enters over .2 s (10 pt rise, scale .98 → 1, ease-out) and leaves faster.
- Top: a filter field, "Start in…", 40 high, 15 pt, focused on open.
- List: one 36 pt row per environment, name at left (14 pt), first folder's path at right in JetBrains Mono 11, a check on the current one. An environment with several folders is followed by one indented row per folder, so a thread can start in any of them; choosing the environment's own row means its first folder. A single raised highlight slides between rows (.12 s) following the pointer and the arrow keys. The list scrolls past about five rows. If the filter matches nothing: "Nothing matches. Choose a folder below."
- Footer, fixed, 48 high, on the surface colour above a hairline: two equal bordered buttons, "Choose folder… ⌘O" (the system folder panel) and "No folder", and "esc to close" at the right.
- Return chooses the highlighted row; Esc or a click on the veil closes. On choosing, the palette closes and the label swaps with a .18 s fade-up.

What each choice does on send:

- **An environment**: the thread starts in its first folder, or in the folder chosen from its indented rows. The first folder is a default, not a rule; the per-environment folder memory stays.
- **Choose folder…**: if the folder already belongs to an environment, that environment is used and the agent starts in the folder that was picked, even when it is not the first. Otherwise a new environment is created for it, named after the folder's last path component. Every unique folder gets an environment this way; the user is never asked.
- **No folder**: the coordinator creates a new folder for this thread under `~/.b4app/projects/` (flavour-aware, through `WorkspacePlatform` paths) and starts the agent there. The thread has no environment. See below.

Phone: the same picker as a sheet listing environments and "No folder", without "Choose folder…" (the phone cannot browse the Mac). A relayed start with no environment is now valid (today it fails with `project_missing`) and creates the temporary folder on the Mac.

## Editing an environment

The edit button on a group heading opens a form in the main view (not a sheet), with a toolbar label "Environment":

- The name as a large heading and the thread count beneath.
- **Name**: a text field, prefilled with the generated name. Hint: "Taken from the folder name. Change it to anything."
- **Folders**: a bordered list of paths (JetBrains Mono 12). The first is tagged "Threads start here"; the others each have "Remove". Below: an "Add folder…" button and the hint "Agents start in the first folder and can work in the others."
- Changes save as they are made. A "Done" button returns to the view the user came from.

- **Delete environment**: a quiet destructive action at the foot of the form, confirmed inline. Its threads move to "No folder"; nothing on disk is touched.

A folder belongs to one environment. Adding a folder that already has its own environment moves the folder, with its threads, into the one being edited; an environment left with no folders is removed. This applies to every environment: the `manual` flag no longer changes what can be merged, edited, or deleted, and the builder may drop it.

On the phone: rename is kept; folder edits and delete are kept and relayed to the Mac as today; creating an environment from the phone is removed, since creation is automatic.

## Temporary folders

This design creates them; a later design cleans them up. To leave that service what it needs, each app-created folder is recorded as created by the app, with the thread it was made for and when. A thread must cope with its folder having been removed: it stays readable, and sending to it says the folder is gone rather than failing obscurely.

## Settings sync

The arrangement, the quiet-threads setting, and "show archived" are stored on the hub per account and apply on every device. What the composer remembers (last place, runtime, model) stays per device, as today, because environments are folders on one Mac.

Fallbacks, where a device cannot show a stored value:

| Stored value | Mac | Phone |
|---|---|---|
| Tiny | Tiny | shown as Collapsed |

The stored value is never rewritten by a device that falls back. The phone's menu still lists Tiny, marked as shown collapsed on this device. Any future setting without parity gets a row in this table.

## Builder's calls

These are the designer's decisions, not the owner's; change them if the code argues otherwise, and say so.

- Pinning exists today (pinned threads sort first). It is kept as data but must not lift a quiet thread into the top list: in "Needs you first" a pinned thread sorts first within its own part of the list.
- The widget and the phone share the new marks (D-126 says the widget shares the dot).
- Age thresholds for the quiet fade; the stable sort key for groups; how simultaneous arrivals trace.
- The setting's storage shape on the hub and the sync fixtures for it.
- The rename's mechanics: tables, wire names, CLI verbs, fixtures. Old names are replaced, not aliased.
- How large the work is and how it is split into pull requests. A natural order: rename; temporary folders and no-folder starts; marks and rows; arrangements and settings sync; composer palette; environment form.

## Questions the builder may meet

- Which `TurnOutcome` values count as "failed", and whether an interrupted or cancelled turn is failed or finished. The designer's guess: errors are failed; a turn the user stopped is finished.
- Whether a B4 thread on a remote route, which has no folder today, appears under "No folder" in the grouped arrangement. The designer's guess: yes.

## What was verified

The mockups were checked in a browser as stills; no animation timing was judged in motion by the designer. Facts about the current code (bands, `ProjectService.ensure(folder:)`, relayed starts requiring a project) came from a read of the code during the design and should be confirmed while planning. Apple's 44 pt touch target and text-size floors are from memory of the guidelines.
