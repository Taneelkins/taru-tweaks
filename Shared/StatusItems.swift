import AppKit
import Combine
import SwiftUI

final class TaruStatusItem: NSObject {
    let item: NSStatusItem
    let name: String
    let page: String
    var onHide: (() -> Void)?
    private let popover = NSPopover()
    private var outside: Any?

    init(name: String, autosave: String, page: String, content: AnyView) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosave
        self.name = name
        self.page = page
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(content.fixedSize()))
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let vc = NSViewController()
        vc.view = host
        popover.contentViewController = vc
        popover.contentSize = host.fittingSize
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "\(name) · Taru Tweaks"
    }

    func set(symbol: String, title: String = "") {
        guard let b = item.button else { return }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        img?.isTemplate = true
        b.image = img
        b.title = title
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        b.font = .menuBarFont(ofSize: 0)
    }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showMenu(); return }
        toggle()
    }

    func toggle() {
        if popover.isShown { close(); return }
        guard let b = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let v = popover.contentViewController?.view { v.layoutSubtreeIfNeeded(); popover.contentSize = v.fittingSize }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    }

    func close() {
        popover.performClose(nil)
        if let o = outside { NSEvent.removeMonitor(o) }
        outside = nil
    }

    private func showMenu() {
        close()
        let m = NSMenu()
        let header = NSMenuItem(title: "\(name) — from Taru Tweaks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        m.addItem(ClosureItem("Open \(name) settings…") { [page] in AppDelegate.shared.openSettings(page) })
        if onHide != nil { m.addItem(ClosureItem("Hide this icon") { [weak self] in self?.onHide?() }) }
        m.addItem(.separator())
        m.addItem(ClosureItem("Quit Taru Tweaks") { NSApp.terminate(nil) })
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
}

final class StatusItems {
    static let shared = StatusItems()
    private(set) var main: TaruStatusItem?
    private(set) var battery: TaruStatusItem?
    private(set) var brightness: TaruStatusItem?
    private var bag = Set<AnyCancellable>()

    func start() {
        guard main == nil else { return }
        let items = MenuItems.shared
        let m = TaruStatusItem(name: "Taru Tweaks", autosave: "Item-0", page: "general", content: AnyView(MainMenu()))
        m.set(symbol: "flame.fill")
        m.onHide = { items.binding(\.main, "menu.main").wrappedValue = false }
        let b = TaruStatusItem(name: "Battery", autosave: "Item-1", page: "battery.charging",
                               content: AnyView(BatteryMenuView(openDashboard: { AppDelegate.shared.openDashboard() }, openSettings: { AppDelegate.shared.openSettings("battery.charging") })))
        b.onHide = { items.binding(\.battery, "battery.menu.show").wrappedValue = false }
        let x = TaruStatusItem(name: "XDR Boost", autosave: "Item-2", page: "brightness",
                               content: AnyView(BrightnessMenu(openSettings: { AppDelegate.shared.openSettings("brightness") })))
        x.onHide = { items.binding(\.brightness, "brightness.menu").wrappedValue = false }
        main = m; battery = b; brightness = x
        updateBattery()
        updateBrightness()
        BatteryModel.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateBattery() }.store(in: &bag)
        Brightness.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateBrightness() }.store(in: &bag)
        items.$main.sink { m.item.isVisible = $0 }.store(in: &bag)
        items.$battery.sink { b.item.isVisible = $0 }.store(in: &bag)
        items.$brightness.sink { x.item.isVisible = $0 }.store(in: &bag)
    }

    private func updateBattery() {
        let model = BatteryModel.shared
        battery?.set(symbol: model.menuIcon ? model.menuSymbol : "", title: model.menuText)
        if !model.menuIcon { battery?.item.button?.image = nil }
    }

    private func updateBrightness() {
        brightness?.set(symbol: Brightness.shared.on ? "sun.max.fill" : "sun.max")
    }
}
