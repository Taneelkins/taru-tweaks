import SwiftUI
import AppKit

struct SwitcherSettings: View {
    let page: String
    @ObservedObject var prefs = SwitcherPrefs.shared
    @State var shortcutIndex = 0
    @State var trusted = AXIsProcessTrusted()
    @State var capture = CGPreflightScreenCaptureAccess()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch page {
            case "switcher.appearance": appearance
            case "switcher.controls": controls
            case "switcher.exceptions": VStack(alignment: .leading, spacing: 0) { PageTitle(title: "Exceptions"); ExceptionsView() }
            case "desktop": extras
            default: shortcuts
            }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted(); capture = CGPreflightScreenCaptureAccess() }
    }

    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Window Switcher", subtitle: "Every window, every Space, with live previews. ⌥⇥ switches apps like macOS does.")
            HStack(spacing: 6) {
                ForEach(prefs.shortcuts.indices, id: \.self) { i in
                    Button { shortcutIndex = i } label: {
                        Text("\(i + 1)  \(modifierString(prefs.shortcuts[i].holdMask))\(keyString(prefs.shortcuts[i].key))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(shortcutIndex == i ? Color.black : Palette.ash)
                            .background(shortcutIndex == i ? Theme.shared.accent : Color.black)
                    }.buttonStyle(.plain)
                }
                if prefs.shortcuts.count < 5 {
                    Button("+") { prefs.shortcuts.append(Shortcut(holdMask: 0x100000 | 0x40000, key: 48)); shortcutIndex = prefs.shortcuts.count - 1 }
                        .buttonStyle(.plain).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash).padding(.horizontal, 8)
                }
                Spacer()
                if prefs.shortcuts.count > 1 {
                    Button("REMOVE") { prefs.shortcuts.remove(at: shortcutIndex); shortcutIndex = 0 }
                        .buttonStyle(.plain).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
                }
            }
            if prefs.shortcuts.indices.contains(shortcutIndex) {
                let b = $prefs.shortcuts[shortcutIndex]
                VStack(spacing: 0) {
                    SettingRow(title: "Enabled") { Toggle("", isOn: b.enabled).toggleStyle(.switch).labelsHidden() }
                    SettingRow(title: "Shortcut", detail: "Hold the modifiers, tap the key. ⇧ goes backwards.") { KeyRecorder(mask: b.holdMask, key: b.key) }
                    SettingRow(title: "When keys are released") { Seg(options: [("Focus window", Release.focus), ("Stay open", Release.stay)], value: b.release) }
                    SettingRow(title: "Show windows from") { Seg(options: [("All apps", AppsFilter.all), ("Active app", AppsFilter.active), ("Other apps", AppsFilter.others)], value: b.apps) }
                    SettingRow(title: "Spaces") { Seg(options: [("All Spaces", SpacesFilter.all), ("Current", SpacesFilter.current)], value: b.spaces) }
                    SettingRow(title: "Screens") { Seg(options: [("All screens", ScreensFilter.all), ("Screen with mouse", ScreensFilter.mouse)], value: b.screens) }
                    SettingRow(title: "Minimized windows") { Seg(options: [("Show", Visibility.show), ("At the end", Visibility.end), ("Hide", Visibility.hide)], value: b.minimized) }
                    SettingRow(title: "Hidden apps") { Seg(options: [("Show", Visibility.show), ("At the end", Visibility.end), ("Hide", Visibility.hide)], value: b.hidden) }
                    SettingRow(title: "Fullscreen windows") { Seg(options: [("Show", Visibility.show), ("At the end", Visibility.end), ("Hide", Visibility.hide)], value: b.fullscreen) }
                    SettingRow(title: "Apps with no open window") { Seg(options: [("Show", Visibility.show), ("At the end", Visibility.end), ("Hide", Visibility.hide)], value: b.windowless) }
                    SettingRow(title: "Order") { Seg(options: [("Recently used", Ordering.recent), ("Newest", Ordering.created), ("A–Z", Ordering.alphabetical), ("Space", Ordering.space)], value: b.ordering) }
                    SettingRow(title: "Quick tab skips the current app's other windows", detail: "One tap always lands in a different app") { Toggle("", isOn: b.skipSameApp).toggleStyle(.switch).labelsHidden() }
                    SettingRow(title: "One icon per app", detail: "Works like the macOS app switcher") { Toggle("", isOn: b.appsOnly).toggleStyle(.switch).labelsHidden() }
                }
            }
            Text("Shortcut 3 (⌥⇥) is an app switcher like macOS's own.").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 6)
        }
    }

    var appearance: some View {
        VStack(spacing: 0) {
            PageTitle(title: "Switcher look")
            SettingRow(title: "Style") { Seg(options: [("Thumbnails", Style.thumbs), ("App icons", Style.icons), ("Titles", Style.titles)], value: $prefs.style) }
            SettingRow(title: "Size") { Seg(options: [("S", TileSize.small), ("M", TileSize.medium), ("L", TileSize.large), ("Auto", TileSize.auto)], value: $prefs.size) }
            SettingRow(title: "Max rows (auto size)", detail: "\(prefs.maxRows)") { Stepper("", value: $prefs.maxRows, in: 1...6).labelsHidden() }
            SettingRow(title: "Max width", detail: "\(Int(prefs.maxWidth * 100))% of the screen") { Slider(value: $prefs.maxWidth, in: 0.4...0.98).frame(width: 180) }
            SettingRow(title: "Show on") { Seg(options: [("Active screen", ShowOn.active), ("Mouse screen", ShowOn.mouse), ("Main", ShowOn.main)], value: $prefs.showOn) }
            SettingRow(title: "Appear after", detail: prefs.delay == 0 ? "Instantly" : "\(Int(prefs.delay * 1000)) ms · a quick tap switches without flashing the switcher") { Slider(value: $prefs.delay, in: 0...0.4, step: 0.05).frame(width: 180) }
            SettingRow(title: "Highlight the selected window on screen") { Toggle("", isOn: $prefs.previewWindow).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Status labels", detail: "MIN · HIDDEN · FULL · SPACE 2") { Toggle("", isOn: $prefs.badges).toggleStyle(.switch).labelsHidden() }
        }
    }

    var controls: some View {
        VStack(spacing: 0) {
            PageTitle(title: "Switcher controls")
            SettingRow(title: "Number keys 1–9 jump to a window") { Toggle("", isOn: $prefs.numberKeys).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Arrow keys") { Toggle("", isOn: $prefs.arrowKeys).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Vim keys", detail: "H J K L move (H no longer hides)") { Toggle("", isOn: $prefs.vimKeys).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Mouse hover selects") { Toggle("", isOn: $prefs.hoverSelects).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Move the pointer to the window you switch to") { Toggle("", isOn: $prefs.cursorFollows).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Trackpad swipe", detail: "Swipe sideways to open and move; lift to switch. Use 4 fingers if macOS uses 3 for Spaces.") {
                Seg(options: [("Off", 0), ("3 fingers", 3), ("4 fingers", 4)], value: $prefs.gesture)
            }
            Text("WHILE OPEN:  ⇥/⇧⇥ move · ↩/Space open · Esc cancel · S or / search · Q quit · ⇧Q force quit · W close · M minimize · F fullscreen · H hide")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
        }
    }

    var extras: some View {
        VStack(spacing: 0) {
            PageTitle(title: "Desktop", subtitle: "Windows-style extras.")
            SettingRow(title: "Show Desktop", detail: "Minimizes every window on this Space; press again to bring them back. Windows' Win+D. Apps in Exceptions with 'Ignore shortcuts' keep the key for themselves.") {
                HStack(spacing: 10) {
                    KeyRecorder(mask: $prefs.desktopMask, key: $prefs.desktopKey)
                    Toggle("", isOn: $prefs.showDesktop).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingRow(title: "Dock right-click shows Force Quit", detail: "Right-click any Dock app: Quit becomes Force Quit, like End Task.") { Toggle("", isOn: $prefs.dockForceQuit).toggleStyle(.switch).labelsHidden() }
        }
    }

}

struct ExceptionsView: View {
    @ObservedObject var prefs = SwitcherPrefs.shared
    @State var adding = ""

    var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in app.activationPolicy == .regular && app.bundleIdentifier != nil && !prefs.exceptions.contains(where: { $0.bundleID == app.bundleIdentifier }) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hide an app from Arsenal, or let it keep ⌘⇥ for itself (games).").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).padding(.bottom, 10)
            ForEach($prefs.exceptions) { $e in
                SettingRow(title: e.name, detail: e.bundleID) {
                    HStack(spacing: 10) {
                        Seg(options: [("Show", "never"), ("Hide if fullscreen", "fullscreen"), ("Always hide", "always")], value: $e.hide)
                        Toggle("Ignore shortcuts", isOn: $e.ignoreShortcuts).toggleStyle(.checkbox).font(.system(size: 11))
                        Button { prefs.exceptions.removeAll { $0.bundleID == e.bundleID } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Palette.ash)
                    }
                }
            }
            HStack {
                Picker("Add app", selection: $adding) {
                    Text("Add a running app…").tag("")
                    ForEach(running, id: \.processIdentifier) { Text($0.localizedName ?? "").tag($0.bundleIdentifier ?? "") }
                }.frame(width: 260)
                Button("Add") {
                    guard !adding.isEmpty, let app = running.first(where: { $0.bundleIdentifier == adding }) else { return }
                    prefs.exceptions.append(AppException(bundleID: adding, name: app.localizedName ?? adding)); adding = ""
                }.disabled(adding.isEmpty)
            }.padding(.top, 14)
        }
    }
}
