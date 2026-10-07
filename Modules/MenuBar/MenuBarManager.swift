import AppKit
import SwiftUI

final class MenuBarManager: ObservableObject {
    static let shared = MenuBarManager()
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "mb.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(enabled, forKey: "mb.enabled"); enabled ? start() : stop() } }
    @Published var autoHide: Double = UserDefaults.standard.object(forKey: "mb.autoHide") as? Double ?? 10 { didSet { UserDefaults.standard.set(autoHide, forKey: "mb.autoHide") } }
    @Published var hideOnClickAway: Bool = UserDefaults.standard.object(forKey: "mb.clickAway") as? Bool ?? true { didSet { UserDefaults.standard.set(hideOnClickAway, forKey: "mb.clickAway") } }
    @Published var showDivider: Bool = UserDefaults.standard.object(forKey: "mb.showDivider") as? Bool ?? true { didSet { UserDefaults.standard.set(showDivider, forKey: "mb.showDivider"); apply() } }
    @Published private(set) var collapsed = true
    @Published var warning = ""

    private var toggle: NSStatusItem?
    private var divider: NSStatusItem?
    private var timer: Timer?
    private var clickMonitor: Any?
    private let wide: CGFloat = 10_000

    func start() {
        guard enabled, toggle == nil else { return }
        let t = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        t.autosaveName = "tt.menubar.toggle"
        t.button?.target = self
        t.button?.action = #selector(clicked)
        t.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        t.button?.toolTip = "Show or hide menu bar icons · ⌘-drag icons left of the divider to hide them"
        toggle = t
        let d = NSStatusBar.system.statusItem(withLength: 12)
        d.autosaveName = "tt.menubar.divider"
        d.button?.toolTip = "Icons to the left of this line hide when collapsed"
        divider = d
        collapsed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.apply() }
    }

    func stop() {
        timer?.invalidate()
        if let t = toggle { NSStatusBar.system.removeStatusItem(t) }
        if let d = divider { NSStatusBar.system.removeStatusItem(d) }
        toggle = nil; divider = nil
    }

    var orderOK: Bool {
        guard let tf = toggle?.button?.window?.frame, let df = divider?.button?.window?.frame else { return true }
        return df.maxX <= tf.minX + 1
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: collapsed ? "Show hidden icons" : "Hide icons", action: #selector(toggleNow), keyEquivalent: "").target = self
            m.addItem(withTitle: "Menu Bar settings…", action: #selector(openSettings), keyEquivalent: "").target = self
            toggle?.menu = m
            toggle?.button?.performClick(nil)
            toggle?.menu = nil
            return
        }
        toggleNow()
    }

    @objc func openSettings() { AppDelegate.shared.openSettings("menubar") }

    @objc func toggleNow() { set(collapsed: !collapsed) }

    func set(collapsed c: Bool) {
        if c && !orderOK {
            warning = "The divider is to the right of the toggle. ⌘-drag the ‹ toggle to the right of the divider first."
            collapsed = false; apply(); return
        }
        warning = ""
        collapsed = c
        apply()
        timer?.invalidate()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if !c {
            if autoHide > 0 { timer = Timer.scheduledTimer(withTimeInterval: autoHide, repeats: false) { [weak self] _ in self?.set(collapsed: true) } }
            if hideOnClickAway {
                clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                    guard let self, let screen = NSScreen.screens.first else { return }
                    let y = NSEvent.mouseLocation.y
                    if y < screen.frame.maxY - 40 && !NSEvent.modifierFlags.contains(.command) { self.set(collapsed: true) }
                }
            }
        }
    }

    func apply() {
        guard let t = toggle, let d = divider else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        t.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: "Toggle hidden icons")?.withSymbolConfiguration(cfg)
        if collapsed {
            d.length = wide
            d.button?.image = nil
        } else {
            d.length = showDivider ? 12 : 0
            d.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Divider")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        }
    }
}

struct MenuBarSettings: View {
    @ObservedObject var m = MenuBarManager.shared
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Menu Bar", subtitle: "Hide menu bar icons you don't need, like Ice or Bartender. Click ‹ in the menu bar to show them again.")
            SettingRow(title: "Menu bar hiding") { Switch(on: $m.enabled) }
            if !m.warning.isEmpty { Text(m.warning).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.accent).padding(.vertical, 6) }
            SettingRow(title: "Hidden icons", detail: m.collapsed ? "Hidden" : "Showing") { TweakButton(title: m.collapsed ? "Show now" : "Hide now") { m.toggleNow() } }
            SettingRow(title: "Hide again after", detail: m.autoHide == 0 ? "Never (click ‹ to hide)" : "\(Int(m.autoHide)) seconds") { Slider(value: $m.autoHide, in: 0...60, step: 5).frame(width: 200) }
            SettingRow(title: "Hide when you click somewhere else") { Switch(on: $m.hideOnClickAway) }
            SettingRow(title: "Show the divider while expanded", detail: "The thin line marking where hidden icons start") { Switch(on: $m.showDivider) }
            SettingRow(title: "Shortcut", detail: "Show or hide the hidden icons") { MenuBarKey() }
            SectionLabel(text: "How to choose what hides")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click ‹ to show everything. A thin divider appears.")
                Text("2. Hold ⌘ and drag any icon to the LEFT of the divider to hide it, or to the right to keep it visible.")
                Text("3. Keep the ‹ toggle to the right of the divider.")
            }.font(.system(size: 12)).foregroundStyle(Palette.bone)
        }
    }
}

struct MenuBarKey: View {
    @State var mask: UInt64 = (UserDefaults.standard.object(forKey: "mb.mask") as? NSNumber)?.uint64Value ?? 0x1C0000
    @State var key: Int64 = (UserDefaults.standard.object(forKey: "mb.key") as? NSNumber)?.int64Value ?? 46
    var body: some View {
        KeyRecorder(mask: Binding(get: { mask }, set: { mask = $0; UserDefaults.standard.set($0, forKey: "mb.mask"); MenuBarManager.registerKey() }),
                    key: Binding(get: { key }, set: { key = $0; UserDefaults.standard.set($0, forKey: "mb.key"); MenuBarManager.registerKey() }))
    }
}

extension MenuBarManager {
    static func registerKey() {
        let d = UserDefaults.standard
        let mask = (d.object(forKey: "mb.mask") as? NSNumber)?.uint64Value ?? 0x1C0000
        let key = (d.object(forKey: "mb.key") as? NSNumber)?.int64Value ?? 46
        HotKeys.shared.set(401, mask: mask, key: key) { MenuBarManager.shared.toggleNow() }
    }
}
