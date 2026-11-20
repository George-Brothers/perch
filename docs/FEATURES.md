# Perch feature spec

Perch is a light menu bar manager for macOS. The goal: the menu bar macOS should have shipped. Small, crisp, and it just works.

## The rules

1. **Do nothing until something changes.** No timers, no background screenshots. Perch reacts to what macOS already announces: an app opening or quitting, a display change, wake, unlock, a click.
2. **Improve the menu bar, never take from it.** Perch's own footprint is one small icon and a hairline divider.
3. **No surprise permissions.** Accessibility is required. Screen Recording is opt-in, behind a switch, with an explanation first.
4. **Never touch the mouse.** Perch moves icons by saving their positions, never with synthetic clicks or drags, and waits while a menu is open.

**Performance budget (each PR is checked against it):**

| Measure | Target |
|---|---|
| CPU while idle | about 0% |
| Memory while idle | under 30 MB |
| Opening Perch's bar or Arrange | under 0.2 s |
| Icon pictures | only for icons that are new, changed size, or 30 min old (each capture flashes the purple dot) |

## Built

| Feature | How it works |
|---|---|
| Perch's bar | Click empty menu bar space (or Perch's line or icon). Every icon that's hidden or doesn't fit, under the menu bar. Clicking one opens its menu there: Perch copies the off-screen menu through Accessibility (panels are moved instead). A divider stretched 10,000 pt keeps those icons off screen. |
| In the menu bar | Nothing (default), a line, or an icon. With nothing, Accessibility tells Perch a click landed on the front app's empty bar, not an icon. Without Accessibility the icon stays. |
| Order | Each icon is in the bar or Hidden, and the bar's order is its priority: when it runs out of room, the leftmost icons wait in Hidden. Perch moves its own divider to match (instant) on launch, a change in Arrange, display change, wake, unlock, and app launch or quit. |
| Arrange | Right-click empty menu bar space. Rows that mirror the bar: Menu bar (in order, Perch's own item included), Hidden, Turned off. Drag an icon to any spot: Perch saves that position and restarts the icon's app (menu-bar-only apps right away, with the spot held open; apps with windows when they next open). Turned-off icons open System Settings → Menu Bar. Rows are drawn to scale and end where the screen does; on another display, a MacBook mark shows where a MacBook's bar would cut off (learned the last time Perch saw the built-in screen). |
| Exact pictures (opt-in) | Perch's bar shows icons exactly as they look instead of app icons. Needs Screen Recording; turned on in Settings → Features after an explanation. |
| Spotlight | Every icon is a Core Spotlight item, re-indexed only when the set of icons changes. Picking one opens its menu, even when hidden. |
| Shortcuts | App Intents: Show Hidden Icons, Open Menu Bar Icon (any icon, by name). |
| Spacing | Slider for `NSStatusItemSpacing` and `NSStatusItemSelectionPadding`. Apps pick it up when they reopen; Perch offers to reopen them. |
| Settings | General, Features, Icons, About. Launch at login, what Perch shows in the bar. |

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
