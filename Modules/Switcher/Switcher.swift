import AppKit
import SwiftUI

final class Switcher: ObservableObject {
    static let shared = Switcher()
    @Published var windows: [Win] = []
    @Published var selected = 0
    @Published var tick = 0
    @Published var query = ""
    @Published var searching = false
    var all: [Win] = []
    var shortcut: Shortcut?
    var style: Style { shortcut?.appsOnly == true ? .icons : SwitcherPrefs.shared.style }
    var visible = false
    var openMouse = CGPoint.zero
    var mouseMoved: Bool { let m = NSEvent.mouseLocation; return abs(m.x - openMouse.x) + abs(m.y - openMouse.y) > 6 }
    private var panel: NSPanel?
    private var host: NSHostingController<AnyView>?
    private var outline: NSWindow?
    private var showTimer: Timer?
    private var shown = false

    func open(shortcut index: Int, backwards: Bool, gesture: Bool = false) {
        let prefs = SwitcherPrefs.shared
        guard prefs.shortcuts.indices.contains(index) else { return }
        let sc = prefs.shortcuts[index]
        shortcut = gesture ? nil : sc
        all = WindowEngine.shared.list(for: sc)
        guard !all.isEmpty else { return }
        query = ""; searching = false
        openMouse = NSEvent.mouseLocation
        let target = all.count > 1 ? (backwards ? all[all.count - 1] : all[1]) : all.first
        if grouping { all = Switcher.grouped(all) }
        windows = all
        selected = target.flatMap { t in windows.firstIndex { $0.id == t.id && $0.pid == t.pid } } ?? 0
        visible = true
        shown = false
        showTimer?.invalidate()
        if prefs.delay <= 0 || gesture || sc.release == .stay { present() } else {
            showTimer = Timer.scheduledTimer(withTimeInterval: prefs.delay, repeats: false) { [weak self] _ in self?.present() }
        }
        if style == .thumbs {
            let stale = all.filter { $0.onCurrentSpace && !$0.minimized && !$0.hidden && !$0.windowless && Thumbnails.shared.isStale($0.id, 8) }.map(\.id)
            Thumbnails.shared.capture(stale)
        }
    }

    private func present() {
        guard visible, !shown else { return }
        shown = true
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            p.animationBehavior = .none
            let hc = NSHostingController(rootView: AnyView(SwitcherView().environmentObject(self).environmentObject(SwitcherPrefs.shared)))
            hc.sizingOptions = []
            host = hc
            p.contentView = hc.view
            panel = p
        }
        layout()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel?.animator().alphaValue = 1 }
        updateOutline()
    }

    var targetScreen: NSScreen {
        switch SwitcherPrefs.shared.showOn {
        case .mouse: return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        case .main: return NSScreen.screens.first!
        case .active: return NSScreen.main ?? NSScreen.screens.first!
        }
    }

    func layout() {
        guard let p = panel, let hc = host else { return }
        let f = targetScreen.visibleFrame
        let size = hc.sizeThatFits(in: CGSize(width: f.width, height: f.height))
        let w = min(size.width, f.width - 16), h = min(size.height, f.height - 16)
        var y = f.midY - h / 2 + f.height * 0.05
        y = min(max(y, f.minY + 8), f.maxY - h - 8)
        p.setFrame(NSRect(x: (f.midX - w / 2).rounded(), y: y.rounded(), width: w, height: h), display: true)
    }

    var grouping: Bool { SwitcherPrefs.shared.groupByApp && style == .thumbs }

    static func grouped(_ list: [Win]) -> [Win] {
        var keys: [String] = []
        var buckets: [String: [Win]] = [:]
        for w in list {
            let k = w.bundleID ?? w.appName
            if buckets[k] == nil { keys.append(k) }
            buckets[k, default: []].append(w)
        }
        return keys.flatMap { buckets[$0] ?? [] }
    }

    func step(_ d: Int) {
        guard !windows.isEmpty else { return }
        selected = (selected + d + windows.count) % windows.count
        if grouping && shown { layout(); DispatchQueue.main.async { self.layout() } }
        updateOutline()
    }

    func select(_ i: Int) { guard windows.indices.contains(i) else { return }; selected = i; if grouping && shown { layout(); DispatchQueue.main.async { self.layout() } }; updateOutline() }

    func released() {
        guard let sc = shortcut else { commit(); return }
        if sc.release == .focus && !searching { commit() }
    }

    func commit() {
        guard visible else { return }
        let target = windows.indices.contains(selected) ? windows[selected] : nil
        hide()
        if let target { WindowEngine.shared.focus(target) }
        DispatchQueue.main.async { self.windows = []; self.all = [] }
    }

    func cancel() { hide() }

    func hide() {
        visible = false
        showTimer?.invalidate()
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        outline?.orderOut(nil)
        outlined = 0
        searching = false
    }

    func act(_ f: @escaping (Win) -> Void) {
        guard windows.indices.contains(selected) else { return }
        f(windows[selected])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard visible, let sc = shortcut ?? SwitcherPrefs.shared.shortcuts.first else { return }
            all = WindowEngine.shared.list(for: sc)
            filter()
            if windows.isEmpty { hide() } else { selected = min(selected, windows.count - 1); layout(); updateOutline() }
        }
    }

    func filter() {
        if query.isEmpty { windows = all } else {
            let q = query.lowercased()
            windows = all.filter { $0.title.lowercased().contains(q) || $0.appName.lowercased().contains(q) }
        }
        selected = min(selected, max(0, windows.count - 1))
        if windows.count > 0 && !query.isEmpty { selected = 0 }
        layout(); updateOutline()
    }

    func key(_ k: Int64, shift: Bool, chars: String) {
        let prefs = SwitcherPrefs.shared
        if !shown { present() }
        if searching {
            switch k {
            case 53: if query.isEmpty { searching = false } else { query = "" ; filter() }
            case 51: if !query.isEmpty { query.removeLast(); filter() } else { searching = false }
            case 36: commit()
            case 48: step(shift ? -1 : 1)
            case 123, 126: step(-1)
            case 124, 125: step(1)
            default: if !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { query += chars; filter() }
            }
            return
        }
        let cols = max(1, currentColumns)
        switch k {
        case 48: step(shift ? -1 : 1)
        case 50: step(-1)
        case 53: cancel()
        case 36, 49: commit()
        case 44, 1: searching = true
        case 12: act(shift ? WindowEngine.shared.forceQuit : WindowEngine.shared.quit)
        case 13: act(WindowEngine.shared.close)
        case 46: act(WindowEngine.shared.minimize)
        case 3: act(WindowEngine.shared.fullscreen)
        case 4 where !prefs.vimKeys: act(WindowEngine.shared.hide)
        case 123 where prefs.arrowKeys: step(-1)
        case 124 where prefs.arrowKeys: step(1)
        case 126 where prefs.arrowKeys: step(-cols)
        case 125 where prefs.arrowKeys: step(cols)
        case 4 where prefs.vimKeys: step(-1)
        case 37 where prefs.vimKeys: step(1)
        case 40 where prefs.vimKeys: step(-cols)
        case 38 where prefs.vimKeys: step(cols)
        default:
            let digits: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if prefs.numberKeys, let i = digits[k], windows.indices.contains(i) { selected = i; commit() }
        }
    }

    var currentColumns: Int { SwitcherView.columns(count: windows.count, prefs: SwitcherPrefs.shared, screen: targetScreen.visibleFrame.width) }

    private var outlined: CGWindowID = 0
    func updateOutline() {
        guard SwitcherPrefs.shared.previewWindow, visible, windows.indices.contains(selected) else { outline?.orderOut(nil); outlined = 0; return }
        let w = windows[selected]
        if w.id == outlined, outline?.isVisible == true { return }
        outlined = w.id
        guard !w.minimized, !w.windowless, w.onCurrentSpace, !w.hidden, !w.frame.isEmpty else { outline?.orderOut(nil); return }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: w.frame.minX, y: h - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        if outline == nil {
            let o = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            o.isOpaque = false; o.backgroundColor = .clear; o.ignoresMouseEvents = true; o.hasShadow = false
            o.level = .floating
            o.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            o.animationBehavior = .none
            o.contentView = NSHostingView(rootView: OutlineView())
            outline = o
        }
        outline?.setFrame(rect, display: true)
        if let p = panel { outline?.order(.below, relativeTo: p.windowNumber) } else { outline?.orderFrontRegardless() }
    }
}

struct OutlineView: View {
    @ObservedObject var theme = Theme.shared
    var body: some View {
        Rectangle().fill(theme.accent.opacity(0.06))
            .overlay(Rectangle().stroke(theme.accent, lineWidth: 3))
            .overlay(Rectangle().stroke(theme.accent.opacity(0.35), lineWidth: 9).padding(-3))
            .drawingGroup()
    }
}
