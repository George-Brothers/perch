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
7. `perch-search`: ⌥⇧Space search panel (Carbon hotkey, no permission).
8. `perch-spotlight`: App Intents (Show Hidden Icons, Search, Open Menu Bar Icon).
9. `perch-polish`: visual pass, docs.

## macOS 26 facts
- Every status item window is owned by Control Center (layer 25); AX per app gives identity (AXExtrasMenuBar).
- Preferred position defaults: smaller = further right. Seeded Perch 100, divider 101.
- Frames are empty right after creating a status item; valid ~0.5 s later.
- Items behind the notch aren't drawn and can't be dragged. The drawer is the fix.
- AXPress fails for Shottr and Wispr Flow; fallback is a synthetic click with the pointer put back.
- Each display draws its own copy of the status item windows.
- Nothing can be moved or captured while the screen is locked; Perch skips passes then.

## Testing
George's Mac is the test machine (MacBook Pro with notch, sometimes a Dell S3225QS as main display). Helpers live in the session scratchpad. Check the screen is unlocked and the front window before synthetic clicks.
