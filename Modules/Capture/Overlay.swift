import AppKit

final class SelectionOverlay {
    enum Mode { case area, text, scroll }
    enum Result {
        case cancel
        case full(DisplayShot)
        case color(String)
        case area(DisplayShot, CGRect, Mode)
        case window(CGWindowID, DisplayShot, CGRect)
    }

    private var windows: [OverlayWindow] = []
    private let done: (Result) -> Void
    private var finished = false
    var mode: Mode { didSet { windows.forEach { $0.view.needsDisplay = true } } }
    let windowRects: [(CGWindowID, CGRect)]

    init(shots: [DisplayShot], mode: Mode, done: @escaping (Result) -> Void) {
        self.mode = mode
        self.done = done
        windowRects = SelectionOverlay.listWindows()
        NSApp.activate(ignoringOtherApps: true)
        for shot in shots {
            let w = OverlayWindow(shot: shot, owner: self)
            windows.append(w)
            w.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    static func listWindows() -> [(CGWindowID, CGRect)] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 40, r.height > 40 else { return nil }
            return (id, CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height))
        }
    }

    func window(at p: CGPoint) -> (CGWindowID, CGRect)? { windowRects.first { $0.1.contains(p) } }

    func finish(_ r: Result) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        DispatchQueue.main.async { self.done(r) }
    }

    func refreshAll() { windows.forEach { $0.view.needsDisplay = true } }
}

final class OverlayWindow: NSPanel {
    let view: OverlayView

    init(shot: DisplayShot, owner: SelectionOverlay) {
        view = OverlayView(shot: shot, owner: owner)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        contentView = view
        setFrame(shot.screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class OverlayView: NSView {
    let shot: DisplayShot
    unowned let owner: SelectionOverlay
    private var start: CGPoint?
    private var selection: CGRect?
    private var mouse: CGPoint = .zero
    private var hovered: (CGWindowID, CGRect)?

    init(shot: DisplayShot, owner: SelectionOverlay) {
        self.shot = shot
        self.owner = owner
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        mouse = global(window?.mouseLocationOutsideOfEventStream ?? .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private func global(_ local: CGPoint) -> CGPoint { CGPoint(x: local.x + shot.screen.frame.minX, y: local.y + shot.screen.frame.minY) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY) }

    override func mouseMoved(with e: NSEvent) {
        mouse = global(convert(e.locationInWindow, from: nil))
        hovered = owner.mode == .area ? owner.window(at: mouse) : nil
        if window?.isKeyWindow == false { window?.makeKey() }
        owner.refreshAll()
    }

    override func mouseDown(with e: NSEvent) {
        start = global(convert(e.locationInWindow, from: nil))
        selection = nil
    }

    override func mouseDragged(with e: NSEvent) {
        mouse = global(convert(e.locationInWindow, from: nil))
        guard let s = start else { return }
        selection = CGRect(x: min(s.x, mouse.x), y: min(s.y, mouse.y), width: abs(mouse.x - s.x), height: abs(mouse.y - s.y))
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { start = nil }
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            owner.finish(.area(shot, sel.intersection(shot.screen.frame), owner.mode))
        } else if owner.mode == .area, let h = owner.window(at: mouse) {
            owner.finish(.window(h.0, shot, h.1.intersection(shot.screen.frame)))
        }
        selection = nil
    }

    override func rightMouseDown(with event: NSEvent) { owner.finish(.cancel) }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: owner.finish(.cancel)
        case 49, 36: owner.finish(.full(shot))
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "t": owner.mode = owner.mode == .text ? .area : .text
            case "c": if let c = shot.color(at: mouse) { owner.finish(.color(c.hex)) }
            default: break
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor(Theme.shared.accent)
        ctx.interpolationQuality = .high
        ctx.draw(shot.image, in: bounds)
        let focus = selection.map(local) ?? hovered.map { local($0.1) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        if let f = focus {
            ctx.addRect(bounds); ctx.addRect(f); ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(selection == nil ? 2 : 1)
            ctx.stroke(f.insetBy(dx: -0.5, dy: -0.5))
        } else {
            ctx.fill(bounds)
        }
        let m = CGPoint(x: mouse.x - shot.screen.frame.minX, y: mouse.y - shot.screen.frame.minY)
        guard bounds.contains(m) else { return }
        if selection == nil {
            ctx.setStrokeColor(accent.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: 0, y: m.y + 0.5), CGPoint(x: bounds.width, y: m.y + 0.5), CGPoint(x: m.x + 0.5, y: 0), CGPoint(x: m.x + 0.5, y: bounds.height)])
        }
        if let s = selection.map(local) {
            label("\(Int(s.width * shot.scale)) × \(Int(s.height * shot.scale))", at: CGPoint(x: s.minX, y: s.maxY + 6))
        }
        drawLoupe(ctx, at: m, accent: accent)
        hint()
    }

    private func drawLoupe(_ ctx: CGContext, at m: CGPoint, accent: NSColor) {
        let cells = 15, zoom: CGFloat = 8
        let size = CGFloat(cells) * zoom
        var origin = CGPoint(x: m.x + 22, y: m.y - size - 40)
        if origin.x + size > bounds.width - 8 { origin.x = m.x - size - 22 }
        if origin.y < 8 { origin.y = m.y + 22 }
        let px = CGPoint(x: m.x * shot.scale, y: (bounds.height - m.y) * shot.scale)
        let src = CGRect(x: Int(px.x) - cells / 2, y: Int(px.y) - cells / 2, width: cells, height: cells)
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(box.insetBy(dx: -1, dy: -1))
        if let crop = shot.image.cropping(to: src) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: box)
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1)
        for i in 1..<cells {
            let o = CGFloat(i) * zoom
            ctx.strokeLineSegments(between: [CGPoint(x: box.minX + o, y: box.minY), CGPoint(x: box.minX + o, y: box.maxY), CGPoint(x: box.minX, y: box.minY + o), CGPoint(x: box.maxX, y: box.minY + o)])
        }
        ctx.setStrokeColor(accent.cgColor)
        ctx.stroke(CGRect(x: box.minX + CGFloat(cells / 2) * zoom, y: box.minY + CGFloat(cells / 2) * zoom, width: zoom, height: zoom))
        ctx.setStrokeColor(NSColor(Palette.rule).cgColor)
        ctx.stroke(box)
        ctx.restoreGState()
        let hex = shot.color(at: mouse)?.hex ?? ""
        label("\(Int(px.x)), \(Int(px.y))  \(hex)", at: CGPoint(x: box.minX, y: box.minY - 22))
    }

    private func label(_ text: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(Palette.bone)]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let r = CGRect(x: p.x, y: p.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.9).setFill()
        r.fill()
        s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3))
    }

    private func hint() {
        let text: String
        switch owner.mode {
        case .area: text = "DRAG · CLICK A WINDOW · SPACE FULL SCREEN · T TEXT · C COLOR · ESC"
        case .text: text = "TEXT MODE · DRAG OVER TEXT TO COPY IT · T BACK · ESC"
        case .scroll: text = "SCROLLING · SELECT THE PART THAT SCROLLS · ESC"
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor(Palette.bone), .kern: 1.2]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let r = CGRect(x: (bounds.width - size.width) / 2 - 14, y: bounds.height - 70, width: size.width + 28, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.92).setFill()
        r.fill()
        NSColor(Palette.rule).setStroke()
        NSBezierPath(rect: r).stroke()
        s.draw(at: CGPoint(x: r.minX + 14, y: r.minY + 6))
    }
}
