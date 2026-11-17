<img src="assets/icon-1024.png" width="96" height="96" alt="Perch icon">

# Perch

A light menu bar manager for macOS. Perch hides the menu bar icons you don't need and brings them back with one click, without slowing your Mac down.

> Early development. See [docs/FEATURES.md](docs/FEATURES.md) for the full plan.

## What works today

- **Hide and show.** Click the bird to show your hidden icons; click again to hide them.
- **Sections.** Icons right of the │ line stay visible. Icons left of it hide. An optional Archived section (┆ line) holds icons you rarely need; Option-click the bird to see those.
- **Notch-safe.** Perch puts its icon next to Control Center, so a crowded menu bar can't push it behind the notch.
- **Auto-hide.** Icons hide again after a delay, when you click elsewhere, or when you switch apps. Perch waits while a menu is open.
- **Settings** with launch at login and a choice of menu bar icon.

Perch uses about 15 MB of memory and no CPU while idle. It needs no special permissions yet.

## Using it

1. Click the bird to show everything, including the │ line.
2. Hold ⌘ and drag the icons you always want to see to the right of the │ line.
3. Click the bird again. Everything left of the line hides.

Right-click the bird for Settings and Quit. Opening Perch again while it's running also opens Settings.

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

## License

MIT. See [LICENSE](LICENSE).
