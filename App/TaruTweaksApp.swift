import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    var retry: Timer?
    var settings: NSWindow?
    var dashboard: NSWindow?
    var taskManager: NSWindow?
    let nav = Nav()

    func updateDockIcon() {
        let any = [settings, dashboard].contains { $0?.isVisible == true }
        let policy: NSApplication.ActivationPolicy = (any || UserDefaults.standard.bool(forKey: "dock.always")) ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func present(_ w: NSWindow?) {
        updateDockIcon()
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.updateDockIcon() }
    }

    func makeWindow(_ title: String, _ size: NSSize, _ view: some View) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false; w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.updateDockIcon() }
        }
        return w
    }

    func openTaskManager() {
        let url = URL(fileURLWithPath: "/Applications/Task Manager.app")
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    func registerTaskManagerKey() {
        let d = UserDefaults.standard
        let mask = (d.object(forKey: "tm.mask") as? NSNumber)?.uint64Value ?? 0x60000
        let key = (d.object(forKey: "tm.key") as? NSNumber)?.int64Value ?? 53
        HotKeys.shared.set(201, mask: mask, key: key) { [weak self] in self?.openTaskManager() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        WindowEngine.shared.start()
        Thumbnails.shared.onUpdate = { Switcher.shared.tick += 1 }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in if CGPreflightScreenCaptureAccess() { WindowEngine.shared.snapshotVisible() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { WindowEngine.shared.snapshotVisible() }
        Input.shared.onLost = { [weak self] in self?.arm() }
        arm()
        Gestures.shared.start()
        _ = BatteryModel.shared
        _ = Brightness.shared
        TaruDock.shared.start()
        Wallpaper.shared.start()
        debugHooks()
        registerTaskManagerKey()
        MenuBarManager.registerKey()
        Capture.shared.registerKeys()
        HotKeys.shared.start()
        MenuBarManager.shared.start()
        TaruBar.shared.start()
        StatusItems.shared.start()
        Responsiveness.shared.start()
        updateDockIcon()
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Brightness.shared.stop(); SkyLight.restoreNativeSwitcher(); exit(0) }
            src.resume(); _ = Unmanaged.passRetained(src)
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == AEEventID(kAEOpenApplication) && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            try? SMAppService.mainApp.register()
            openSettings("general")
        } else if !atLogin && !CommandLine.arguments.contains("--background") {
            openSettings(nil)
        }
    }

    func arm() {
        if AXIsProcessTrusted(), Input.shared.start() {
            if SwitcherPrefs.shared.enabled { SkyLight.moveNativeSwitcherToOption() }
            retry?.invalidate(); return
        }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.arm() }
    }

    func debugHooks() {
        let dc = DistributedNotificationCenter.default()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WindowEngine.shared.snapshotVisible() } }
        dc.addObserver(forName: .init("com.taru.tweaks.peek"), object: nil, queue: .main) { _ in
            Switcher.shared.open(shortcut: 0, backwards: false, gesture: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Switcher.shared.cancel() }
        }
        dc.addObserver(forName: .init("com.taru.tweaks.status"), object: nil, queue: .main) { _ in
            let wins = WindowEngine.shared.all()
            let st: [String: Any] = ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "tapActive": Input.shared.active,
                                     "windows": wins.count, "titled": wins.filter { !$0.title.isEmpty }.count, "thumbs": Thumbnails.shared.count,
                                     "helper": BatteryModel.shared.helperState.rawValue, "helperAlive": BatteryModel.shared.helperAlive, "xdr": Brightness.shared.supported]
            if let d = try? JSONSerialization.data(withJSONObject: st) { try? d.write(to: URL(fileURLWithPath: "/tmp/tarutweaks-status.json")) }
        }
        dc.addObserver(forName: .init("com.taru.tweaks.bench"), object: nil, queue: .main) { _ in
            var t = Date()
            let all = WindowEngine.shared.all()
            let tAll = Date().timeIntervalSince(t) * 1000
            t = Date()
            let list = WindowEngine.shared.list(for: SwitcherPrefs.shared.shortcuts[0])
            let tList = Date().timeIntervalSince(t) * 1000
            Thumbnails.shared.stats = ["ok": 0, "fail": 0, "missing": 0]
            Thumbnails.shared.capture(all.map(\.id))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let st: [String: Any] = ["allMs": Int(tAll), "listMs": Int(tList), "windows": all.count, "listed": list.count,
                                         "onCurrentSpace": all.filter { $0.onCurrentSpace && !$0.minimized }.count, "cached": Thumbnails.shared.count,
                                         "captureOK": Thumbnails.shared.stats["ok"] ?? 0, "captureFail": Thumbnails.shared.stats["fail"] ?? 0, "notInSCK": Thumbnails.shared.stats["missing"] ?? 0,
                                         "titles": list.prefix(12).map { "\($0.appName) | \($0.title) | cur:\($0.onCurrentSpace) min:\($0.minimized) id:\($0.id) thumb:\(Thumbnails.shared.cache[$0.id] != nil)" }]
                if let d = try? JSONSerialization.data(withJSONObject: st, options: .prettyPrinted) { try? d.write(to: URL(fileURLWithPath: "/tmp/tarutweaks-bench.json")) }
            }
        }
        dc.addObserver(forName: .init("com.taru.tweaks.state"), object: nil, queue: .main) { _ in
            let sw = Switcher.shared
            let st: [String: Any] = ["visible": sw.visible, "count": sw.windows.count, "selected": sw.selected, "searching": sw.searching, "query": sw.query,
                                     "titles": sw.windows.prefix(10).map { "\($0.appName) | \($0.title)" },
                                     "selectedTitle": sw.windows.indices.contains(sw.selected) ? "\(sw.windows[sw.selected].appName) | \(sw.windows[sw.selected].title)" : "",
                                     "front": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                                     "native1": SkyLight.hotKeyValue(1), "native27": SkyLight.hotKeyEnabled(27),
                                     "dockPreset": DockPresets.shared.activeName, "dockCount": DockPresets.shared.presets.count, "dockShown": TaruDock.shared.shown, "wpPlaying": Wallpaper.shared.playing, "barCPU": TaruBarModel.shared.cpu.last ?? -1, "barTemp": TaruBarModel.shared.temperature ?? -999, "wpCurrent": Wallpaper.shared.current, "dockFrame": NSStringFromRect(TaruDock.shared.panel.frame), "xdrOn": Brightness.shared.on, "xdrFactor": Brightness.shared.factor, "xdrNote": Brightness.shared.note]
            if let d = try? JSONSerialization.data(withJSONObject: st, options: .prettyPrinted) { try? d.write(to: URL(fileURLWithPath: "/tmp/tarutweaks-state.json")) }
        }
        dc.addObserver(forName: .init("com.taru.tweaks.notifytest"), object: nil, queue: .main) { _ in
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let c = UNMutableNotificationContent(); c.title = "Battery"; c.body = "Test notification"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { e in
                    try? "auth:\(s.authorizationStatus.rawValue) alert:\(s.alertSetting.rawValue) err:\(e.map { "\($0)" } ?? "none")".write(toFile: "/tmp/tarutweaks-notify.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        dc.addObserver(forName: .init("com.taru.tweaks.open"), object: nil, queue: .main) { [weak self] n in
            if (n.object as? String) == "taskmanager" { self?.openTaskManager() } else { self?.openSettings((n.object as? String) ?? "general") }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { openSettings(nil); return true }
    func applicationWillTerminate(_ n: Notification) { SkyLight.restoreNativeSwitcher() }

    func openSettings(_ page: String?) {
        if let page { nav.page = page }
        if settings == nil { settings = makeWindow("Taru Tweaks", NSSize(width: 900, height: 660), SettingsRoot().environmentObject(nav)) }
        present(settings)
    }

    func openDashboard() {
        if dashboard == nil { dashboard = makeWindow("Battery", NSSize(width: 960, height: 720), DashboardWindow()) }
        present(dashboard)
    }
}

final class Nav: ObservableObject { @Published var page = "general" }

struct SettingsRoot: View {
    @EnvironmentObject var nav: Nav
    let groups = [
        SidebarGroup(id: "Taru Tweaks", items: [SidebarItem(id: "general", title: "General", icon: "square.grid.2x2"), SidebarItem(id: "bar", title: "Taru Bar", icon: "menubar.arrow.up.rectangle"), SidebarItem(id: "menubar", title: "Menu Bar", icon: "menubar.rectangle"), SidebarItem(id: "theme", title: "Theme", icon: "paintpalette")]),
        SidebarGroup(id: "Windows", items: [SidebarItem(id: "switcher.shortcuts", title: "Switcher", icon: "rectangle.on.rectangle"), SidebarItem(id: "switcher.appearance", title: "Look", icon: "square.grid.3x2"),
                                           SidebarItem(id: "switcher.controls", title: "Controls", icon: "keyboard"), SidebarItem(id: "switcher.exceptions", title: "Exceptions", icon: "nosign"),
                                           SidebarItem(id: "desktop", title: "Desktop", icon: "menubar.dock.rectangle"), SidebarItem(id: "dock", title: "Taru Dock", icon: "dock.rectangle")]),
        SidebarGroup(id: "Battery", items: [SidebarItem(id: "battery.charging", title: "Charging", icon: "bolt"), SidebarItem(id: "battery.protection", title: "Protection", icon: "thermometer.medium"),
                                           SidebarItem(id: "battery.automation", title: "Automation", icon: "calendar.badge.clock"), SidebarItem(id: "battery.display", title: "Dashboard", icon: "chart.xyaxis.line")]),
        SidebarGroup(id: "Display", items: [SidebarItem(id: "brightness", title: "XDR Boost", icon: "sun.max"), SidebarItem(id: "wallpaper", title: "Live Wallpaper", icon: "play.rectangle")]),
        SidebarGroup(id: "Capture", items: [SidebarItem(id: "capture", title: "Screenshots", icon: "camera.viewfinder")])
    ]
    var body: some View {
        TweaksShell(groups: groups, current: $nav.page) { page in
            switch page {
            case "general": GeneralPage()
            case "menubar": MenuBarSettings()
            case "bar": TaruBarSettings()
            case "theme": VStack(alignment: .leading, spacing: 0) { PageTitle(title: "Theme", subtitle: "One accent color for every module."); ThemePicker() }
            case let p where p.hasPrefix("switcher") || p == "desktop": SwitcherSettings(page: p)
            case let p where p.hasPrefix("battery"): BatterySettings(page: p)
            case "dock": DockPresetsSettings()
            case "wallpaper": WallpaperSettings()
            case "capture": CaptureSettings()
            default: BrightnessSettings()
            }
        }
    }
}

struct GeneralPage: View {
    @State var trusted = AXIsProcessTrusted()
    @State var capture = CGPreflightScreenCaptureAccess()
    @State var login = SMAppService.mainApp.status == .enabled
    @State var dockAlways = UserDefaults.standard.bool(forKey: "dock.always")
    @ObservedObject var switcher = SwitcherPrefs.shared
    @ObservedObject var battery = BatteryModel.shared
    @ObservedObject var bright = Brightness.shared
    @ObservedObject var theme = Theme.shared
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    func ok(_ on: Bool) -> some View {
        Text(on ? "GRANTED" : "NEEDED").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(on ? theme.accent : Palette.ash)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Taru Tweaks", subtitle: "Window switcher, desktop tricks, battery control and XDR boost in one app with one set of permissions.")
            SectionLabel(text: "Permissions")
            SettingRow(title: "Accessibility", detail: "Shortcuts, window control, Dock right-click") {
                HStack { ok(trusted); if !trusted { TweakButton(title: "Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } } }
            }
            SettingRow(title: "Screen Recording", detail: "Live window previews and titles") {
                HStack { ok(capture); if !capture { TweakButton(title: "Open") { CGRequestScreenCaptureAccess(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } } }
            }
            SettingRow(title: "Charging helper", detail: battery.helperAlive ? "Running" : "Needed for the Battery module") {
                HStack { ok(battery.helperAlive); if !battery.helperAlive { TweakButton(title: battery.helperState == .requiresApproval ? "Approve" : "Install") { battery.installHelper() } } }
            }
            SectionLabel(text: "Modules")
            SettingRow(title: "Window switcher", detail: "⌘⇥ and friends") { Switch(on: $switcher.enabled) }
            SettingRow(title: "Show Desktop", detail: "\(modifierString(switcher.desktopMask))\(keyString(switcher.desktopKey))") { Switch(on: $switcher.showDesktop) }
            SettingRow(title: "Dock right-click Force Quit") { Switch(on: $switcher.dockForceQuit) }
            SettingRow(title: "Battery control") { Switch(on: Binding(get: { battery.config.enabled }, set: { v in battery.update { $0.enabled = v } })) }
            SettingRow(title: "XDR Boost") { Switch(on: $bright.on) }
            SettingRow(title: "Task Manager shortcut", detail: "Opens the Task Manager app from anywhere") { TaskManagerKey() }
            SectionLabel(text: "App")
            SettingRow(title: "Always show in the Dock", detail: "Otherwise the Dock icon only appears while a Taru Tweaks window is open") {
                Switch(on: Binding(get: { dockAlways }, set: { dockAlways = $0; UserDefaults.standard.set($0, forKey: "dock.always"); AppDelegate.shared.updateDockIcon() }))
            }
            SettingRow(title: "Launch at login") {
                Switch(on: Binding(get: { login }, set: { v in login = v; if v { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }))
            }
            SettingRow(title: "Version", detail: "Personal build · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") { TweakButton(title: "Quit") { NSApp.terminate(nil) } }
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted(); capture = CGPreflightScreenCaptureAccess() }
    }
}

struct MainMenu: View {
    @ObservedObject var switcher = SwitcherPrefs.shared
    @ObservedObject var battery = BatteryModel.shared
    @ObservedObject var bright = Brightness.shared
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("TARU").font(.system(size: 18, weight: .heavy, design: .monospaced)).tracking(3)
                Text("TWEAKS").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(4).opacity(0.8)
            }.foregroundStyle(theme.accent)
            row("Window switcher", "⌘⇥ windows · ⌥⇥ apps", $switcher.enabled)
            row("Show Desktop", "\(modifierString(switcher.desktopMask))\(keyString(switcher.desktopKey))", $switcher.showDesktop)
            row("XDR Boost", "\(bright.nits) nits", $bright.on)
            HStack { Text("Task Manager").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone); Spacer(); Text("⌃⇧Esc").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash) }
            row("Battery limit", "\(battery.battery.percent)% · \(battery.status?.reason ?? "helper off")", Binding(get: { battery.config.enabled }, set: { v in battery.update { $0.enabled = v } }))
            HStack(spacing: 8) {
                TweakButton(title: "Settings") { AppDelegate.shared.openSettings(nil) }
                TweakButton(title: "Battery") { AppDelegate.shared.openDashboard() }
                TweakButton(title: "Tasks") { AppDelegate.shared.openTaskManager() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
            }
        }
        .padding(16).frame(width: 360).background(Palette.pit).tint(theme.accent)
    }
    func row(_ t: String, _ d: String, _ b: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
                Text(d).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

final class MenuItems: ObservableObject {
    static let shared = MenuItems()
    @Published var main: Bool
    @Published var battery: Bool
    @Published var brightness: Bool
    init() {
        let d = UserDefaults.standard
        main = d.object(forKey: "menu.main") as? Bool ?? true
        battery = d.object(forKey: "battery.menu.show") as? Bool ?? true
        brightness = d.object(forKey: "brightness.menu") as? Bool ?? true
    }
    func binding(_ kp: ReferenceWritableKeyPath<MenuItems, Bool>, _ key: String) -> Binding<Bool> {
        Binding(get: { self[keyPath: kp] }, set: { v in
            guard v != self[keyPath: kp] else { return }
            self[keyPath: kp] = v
            UserDefaults.standard.set(v, forKey: key)
        })
    }
}

struct BatteryLabel: View {
    @ObservedObject var battery = BatteryModel.shared
    var body: some View {
        HStack(spacing: 3) {
            if battery.menuIcon { Image(systemName: battery.menuSymbol) }
            if !battery.menuText.isEmpty { Text(battery.menuText) }
        }
    }
}

struct BrightnessLabel: View {
    @ObservedObject var bright = Brightness.shared
    var body: some View { Image(systemName: bright.on ? "sun.max.fill" : "sun.max") }
}

@main
struct TaruTweaksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var items = MenuItems.shared

    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct TaskManagerKey: View {
    @State var mask: UInt64 = (UserDefaults.standard.object(forKey: "tm.mask") as? NSNumber)?.uint64Value ?? 0x60000
    @State var key: Int64 = (UserDefaults.standard.object(forKey: "tm.key") as? NSNumber)?.int64Value ?? 53
    var body: some View {
        KeyRecorder(mask: Binding(get: { mask }, set: { mask = $0; UserDefaults.standard.set($0, forKey: "tm.mask"); AppDelegate.shared.registerTaskManagerKey() }),
                    key: Binding(get: { key }, set: { key = $0; UserDefaults.standard.set($0, forKey: "tm.key"); AppDelegate.shared.registerTaskManagerKey() }))
    }
}
