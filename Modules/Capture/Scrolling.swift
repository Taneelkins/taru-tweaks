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
            let shift = ScrollCapture.overlapShift(prev, next)
            if shift < 2 {
                stalls += 1
                if stalls >= 2 { break }
                continue
            }
            stalls = 0
            if let slice = next.cropping(to: CGRect(x: 0, y: next.height - shift, width: next.width, height: shift)) {
                slices.append(slice)
                total += shift
            }
            frames.append(next)
        }
        if let m = savedMouse { CGWarpMouseCursorPosition(m) }
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

    static func overlapShift(_ prev: CGImage, _ next: CGImage) -> Int {
        let a = rows(prev), b = rows(next)
        let h = min(a.count, b.count)
        guard h > 20 else { return 0 }
        func cost(_ s: Int) -> Double {
            let n = h - s
            guard n > 10 else { return .infinity }
            var total = 0, count = 0
            var r = 0
            while r < n {
                let x = a[r + s], y = b[r]
                for c in stride(from: 0, to: x.count, by: 3) { total += abs(Int(x[c]) - Int(y[c])) }
                count += (x.count + 2) / 3
                r += 3
            }
            return Double(total) / Double(max(count, 1))
        }
        if cost(0) < 0.5 { return 0 }
        var best = 0, bestCost = Double.infinity
        for s in stride(from: 2, to: h - 10, by: 4) {
            let c = cost(s)
            if c < bestCost { bestCost = c; best = s }
        }
        var lo = max(1, best - 4), hi = min(h - 11, best + 4)
        if lo > hi { swap(&lo, &hi) }
        for s in lo...hi {
            let c = cost(s)
            if c < bestCost { bestCost = c; best = s }
        }
        return bestCost < 6 ? best : 0
    }
}
