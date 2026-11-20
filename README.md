<img src="assets/icon-1024.png" width="96" height="96" alt="Perch icon">

# Perch

A light menu bar manager for macOS. Perch hides the menu bar icons you don't need and brings them back with one click, without slowing your Mac down.

> Early development. See [docs/FEATURES.md](docs/FEATURES.md) for what's built and what's next.

## What it does

- **Click empty menu bar space for Perch's bar.** Every icon that's hidden or doesn't fit drops down in a small bar under the menu bar. Click one and its menu opens right there, like any menu, with Perch's bar still showing. Nothing moves in the menu bar. Perch adds nothing to your bar unless you want it to: a thin line or an icon are options in Settings.
- **Put every icon where you want it.** Arrange mirrors your menu bar: the bar in order, then Hidden, then icons turned off in System Settings. Drag an icon anywhere and Perch moves the real one there. Order is priority: when the bar is full, icons on the left wait in Hidden until there's room.
- **Fits your screen.** On a laptop, icons that would land behind the notch go to Perch's bar instead, in your order.
- **Exact pictures (optional).** Perch's bar shows app icons, or with Screen Recording (Settings → Features), the icons exactly as they look.
- **Spotlight.** Every menu bar icon shows up in Spotlight. Type its name and press Return to open its menu, even when it's hidden.
- **Shortcuts.** Show Hidden Icons, Arrange Menu Bar and Open Menu Bar Icon actions.
- **Tighter spacing.** A slider fits more icons in the same bar.
- **Launch at login.**

Perch uses about 15 MB of memory and no CPU while idle. It reacts to events and never polls. It needs Accessibility to see and open icons; Screen Recording only for exact pictures.

## Using it

- **Click** empty menu bar space (or Perch's line or icon): Perch's bar.
- **Right-click** empty menu bar space: Arrange. Drag icons to reorder them. Settings and Quit are in its ⋯ menu.
- **Spotlight**: "Arrange Menu Bar" opens Arrange too.
- **⌘Space**, then an icon's name: open that icon's menu.

## Build

Requires macOS 15 or later and Xcode 26.

```sh
./scripts/build.sh            # builds build/Perch.app
./scripts/build.sh --install  # also copies it to /Applications and opens it
```

Or open `Perch.xcodeproj` and press Run.

Perch isn't notarized yet. The first time you open a downloaded copy, right-click it and choose Open.

## How it works

macOS has no API for hiding another app's menu bar icon. Perch adds a divider item and, when hiding, stretches it thousands of points wide. Everything to its left is pushed off the screen. Shrinking the divider brings them back.

Perch never touches your mouse. macOS keeps a saved position for every menu bar icon. To fit your screen, Perch moves only its own divider, which is instant. To move another app's icon, it saves the icon's new position and quietly restarts that app, holding the spot open so nothing jumps. Apps with windows open aren't restarted; their icon moves the next time they open. Accessibility tells Perch where each icon is. A hidden icon sits off screen, so when Perch opens it, its menu opens off screen too. Perch reads that menu through Accessibility, closes it, and shows the same items as its own menu; picking one presses the real item. Icons that open a panel get the panel moved under Perch's bar.

## License

MIT. See [LICENSE](LICENSE).
