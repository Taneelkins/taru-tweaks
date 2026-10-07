import AppKit
import Combine
import SwiftUI

let FinderPath = "/System/Library/CoreServices/Finder.app"
let DockLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))

enum MacDock {
    static let domain = "com.apple.dock" as CFString
    static let hidden: [(String, CFPropertyList)] = [("autohide", kCFBooleanTrue), ("autohide-delay", NSNumber(value: 1000.0)), ("no-bouncing", kCFBooleanTrue),
                                                    ("launchanim", kCFBooleanFalse), ("tilesize", NSNumber(value: 16)), ("magnification", kCFBooleanFalse)]

    static func hide() {
        let d = UserDefaults.standard
        CFPreferencesAppSynchronize(domain)
        var saved = d.dictionary(forKey: "dock.mac.saved") ?? [:]
        if d.bool(forKey: "dock.mac.hidden"), saved.isEmpty {
            saved["autohide"] = d.bool(forKey: "dock.mac.autohide")
            saved["autohide-delay"] = d.object(forKey: "dock.mac.delay") ?? "unset"
        }
        var changed = false
        for (key, value) in hidden {
            let now = CFPreferencesCopyAppValue(key as CFString, domain)
            if saved[key] == nil { saved[key] = now ?? ("unset" as CFPropertyList) }
            if !(now.map { CFEqual($0, value) } ?? false) {
                CFPreferencesSetAppValue(key as CFString, value, domain)
                changed = true
            }
        }
        d.set(saved, forKey: "dock.mac.saved")
        d.set(true, forKey: "dock.mac.hidden")
        if changed { CFPreferencesAppSynchronize(domain); restart() }
    }

    static func restore() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "dock.mac.hidden"), let saved = d.dictionary(forKey: "dock.mac.saved") else { return }
        for (key, value) in saved {
            let v: CFPropertyList? = (value as? String) == "unset" ? nil : value as CFPropertyList
            CFPreferencesSetAppValue(key as CFString, v, domain)
        }
        CFPreferencesAppSynchronize(domain)
        d.removeObject(forKey: "dock.mac.saved")
        d.set(false, forKey: "dock.mac.hidden")
        restart()
    }

    static func restart() {
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); k.arguments = ["Dock"]
        try? k.run(); k.waitUntilExit()
    }
}

final class TaruDock {
    static let shared = TaruDock()
    let model = DockPresets.shared
    let panel = DockPanel()
    lazy var view = DockView(dock: self)
    private(set) var shown = false
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    private var badgeTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var started = false
    var holds = 0 { didSet { if holds <= 0 { holds = 0; pointerMoved() } } }

    var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    func start() {
        guard !started else { return }
        started = true
        panel.contentView = view
        model.$enabled.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] on in on ? self?.enable() : self?.disable() }.store(in: &bag)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.view.setNeedsRebuild() }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.place(animated: false) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in MacDock.restore() }
    }

    private func enable() {
        MacDock.hide()
        view.rebuild()
        if monitors.isEmpty {
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.pointerMoved() }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in self?.pointerMoved(); return e }) { monitors.append(l) }
        }
        badgeTimer?.invalidate()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.checkAttention() }
        if !model.autohide { show() }
    }

    private func checkAttention() {
        let raised = view.refreshBadges()
        guard !raised.isEmpty else { return }
        if !shown {
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self, self.shown, self.holds == 0, !self.panel.frame.insetBy(dx: -30, dy: -30).contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.view.attention(raised) }
    }

    private func disable() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        badgeTimer?.invalidate(); badgeTimer = nil
        panel.orderOut(nil)
        shown = false
        MacDock.restore()
    }

    func targetFrame(shown: Bool) -> NSRect {
        let size = view.preferredSize
        let f = screen.frame
        return NSRect(x: (f.midX - size.width / 2).rounded(), y: shown ? f.minY + 6 : f.minY - size.height - 4, width: size.width, height: size.height)
    }

    func pointerMoved() {
        guard model.enabled else { return }
        let p = NSEvent.mouseLocation
        if !model.autohide { if !shown { show() }; return }
        if !shown {
            let f = targetFrame(shown: true)
            if p.y <= screen.frame.minY + 1.5 && p.x >= f.minX - 40 && p.x <= f.maxX + 40 { show() }
            return
        }
        if holds > 0 || panel.frame.insetBy(dx: -30, dy: -30).contains(p) {
            hideWork?.cancel(); hideWork = nil
            return
        }
        if hideWork == nil {
            let w = DispatchWorkItem { [weak self] in self?.hideWork = nil; self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    func show() {
        hideWork?.cancel(); hideWork = nil
        guard !shown else { return }
        shown = true
        panel.setFrame(targetFrame(shown: false), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame(shown: true), display: true)
        }
    }

    func hide() {
        guard shown, holds == 0, model.autohide else { return }
        shown = false
        view.endHover()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.16
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetFrame(shown: false), display: true)
        }, completionHandler: { [weak self] in if self?.shown == false { self?.panel.orderOut(nil) } })
    }

    func place(animated: Bool) {
        guard shown else { return }
        let f = targetFrame(shown: true)
        guard f != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; panel.animator().setFrame(f, display: true) }
        } else {
            panel.setFrame(f, display: true)
        }
    }
}

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = DockLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovable = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum TileKind {
    case finder, item(DockItem), running(URL), trash
}

final class DockTile {
    let kind: TileKind
    let page: Int
    let layer = CALayer()
    let icon = CALayer()
    let dot = CALayer()
    let badge = CATextLayer()
    let image: NSImage

    var running = false { didSet { dot.opacity = running ? 1 : 0 } }

    var url: URL? {
        switch kind {
        case .finder: return URL(fileURLWithPath: FinderPath)
        case .item(let i): return i.url
        case .running(let u): return u
        case .trash: return nil
        }
    }

    var name: String {
        switch kind {
        case .finder: return "Finder"
        case .item(let i): return i.name
        case .running(let u): return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
        case .trash: return "Trash"
        }
    }

    var isApp: Bool { url?.pathExtension == "app" }

    init(kind: TileKind, page: Int, size s: CGFloat) {
        self.kind = kind
        self.page = page
        if case .trash = kind {
            image = NSImage(named: NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(for: .folder)
        } else {
            let u = { () -> URL? in
                switch kind {
                case .finder: return URL(fileURLWithPath: FinderPath)
                case .item(let i): return i.url
                case .running(let u): return u
                case .trash: return nil
                }
            }()
            image = u.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        }
        image.size = NSSize(width: s, height: s)
        layer.frame = CGRect(x: 0, y: 6, width: s, height: s + 8)
        icon.anchorPoint = CGPoint(x: 0.5, y: 0)
        icon.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        icon.position = CGPoint(x: s / 2, y: 8)
        icon.contents = image.layerContents(forContentsScale: 2)
        icon.contentsScale = 2
        icon.contentsGravity = .resizeAspect
        dot.frame = CGRect(x: (s - 10) / 2, y: 2, width: 10, height: 2)
        dot.backgroundColor = NSColor(Theme.shared.accent).cgColor
        dot.opacity = 0
        badge.isHidden = true
        badge.fontSize = 10
        badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.foregroundColor = NSColor.black.cgColor
        badge.backgroundColor = NSColor(Theme.shared.accent).cgColor
        badge.alignmentMode = .center
        badge.contentsScale = 2
        badge.cornerRadius = 2
        layer.addSublayer(icon)
        layer.addSublayer(dot)
        layer.addSublayer(badge)
    }

    func setBadge(_ s: String?) {
        guard let s, !s.isEmpty else { badge.isHidden = true; return }
        let w = max(15, CGFloat(s.count) * 7 + 6)
        badge.string = s
        badge.frame = CGRect(x: layer.bounds.width - w + 4, y: layer.bounds.height - 13, width: w, height: 15)
        badge.isHidden = false
    }
}

final class DockLabel {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let field = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel.level = NSWindow.Level(rawValue: DockLevel.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        box.layer?.borderColor = NSColor(Palette.rule).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 3
        field.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        field.textColor = NSColor(Palette.bone)
        box.addSubview(field)
        panel.contentView = box
    }

    func show(_ text: String, centerX: CGFloat, bottom: CGFloat, for seconds: Double? = nil) {
        hideWork?.cancel()
        field.stringValue = text
        let size = field.fittingSize
        field.frame = NSRect(x: 9, y: 4, width: size.width, height: size.height)
        panel.setFrame(NSRect(x: (centerX - (size.width + 18) / 2).rounded(), y: bottom, width: size.width + 18, height: size.height + 8), display: true)
        panel.orderFrontRegardless()
        if let seconds {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }
}

final class DragGhost {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let size: CGFloat

    init(image: NSImage, size: CGFloat) {
        self.size = size
        panel.level = NSWindow.Level(rawValue: DockLevel.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let v = NSImageView(image: image)
        v.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = v
        panel.setFrame(NSRect(x: 0, y: 0, width: size, height: size), display: false)
        panel.alphaValue = 0.9
        panel.orderFrontRegardless()
    }

    func move(to p: NSPoint) { panel.setFrameOrigin(NSPoint(x: p.x - size / 2, y: p.y - size / 2)) }
    func setRemoving(_ r: Bool) { panel.alphaValue = r ? 0.4 : 0.9 }
    func close() { panel.orderOut(nil) }
}

final class ClosureItem: NSMenuItem {
    var handler: () -> Void = {}
    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
    }
    @objc func fire() { handler() }
}

final class DockView: NSView, NSPopoverDelegate {
    unowned let dock: TaruDock
    var model: DockPresets { dock.model }
    private let bg = CALayer()
    private let pager = CALayer()
    private let pages = CALayer()
    private var pageTiles: [[DockTile]] = []
    private var fixedLeft: [DockTile] = []
    private var fixedRight: [DockTile] = []
    private var separators: [CALayer] = []
    private var bars: [CALayer] = []
    private var hints: [Int: CATextLayer] = [:]
    private var pageWidth: CGFloat = 0
    private var offset: CGFloat = 0
    private var tracking = false
    private var axisLocked: Bool?
    private var hover: DockTile?
    private let label = DockLabel()
    private var needsRebuild = false
    private var down: (tile: DockTile?, point: CGPoint)?
    private var drag: (tile: DockTile, ghost: DragGhost, index: Int?, remove: Bool)?
    private var dropTarget: (tile: DockTile?, index: Int?)?
    private var dropHold = false
    private var launching = Set<String>()
    private var lastLabels: [String: String] = [:]
    private var popup: DockPopup?
    private(set) var preferredSize = NSSize(width: 200, height: 70)

    private var s: CGFloat = 48
    private let gap: CGFloat = 8
    private let pad: CGFloat = 10
    private var activeRow: [DockTile] { pageTiles.indices.contains(model.activeIndex) ? pageTiles[model.activeIndex] : [] }

    init(dock: TaruDock) {
        self.dock = dock
        super.init(frame: .zero)
        wantsLayer = true
        bg.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        bg.borderColor = NSColor(Palette.rule).cgColor
        bg.borderWidth = 1
        bg.cornerRadius = 8
        layer?.addSublayer(bg)
        pager.masksToBounds = true
        layer?.addSublayer(pager)
        pager.addSublayer(pages)
        registerForDraggedTypes([.fileURL])
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let p = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path { self?.launching.remove(p) }
            self?.setNeedsRebuild()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.setNeedsRebuild() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        CATransaction.commit()
    }

    // MARK: Build

    func setNeedsRebuild() {
        if drag != nil || tracking || dropHold { needsRebuild = true } else { rebuild() }
    }

    func rebuild() {
        needsRebuild = false
        setHover(nil)
        (fixedLeft + fixedRight + pageTiles.flatMap { $0 }).forEach { $0.layer.removeFromSuperlayer() }
        (separators + bars + Array(hints.values)).forEach { $0.removeFromSuperlayer() }
        hints = [:]
        separators = []; bars = []
        let pinned = Set(model.presets.indices.contains(model.activeIndex) ? model.presets[model.activeIndex].items.map(\.path) : [])
        var runningURLs: [URL] = []
        if model.showRunning {
            var seen = Set<String>()
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let u = app.bundleURL, u.path != FinderPath, !pinned.contains(u.path), app.bundleIdentifier != Bundle.main.bundleIdentifier, seen.insert(u.path).inserted else { continue }
                runningURLs.append(u)
            }
        }
        let slots = max(3, model.presets.map(\.items.count).max() ?? 0)
        let count = CGFloat(1 + slots + runningURLs.count + 1)
        let maxWidth = (NSScreen.screens.first?.frame.width ?? 1512) - 24
        let fit = (maxWidth - 2 * pad - 16 - count * gap) / count
        s = max(24, min(CGFloat(model.iconSize), fit.rounded(.down)))
        let size = s
        fixedLeft = [DockTile(kind: .finder, page: -1, size: size)]
        pageTiles = model.presets.enumerated().map { i, p in p.items.map { DockTile(kind: .item($0), page: i, size: size) } }
        var right: [DockTile] = runningURLs.map { DockTile(kind: .running($0), page: -1, size: size) }
        right.append(DockTile(kind: .trash, page: -1, size: size))
        fixedRight = right
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for t in fixedLeft + fixedRight { layer?.addSublayer(t.layer) }
        for row in pageTiles { for t in row { pages.addSublayer(t.layer) } }
        for (i, row) in pageTiles.enumerated() where row.isEmpty {
            let h = CATextLayer()
            h.string = "DRAG APPS HERE"
            h.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            h.fontSize = 10
            h.foregroundColor = NSColor(Palette.ash).cgColor
            h.alignmentMode = .center
            h.contentsScale = 2
            pages.addSublayer(h)
            hints[i] = h
        }
        for _ in 0..<2 {
            let l = CALayer()
            l.backgroundColor = NSColor(Palette.rule).cgColor
            layer?.addSublayer(l)
            separators.append(l)
        }
        if model.presets.count > 1 {
            for _ in model.presets { let b = CALayer(); layer?.addSublayer(b); bars.append(b) }
        }
        CATransaction.commit()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        for t in fixedLeft + fixedRight + pageTiles.flatMap({ $0 }) {
            if case .running = t.kind { t.running = true } else if let p = t.url?.path { t.running = running.contains(p) }
            if let p = t.url?.path, launching.contains(p) { bounce(t) }
        }
        offset = 0
        relayout(animated: false)
        refreshBadges()
        dock.place(animated: true)
    }

    private func relayout(animated: Bool, gapAt: Int? = nil, excluding: DockTile? = nil) {
        let s = self.s, H = s + 22
        let active = model.activeIndex
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        var x = pad
        for t in fixedLeft { t.layer.frame.origin = CGPoint(x: x, y: 6); x += s + gap }
        let visibleActive = activeRow.filter { $0 !== excluding }.count + (gapAt != nil ? 1 : 0)
        let slots = max(3, pageTiles.map(\.count).max() ?? 0, visibleActive)
        pageWidth = CGFloat(slots) * (s + gap) - gap
        pager.frame = CGRect(x: x, y: 0, width: pageWidth, height: H)
        pages.frame = CGRect(x: -CGFloat(active) * pageWidth + offset, y: 0, width: CGFloat(max(pageTiles.count, 1)) * pageWidth, height: H)
        for (i, row) in pageTiles.enumerated() {
            let visible = row.filter { $0 !== excluding }
            let n = visible.count + (i == active && gapAt != nil ? 1 : 0)
            var tx = CGFloat(i) * pageWidth + (pageWidth - (CGFloat(n) * (s + gap) - gap)) / 2
            for (k, t) in visible.enumerated() {
                if i == active, let g = gapAt, k == g { tx += s + gap }
                t.layer.frame.origin = CGPoint(x: tx, y: 6)
                tx += s + gap
            }
        }
        for (i, h) in hints { h.frame = CGRect(x: CGFloat(i) * pageWidth, y: 6 + 8 + s / 2 - 7, width: pageWidth, height: 14); h.isHidden = i == active && gapAt != nil }
        x += pageWidth + gap
        separators[0].frame = CGRect(x: x - gap / 2 + 2, y: 14 + s * 0.15, width: 1, height: s * 0.7)
        x += 4
        let runningTiles = fixedRight.dropLast()
        for t in runningTiles { t.layer.frame.origin = CGPoint(x: x, y: 6); x += s + gap }
        separators[1].isHidden = runningTiles.isEmpty
        if !runningTiles.isEmpty {
            separators[1].frame = CGRect(x: x - gap / 2 + 2, y: 14 + s * 0.15, width: 1, height: s * 0.7)
            x += 4
        }
        fixedRight.last?.layer.frame.origin = CGPoint(x: x, y: 6)
        x += s + pad
        let total = CGFloat(bars.count) * 14 + CGFloat(max(bars.count - 1, 0)) * 4
        var bx = pager.frame.midX - total / 2
        for (i, b) in bars.enumerated() {
            b.frame = CGRect(x: bx, y: 2, width: 14, height: 2)
            b.backgroundColor = (i == active ? NSColor(Theme.shared.accent) : NSColor(Palette.rule)).cgColor
            bx += 18
        }
        CATransaction.commit()
        preferredSize = NSSize(width: x, height: H)
    }

    private func rect(of t: DockTile) -> CGRect {
        guard t.page >= 0, let root = layer else { return t.layer.frame }
        return pages.convert(t.layer.frame, to: root)
    }

    private func tile(at p: CGPoint) -> DockTile? {
        (fixedLeft + activeRow + fixedRight).first { $0 !== drag?.tile && rect(of: $0).insetBy(dx: -gap / 2, dy: -6).contains(p) }
    }

    private func insertionIndex(at x: CGFloat, excluding: DockTile?) -> Int {
        let count = activeRow.filter { $0 !== excluding }.count
        let n = CGFloat(count + 1)
        let start = pager.frame.minX + (pageWidth - (n * (s + gap) - gap)) / 2
        return min(max(Int(((x - start) / (s + gap)).rounded(.down)), 0), count)
    }

    // MARK: Hover + labels

    override func mouseMoved(with e: NSEvent) { if drag == nil { setHover(tile(at: convert(e.locationInWindow, from: nil))) } }
    override func mouseExited(with e: NSEvent) { if drag == nil { setHover(nil) } }
    func endHover() { setHover(nil) }

    private func setHover(_ t: DockTile?) {
        guard t !== hover else { return }
        hover?.icon.setAffineTransform(.identity)
        hover = t
        hoverWork?.cancel()
        guard let t else { label.hide(); return }
        t.icon.setAffineTransform(CGAffineTransform(scaleX: 1.1, y: 1.1))
        if popup != nil && hoverPopup && popupTile === t { return }
        showLabel(t.name, over: rect(of: t))
        guard t.isApp, let u = t.url, drag == nil, !tracking else { return }
        let w = DispatchWorkItem { [weak self, weak t] in
            guard let self, let t, self.hover === t else { return }
            let wins = self.windows(of: u)
            if wins.count >= 1 { self.label.hide(); self.showWindows(wins, from: t, hovering: true) } else if self.hoverPopup { self.popup?.dismiss() }
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (popup != nil && hoverPopup ? 0.12 : 0.45), execute: w)
    }

    private var hoverWork: DispatchWorkItem?
    private var hoverPopup = false
    private weak var popupTile: DockTile?
    private var hoverWatch: Timer?

    private func watchHoverPopup() {
        hoverWatch?.invalidate()
        var misses = 0
        hoverWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self, let p = self.popup, self.hoverPopup, let w = self.window else { timer.invalidate(); return }
            let m = NSEvent.mouseLocation
            let tileRect = self.popupTile.map { w.convertToScreen(self.convert(self.rect(of: $0), to: nil)).insetBy(dx: -6, dy: -10) } ?? .zero
            let bridge = NSRect(x: min(tileRect.minX, p.frame.minX), y: tileRect.maxY - 2, width: max(tileRect.maxX, p.frame.maxX) - min(tileRect.minX, p.frame.minX), height: max(0, p.frame.minY - tileRect.maxY + 4))
            if p.frame.insetBy(dx: -6, dy: -6).contains(m) || tileRect.contains(m) || bridge.contains(m) || w.frame.contains(m) && self.hover != nil && self.hover === self.popupTile {
                misses = 0
            } else {
                misses += 1
                if misses >= 2 { p.dismiss(); timer.invalidate() }
            }
        }
    }

    private func showLabel(_ text: String, over r: CGRect, for seconds: Double? = nil) {
        guard let w = window else { return }
        let sr = w.convertToScreen(convert(r, to: nil))
        label.show(text, centerX: sr.midX, bottom: w.frame.maxY + 8, for: seconds)
    }

    // MARK: Clicks + dragging icons

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        let p = convert(e.locationInWindow, from: nil)
        down = (tile(at: p), p)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if drag == nil, let d = down, let t = d.tile, hypot(p.x - d.point.x, p.y - d.point.y) > 5, canDrag(t) { beginDrag(t) }
        if drag != nil { updateDrag() }
    }

    override func mouseUp(with e: NSEvent) {
        defer { down = nil }
        if drag != nil { endDrag(); return }
        guard let t = down?.tile, t === tile(at: convert(e.locationInWindow, from: nil)) else { return }
        activate(t)
    }

    private func canDrag(_ t: DockTile) -> Bool {
        switch t.kind {
        case .item: return t.page == model.activeIndex
        case .running: return true
        default: return false
        }
    }

    private func beginDrag(_ t: DockTile) {
        setHover(nil)
        drag = (t, DragGhost(image: t.image, size: s), nil, false)
        CATransaction.begin(); CATransaction.setDisableActions(true); t.layer.opacity = 0; CATransaction.commit()
        dock.holds += 1
    }

    private func updateDrag() {
        guard var d = drag, let w = window else { return }
        let m = NSEvent.mouseLocation
        d.ghost.move(to: m)
        let local = convert(w.convertPoint(fromScreen: m), from: nil)
        d.remove = false
        d.index = nil
        if m.y > w.frame.maxY + 50 {
            if case .item = d.tile.kind { d.remove = true }
        } else if pager.frame.insetBy(dx: -s / 2, dy: -24).contains(local) {
            d.index = insertionIndex(at: local.x, excluding: d.tile)
        }
        d.ghost.setRemoving(d.remove)
        let changed = d.index != drag?.index || d.remove != drag?.remove
        drag = d
        if d.remove { label.show("Remove", centerX: m.x, bottom: m.y + s / 2 + 6) } else { label.hide() }
        if changed {
            relayout(animated: true, gapAt: d.index, excluding: d.tile)
            dock.place(animated: true)
        }
    }

    private func endDrag() {
        guard let d = drag else { return }
        drag = nil
        d.ghost.close()
        label.hide()
        let active = model.activeIndex
        var items = model.presets[active].items
        switch d.tile.kind {
        case .item(let item):
            if d.remove {
                items.removeAll { $0 == item }
                NSAnimationEffect.poof.show(centeredAt: NSEvent.mouseLocation, size: NSSize(width: s, height: s))
            } else if let i = d.index {
                items.removeAll { $0 == item }
                items.insert(item, at: min(i, items.count))
            }
        case .running(let u):
            if let i = d.index { items.insert(DockItem(path: u.path), at: min(i, items.count)) }
        default: break
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); d.tile.layer.opacity = 1; CATransaction.commit()
        if items != model.presets[active].items {
            model.presets[active].items = items
        } else {
            relayout(animated: true)
            dock.place(animated: true)
        }
        dock.holds -= 1
        if needsRebuild { rebuild() }
    }

    private func activate(_ t: DockTile) {
        switch t.kind {
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case .item(let i) where i.isFolder:
            showStack(i, from: t)
        case .item(let i) where !i.isApp:
            NSWorkspace.shared.open(i.url)
        default:
            guard let u = t.url else { return }
            let wins = windows(of: u)
            popup?.dismiss()
            if let w = mostRecent(wins), NSWorkspace.shared.frontmostApplication?.processIdentifier != w.pid || w.minimized || wins.count > 1 {
                NSRunningApplication(processIdentifier: w.pid)?.activate(options: [.activateAllWindows])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { WindowEngine.shared.focus(w) }
                return
            }
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == u.path }) {
                launching.insert(u.path)
                bounce(t)
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: u, configuration: cfg)
        }
    }

    private func bounce(_ t: DockTile) {
        let a = CABasicAnimation(keyPath: "position.y")
        a.byValue = 6
        a.duration = 0.26
        a.autoreverses = true
        a.repeatCount = 14
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        t.icon.add(a, forKey: "bounce")
    }

    // MARK: Menus

    override func rightMouseDown(with e: NSEvent) {
        guard let t = tile(at: convert(e.locationInWindow, from: nil)) else { return }
        setHover(nil)
        dock.holds += 1
        NSMenu.popUpContextMenu(menu(for: t), with: e, for: self)
        dock.holds -= 1
    }

    private func menu(for t: DockTile) -> NSMenu {
        let m = NSMenu()
        let app = t.url.flatMap { u in NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == u.path } }
        switch t.kind {
        case .trash:
            m.addItem(ClosureItem("Open") { [weak self] in self?.activate(t) })
        case .finder:
            m.addItem(ClosureItem("New Finder Window") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())) })
        default:
            guard let u = t.url else { break }
            let wins = t.isApp ? windows(of: u) : []
            for w in wins {
                let it = ClosureItem(w.title.isEmpty ? w.appName : w.title) { WindowEngine.shared.focus(w) }
                if w.minimized { it.image = NSImage(systemSymbolName: "minus.square", accessibilityDescription: nil) }
                m.addItem(it)
            }
            if !wins.isEmpty { m.addItem(.separator()) }
            if t.isApp {
                m.addItem(ClosureItem("Open") { [weak self] in self?.activate(t) })
            } else {
                m.addItem(ClosureItem("Open") { NSWorkspace.shared.open(u) })
            }
            m.addItem(ClosureItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
            m.addItem(.separator())
            let keep = ClosureItem("Keep in Dock") { [weak self] in self?.togglePin(u.path, in: nil) }
            keep.state = activeRow.contains { $0.url?.path == u.path } ? .on : .off
            m.addItem(keep)
            if model.presets.count > 1 {
                let sub = NSMenu()
                for (i, p) in model.presets.enumerated() where i != model.activeIndex {
                    let it = ClosureItem(p.name) { [weak self] in self?.togglePin(u.path, in: i) }
                    it.state = p.items.contains { $0.path == u.path } ? .on : .off
                    sub.addItem(it)
                }
                let parent = NSMenuItem(title: "Also in Preset", action: nil, keyEquivalent: "")
                parent.submenu = sub
                m.addItem(parent)
            }
        }
        if let app {
            m.addItem(.separator())
            m.addItem(ClosureItem(app.isHidden ? "Show" : "Hide") { app.isHidden ? app.unhide() : app.hide() })
            if SwitcherPrefs.shared.dockForceQuit {
                m.addItem(ClosureItem("Force Quit") { app.forceTerminate() })
                m.addItem(ClosureItem("Quit") { app.terminate() })
            } else {
                m.addItem(ClosureItem("Quit") { app.terminate() })
                let fq = ClosureItem("Force Quit") { app.forceTerminate() }
                fq.isAlternate = true
                fq.keyEquivalentModifierMask = .option
                m.addItem(fq)
            }
        }
        return m
    }

    private func togglePin(_ path: String, in index: Int?) {
        let i = index ?? model.activeIndex
        guard model.presets.indices.contains(i) else { return }
        if model.presets[i].items.contains(where: { $0.path == path }) {
            model.presets[i].items.removeAll { $0.path == path }
        } else {
            model.presets[i].items.append(DockItem(path: path))
        }
    }

    private func windows(of app: URL) -> [Win] {
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.path }.map(\.processIdentifier))
        guard !pids.isEmpty else { return [] }
        return WindowEngine.shared.all().filter { pids.contains($0.pid) && !$0.windowless && ($0.minimized || ($0.frame.width >= 420 && $0.frame.height >= 240)) }
    }

    private func mostRecent(_ wins: [Win]) -> Win? {
        let order = WindowEngine.shared.mru
        return wins.min { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
    }

    private func showWindows(_ wins: [Win], from t: DockTile, hovering: Bool = false) {
        let order = WindowEngine.shared.mru
        let sorted = wins.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
        let picker = WindowPickerModel(wins: sorted)
        present(WindowPicker(model: picker, pick: { [weak self] w in
            self?.popup?.dismiss()
            NSRunningApplication(processIdentifier: w.pid)?.activate(options: [.activateAllWindows])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { WindowEngine.shared.focus(w) }
        }, onEmpty: { [weak self] in self?.popup?.dismiss() }), from: t)
        hoverPopup = hovering
        popupTile = t
        if hovering { watchHoverPopup() }
        Thumbnails.shared.refresh(wins) { DispatchQueue.main.async { picker.reload() } }
    }

    private func present<V: View>(_ content: V, from t: DockTile) {
        popup?.dismiss()
        hoverPopup = false
        hoverWatch?.invalidate()
        guard let w = window else { return }
        let p = DockPopup(content)
        p.onClose = { [weak self, weak p] in
            guard let self, self.popup === p else { return }
            self.popup = nil
            self.hoverPopup = false
            self.hoverWatch?.invalidate()
            self.dock.holds -= 1
        }
        popup = p
        dock.holds += 1
        p.show(above: w.convertToScreen(convert(rect(of: t), to: nil)), within: w.screen ?? NSScreen.screens[0])
    }

    // MARK: Folder stacks

    private func showStack(_ item: DockItem, from t: DockTile) {
        present(StackView(folder: item.url) { [weak self] in self?.popup?.dismiss() }, from: t)
    }

    // MARK: Swiping between presets

    override func scrollWheel(with e: NSEvent) {
        guard model.presets.count > 1, drag == nil, e.momentumPhase.isEmpty else { return }
        let i = model.activeIndex, last = model.presets.count - 1
        switch e.phase {
        case .began:
            tracking = true
            offset = 0
            axisLocked = nil
            setHover(nil)
        case .changed:
            guard tracking else { return }
            if axisLocked == nil, e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 { axisLocked = abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) }
            guard axisLocked == true else { return }
            offset += e.scrollingDeltaX
            var visual = offset
            if (i == 0 && visual > 0) || (i == last && visual < 0) { visual *= 0.25 }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pages.frame.origin.x = -CGFloat(i) * pageWidth + visual
            CATransaction.commit()
        case .ended, .cancelled:
            guard tracking else { return }
            tracking = false
            let threshold = min(pageWidth * 0.2, 70)
            var target = i
            if axisLocked == true {
                if offset < -threshold && i < last { target = i + 1 } else if offset > threshold && i > 0 { target = i - 1 }
            }
            offset = 0
            slide(to: target)
        default:
            break
        }
    }

    private func slide(to target: Int) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.24)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            if target != self.model.activeIndex { self.model.select(target) } else if self.needsRebuild { self.rebuild() }
        }
        pages.frame.origin.x = -CGFloat(target) * pageWidth
        for (k, b) in bars.enumerated() { b.backgroundColor = (k == target ? NSColor(Theme.shared.accent) : NSColor(Palette.rule)).cgColor }
        CATransaction.commit()
        if target != model.activeIndex, model.presets.indices.contains(target) {
            showLabel(model.presets[target].name.uppercased(), over: pager.frame, for: 0.9)
        }
    }

    // MARK: Badges

    @discardableResult
    func refreshBadges() -> [String] {
        guard let macDock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(macDock.processIdentifier), kAXChildrenAttribute as CFString, &kids)
        guard let list = (kids as? [AXUIElement])?.first else { return [] }
        var items: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items)
        var labels: [String: String] = [:]
        for it in (items as? [AXUIElement]) ?? [] {
            var u: CFTypeRef?, l: CFTypeRef?
            AXUIElementCopyAttributeValue(it, kAXURLAttribute as CFString, &u)
            AXUIElementCopyAttributeValue(it, "AXStatusLabel" as CFString, &l)
            if let url = u as? URL, let text = l as? String, !text.isEmpty { labels[url.standardizedFileURL.path] = text }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for t in fixedLeft + fixedRight + pageTiles.flatMap({ $0 }) { t.setBadge(t.url.flatMap { labels[$0.standardizedFileURL.path] }) }
        CATransaction.commit()
        let raised = labels.filter { path, text in
            guard let old = lastLabels[path] else { return true }
            if let a = Int(text), let b = Int(old) { return a > b }
            return text != old
        }.map(\.key)
        let first = lastLabels.isEmpty && !labels.isEmpty
        lastLabels = labels
        return first ? [] : raised
    }

    func attention(_ paths: [String]) {
        for t in fixedLeft + activeRow + fixedRight {
            guard let p = t.url?.standardizedFileURL.path, paths.contains(p) else { continue }
            let a = CABasicAnimation(keyPath: "position.y")
            a.byValue = 6
            a.duration = 0.22
            a.autoreverses = true
            a.repeatCount = 3
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            t.icon.add(a, forKey: "attention")
        }
    }

    // MARK: Files dragged in from Finder

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func clearDrop() {
        if let t = dropTarget?.tile { t.icon.setAffineTransform(.identity) }
        dropTarget = nil
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        if !dropHold { dropHold = true; dock.holds += 1 }
        return draggingUpdated(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return [] }
        let p = convert(info.draggingLocation, from: nil)
        let previous = dropTarget?.index
        clearDrop()
        if let t = tile(at: p) {
            if case .trash = t.kind {
                dropTarget = (t, nil)
                t.icon.setAffineTransform(CGAffineTransform(scaleX: 1.2, y: 1.2))
                if previous != nil { relayout(animated: true) }
                return .move
            }
            if t.isApp && !urls.contains(where: { $0.pathExtension == "app" }) {
                dropTarget = (t, nil)
                t.icon.setAffineTransform(CGAffineTransform(scaleX: 1.2, y: 1.2))
                if previous != nil { relayout(animated: true) }
                return .generic
            }
        }
        let addable = urls.allSatisfy { $0.pathExtension == "app" || DockItem(path: $0.path).isFolder }
        if addable, pager.frame.insetBy(dx: -s / 2, dy: -12).contains(p) {
            let i = insertionIndex(at: p.x, excluding: nil)
            dropTarget = (nil, i)
            if i != previous { relayout(animated: true, gapAt: i); dock.place(animated: true) }
            return .link
        }
        if previous != nil { relayout(animated: true); dock.place(animated: true) }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrop()
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let urls = fileURLs(info)
        guard let target = dropTarget else { return false }
        if let t = target.tile {
            if case .trash = t.kind {
                for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            } else if let app = t.url {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
        } else if let i = target.index {
            let active = model.activeIndex
            var items = model.presets[active].items
            var at = min(i, items.count)
            for u in urls where !items.contains(where: { $0.path == u.path }) {
                items.insert(DockItem(path: u.path), at: at)
                at += 1
            }
            clearDrop()
            model.presets[active].items = items
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        endDrop()
    }

    private func endDrop() {
        let hadGap = dropTarget?.index != nil
        clearDrop()
        if dropHold { dropHold = false; dock.holds -= 1 }
        if needsRebuild { rebuild() } else if hadGap { relayout(animated: true); dock.place(animated: true) }
    }
}

struct StackView: View {
    let folder: URL
    let close: () -> Void
    @State private var entries: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FileManager.default.displayName(atPath: folder.path).uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash)
            if entries.isEmpty {
                Text("Empty").font(.system(size: 12)).foregroundStyle(Palette.ash).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 8), count: 5), spacing: 12) {
                        ForEach(entries, id: \.self) { u in
                            Button { NSWorkspace.shared.open(u); close() } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 44, height: 44)
                                    Text(FileManager.default.displayName(atPath: u.path)).font(.system(size: 10.5)).foregroundStyle(Palette.bone)
                                        .lineLimit(2).multilineTextAlignment(.center).frame(width: 76)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat((entries.count + 4) / 5) * 88, 360))
            }
            HStack {
                Spacer()
                TweakButton(title: "Open in Finder") { NSWorkspace.shared.open(folder); close() }
            }
        }
        .padding(14)
        .frame(width: 444)
        .background(Palette.pit)
        .onAppear(perform: load)
    }

    private func load() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .nameKey]
        let list = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let byDate = folder.lastPathComponent == "Downloads"
        entries = Array(list.sorted { a, b in
            if byDate {
                let da = (try? a.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) ?? .distantPast
                return da > db
            }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }.prefix(60))
    }
}

final class WindowPickerModel: ObservableObject {
    @Published var wins: [Win]
    @Published var thumbs: [CGWindowID: CGImage] = [:]
    init(wins: [Win]) { self.wins = wins; reload() }
    func reload() { thumbs = Dictionary(uniqueKeysWithValues: wins.compactMap { w in Thumbnails.shared.cache[w.id].map { (w.id, $0) } }) }
}

struct WindowPicker: View {
    @ObservedObject var model: WindowPickerModel
    let pick: (Win) -> Void
    var onEmpty: () -> Void = {}

    private func close(_ w: Win) {
        NSRunningApplication(processIdentifier: w.pid)?.forceTerminate()
        model.wins.removeAll { $0.pid == w.pid }
        hover = nil
        if model.wins.isEmpty { onEmpty() }
    }
    @State private var hover: CGWindowID?
    @ObservedObject var theme = Theme.shared

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(180), spacing: 10, alignment: .top), count: min(max(model.wins.count, 1), 4)), spacing: 12) {
            ForEach(model.wins) { w in
                Button { pick(w) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack {
                            Rectangle().fill(Color.black)
                            if let img = model.thumbs[w.id] {
                                Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Text(w.minimized ? "MINIMIZED" : "NO PREVIEW").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
                            }
                        }
                        .frame(width: 180, height: 112)
                        .overlay(Rectangle().stroke(hover == w.id ? theme.accent : Palette.rule, lineWidth: hover == w.id ? 2 : 1))
                        .overlay(alignment: .topTrailing) {
                            if hover == w.id {
                                Button { close(w) } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .heavy))
                                        .foregroundStyle(Color.black).frame(width: 20, height: 20).background(theme.accent)
                                }
                                .buttonStyle(.plain).help(model.wins.filter { $0.pid == w.pid }.count > 1 ? "Force quit (closes all \(model.wins.filter { $0.pid == w.pid }.count) windows of this app)" : "Force quit").padding(5)
                            }
                        }
                        Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.bone)
                            .lineLimit(1).frame(width: 180, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? w.id : (hover == w.id ? nil : hover) }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.wins.map(\.id))
        .padding(12)
        .background(Palette.pit)
    }
}

final class DockPopup: NSPanel {
    var onClose: (() -> Void)?
    private var monitors: [Any] = []
    private var closed = false

    init<V: View>(_ content: V) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: DockLevel.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = NSHostingView(rootView: content.overlay(Rectangle().stroke(Palette.rule)))
    }

    override var canBecomeKey: Bool { true }

    func show(below anchor: NSRect, within screen: NSScreen) {
        let size = contentView?.fittingSize ?? .zero
        let f = screen.frame
        let x = min(max(anchor.midX - size.width / 2, f.minX + 8), f.maxX - size.width - 8)
        present(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height))
    }

    func show(above anchor: NSRect, within screen: NSScreen) {
        let size = contentView?.fittingSize ?? .zero
        let f = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, f.minX + 8), f.maxX - size.width - 8)
        let y = min(anchor.maxY + 12, f.maxY - size.height - 8)
        present(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    private func present(_ frame: NSRect) {
        let size = frame.size, x = frame.minX, y = frame.minY
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.dismiss() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown { if e.keyCode == 53 { self.dismiss(); return nil }; return e }
            if e.window !== self { self.dismiss() }
            return e
        }) { monitors.append(l) }
    }

    func dismiss() {
        guard !closed else { return }
        closed = true
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        orderOut(nil)
        onClose?()
    }
}
