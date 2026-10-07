import AppKit
import SwiftUI

enum EditTool: String, CaseIterable {
    case arrow, rect, line, text, highlight, blur, step, crop, measure, picker
    var icon: String {
        [.arrow: "arrow.up.right", .rect: "rectangle", .line: "line.diagonal", .text: "textformat", .highlight: "highlighter",
         .blur: "square.grid.3x3.fill", .step: "1.circle", .crop: "crop", .measure: "ruler", .picker: "eyedropper"][self]!
    }
    var key: String { [.arrow: "A", .rect: "R", .line: "L", .text: "T", .highlight: "H", .blur: "B", .step: "N", .crop: "K", .measure: "M", .picker: "I"][self]! }
    var title: String { [.arrow: "Arrow", .rect: "Box", .line: "Line", .text: "Text", .highlight: "Highlight", .blur: "Blur", .step: "Step", .crop: "Crop", .measure: "Measure", .picker: "Color"][self]! }
}

enum Mark {
    case arrow(CGPoint, CGPoint), rect(CGRect), line(CGPoint, CGPoint), text(CGPoint, String), highlight(CGRect), blur(CGRect), step(CGPoint, Int)
}

struct Annotation {
    var mark: Mark
    var color: NSColor
    var width: CGFloat
}

final class EditorModel: ObservableObject {
    let image: CGImage
    let scale: CGFloat
    @Published var tool: EditTool = .arrow
    @Published var color: NSColor = NSColor(Theme.shared.accent)
    @Published var weight: CGFloat = 2
    @Published var marks: [Annotation] = []
    @Published var redo: [Annotation] = []
    @Published var crop: CGRect?
    @Published var info = ""
    var savedURL: URL?
    let palette: [NSColor] = [NSColor(Theme.shared.accent), .systemYellow, .systemGreen, .systemBlue, .white, .black]

    init(image: CGImage, scale: CGFloat, savedURL: URL?) {
        self.image = image
        self.scale = scale
        self.savedURL = savedURL
        info = "\(image.width) × \(image.height)"
    }

    var nextStep: Int { marks.reduce(0) { if case .step = $1.mark { return $0 + 1 }; return $0 } + 1 }

    func add(_ a: Annotation) { marks.append(a); redo = [] }
    func undo() { if let a = marks.popLast() { redo.append(a) } else if crop != nil { crop = nil } }
    func redoLast() { if let a = redo.popLast() { marks.append(a) } }

    func render() -> CGImage? {
        let area = (crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard area.width >= 1, area.height >= 1,
              let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        EditorModel.draw(image: image, marks: marks, scale: scale, in: ctx)
        return ctx.makeImage()
    }

    static func draw(image: CGImage, marks: [Annotation], scale: CGFloat, in ctx: CGContext) {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: full.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: full)
        ctx.restoreGState()
        for a in marks { draw(a, image: image, scale: scale, in: ctx) }
    }

    static func draw(_ a: Annotation, image: CGImage, scale: CGFloat, in ctx: CGContext) {
        let w = a.width * scale * 1.5
        ctx.saveGState()
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 3 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        switch a.mark {
        case .arrow(let p, let q):
            let angle = atan2(q.y - p.y, q.x - p.x)
            let head = max(14 * scale, w * 4)
            let base = CGPoint(x: q.x - cos(angle) * head * 0.8, y: q.y - sin(angle) * head * 0.8)
            ctx.strokeLineSegments(between: [p, base])
            ctx.move(to: q)
            ctx.addLine(to: CGPoint(x: q.x - cos(angle - 0.45) * head, y: q.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: q.x - cos(angle + 0.45) * head, y: q.y - sin(angle + 0.45) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rect(let r):
            ctx.stroke(r)
        case .line(let p, let q):
            ctx.strokeLineSegments(between: [p, q])
        case .text(let p, let s):
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let size = (12 + a.width * 4) * scale
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: a.color,
                                                        .strokeColor: (a.color == .black ? NSColor.white : NSColor.black).withAlphaComponent(0.8), .strokeWidth: -2.5]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: s, attributes: attrs).draw(at: p)
            NSGraphicsContext.restoreGraphicsState()
        case .highlight(let r):
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.withAlphaComponent(0.45).cgColor)
            ctx.fill(r)
        case .blur(let r):
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let block = max(8, 10 * scale)
            if let crop = image.cropping(to: r.integral),
               let small = CGContext(data: nil, width: max(1, Int(r.width / block)), height: max(1, Int(r.height / block)), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                small.interpolationQuality = .medium
                small.draw(crop, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
                if let tiny = small.makeImage() {
                    ctx.interpolationQuality = .none
                    ctx.translateBy(x: 0, y: r.maxY + r.minY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(tiny, in: r.integral)
                }
            }
        case .step(let p, let n):
            let radius = (11 + a.width * 2) * scale
            ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: radius * 1.1, weight: .heavy), .foregroundColor: a.color == .white || a.color == .systemYellow ? NSColor.black : NSColor.white]
            let s = NSAttributedString(string: "\(n)", attributes: attrs)
            let sz = s.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }
}

final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    private var start: CGPoint?
    private var draft: Annotation?
    private var dragRect: CGRect?
    private var measure: (CGPoint, CGPoint)?
    private var field: NSTextField?
    private var fieldPoint: CGPoint = .zero

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Palette.pit).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var fit: (k: CGFloat, origin: CGPoint) {
        let iw = CGFloat(model.image.width), ih = CGFloat(model.image.height)
        let k = min((bounds.width - 32) / iw, (bounds.height - 32) / ih, 1 / model.scale * 1)
        let k2 = max(k, 0.05)
        return (k2, CGPoint(x: (bounds.width - iw * k2) / 2, y: (bounds.height - ih * k2) / 2))
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let f = fit
        return CGPoint(x: (p.x - f.origin.x) / f.k, y: (p.y - f.origin.y) / f.k)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let f = fit
        return CGRect(x: f.origin.x + r.minX * f.k, y: f.origin.y + r.minY * f.k, width: r.width * f.k, height: r.height * f.k)
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = fit
        ctx.saveGState()
        ctx.translateBy(x: f.origin.x, y: f.origin.y)
        ctx.scaleBy(x: f.k, y: f.k)
        ctx.interpolationQuality = .high
        EditorModel.draw(image: model.image, marks: model.marks + (draft.map { [$0] } ?? []), scale: model.scale, in: ctx)
        ctx.restoreGState()
        let full = toView(CGRect(x: 0, y: 0, width: model.image.width, height: model.image.height))
        NSColor(Palette.rule).setStroke()
        NSBezierPath(rect: full.insetBy(dx: -0.5, dy: -0.5)).stroke()
        if let c = (model.tool == .crop ? dragRect : nil) ?? model.crop {
            let v = toView(c)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.addRect(full); ctx.addRect(v); ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor(Theme.shared.accent).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(v)
        }
        if let (p, q) = measure {
            let a = toView(CGRect(origin: p, size: .zero)).origin, b = toView(CGRect(origin: q, size: .zero)).origin
            ctx.setStrokeColor(NSColor(Theme.shared.accent).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokeLineSegments(between: [a, b])
            let dx = abs(q.x - p.x), dy = abs(q.y - p.y)
            tag(String(format: "%.0f px   %.0f × %.0f", hypot(dx, dy), dx, dy), at: CGPoint(x: b.x + 8, y: b.y + 8))
        }
    }

    private func tag(_ text: String, at p: CGPoint) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(Palette.bone)])
        let r = CGRect(x: p.x, y: p.y, width: s.size().width + 12, height: s.size().height + 6)
        NSColor.black.withAlphaComponent(0.9).setFill()
        r.fill()
        s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let p = toImage(convert(e.locationInWindow, from: nil))
        start = p
        switch model.tool {
        case .text: beginText(at: p)
        case .step: model.add(Annotation(mark: .step(p, model.nextStep), color: model.color, width: model.weight))
        case .picker: pickColor(at: p)
        default: break
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        var p = toImage(convert(e.locationInWindow, from: nil))
        if e.modifierFlags.contains(.shift), [.arrow, .line, .measure].contains(model.tool) {
            let dx = p.x - s.x, dy = p.y - s.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            p = CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        }
        let r = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        let c = model.color, w = model.weight
        switch model.tool {
        case .arrow: draft = Annotation(mark: .arrow(s, p), color: c, width: w)
        case .line: draft = Annotation(mark: .line(s, p), color: c, width: w)
        case .rect: draft = Annotation(mark: .rect(r), color: c, width: w)
        case .highlight: draft = Annotation(mark: .highlight(r), color: c == NSColor(Theme.shared.accent) ? .systemYellow : c, width: w)
        case .blur: draft = Annotation(mark: .blur(r), color: c, width: w)
        case .crop: dragRect = r.intersection(CGRect(x: 0, y: 0, width: model.image.width, height: model.image.height))
        case .measure: measure = (s, p)
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let d = draft { model.add(d) }
        if let r = dragRect, r.width > 4, r.height > 4 { model.crop = r; model.info = "\(Int(r.width)) × \(Int(r.height))" }
        draft = nil
        dragRect = nil
        start = nil
        needsDisplay = true
    }

    private func pickColor(at p: CGPoint) {
        guard let px = model.image.cropping(to: CGRect(x: Int(p.x), y: Int(p.y), width: 1, height: 1)), let c = NSBitmapImageRep(cgImage: px).colorAt(x: 0, y: 0) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.hex, forType: .string)
        model.info = "Copied \(c.hex)"
        Capture.shared.toast.show("Copied \(c.hex)", swatch: c)
    }

    private func beginText(at p: CGPoint) {
        let f = fit
        let size = (12 + model.weight * 4) * model.scale * f.k
        let t = NSTextField(frame: CGRect(x: f.origin.x + p.x * f.k, y: f.origin.y + p.y * f.k, width: 320, height: size + 10))
        t.font = .systemFont(ofSize: size, weight: .bold)
        t.textColor = model.color
        t.backgroundColor = NSColor.black.withAlphaComponent(0.4)
        t.isBordered = false
        t.focusRingType = .none
        t.placeholderString = "Type, then Return"
        t.delegate = self
        addSubview(t)
        window?.makeFirstResponder(t)
        field = t
        fieldPoint = p
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); window?.makeFirstResponder(self); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { field?.removeFromSuperview(); field = nil; window?.makeFirstResponder(self); return true }
        return false
    }

    func commitText() {
        guard let t = field else { return }
        field = nil
        let s = t.stringValue.trimmingCharacters(in: .whitespaces)
        t.removeFromSuperview()
        if !s.isEmpty { model.add(Annotation(mark: .text(fieldPoint, s), color: model.color, width: model.weight)) }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { window?.performClose(nil); return }
        if e.keyCode == 36 || e.keyCode == 76 { (window?.windowController as? EditorController)?.copyAndClose(); return }
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty, let ch = e.charactersIgnoringModifiers?.uppercased() {
            if let t = EditTool.allCases.first(where: { $0.key == ch }) { model.tool = t; measure = nil; needsDisplay = true; return }
            if let n = Int(ch), n >= 1, n <= model.palette.count { model.color = model.palette[n - 1]; return }
            if ch == "P" { (window?.windowController as? EditorController)?.pin(); return }
            if ch == "O" { (window?.windowController as? EditorController)?.ocr(); return }
        }
        super.keyDown(with: e)
    }
}

final class EditorController: NSWindowController, NSWindowDelegate {
    static var open: [EditorController] = []
    let model: EditorModel
    private var observer: Any?

    static func show(_ image: CGImage, scale: CGFloat, savedURL: URL?) {
        let c = EditorController(model: EditorModel(image: image, scale: scale, savedURL: savedURL))
        open.append(c)
        NSApp.activate(ignoringOtherApps: true)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    init(model: EditorModel) {
        self.model = model
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let pts = CGSize(width: CGFloat(model.image.width) / model.scale, height: CGFloat(model.image.height) / model.scale)
        let w = min(max(pts.width + 32, 640), vf.width * 0.86), h = min(max(pts.height + 32 + 52, 360), vf.height * 0.86)
        let win = NSWindow(contentRect: NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(Palette.pit)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 560, height: 320)
        super.init(window: win)
        win.delegate = self
        let canvas = CanvasView(model: model)
        let bar = NSHostingView(rootView: EditorBar(model: model, controller: self))
        let stack = NSView()
        stack.addSubview(bar)
        stack.addSubview(canvas)
        bar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: stack.topAnchor, constant: 28), bar.leadingAnchor.constraint(equalTo: stack.leadingAnchor), bar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor), canvas.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: stack.trailingAnchor), canvas.bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        ])
        win.contentView = stack
        win.makeFirstResponder(canvas)
        observer = model.objectWillChange.sink { [weak canvas] in DispatchQueue.main.async { canvas?.needsDisplay = true } }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        EditorController.open.removeAll { $0 === self }
    }

    func copyImage() {
        guard let img = model.render() else { return }
        Capture.shared.copy(img, scale: model.scale)
        model.info = "Copied"
    }

    func copyAndClose() { copyImage(); window?.close() }

    func save() {
        guard let img = model.render() else { return }
        if let url = Capture.shared.write(img, scale: model.scale, to: model.savedURL) {
            model.savedURL = url
            model.info = "Saved " + url.lastPathComponent
        }
    }

    func saveAs() {
        guard let img = model.render() else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = model.savedURL?.lastPathComponent ?? "Screenshot.png"
        p.directoryURL = URL(fileURLWithPath: CapturePrefs.shared.folder)
        if p.runModal() == .OK, let url = p.url, Capture.shared.write(img, scale: model.scale, to: url) != nil { model.savedURL = url; model.info = "Saved " + url.lastPathComponent }
    }

    func pin() {
        guard let img = model.render() else { return }
        PinWindow.show(img, scale: model.scale, near: window?.frame)
        window?.close()
    }

    func ocr() {
        guard let img = model.render() else { return }
        Capture.shared.recognize(img)
    }

    func reveal() {
        if model.savedURL == nil { save() }
        if let url = model.savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

struct EditorBar: View {
    @ObservedObject var model: EditorModel
    let controller: EditorController
    @ObservedObject var theme = Theme.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EditTool.allCases, id: \.self) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 26)
                        .foregroundStyle(model.tool == t ? Color.black : Palette.bone)
                        .background(model.tool == t ? theme.accent : Color.clear)
                }.buttonStyle(.plain).help("\(t.title) (\(t.key))")
            }
            Rectangle().fill(Palette.rule).frame(width: 1, height: 18).padding(.horizontal, 6)
            ForEach(Array(model.palette.enumerated()), id: \.offset) { i, c in
                Button { model.color = c } label: {
                    Rectangle().fill(Color(nsColor: c)).frame(width: 16, height: 16)
                        .overlay(Rectangle().stroke(model.color == c ? Palette.bone : Palette.rule, lineWidth: model.color == c ? 2 : 1))
                }.buttonStyle(.plain).help("Color \(i + 1)")
            }
            Seg(options: [("S", CGFloat(1)), ("M", CGFloat(2)), ("L", CGFloat(4))], value: $model.weight).padding(.leading, 6)
            Spacer()
            Text(model.info.uppercased()).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 26) }.buttonStyle(.plain).foregroundStyle(Palette.bone).keyboardShortcut("z", modifiers: .command).help("Undo")
            Button { model.redoLast() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 26) }.buttonStyle(.plain).foregroundStyle(Palette.bone).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
            Group {
                bar("Text", "O") { controller.ocr() }
                bar("Pin", "P") { controller.pin() }
                Button("") { controller.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).frame(width: 0).opacity(0)
                bar("Save", "⌘S") { controller.save() }.keyboardShortcut("s", modifiers: .command)
                bar("Copy", "⌘C") { controller.copyImage() }.keyboardShortcut("c", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.black)
        .overlay(Rectangle().fill(Palette.rule).frame(height: 1), alignment: .bottom)
    }

    private func bar(_ title: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(theme.accent).overlay(Rectangle().stroke(theme.accent))
        }.buttonStyle(.plain).help("\(title) (\(key))")
    }
}

final class PinWindow: NSPanel {
    static var pins: [PinWindow] = []
    private let image: CGImage
    private let scale: CGFloat

    static func show(_ image: CGImage, scale: CGFloat, near: NSRect?) {
        let p = PinWindow(image: image, scale: scale)
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let center = near.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.midY)
        p.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        pins.append(p)
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSImageView(image: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)))
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.borderColor = NSColor(Theme.shared.accent).withAlphaComponent(0.6).cgColor
        v.layer?.borderWidth = 1
        contentView = v
        aspectRatio = NSSize(width: image.width, height: image.height)
    }

    override var canBecomeKey: Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { close(); PinWindow.pins.removeAll { $0 === self }; return }
        super.mouseDown(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.option) {
            alphaValue = min(1, max(0.2, alphaValue + e.scrollingDeltaY * 0.01))
            return
        }
        let f = frame
        let k = 1 + e.scrollingDeltaY * 0.01
        let w = max(80, f.width * k), h = w * f.height / f.width
        setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { close(); PinWindow.pins.removeAll { $0 === self } } else { super.keyDown(with: e) }
    }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        m.addItem(ClosureItem("Copy") { [weak self] in guard let self else { return }; Capture.shared.copy(self.image, scale: self.scale) })
        m.addItem(ClosureItem("Edit") { [weak self] in guard let self else { return }; EditorController.show(self.image, scale: self.scale, savedURL: nil); self.close() })
        m.addItem(ClosureItem("Close") { [weak self] in self?.close() })
        NSMenu.popUpContextMenu(m, with: e, for: contentView!)
    }
}
