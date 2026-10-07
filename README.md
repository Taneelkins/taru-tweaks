# Taru Tweaks

Personal macOS utility for a MacBook Pro (M5, macOS 26). One app, one set of permissions, modules for:

| Module | Replaces | Highlights |
|---|---|---|
| **Switcher** | AltTab Pro | ⌘⇥ window switcher across every Space and fullscreen app, live/remembered previews, 5 shortcuts with per-shortcut filters, search, thumbnails/icons/titles styles, app exceptions, trackpad swipe. macOS's own switcher moves to ⌥⇥. |
| **Menu Bar** | Ice / Bartender | ‹ toggle + divider: icons left of the divider hide (divider stretches 10,000 pt). ⌃⌥⌘M, auto re-hide, hide on click-away, refuses to collapse if the toggle is on the hidden side. Other apps' icons can be placed by editing their `NSStatusItem Preferred Position <name>` defaults and relaunching them (macOS ignores synthetic ⌘-drags). |
| **Desktop** | — | ⌘D Show Desktop (minimize all, press again to restore). Dock right-click shows Force Quit. |
| **Taru Dock** | macOS Dock | Own Dock that replaces the macOS one (hidden via autohide-delay 1000, restored on quit). Presets you swipe between with two fingers, slide + rubber band, no Dock restart so minimized windows stay put. Running dots, badges (read from the hidden macOS Dock), folder stacks, drag to add/reorder/remove, drop files on apps or Trash, right-click menu with Force Quit and Also in Preset. |
| **Live Wallpaper** | Muro | Video wallpaper played 24/7 by Taru Tweaks itself: desktop-level window on every Space/display (ordered under Übersicht widgets), AVPlayerLooper, pauses only when nothing can see it (occlusion, lock, display sleep). Sets a still frame as the system wallpaper for lock screen/Mission Control. Library + import in settings. |
| **Battery** | AlDente Pro | Charge limit, sailing, discharge, auto-discharge, top up, heat protection, calibration, stop charging asleep, stay awake until limit, clamshell discharge, MagSafe LED, power modes, schedules + history, notifications, dashboard with Sankey power flow, Apple Shortcuts actions. Root helper uses the M5 SMC keys `CHTE` / `CHIE` / `ACLC`. |
| **XDR Boost** | BrightIntosh | Up to 1000 nits everywhere, custom shortcuts, battery/heat cut-offs, timer, auto-on with charger, external XDR displays. |
| **Task Manager** *(standalone app)* | Windows Task Manager | Processes grouped by app, CPU/memory, not-responding detection, End task / Force quit / process tree, live CPU/GPU/memory/network/disk graphs, startup items. ⌃⇧Esc. |

Two apps are built from this repo: **Taru Tweaks** (menu bar, all modules) and **Task Manager** (standalone, Dock app). Taru Tweaks owns the ⌃⇧Esc shortcut and launches Task Manager.

## Build

```
brew install xcodegen
xcodegen generate
for s in TaruTweaks TaskManager; do xcodebuild -project TaruTweaks.xcodeproj -scheme $s -configuration Release -derivedDataPath build build; done
cp -R "build/Build/Products/Release/Taru Tweaks.app" "build/Build/Products/Release/Task Manager.app" /Applications/
```

Signing uses the local Apple Development certificate (see `project.yml`). Keep the same certificate so Accessibility / Screen Recording grants survive rebuilds.

## Layout

- `App/` app shell, menu bar items, settings window, Shortcuts intents
- `Modules/` Switcher, Battery, Brightness, Dock, MenuBar, TaskManager
- `TaskManagerApp/` standalone Task Manager app entry point
- `Shared/` theme, settings UI kit, hotkeys, battery config shared with the helper
- `Helper/` root launch daemon (`com.taru.tweaks.helper`) registered with `SMAppService`
