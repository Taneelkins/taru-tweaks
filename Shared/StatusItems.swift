import AppKit
import Combine
import SwiftUI

final class TaruStatusItem: NSObject, NSPopoverDelegate {
    let item: NSStatusItem
    let name: String
    let page: String
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?
    var onLog: ((String) -> Void)?
    private let popover = NSPopover()
    private var monitors: [Any] = []
    private var source: NSRunningApplication?

    init(name: String, autosave: String, page: String, content: AnyView) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosave
        self.name = name
        self.page = page
        super.init()
        // closes only when we say so: .transient shut it the moment activation or a Space change landed,
        // which read as open-then-close (and a flash in full-screen apps)
        popover.behavior = .applicationDefined
        popover.delegate = self
        // fires however the popover closes, click outside included
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in self?.onClose?() }
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

    var isShown: Bool { popover.isShown }

    // content that grows or shrinks while open (a list) asks for a new size
    func fit() {
        guard popover.isShown, let v = popover.contentViewController?.view else { return }
        v.layoutSubtreeIfNeeded()
        if popover.contentSize != v.fittingSize { popover.contentSize = v.fittingSize }
    }

    func toggle() {
        if popover.isShown { close(handBack: true); return }
        guard let b = item.button else { return }
        if let v = popover.contentViewController?.view { v.layoutSubtreeIfNeeded(); popover.contentSize = v.fittingSize }
        let front = NSWorkspace.shared.frontmostApplication
        source = front?.processIdentifier == getpid() ? nil : front
        onShow?()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        guard popover.isShown, let w = popover.contentViewController?.view.window else { return }
        // stay on the Space you're looking at (full-screen apps included) instead of dragging you to ours
        w.collectionBehavior.insert([.fullScreenAuxiliary, .canJoinAllSpaces])
        (w as? NSPanel)?.hidesOnDeactivate = false
        w.makeKey()
        // activate only after the popup is key on this Space, so activation has nowhere else to go
        NSApp.activate(ignoringOtherApps: true)
        // a global monitor only sees clicks in other apps: those dismiss it
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            let src = e.cgEvent.map { pid_t($0.getIntegerValueField(.eventSourceUnixProcessID)) } ?? 0
            let state = e.cgEvent.map { $0.getIntegerValueField(.eventSourceStateID) } ?? 0
            self?.onLog?("outside click type=\(e.type.rawValue) at=\(NSStringFromPoint(NSEvent.mouseLocation)) src=\(src) \(NSRunningApplication(processIdentifier: src)?.localizedName ?? "?") state=\(state)")
            self?.close()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            self?.close(handBack: true); return nil
        }) { monitors.append(m) }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        onLog?("shouldClose ev=\(NSApp.currentEvent?.type.rawValue ?? 0) active=\(NSApp.isActive) " + Thread.callStackSymbols.prefix(14).map { $0.split(separator: " ").dropFirst(3).prefix(1).joined() }.joined(separator: " < "))
        return true
    }

    func close(handBack: Bool = false) {
        onLog?("close() handBack=\(handBack) shown=\(popover.isShown)")
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let src = source
        source = nil
        guard popover.isShown else { return }
        popover.performClose(nil)
        // closed from the icon or Esc: give the keyboard back to the app you were in (an outside click already did)
        guard handBack, let src, !src.isTerminated else { return }
        DispatchQueue.main.async { if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { src.activate() } }
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
