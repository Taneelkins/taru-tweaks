import AppKit
import SwiftUI

final class SelectionOverlay {
    enum Result {
        case cancel
        case finished
        case full(DisplayShot)
        case color(String)
        case scroll(DisplayShot, CGRect)
        case window(CGWindowID, DisplayShot, CGRect)
    }

    var windows: [OverlayWindow] = []
    private let done: (Result) -> Void
    private var finished = false
    let windowRects: [(CGWindowID, CGRect)]
    weak var editing: OverlayView?
    private var tucked: [NSWindow] = []

    init(shots: [DisplayShot], done: @escaping (Result) -> Void) {
        self.done = done
        windowRects = SelectionOverlay.listWindows()
        tucked = NSApp.windows.filter { $0.isVisible && $0.level == .normal && !($0 is NSPanel) }
        tucked.forEach { $0.orderOut(nil) }
        for shot in shots {
            let w = OverlayWindow(shot: shot, owner: self)
            windows.append(w)
            w.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak key] in
            guard let self, !self.finished, let key, !key.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            key.makeKeyAndOrderFront(nil)
            key.makeFirstResponder(key.view)
        }
    }

    static func listWindows() -> [(CGWindowID, CGRect)] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  !["borders", "Übersicht", "WindowManager"].contains(w[kCGWindowOwnerName as String] as? String ?? ""),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 60, r.height > 60 else { return nil }
            return (id, CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height))
        }
    }

    func window(at p: CGPoint) -> (CGWindowID, CGRect)? { windowRects.first { $0.1.contains(p) } }

    func finish(_ r: Result) {
        guard !finished else { return }
        finished = true
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let back = tucked
        DispatchQueue.main.async {
            self.done(r)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { back.forEach { $0.orderBack(nil) } }
        }
    }

    func refreshAll() { windows.forEach { $0.view.needsDisplay = true } }
}

final class OverlayWindow: NSPanel {
    let view: OverlayView

    init(shot: DisplayShot, owner: SelectionOverlay) {
        view = OverlayView(shot: shot, owner: owner)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
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

final class OverlayView: NSView, NSTextFieldDelegate {
    enum Drag { case none, select(CGPoint), move(CGPoint, CGRect), resize(Int, CGRect), draw(CGPoint), measure(CGPoint) }

    let shot: DisplayShot
    weak var owner: SelectionOverlay?
    let model: EditorModel
    private var selection: CGRect?
    private var editing = false
    private var drag: Drag = .none
    private var mouse: CGPoint = .zero
    private var hovered: (CGWindowID, CGRect)?
    private var draft: Annotation?
    private var measureLine: (CGPoint, CGPoint)?
    private var field: NSTextField?
    private var fieldPoint: CGPoint = .zero
    private var tools: NSHostingView<InPlaceTools>?
    private var actions: NSHostingView<InPlaceActions>?
    private var observer: Any?
    private var prefs: CapturePrefs { CapturePrefs.shared }

    init(shot: DisplayShot, owner: SelectionOverlay) {
        self.shot = shot
        self.owner = owner
        model = EditorModel(image: shot.image, scale: shot.scale, savedURL: nil)
        model.tool = .move
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        let m = NSEvent.mouseLocation
        mouse = CGPoint(x: m.x - shot.screen.frame.minX, y: m.y - shot.screen.frame.minY)
        observer = model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.needsDisplay = true } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    // MARK: Geometry

    private var global: CGRect? { selection?.offsetBy(dx: shot.screen.frame.minX, dy: shot.screen.frame.minY) }
    private func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * shot.scale, y: (bounds.height - p.y) * shot.scale) }
    private func pxRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * shot.scale, y: (bounds.height - r.maxY) * shot.scale, width: r.width * shot.scale, height: r.height * shot.scale).integral }
    private func local(_ g: CGRect) -> CGRect { g.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY) }

    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: CGPoint) -> Int? {
        guard let s = selection else { return nil }
        return handles(s).firstIndex { abs($0.x - p.x) <= 7 && abs($0.y - p.y) <= 7 }
    }

    private func resized(_ r: CGRect, handle h: Int, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if [0, 6, 7].contains(h) { minX = p.x }
        if [2, 3, 4].contains(h) { maxX = p.x }
        if [0, 1, 2].contains(h) { maxY = p.y }
        if [4, 5, 6].contains(h) { minY = p.y }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)).intersection(bounds)
    }

    private func updateCursor() {
        if !editing { NSCursor.crosshair.set(); return }
        if let h = handle(at: mouse) {
            ([1, 5].contains(h) ? NSCursor.resizeUpDown : [3, 7].contains(h) ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
        } else if model.tool == .move, selection?.contains(mouse) == true {
            NSCursor.openHand.set()
        } else if model.tool == .text {
            NSCursor.iBeam.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        mouse = convert(e.locationInWindow, from: nil)
        if window?.isKeyWindow == false { window?.makeKey() }
        if !editing, owner?.editing == nil {
            hovered = owner?.window(at: CGPoint(x: mouse.x + shot.screen.frame.minX, y: mouse.y + shot.screen.frame.minY))
        }
        updateCursor()
        owner?.refreshAll()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p
        commitText()
        guard owner?.editing == nil || owner?.editing === self else { return }
        if !editing { drag = .select(p); return }
        if let h = handle(at: p), let s = selection { drag = .resize(h, s); return }
        switch model.tool {
        case .move:
            if let s = selection, s.contains(p) { drag = .move(p, s); NSCursor.closedHand.set() } else { drag = .select(p) }
        case .text: beginText(at: p)
        case .step: model.add(Annotation(mark: .step(px(p), model.nextStep), color: model.color, width: model.weight))
        case .picker: pick(at: p)
        case .measure: drag = .measure(p)
        default: drag = .draw(p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        var p = convert(e.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.width); p.y = min(max(p.y, 0), bounds.height)
        mouse = p
        switch drag {
        case .select(let s):
            selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            hovered = nil
            hideBars()
        case .move(let start, let r):
            var n = r.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            n.origin.x = min(max(n.minX, 0), bounds.width - n.width)
            n.origin.y = min(max(n.minY, 0), bounds.height - n.height)
            selection = n
            layoutBars()
        case .resize(let h, let r):
            selection = resized(r, handle: h, to: p)
            layoutBars()
        case .draw(let s):
            draftMark(from: s, to: p, shift: e.modifierFlags.contains(.shift))
        case .measure(let s):
            measureLine = (s, p)
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none; updateCursor(); needsDisplay = true }
        switch drag {
        case .select:
            if let s = selection, s.width >= 4, s.height >= 4 {
                startEditing()
            } else if let h = owner?.window(at: CGPoint(x: mouse.x + shot.screen.frame.minX, y: mouse.y + shot.screen.frame.minY)) {
                selection = local(h.1).intersection(bounds)
                startEditing()
            } else if !editing {
                selection = nil
            }
        case .draw:
            if let d = draft { model.add(d) }
            draft = nil
        case .move, .resize:
            if let s = selection, s.width < 4 || s.height < 4 { selection = nil; editing = false; hideBars() }
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) { owner?.finish(.cancel) }

    private func startEditing() {
        editing = true
        owner?.editing = self
        hovered = nil
        layoutBars()
    }

    private func draftMark(from s: CGPoint, to p0: CGPoint, shift: Bool) {
        var p = p0
        if shift, [.arrow, .line].contains(model.tool) {
            let dx = p.x - s.x, dy = p.y - s.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            p = CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        }
        let a = px(s), b = px(p)
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let c = model.color, w = model.weight
        switch model.tool {
        case .pen:
            if case .pen(var pts) = draft?.mark { pts.append(b); draft = Annotation(mark: .pen(pts), color: c, width: w) } else { draft = Annotation(mark: .pen([a, b]), color: c, width: w) }
        case .arrow: draft = Annotation(mark: .arrow(a, b), color: c, width: w)
        case .line: draft = Annotation(mark: .line(a, b), color: c, width: w)
        case .rect: draft = Annotation(mark: .rect(r), color: c, width: w)
        case .highlight: draft = Annotation(mark: .highlight(r), color: c == NSColor(Theme.shared.accent) ? .systemYellow : c, width: w)
        case .blur: draft = Annotation(mark: .blur(r), color: c, width: w)
        default: break
        }
    }

    private func pick(at p: CGPoint) {
        guard let c = shot.color(at: CGPoint(x: p.x + shot.screen.frame.minX, y: p.y + shot.screen.frame.minY)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.hex, forType: .string)
        Capture.shared.toast.show("Copied \(c.hex)", swatch: c)
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        let size = (12 + model.weight * 4)
        let t = NSTextField(frame: CGRect(x: p.x, y: p.y - size - 6, width: 360, height: size + 10))
        t.font = .systemFont(ofSize: size, weight: .bold)
        t.textColor = model.color
        t.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        t.isBordered = false
        t.focusRingType = .none
        t.placeholderString = "Type, then Return"
        t.delegate = self
        addSubview(t)
        window?.makeFirstResponder(t)
        field = t
        fieldPoint = px(CGPoint(x: p.x, y: p.y))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); window?.makeFirstResponder(self); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { field?.removeFromSuperview(); field = nil; window?.makeFirstResponder(self); return true }
        return false
    }

    private func commitText() {
        guard let t = field else { return }
        field = nil
        let s = t.stringValue.trimmingCharacters(in: .whitespaces)
        t.removeFromSuperview()
        if !s.isEmpty { model.add(Annotation(mark: .text(fieldPoint, s), color: model.color, width: model.weight)) }
        window?.makeFirstResponder(self)
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.keyCode == 53 { owner?.finish(.cancel); return }
        if !editing {
            if e.keyCode == 49 || e.keyCode == 36 { owner?.finish(.full(shot)) }
            else if ch == "c" { if let c = shot.color(at: CGPoint(x: mouse.x + shot.screen.frame.minX, y: mouse.y + shot.screen.frame.minY)) { owner?.finish(.color(c.hex)) } }
            return
        }
        if mods == .command {
            switch ch {
            case "c": run(.copy); return
            case "s": run(.save); return
            case "z": model.undo(); return
            default: break
            }
        }
        if mods == [.command, .shift], ch == "z" { model.redoLast(); return }
        if e.keyCode == 36 || e.keyCode == 76 { run(.done); return }
        if [123, 124, 125, 126].contains(e.keyCode), var s = selection {
            let d: CGFloat = mods.contains(.shift) ? 10 : 1
            switch e.keyCode {
            case 123: s.origin.x -= d
            case 124: s.origin.x += d
            case 125: s.origin.y -= d
            default: s.origin.y += d
            }
            selection = s.intersection(bounds)
            layoutBars()
            needsDisplay = true
            return
        }
        guard mods.isEmpty || mods == .shift else { return }
        if let t = EditTool.inPlace.first(where: { $0.key.lowercased() == ch }) { model.tool = t; measureLine = nil; updateCursor(); return }
        if let n = Int(ch), n >= 1, n <= model.palette.count { model.color = model.palette[n - 1]; return }
        switch ch {
        case "p": run(.pin)
        case "o": run(.text)
        case "e": run(.editor)
        case "s": run(.scroll)
        default: break
        }
    }

    // MARK: Actions

    enum Action { case copy, save, saveAs, done, pin, text, editor, scroll, close }

    func run(_ a: Action) {
        commitText()
        guard let sel = selection else { return }
        if a == .close { owner?.finish(.cancel); return }
        if a == .scroll { owner?.finish(.scroll(shot, sel.offsetBy(dx: shot.screen.frame.minX, dy: shot.screen.frame.minY))); return }
        model.crop = pxRect(sel)
        guard let img = model.render() else { return }
        let cap = Capture.shared
        switch a {
        case .copy:
            owner?.finish(.finished)
            cap.deliver(img, scale: shot.scale, copy: true, save: prefs.save && prefs.saveOnCopy)
        case .save:
            owner?.finish(.finished)
            cap.deliver(img, scale: shot.scale, copy: false, save: true)
        case .saveAs:
            owner?.finish(.finished)
            DispatchQueue.main.async { cap.saveAs(img, scale: self.shot.scale) }
        case .done:
            owner?.finish(.finished)
            cap.deliver(img, scale: shot.scale, copy: prefs.enterAction != "save", save: prefs.enterAction != "copy")
        case .pin:
            owner?.finish(.finished)
            let g = sel.offsetBy(dx: shot.screen.frame.minX, dy: shot.screen.frame.minY)
            PinWindow.show(img, scale: shot.scale, near: g)
        case .text:
            owner?.finish(.finished)
            cap.recognize(img)
        case .editor:
            owner?.finish(.finished)
            EditorController.show(img, scale: shot.scale, savedURL: nil)
        default: break
        }
    }

    // MARK: Bars

    private func hideBars() {
        tools?.isHidden = true
        actions?.isHidden = true
    }

    private func layoutBars() {
        guard editing, let s = selection else { hideBars(); return }
        if tools == nil {
            let t = NSHostingView(rootView: InPlaceTools(model: model))
            let a = NSHostingView(rootView: InPlaceActions(model: model) { [weak self] act in self?.run(act) })
            addSubview(t); addSubview(a)
            tools = t; actions = a
        }
        guard let tools, let actions else { return }
        tools.isHidden = false
        actions.isHidden = false
        let ts = tools.fittingSize, asz = actions.fittingSize
        var tx = s.maxX + 8
        if tx + ts.width > bounds.width - 4 { tx = s.minX - ts.width - 8 }
        if tx < 4 { tx = s.maxX - ts.width - 8 }
        var ty = s.maxY - ts.height
        ty = min(max(ty, 4), bounds.height - ts.height - 4)
        tools.frame = CGRect(x: tx, y: ty, width: ts.width, height: ts.height)
        var ax = s.maxX - asz.width
        ax = min(max(ax, 4), bounds.width - asz.width - 4)
        var ay = s.minY - asz.height - 8
        if ay < 4 { ay = s.maxY + 8 }
        if ay + asz.height > bounds.height - 4 { ay = s.minY + 8 }
        actions.frame = CGRect(x: ax, y: ay, width: asz.width, height: asz.height)
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        guard owner != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor(Theme.shared.accent)
        ctx.interpolationQuality = .high
        ctx.draw(shot.image, in: bounds)
        if editing || !model.marks.isEmpty || draft != nil {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1 / shot.scale, y: -1 / shot.scale)
            for a in model.marks + (draft.map { [$0] } ?? []) { EditorModel.draw(a, image: shot.image, scale: shot.scale, in: ctx) }
            ctx.restoreGState()
        }
        let focus = selection ?? hovered.map { local($0.1) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let f = focus {
            ctx.addRect(bounds); ctx.addRect(f); ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(selection == nil ? 2 : 1)
            ctx.stroke(f.insetBy(dx: -0.5, dy: -0.5))
        } else {
            ctx.fill(bounds)
        }
        if let s = selection {
            if editing {
                ctx.setFillColor(accent.cgColor)
                for h in handles(s) { ctx.fill(CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7)) }
            }
            label("\(Int(s.width * shot.scale)) × \(Int(s.height * shot.scale))", at: CGPoint(x: s.minX, y: min(s.maxY + 6, bounds.height - 24)))
        }
        if let (p, q) = measureLine {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokeLineSegments(between: [p, q])
            ctx.setLineDash(phase: 0, lengths: [])
            let dx = abs(q.x - p.x) * shot.scale, dy = abs(q.y - p.y) * shot.scale
            label(String(format: "%.0f px   %.0f × %.0f", hypot(dx, dy), dx, dy), at: CGPoint(x: q.x + 8, y: q.y + 8))
        }
        guard bounds.contains(mouse), owner?.editing == nil || owner?.editing === self else { return }
        let resizing: Bool = { if case .resize = drag { return true }; return false }()
        if !editing || resizing {
            if selection == nil {
                ctx.setStrokeColor(accent.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeLineSegments(between: [CGPoint(x: 0, y: mouse.y + 0.5), CGPoint(x: bounds.width, y: mouse.y + 0.5), CGPoint(x: mouse.x + 0.5, y: 0), CGPoint(x: mouse.x + 0.5, y: bounds.height)])
            }
            if prefs.magnifier { drawLoupe(ctx, at: mouse, accent: accent) }
            if !editing && selection == nil { hint("DRAG AN AREA OR CLICK A WINDOW · SPACE FULL SCREEN · C COPY COLOR · ESC") }
        }
    }

    private func drawLoupe(_ ctx: CGContext, at m: CGPoint, accent: NSColor) {
        let cells = 15, zoom: CGFloat = 8
        let size = CGFloat(cells) * zoom
        var origin = CGPoint(x: m.x + 22, y: m.y - size - 40)
        if origin.x + size > bounds.width - 8 { origin.x = m.x - size - 22 }
        if origin.y < 8 { origin.y = m.y + 22 }
        let p = px(m)
        let src = CGRect(x: Int(p.x) - cells / 2, y: Int(p.y) - cells / 2, width: cells, height: cells)
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
        let hex = shot.color(at: CGPoint(x: m.x + shot.screen.frame.minX, y: m.y + shot.screen.frame.minY))?.hex ?? ""
        label("\(Int(p.x)), \(Int(p.y))  \(hex)", at: CGPoint(x: box.minX, y: box.minY - 22))
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

    private func hint(_ text: String) {
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

struct InPlaceTools: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(EditTool.inPlace, id: \.self) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 28)
                        .foregroundStyle(model.tool == t ? Color.black : Palette.bone)
                        .background(model.tool == t ? theme.accent : Color.clear)
                }.buttonStyle(.plain).help("\(t.title) (\(t.key))")
            }
            Rectangle().fill(Palette.rule).frame(width: 22, height: 1).padding(.vertical, 4)
            ForEach(Array(model.palette.enumerated()), id: \.offset) { i, c in
                Button { model.color = c } label: {
                    Rectangle().fill(Color(nsColor: c)).frame(width: 16, height: 16)
                        .overlay(Rectangle().stroke(model.color == c ? Palette.bone : Palette.rule, lineWidth: model.color == c ? 2 : 1))
                        .frame(width: 32, height: 22)
                }.buttonStyle(.plain).help("Color \(i + 1)")
            }
            Rectangle().fill(Palette.rule).frame(width: 22, height: 1).padding(.vertical, 4)
            ForEach([CGFloat(1), 2, 4], id: \.self) { w in
                Button { model.weight = w } label: {
                    Capsule().fill(model.weight == w ? theme.accent : Palette.ash).frame(width: 18, height: w + 1).frame(width: 32, height: 18)
                }.buttonStyle(.plain).help(w == 1 ? "Thin" : w == 2 ? "Medium" : "Thick")
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.94))
        .overlay(Rectangle().stroke(Palette.rule))
        .fixedSize()
    }
}

struct InPlaceActions: View {
    @ObservedObject var model: EditorModel
    let run: (OverlayView.Action) -> Void
    @ObservedObject var theme = Theme.shared

    var body: some View {
        HStack(spacing: 4) {
            icon("arrow.uturn.backward", "Undo (⌘Z)") { model.undo() }
            icon("arrow.uturn.forward", "Redo (⇧⌘Z)") { model.redoLast() }
            Rectangle().fill(Palette.rule).frame(width: 1, height: 18).padding(.horizontal, 4)
            icon("text.viewfinder", "Copy text (O)") { run(.text) }
            icon("arrow.down.doc", "Scrolling capture (S)") { run(.scroll) }
            icon("pin", "Pin on screen (P)") { run(.pin) }
            icon("macwindow", "Open in editor (E)") { run(.editor) }
            icon("square.and.arrow.down.on.square", "Save as…") { run(.saveAs) }
            Rectangle().fill(Palette.rule).frame(width: 1, height: 18).padding(.horizontal, 4)
            word("Save", "⌘S") { run(.save) }
            word("Copy", "⌘C") { run(.copy) }
            icon("xmark", "Close (Esc)") { run(.close) }
        }
        .padding(4)
        .background(Color.black.opacity(0.94))
        .overlay(Rectangle().stroke(Palette.rule))
        .fixedSize()
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.bone).frame(width: 30, height: 26) }
            .buttonStyle(.plain).help(help)
    }

    private func word(_ title: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1).lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(title == "Copy" ? Color.black : theme.accent)
                .background(title == "Copy" ? theme.accent : Color.clear)
                .overlay(Rectangle().stroke(theme.accent))
        }.buttonStyle(.plain).help("\(title) (\(key))")
    }
}
