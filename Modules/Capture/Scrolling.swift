import AppKit
import ScreenCaptureKit

final class ScrollCapture {
    private let rect: CGRect
    private let screen: NSScreen
    private let done: (CGImage?) -> Void
    private var stop = false
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var frames: [CGImage] = []
    private var footer: CGImage?
    private var footerHeight = 0
    private var slices: [CGImage] = []

    init(rect: CGRect, screen: NSScreen, done: @escaping (CGImage?) -> Void) {
        self.rect = rect
        self.screen = screen
        self.done = done
    }

    func start() {
        showPanel()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in if e.keyCode == 53 || e.keyCode == 36 { self?.stop = true } }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.stop = true }
        Task { @MainActor in await self.loop() }
    }

    private func showPanel() {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.ignoresMouseEvents = true
        let label = NSTextField(labelWithString: "SCROLLING CAPTURE · ESC OR CLICK TO FINISH")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = NSColor(Palette.bone)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        box.layer?.borderColor = NSColor(Theme.shared.accent).cgColor
        box.layer?.borderWidth = 1
        box.addSubview(label)
        let size = label.fittingSize
        label.frame = NSRect(x: 12, y: 6, width: size.width, height: size.height)
        p.contentView = box
        var y = rect.minY - size.height - 24
        if y < screen.frame.minY + 4 { y = rect.maxY + 8 }
        p.setFrame(NSRect(x: rect.midX - (size.width + 24) / 2, y: y, width: size.width + 24, height: size.height + 12), display: true)
        p.orderFrontRegardless()
        panel = p
        let border = NSPanel(contentRect: rect.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.level = .statusBar
        border.backgroundColor = .clear
        border.isOpaque = false
        border.ignoresMouseEvents = true
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor(Theme.shared.accent).cgColor
        v.layer?.borderWidth = 2
        border.contentView = v
        border.orderFrontRegardless()
        borderPanel = border
    }
    private var borderPanel: NSPanel?

    private func grab() async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let mine = content.applications.filter { $0.processID == getpid() }
        let cfg = SCStreamConfiguration()
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.sourceRect = local
        cfg.width = Int(rect.width * screen.backingScaleFactor)
        cfg.height = Int(rect.height * screen.backingScaleFactor)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), configuration: cfg)
    }

    @MainActor
    private func loop() async {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        let savedMouse = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(center)
        guard let first = await grab() else { finish(nil); return }
        frames = [first]
        slices = [first]
        var stalls = 0
        var total = first.height
        while !stop && frames.count < 60 && total < 40_000 {
            let step = Int32(-(rect.height * 0.55))
            for _ in 0..<4 {
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: step / 4, wheel2: 0, wheel3: 0)
                e?.location = center
                e?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let next = await grab(), let prev = frames.last else { break }
            let o = ScrollCapture.overlap(prev, next)
            if UserDefaults.standard.bool(forKey: "cap.debugScroll") {
                let dir = URL(fileURLWithPath: "/tmp/tt-scroll"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: next).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("f\(frames.count).png"))
                if frames.count == 1 { try? NSBitmapImageRep(cgImage: prev).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("f0.png")) }
                try? "\(frames.count) \(o)\n".appendLine(to: dir.appendingPathComponent("log.txt"))
            }
            if o.shift < 2 {
                stalls += 1
                if stalls >= 2 { break }
                continue
            }
            stalls = 0
            if footer == nil {
                footer = o.bottom > 0 ? next.cropping(to: CGRect(x: 0, y: next.height - o.bottom, width: next.width, height: o.bottom)) : nil
                footerHeight = o.bottom
                if o.bottom > 0, let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - o.bottom)) { slices[0] = trimmed; total -= o.bottom }
            }
            let cut = footerHeight
            if let slice = next.cropping(to: CGRect(x: 0, y: next.height - cut - o.shift, width: next.width, height: o.shift)) {
                slices.append(slice)
                total += o.shift
            }
            frames.append(next)
        }
        if let m = savedMouse { CGWarpMouseCursorPosition(m) }
        if let footer { slices.append(footer) }
        finish(stitch())
    }

    private func finish(_ img: CGImage?) {
        [keyMonitor, clickMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        panel?.orderOut(nil)
        borderPanel?.orderOut(nil)
        done(img)
    }

    private func stitch() -> CGImage? {
        guard let w = slices.first?.width else { return nil }
        let h = slices.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = h
        for s in slices {
            y -= s.height
            ctx.draw(s, in: CGRect(x: 0, y: y, width: s.width, height: s.height))
        }
        return ctx.makeImage()
    }

    static func rows(_ img: CGImage, columns: Int = 96) -> [[UInt8]] {
        let h = img.height
        guard let ctx = CGContext(data: nil, width: columns, height: h, bitsPerComponent: 8, bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: columns, height: h))
        guard let data = ctx.data else { return [] }
        let p = data.bindMemory(to: UInt8.self, capacity: columns * h)
        return (0..<h).map { r in Array(UnsafeBufferPointer(start: p + r * columns, count: columns)) }
    }

    static func rowDiff(_ x: [UInt8], _ y: [UInt8]) -> Double {
        var t = 0
        for c in 0..<min(x.count, y.count) { t += abs(Int(x[c]) - Int(y[c])) }
        return Double(t) / Double(max(x.count, 1))
    }

    /// Returns how many new rows scrolled in, plus the fixed header/footer heights that never move.
    static func overlap(_ prev: CGImage, _ next: CGImage) -> (shift: Int, top: Int, bottom: Int) {
        let a = rows(prev), b = rows(next)
        let h = min(a.count, b.count)
        guard h > 40 else { return (0, 0, 0) }
        var top = 0
        while top < h / 3, rowDiff(a[top], b[top]) < 1.5 { top += 1 }
        var bottom = 0
        while bottom < h / 3, rowDiff(a[h - 1 - bottom], b[h - 1 - bottom]) < 1.5 { bottom += 1 }
        if top >= h / 3 && bottom >= h / 3 { return (0, top, bottom) }
        let lo = top, hi = h - bottom
        let span = hi - lo
        guard span > 30 else { return (0, top, bottom) }
        func cost(_ sh: Int) -> Double {
            let n = span - sh
            guard n > 12 else { return .infinity }
            var total = 0.0, count = 0
            var r = 0
            while r < n {
                total += rowDiff(a[lo + r + sh], b[lo + r])
                count += 1
                r += 2
            }
            return total / Double(max(count, 1))
        }
        let still = cost(0)
        var best = 0, bestCost = Double.infinity
        for sh in stride(from: 2, to: span - 12, by: 3) {
            let c = cost(sh)
            if c < bestCost { bestCost = c; best = sh }
        }
        for sh in max(1, best - 3)...min(span - 13, best + 3) {
            let c = cost(sh)
            if c < bestCost { bestCost = c; best = sh }
        }
        guard bestCost < max(4, still * 0.45) else { return (0, top, bottom) }
        return (best, top, bottom)
    }
}

extension String {
    func appendLine(to url: URL) throws {
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data(using: .utf8)!); try h.close() } else { try write(to: url, atomically: true, encoding: .utf8) }
    }
}
