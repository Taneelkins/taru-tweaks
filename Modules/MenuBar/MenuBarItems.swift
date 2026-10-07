import AppKit
import SwiftUI

struct BarItem: Identifiable, Equatable {
    var id: String { "\(bundleID)#\(key ?? "x\(index)")" }
    let bundleID: String
    let appName: String
    let pid: pid_t
    let index: Int
    let x: CGFloat
    let width: CGFloat
    let label: String
    let key: String?
    let value: Double?
    let system: Bool
    var hidden: Bool
}

enum Defaults {
    static func run(_ args: [String]) -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return data
    }
    static func sandboxed(_ bundleID: String) -> Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Containers/\(bundleID)")
    }

    static func positions(_ bundleID: String) -> [(String, Double)] {
        if sandboxed(bundleID) { return [] }
        let data = run(["export", bundleID, "-"])
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        let prefix = "NSStatusItem Preferred Position "
        return plist.compactMap { k, v in
            guard k.hasPrefix(prefix), let n = (v as? NSNumber)?.doubleValue else { return nil }
            return (String(k.dropFirst(prefix.count)), n)
        }
    }
    static func setPosition(_ bundleID: String, _ key: String, _ value: Double) {
        _ = run(["write", bundleID, "NSStatusItem Preferred Position \(key)", "-float", String(value)])
    }
}

final class MenuBarItems: ObservableObject {
    static let shared = MenuBarItems()
    @Published var items: [BarItem] = []
    @Published var busy: Set<String> = []
    @Published var note = ""
    @Published var scanning = false
    let disruptive: Set<String> = ["com.anthropic.claudefordesktop", "com.hnc.Discord", "com.spotify.client", "com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "com.microsoft.VSCode", "com.roblox.RobloxStudio", "com.valvesoftware.steam", "com.tinyspeck.slackmacgap"]

    var dividerValue: Double {
        (UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tt.menubar.divider") as? NSNumber)?.doubleValue ?? 6200
    }
    var toggleValue: Double {
        (UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position tt.menubar.toggle") as? NSNumber)?.doubleValue ?? 6190
    }

    func reload() {
        let me = Bundle.main.bundleIdentifier ?? ""
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var out: [BarItem] = []
            for app in apps {
                guard let bid = app.bundleIdentifier else { continue }
                let el = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(el, 0.3)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success, let b = bar else { continue }
                var kids: CFTypeRef?
                AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
                var raw: [(CGFloat, CGFloat, String)] = []
                for k in (kids as? [AXUIElement]) ?? [] {
                    var p: CFTypeRef?, s: CFTypeRef?, d: CFTypeRef?, t: CFTypeRef?
                    AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &p)
                    AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &s)
                    AXUIElementCopyAttributeValue(k, kAXDescriptionAttribute as CFString, &d)
                    AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &t)
                    var pt = CGPoint.zero, sz = CGSize.zero
                    if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
                    if let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
                    guard sz.width > 0 else { continue }
                    raw.append((pt.x, sz.width, (d as? String) ?? (t as? String) ?? ""))
                }
                guard !raw.isEmpty else { continue }
                let system = bid.hasPrefix("com.apple.")
                raw.sort { $0.0 < $1.0 }
                var keys = system ? [] : Defaults.positions(bid).sorted { $0.1 > $1.1 }
                if bid == me { keys = keys.filter { !$0.0.hasPrefix("tt.menubar") } }
                for (i, r) in raw.enumerated() {
                    if bid == me && (r.1 > 1000 || r.2.contains("Toggle hidden") || r.2 == "Divider") { continue }
                    let key = keys.count == raw.count - (bid == me ? 2 : 0) && i < keys.count ? keys[i] : nil
                    let hidden = key.map { $0.1 > dividerValue } ?? (r.0 < 0)
                    out.append(BarItem(bundleID: bid, appName: app.localizedName ?? bid, pid: app.processIdentifier, index: i, x: r.0, width: r.1, label: r.2, key: key?.0, value: key?.1, system: system, hidden: hidden))
                }
            }
            out.sort { ($0.system ? 1 : 0, $0.appName.lowercased(), $0.index) < ($1.system ? 1 : 0, $1.appName.lowercased(), $1.index) }
            DispatchQueue.main.async { self.items = out; self.scanning = false }
        }
    }

    func set(_ item: BarItem, hidden: Bool) {
        guard let key = item.key else { return }
        busy.insert(item.id)
        let siblings = items.filter { $0.bundleID == item.bundleID }
        let used = Set(items.compactMap(\.value))
        var v: Double
        if hidden {
            v = max(dividerValue + 60, (items.filter(\.hidden).compactMap(\.value).max() ?? dividerValue) + 40)
        } else {
            v = min(toggleValue - 60, (items.filter { !$0.hidden && !$0.system }.compactMap(\.value).max() ?? 5000) + 20)
            if v >= toggleValue { v = toggleValue - 30 }
        }
        while used.contains(v) { v += hidden ? 7 : -7 }
        Defaults.setPosition(item.bundleID, key, v)
        _ = siblings
        restart(item.bundleID) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.busy.remove(item.id); self?.reload() }
        }
    }

    func restart(_ bundleID: String, done: @escaping () -> Void) {
        if bundleID == Bundle.main.bundleIdentifier {
            let path = Bundle.main.bundlePath
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1.2; /usr/bin/open -g \"\(path)\" --args --background"]
            try? p.run()
            NSApp.terminate(nil)
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let url = app.bundleURL else { done(); return }
        app.terminate()
        DispatchQueue.global().async {
            for _ in 0..<40 { if app.isTerminated { break }; usleep(100_000) }
            if !app.isTerminated { app.forceTerminate(); usleep(500_000) }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in DispatchQueue.main.async(execute: done) }
        }
    }
}

struct MenuBarItemsList: View {
    @ObservedObject var store = MenuBarItems.shared
    @ObservedObject var theme = Theme.shared
    @State var confirm: BarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.scanning && store.items.isEmpty ? "Scanning the menu bar…" : "\(store.items.filter { !$0.hidden }.count) visible · \(store.items.filter(\.hidden).count) hidden").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash)
                Spacer()
                TweakButton(title: "Refresh") { store.reload() }
            }.padding(.bottom, 6)
            ForEach(store.items) { item in
                SettingRow(title: item.appName + (item.label.isEmpty || item.label == item.appName ? "" : " · \(item.label)"), detail: detail(item)) {
                    HStack(spacing: 10) {
                        Text(item.hidden ? "HIDDEN" : "VISIBLE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(item.hidden ? Palette.ash : theme.accent)
                        if store.busy.contains(item.id) { ProgressView().controlSize(.small) }
                        else if item.system {
                            TweakButton(title: "Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!) }
                        } else if item.key != nil {
                            Toggle("", isOn: Binding(get: { !item.hidden }, set: { show in
                                if store.disruptive.contains(item.bundleID) { confirm = item } else { store.set(item, hidden: !show) }
                            })).toggleStyle(.switch).labelsHidden()
                        } else {
                            Text("⌘-DRAG").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18).offset(x: -26) }
                }
            }
        }
        .padding(.leading, 26)
        .onAppear { store.reload() }
        .alert(item: $confirm) { item in
            Alert(title: Text("Restart \(item.appName)?"), message: Text("\(item.appName) has to restart to move its menu bar icon."),
                  primaryButton: .default(Text("Restart")) { store.set(item, hidden: !item.hidden) }, secondaryButton: .cancel())
        }
    }

    func detail(_ i: BarItem) -> String {
        if i.system { return "macOS icon · managed in System Settings → Menu Bar" }
        if i.key == nil { return "This app doesn't save its position · hold ⌘ and drag it past the divider" }
        return i.hidden ? "Left of the divider" : (i.x > 0 ? "Shown in the menu bar" : "Shown")
    }
}
