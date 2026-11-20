# Perch feature spec

Perch is a light menu bar manager for macOS. The goal: the menu bar macOS should have shipped. Small, crisp, and it just works.

## The rules

1. **Do nothing until something changes.** No timers, no background screenshots. Perch reacts to what macOS already announces: an app opening or quitting, a display change, wake, unlock, a click.
2. **Improve the menu bar, never take from it.** By default Perch adds nothing you can see to the menu bar; a thin line or a small icon are options.
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
| Perch's bar | Click empty menu bar space (or Perch's line or icon). Every icon that's hidden or doesn't fit, in a dark pill under the menu bar (Arrange uses the same dark glass, so both stand out over any window; icon pictures taken on a light menu bar are turned light). Clicking one opens its menu there: Perch copies the off-screen menu through Accessibility (panels are moved instead). The bar stays open with that icon highlighted, like the menu bar, and closes once you pick something. Right-click an icon you hid for Show in Menu Bar (if that needs the bar to reset, it resets right away: there's no Arrange to wait for); an icon there only for lack of room says so. A divider stretched thousands of points wide keeps those icons off screen. |
| In the menu bar | Nothing (default), a line, or an icon. With nothing, Accessibility tells Perch a click landed on the front app's empty bar, not an icon. Without Accessibility the icon stays. |
| Order | Each icon is in the bar or Hidden, and the bar's order is its priority: when it runs out of room, the leftmost icons wait in Hidden. Perch moves its own divider to match (instant) on launch, a change in Arrange, display change, wake, unlock, app launch or quit, and whenever an icon right of the divider appears, goes or changes width (a Live Activity, say: macOS adds those without any app launching). That last one costs nothing: AppKit reports when the divider's right edge moves, and Perch ignores the moves it makes itself. |
| Live Activities | macOS puts them (and the mic and camera dot) at the left end of the shown icons itself; they have no saved position, so Perch can't hide or reorder them. Perch leaves room for them, hiding the leftmost icon if needed, and Arrange shows them pinned at the left of the bar side, not draggable, with a note saying so. |
| Arrange | Right-click empty menu bar space. One strip that mirrors the bar: Hidden (dimmed, in Perch's bar order) left of a line, then the menu bar in order (Perch's own item included). Drag an icon to any spot, or drag the line to hide or show the icons beside it (one move per icon). Opens under the menu bar, or over it (Settings → Arrange): over it, the strip covers the bar up to the clock and Control Center, with a toolbar for Settings and Done; beside a notch, if it doesn't fit, it opens under the bar instead. Icons turned off in System Settings aren't shown. Instant when only the divider has to move (hiding the leftmost icon, showing the rightmost hidden one) and for any order inside Hidden, which Perch keeps itself. Otherwise Arrange shows the new order right away and the bar follows when Arrange closes: Perch saves new positions for the icons that have to move (as few as possible, never a sandboxed app's) and restarts Control Center once, which places every app's icon at its saved spot (about a second; Apple's icons blink and Focus shows its name). Apps are never restarted. A move Perch can't make is refused with a note, and so is an icon that didn't land. Icons are drawn at their real size; on another display, a MacBook mark shows where a MacBook's bar would cut off (learned the last time Perch saw the built-in screen). |
| Exact pictures (opt-in) | Perch's bar shows icons exactly as they look instead of app icons. Needs Screen Recording; turned on in Settings after an explanation. |
| Spotlight | Every icon is a Core Spotlight item, re-indexed only when the set of icons changes. Picking one opens its menu, even when hidden. |
| Shortcuts | App Intents: Show Hidden Icons, Arrange Menu Bar, Open Menu Bar Icon (any icon, by name). |
| Spacing | Slider for `NSStatusItemSpacing` and `NSStatusItemSelectionPadding`. Apply restarts Control Center, so Apple's icons change at once; other apps pick it up the next time they open. Perch never restarts them. |
| Settings | The gear in Arrange (or ⌘, while Arrange is open). One short page: open at login, what Perch shows in the bar, where Arrange opens, exact pictures, icon spacing, version, Guide and Quit. |
| Setup | Plays on first launch, in order: Welcome (a short animation of a crowded menu bar tucking its extra icons into Perch's bar), Accessibility (live), a few choices (open at login, what's in the menu bar, where Arrange opens), and Perch is ready (how to click and right-click, with a button for the Guide). It comes back after Accessibility is allowed if it was closed before. |
| Guide | From Settings → Guide, or the end of setup. A window with topics on the left (About Perch, Accessibility, Hidden Icons, Arrange, Spotlight, Settings); pick any to learn it, most with a button to try it. Next steps through them in order. |

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
