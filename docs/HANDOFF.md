# Perch handoff (2026-11-17)

## Goal
Native Swift macOS menu bar manager ("Perch"): Bartender-level features, lightweight (idle ~0% CPU, <30 MB). Spec: docs/FEATURES.md. Open source (MIT) at github.com/George-Brothers/perch.

## Done
- PR #1 `perch-app-shell` → main: status items (bird + │ hidden divider + ┆ archived divider), 10,000pt divider trick, positions seeded next to Control Center (100/101/102) so the notch can't hide the bird, waits for real frames before first hide, order check, auto-hide (timer / click outside / app switch; waits while a menu or Control Center panel is open), Settings (General, Sections, Auto-Hide, About), launch at login.
- PR #2 `perch-panel` → perch-app-shell (stacked): click bird opens panel listing all items via Accessibility (AXExtrasMenuBar per app; on macOS 26 all item windows are owned by Control Center), sections by divider x-edges, "Not in the menu bar" for items with no CG window. Clicking an item reveals hidden section then AXPress; fallback synthetic click + cursor restore.
- Local signing cert "Perch Local Signing" in George's login keychain; scripts/build.sh signs with it so the Accessibility grant survives rebuilds. George granted Accessibility.

## Findings (macOS 26.5, MacBook Pro with notch)
- Items behind the notch are simply not drawn. George's bar is full up to the notch.
- Preferred positions: smaller = further right (Control Center ~132).
- Status item frames are empty (height 0) right after creation; valid ~0.5 s later.
- Control Center panels (Wi-Fi etc.) are layer-23 windows from y=0; third-party menus are layer 101.
- Shottr and Wispr Flow do NOT support AXPress (-25204); most third-party items need the click fallback.
- George turned auto-hide off and switched icon to Chevron while trying it (2026-11-17).

## George's feedback (latest)
"Too clunky. UI needs to be cleaner, UX better, function not built out enough, needs to be super adaptable and just work." He asked for a diagnosis and improvement proposal (given in chat 2026-11-17). Awaiting his pick before redesigning.

## Next
Depends on George's answer to the redesign proposal. PR 3 (rearranging via simulated ⌘-drag, layout guard, new-icon rule, backups) is the core missing function.

## Testing notes
Helpers in the session scratchpad (click, rclick, move, esc, win2/win3/win4 window dumps). Before synthetic clicks, confirm the front window at that point is Perch; earlier clicks landed in T3 Code.

## Update: George's answers and the redesign in progress (2026-11-17)
- George: click the bird must simply show/hide (PR 2 made click open the panel, which is why "it wasn't unhiding"). He wants Stats always visible. Perch takes too much bar space. Simplify setup. Priority model (Always / Auto / Hide): yes. Screen Recording: only if it really makes sense → not used. Auto-hide: he turned it off because seeing things was a pain.
- Mover prototype WORKS on macOS 26: synthetic ⌘-drag (CGEvent flags .maskCommand, leftMouseDown → 10 leftMouseDragged steps → leftMouseUp, posted to .cgSessionEventTap, cursor warped back). Dropping at divider.maxX + ~2 puts an item just right of the divider. Stats was moved this way (George's bar changed).
- Redesign being built on branch `perch-redesign` (on top of perch-panel), one PR:
  1. Click bird = show/hide. Option-click or right-click → "Arrange Icons…". No click-action setting.
  2. Smaller footprint: fixed narrow lengths for bird and divider; archived divider removed (Hide covers it).
  3. Priorities per icon (Always / Auto / Hide), stored in UserDefaults by bundleID#identifier. Default Auto.
  4. Layout engine: reveal, ⌘-drag items across the divider so Always + as many Auto icons as fit (left bound = notch right edge via screen.auxiliaryTopRightArea, else screen midX) are right of the divider; rest left. Runs on launch, priority change, display change, wake, app launch (debounced). Auto-resets Perch's own positions if the bird ends up left of the divider.
  5. Arrange panel: compact rows (icon, name, Always/Auto/Hide picker). Same list in Settings → Icons.
  6. Settings: General (startup, icon, auto-hide, permission), Icons, About. Sections and Auto-Hide panes removed.
- After building: run the `council` skill to review the PR (George asked).
