<img src="assets/icon-1024.png" width="96" height="96" alt="Perch icon">

# Perch

A light menu bar manager for macOS. Perch hides the menu bar icons you don't need and brings them back with one click, without slowing your Mac down.

> Early development. See [docs/FEATURES.md](docs/FEATURES.md) for what's built and what's next.

## What it does

- **Click the bird to show or hide.** Hidden icons come back with one click and go away with another.
- **Put every icon where you want it.** Arrange shows your menu bar in order. Drag an icon to a new spot and Perch moves the real one there. Left of the line is hidden. Icons can also show only when there's room (right-click one).
- **Drawer (optional).** Hidden icons drop down in a small bar under the menu bar, so nothing has to fit next to the notch. Needs Screen Recording, so it's off until you turn it on in Settings → Features.
- **Spotlight.** Every menu bar icon shows up in Spotlight. Type its name and press Return to open its menu, even when it's hidden.
- **Shortcuts.** Show Hidden Icons, Arrange Menu Bar and Open Menu Bar Icon actions.
- **Tighter spacing.** A slider fits more icons in the same bar.
- **Auto-hide**, launch at login and a choice of menu bar icon.

Perch uses about 15 MB of memory and no CPU while idle. It reacts to events and never polls. It needs Accessibility to see and move icons; Screen Recording only if you turn on the drawer.

## Using it

- **Click** the bird: show or hide hidden icons (or open the drawer, if it's on).
- **Right-click** the bird: Arrange. Drag icons to reorder them. Settings and Quit are in its ⋯ menu.
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

To move an icon across the divider, Perch does what you would: a quick ⌘-drag, with the pointer hidden and put back. Accessibility tells it where each icon is. The drawer draws icons from pictures taken only while it's open.

## License

MIT. See [LICENSE](LICENSE).
