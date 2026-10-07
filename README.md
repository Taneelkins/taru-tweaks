# Taru Tweaks

Personal macOS utility for a MacBook Pro (M5, macOS 26). One app, one set of permissions, modules for:

| Module | Replaces | Highlights |
|---|---|---|
| **Switcher** | AltTab Pro | ⌘⇥ window switcher across every Space and fullscreen app, live/remembered previews, 5 shortcuts with per-shortcut filters, search, thumbnails/icons/titles styles, app exceptions, trackpad swipe. macOS's own switcher moves to ⌥⇥. |
| **Desktop** | — | ⌘D Show Desktop (minimize all, press again to restore). Dock right-click shows Force Quit. |
| **Battery** | AlDente Pro | Charge limit, sailing, discharge, auto-discharge, top up, heat protection, calibration, stop charging asleep, stay awake until limit, clamshell discharge, MagSafe LED, power modes, schedules + history, notifications, dashboard with Sankey power flow, Apple Shortcuts actions. Root helper uses the M5 SMC keys `CHTE` / `CHIE` / `ACLC`. |
| **XDR Boost** | BrightIntosh | Up to 1000 nits everywhere, custom shortcuts, battery/heat cut-offs, timer, auto-on with charger, external XDR displays. |
| **Task Manager** | Windows Task Manager | Processes grouped by app, CPU/memory, not-responding detection, End task / Force quit / process tree, live CPU/GPU/memory/network/disk graphs, startup items. ⌃⇧Esc. |

## Build

```
brew install xcodegen
xcodegen generate
xcodebuild -project TaruTweaks.xcodeproj -scheme TaruTweaks -configuration Release -derivedDataPath build build
cp -R "build/Build/Products/Release/Taru Tweaks.app" /Applications/
```

Signing uses the local Apple Development certificate (see `project.yml`). Keep the same certificate so Accessibility / Screen Recording grants survive rebuilds.

## Layout

- `App/` app shell, menu bar items, settings window, Shortcuts intents
- `Modules/` Switcher, Battery, Brightness, TaskManager
- `Shared/` theme, settings UI kit, hotkeys, battery config shared with the helper
- `Helper/` root launch daemon (`com.taru.tweaks.helper`) registered with `SMAppService`
