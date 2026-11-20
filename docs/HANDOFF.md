# Perch handoff (2026-11-18)

## Goal
"What macOS should be": a small, crisp menu bar manager that improves the bar without taking from it. Light (idle ~0% CPU, ~15 MB), event-driven, no surprise permissions. Spec: docs/FEATURES.md. MIT, github.com/George-Brothers/perch.

## PR stack (each on the one before)
1. #1 `perch-app-shell` → main: status items, divider trick, settings, launch at login.
2. #2 `perch-panel`: Accessibility scan of every app's menu bar items.
3. #3 `perch-redesign`: click = show/hide, Always/Auto/Hide priorities, LayoutEngine moves icons with synthetic ⌘-drags. Council: Opus 8.5, GPT Sol 9.
4. `perch-drawer`: opt-in drawer under the bar (Screen Recording, explained first in Settings → Features).
5. `perch-arrange`: Arrange as three drag-and-drop shelves.
6. `perch-spacing`: icon spacing slider (NSStatusItemSpacing / NSStatusItemSelectionPadding, reopen apps to apply).
7. `perch-search`: ⌥⇧Space search panel (Carbon hotkey). Replaced by Spotlight in `perch-spotlight-icons`.
8. `perch-spotlight`: App Intents (Show Hidden Icons, Search, Open Menu Bar Icon).
9. `perch-polish`: visual pass, docs, council fixes.
10. `perch-compact`: smaller Perch icon.
11. `perch-spotlight-icons`: icons in Spotlight; search panel and hotkey removed.
12. `perch-arrange-order`: Arrange as one ordered bar; drag to any spot; right-click opens it.
13. `perch-bar-item`: Perch shows nothing, a line, or an icon (Settings → General). Clicking empty menu bar space shows or hides; right-click arranges.
14. `perch-no-mouse`: moves by saved positions and app restarts, never the mouse.
15. `perch-overflow-bar`: click opens Perch's bar (no Screen Recording needed); hidden icons open in place via copied menus (MenuMirror). Auto-hide removed.
16. `perch-cutoff`: Arrange draws the bar to scale and ends where the screen does; on another display, a MacBook mark shows where its screen would cut off. No instruction text.
17. `perch-welcome`: one-time welcome under the menu bar (three lines, asks for Accessibility).
18. `perch-bar-stays`: Perch's bar stays open while an icon's menu is up, with that icon highlighted; it closes after you pick something.
19. `perch-no-restart`: Perch never restarts apps. Moves that only need the divider are instant; Hidden's order is Perch's own (`hiddenOrder`); other moves wait for the app's next launch (`pendingMoves`, undone exactly if you move the icon back).
20. `perch-arrange-drag`: drags across rows no longer get stuck (gesture on the rows, cancelled drags clear).
21. `perch-arrange-still`: Arrange holds still once you use it (top and right edges pinned).
22. `perch-instant-moves`: every Arrange move is instant: save positions, restart Control Center once, check each icon landed (else it waits, as in 19). Hiding checks priorities, not what's on screen, and puts the icon left of every icon meant to show.
23. `perch-no-hang`: no Accessibility or settings I/O can block the main thread. Saved spots are read in the background with each scan; sandboxed apps' containers are never read (macOS asks permission and the read blocks until answered); their positions are guessed and moves hug the known neighbor. Writes there prompt every time, so Perch never writes them either (see 26). Drops start a pass at once.
24. `perch-arrange-steady`: after a move Perch scans until two scans agree before publishing (a scan mid-move filed hidden icons under Turned off); drags allowed mid-move; Arrange logs every drag, drop and skipped move (category "arrange").
25. `perch-arrange-redrag`: icons can be dragged again right after a drop (frames refresh on every layout change).
26. `perch-private-apps`: Perch never writes a sandboxed app's settings (every write there asks permission). To show or hide one of its icons, Perch moves the icons around it instead: icons in the way get spots just past a known neighbor, hidden ones go far left. A move it can't make is undone and Arrange says so. Hiding goes by which icons are showing and meant to show, so a new app's icon at the far left doesn't block it.
27. `perch-one-reset`: each Control Center restart makes Focus show its name again, so moves wait while Arrange is open and apply with one restart when it closes (`holdsMoves`). Arrange keeps the order you set (`queuedBar`) and the bar follows. `plan` works from the whole order: hidden icons, then the shown order, then the clock; it keeps the longest run already in order (always including icons Perch can't move) and gives the rest spots between their neighbors. No writes means only the divider moves, which happens at once. Priorities change when the order is applied, so quitting with moves waiting leaves nothing half done. Moves no longer wait for an app's next launch.
28. `perch-spacing-no-restart`: the spacing slider no longer quits and reopens apps. Apply restarts Control Center (Apple's icons re-space; tested 2026-11-18: third-party icons keep their old spacing until their app reopens) and Perch.
29. `perch-first-launch`: without Accessibility Perch stays revealed (it can't see icons, and the seeded divider at 101 would hide nearly all of them). Every first hide, at launch or once Accessibility is granted, runs a real pass first (`placeFirst`), so only what doesn't fit is hidden.
30. `perch-safe-moves` (council round 1): Settings → Icons holds moves too (`hold(_:for:)`); a drop during a pass isn't lost (the pass only clears the order it applied); icons that appear while moves wait keep their own priority and spot (`queuedFrom`); queued moves keep waiting for an open menu instead of giving up; no passes while the screen is locked; writes are all or nothing and failed moves are undone (`StatusItemPositions.restore`); restarts are at least 10.5 s apart (launchd throttles faster respawns, leaving the bar empty) and verification waits for the icons to come back; priorities change after verification; the kept run needs saved spots in order; hugs next to an unreadable spot stop halfway to the next known one. The old wait-for-next-launch code (`pendingMoves`) is gone.
31. `perch-divider-fixes`: Perch's own item's room is reserved first; if the cut falls right of it, Perch moves to the cut and the divider is placed in the same pass (it used to wait for another trigger). Icons macOS places itself (the mic indicator) were counted twice; the walk skips them. Moving the divider or Perch's item ignored differences under 0.01, but hugged spots can be closer than that, so the divider never got between them; the tolerance is now 1e-6 and a no-op move reports false.
32. `perch-public-docs`: macOS 26 minimum (deployment target and README), build-from-source instructions with the optional signing script, current Gatekeeper steps, README claims qualified (copied menus can fall back to revealing; Spotlight skips Live Activities), README screenshot.
33. `perch-mirror-checks`: pressing a copied menu item checks the title at every step of its path; if an item moved, Perch takes the one item with that title or closes the menu, never a guess (an app reordering its submenus could otherwise run the wrong command).
34. `perch-review-fixes`: council round 2. A failed move blames only the icons that are out of order (and ones that never came back), so spots that landed aren't undone; position writes and undos run one at a time and every undo is checked; Perch shows every icon when Accessibility is turned off and hides only after a real pass; Control Center restarts wait out its launch time, an open menu and a locked screen; icons that appear while moves wait show in their real row and join the batch when moved; the planner refuses zero-width gaps and chains through unreadable icons; copied menus press an item only by a unique title or an unchanged menu; spacing Apply waits while moves apply.
35. `perch-minimal-settings`: Settings is one short page (open at login, what's in the menu bar, exact pictures, icon spacing, version and Quit). The Icons tab (a copy of Arrange) and the About tab are gone, and so is the Settings hold on moves.

## macOS 26 facts
- Reading or writing another app's sandbox container (~/Library/Containers/<id>) triggers the "access data from other apps" prompt (kTCCServiceSystemPolicyAppData) and the call blocks until it's answered. Perch tells sandboxed apps by their code signature, never by touching the container.
- Every status item window is owned by Control Center (layer 25); AX per app gives identity (AXExtrasMenuBar).
- Preferred position defaults: smaller = further right. Seeded Perch 100, divider 101.
- Frames are empty right after creating a status item; valid ~0.5 s later.
- Items behind the notch aren't drawn and can't be dragged. The drawer is the fix.
- AXPress opens Shottr and Wispr Flow's menus even when it reports an error. No synthetic clicks anywhere.
- Icon order is `NSStatusItem Preferred Position <name>` in each app's defaults (sandboxed apps: their container plist). Roughly the distance from the right edge; the whole bar sorts by it. Apps read it at launch, but on macOS 26 Control Center draws every status item and re-reads all saved positions when it restarts (SIGTERM; launchd brings it back in ~1 s). Tested 2026-11-18 with ActivityWatch, Google Drive and Shottr: they moved, their pids didn't change. Perch never restarts other apps (some show nag windows on launch). Control Center's items are in com.apple.controlcenter; it relaunches itself after SIGTERM.
- ⌘-drag events posted to a pid (cursor untouched) don't move icons. Only a real pointer drag does, so Perch doesn't drag at all.
- Removing a status item makes macOS forget its saved position, so Perch's items switch between two autosave names to move.
- AXPress on a hidden (off-screen) icon opens its menu off screen. While open, the AXMenu child of the item exposes every item (title, enabled, AXMenuItemMarkChar, AXMenuItemCmdChar/Modifiers: 1 shift, 2 option, 4 control, 8 no command) and submenus; AXPress on any item, even in a closed submenu, picks it. AXCancel on the AXMenu closes it.
- Panel-style icons (Stats) open an AXWindow whose position is settable.
- Each display draws its own copy of the status item windows.
- AX hit test (`AXUIElementCopyElementAtPosition`) on empty menu bar space returns role AXMenuBar owned by the front app; app menus and icons return AXMenuBarItem. That's how Perch spots an empty-space click.
- A collapsed divider is clamped to about 5,000 pt wide; its right edge is still where hidden icons end.
- Nothing can be moved or captured while the screen is locked; Perch skips passes then.

## Testing
Testing happens on a MacBook Pro with a notch, sometimes with an external display as the main one. Perch never sends synthetic clicks; test drags go through a temporary in-app hook that feeds mouse events to Perch's own Arrange window (never committed).
