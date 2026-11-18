# Perch feature spec

Perch is a light menu bar manager for macOS. The goal: the menu bar macOS should have shipped. Small, crisp, and it just works.

## The rules

1. **Do nothing until something changes.** No timers, no background screenshots. Perch reacts to what macOS already announces: an app opening or quitting, a display change, wake, unlock, a click.
2. **Improve the menu bar, never take from it.** Perch's own footprint is one small icon and a hairline divider.
3. **No surprise permissions.** Accessibility is required. Screen Recording is opt-in, behind a switch, with an explanation first.
4. **Never fight the user.** Perch waits while you use the mouse or a menu, and gives up on an icon it can't move instead of retrying it.

**Performance budget (each PR is checked against it):**

| Measure | Target |
|---|---|
| CPU while idle | about 0% |
| Memory while idle | under 30 MB |
| Opening the drawer, Arrange or search | under 0.2 s |
| Icon pictures | only while the drawer or Arrange is open |

## Built

| Feature | How it works |
|---|---|
| Show and hide | Click the bird. A divider stretched 10,000 pt pushes hidden icons off screen. |
| Priorities | Each icon is Always, When there's room, or Hidden. Perch ⌘-drags icons across the divider to match, on launch, priority change, display change, wake, unlock, and app launch or quit. |
| Arrange | Three shelves; drag an icon to the one you want. Right-click for the same moves. |
| Drawer (opt-in) | Hidden icons in a small bar under the menu bar. Needs Screen Recording; turned on in Settings → Features after an explanation. |
| Search | ⌥⇧Space by default. Type, arrow keys, Return opens the icon's menu, even when hidden. |
| Spotlight and Shortcuts | App Intents: Show Hidden Icons, Search Menu Bar Icons, Open Menu Bar Icon (any icon, by name). |
| Spacing | Slider for `NSStatusItemSpacing` and `NSStatusItemSelectionPadding`. Apps pick it up when they reopen; Perch offers to reopen them. |
| Auto-hide | After a delay or a click outside. Never while a menu is open or the pointer is in the bar. |
| Settings | General, Features, Icons, About. Launch at login, icon style. |

## Next

1. **Show icons while they're active.** For example a recording or timer icon comes out of hiding while it's doing something. Needs a cheap change signal; no polling.
2. **Per-display layouts** that switch when you plug a monitor in or out.
3. **Profiles** (School, Client work, Desk), switched by Focus mode or display.
4. **Custom compact icons** for long items, static so they cost nothing.
5. **Release:** notarized build, Homebrew tap.

## Not doing (and why)

| Feature | Why not |
|---|---|
| Menu bar tints and shapes | Extra windows on every screen and Space, all cosmetic |
| Widgets (CPU, RAM) | Constant polling; Stats already does it |
| Clipboard history, Dynamic Island, weather | Different apps; this is where Bartender got heavy |
| Live shrunken copies of icons | Would mean screenshotting the menu bar constantly |
