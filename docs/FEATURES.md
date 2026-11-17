# Perch feature spec

Perch is a light menu bar manager for macOS. It aims to do most of what Bartender does without its weight.

## The rule: do nothing until something changes

Perch never polls the menu bar on a timer and never takes screenshots in the background. It reacts only to events macOS already sends: an app launching or quitting, a display connecting, Wi-Fi changing, the Mac waking, the mic turning on.

**Performance budget (each PR is checked against it):**

| Measure | Target |
|---|---|
| CPU while idle | about 0% |
| Memory while idle | under 30 MB |
| Opening the dropdown | under 0.2 s |
| Moving your cursor on its own | never |
| Screenshots of icons | only while the dropdown is open, then cached |

## Features

### 1. Core hiding
- **Three sections:** Shown, Hidden and Archived. Archived icons never appear in the bar, only in Perch.
- **Reveal:** click the Perch icon, click an empty part of the menu bar, scroll or swipe on the bar, hover, or press a hotkey. Click-only is the default; hover is opt-in.
- **Auto-rehide:** after a delay, on a click outside the menu bar, or on an app switch. Never while a menu is open.
- **Clean mode:** one hotkey hides everything, for screenshots and screen shares.

### 2. Layout
- **Drag-and-drop dropdown:** reorder icons and move them between sections; the real menu bar follows.
- **Moves happen in one pass, only when you ask.** No constant re-arranging.
- **Layout guard:** Perch remembers your exact order and puts it back when macOS or an app update reshuffles it.
- **New icon rule:** a new app's icon goes to Shown, Hidden, or "ask me".
- **Backups:** automatic before every change, plus export and import.
- **Spacers:** blank gaps to group icons.
- **System icons** (Wi-Fi, Battery, Bluetooth) move like any other icon.

### 3. Notch and screens
- **Perch Bar:** a strip that drops below the menu bar and holds hidden icons.
- **Notch rescue:** icons that would land behind the notch go to the Perch Bar automatically.
- **Spacing presets:** Default, Small (about 2 more icons fit) and Tiny (about 4 more). Needs one log-out.
- **Per-display layouts** that switch when you plug a monitor in or out.

### 4. Keyboard
- **Quick Search:** a hotkey opens a search box; type "wifi" and its menu opens. The same box switches profiles and runs actions.
- **Hotkeys** for showing hidden icons, the Perch Bar, search, clean mode, each profile, and any single icon.

### 5. Spotlight and Shortcuts
Built on App Intents, so it costs nothing until Spotlight calls it.
- **Actions in Spotlight:** "Show Hidden Icons", "Hide Icons", "Show Archived Icons", "Clean Mode", "Switch Perch Profile", "Open Menu Bar Item".
- **Menu bar icons searchable in Spotlight:** type "Wispr" in Spotlight, pick the Perch result, and Wispr's menu opens.
- **Spotlight quick keys:** assign a short key such as `ph` to an action.
- **Shortcuts app and `perch://` links**, so Raycast, Shortcuts or a script can drive Perch.

### 6. Automations
Show an icon when:

| Trigger | Example |
|---|---|
| Battery unplugged, charging, or below X% | Show Battery under 20% |
| Wi-Fi on a named network, or disconnected | Show VPN away from home Wi-Fi |
| An app is running or in front | Show Granola while Zoom is open |
| Mic or camera in use | Show Wispr during a call |
| Focus mode | Different icons for School and Client work |
| Display connected | Desk layout at your desk |
| Time schedule | Hide distractions 9 to 5 |

Each trigger listens to a system notification, so none of them poll.

### 7. Profiles
- Whole layouts you can swap (School, Client work, Desk).
- Switch by hotkey, automation, Focus mode or display setup.

### 8. Groups
- Several icons fold into one icon that opens a small dropdown, for example Drive, Dropbox and iCloud as one "Cloud" icon.

### 9. Settings and polish
- Settings tabs: General, Sections, Auto-Hide, Hotkeys, Automations, Profiles, Displays, Advanced, About.
- **Health card:** permission status, last layout check, and Perch's own CPU and memory.
- **Works without Screen Recording:** falls back to app icons. Screen Recording is optional and asked for once.
- Launch at login, daily update check, light and dark mode.

## Not doing (and why)

| Feature | Why not |
|---|---|
| Menu bar tints and shapes | Extra windows on every screen and Space, all cosmetic |
| Widgets (CPU, RAM) | Constant polling; Stats already does it |
| Clipboard history, Dynamic Island, weather | Different apps; this is where Bartender got heavy |
| Location trigger | Another permission and battery drain |
| "Not clicked in 30 days" | Would mean watching every click |

## Build order (one PR each)

1. App shell: the Perch icon, sections with dividers, hide and show, auto-rehide, settings window, launch at login.
2. Icon detection and the dropdown layout panel.
3. Rearranging, layout guard, new icon rule, backups.
4. Perch Bar, notch rescue, spacing presets.
5. Quick Search, hotkeys, clean mode.
6. Spotlight and Shortcuts (App Intents, `perch://` links).
7. Automations, profiles, per-display layouts.
8. Groups and spacers.
9. Release: GitHub release, Homebrew tap, README with screenshots.
