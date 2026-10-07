import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision

enum CaptureAction: String, CaseIterable, Identifiable {
    case area, full, text, scroll
    var id: String { rawValue }
    var hotKeyID: UInt32 { [.area: 501, .full: 502, .text: 503, .scroll: 504][self]! }
    var title: String { [.area: "Area or window", .full: "Full screen", .text: "Copy text from area", .scroll: "Scrolling capture"][self]! }
    var defaultMask: UInt64 { self == .text ? 0x140000 : 0x120000 }
    var defaultKey: Int64 { [.area: 19, .full: 18, .text: 17, .scroll: 25][self]! }
}

struct DisplayShot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    let scale: CGFloat

    func crop(_ rect: CGRect) -> CGImage? {
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let px = CGRect(x: local.minX * scale, y: (screen.frame.height - local.maxY) * scale, width: local.width * scale, height: local.height * scale).integral
        return image.cropping(to: px)
    }

    func color(at p: CGPoint) -> NSColor? {
        let local = CGPoint(x: (p.x - screen.frame.minX) * scale, y: (screen.frame.height - (p.y - screen.frame.minY)) * scale)
        guard let px = image.cropping(to: CGRect(x: Int(local.x), y: Int(local.y), width: 1, height: 1)) else { return nil }
        return NSBitmapImageRep(cgImage: px).colorAt(x: 0, y: 0)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}

extension NSColor {
    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

final class CapturePrefs: ObservableObject {
    static let shared = CapturePrefs()
    private let d = UserDefaults.standard
    @Published var openEditor: Bool { didSet { d.set(openEditor, forKey: "cap.editor") } }
    @Published var copy: Bool { didSet { d.set(copy, forKey: "cap.copy") } }
    @Published var save: Bool { didSet { d.set(save, forKey: "cap.save") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "cap.sound") } }
    @Published var folder: String { didSet { d.set(folder, forKey: "cap.folder") } }

    init() {
        openEditor = d.object(forKey: "cap.editor") as? Bool ?? true
        copy = d.object(forKey: "cap.copy") as? Bool ?? true
        save = d.object(forKey: "cap.save") as? Bool ?? true
        sound = d.object(forKey: "cap.sound") as? Bool ?? true
        let system = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        folder = d.string(forKey: "cap.folder") ?? system ?? (NSHomeDirectory() + "/Pictures/Screenshots")
    }

    func mask(_ a: CaptureAction) -> UInt64 { (d.object(forKey: "cap.\(a.rawValue).mask") as? NSNumber)?.uint64Value ?? a.defaultMask }
    func key(_ a: CaptureAction) -> Int64 { (d.object(forKey: "cap.\(a.rawValue).key") as? NSNumber)?.int64Value ?? a.defaultKey }
    func setKey(_ a: CaptureAction, mask: UInt64, key: Int64) {
        d.set(mask, forKey: "cap.\(a.rawValue).mask")
        d.set(key, forKey: "cap.\(a.rawValue).key")
        objectWillChange.send()
        Capture.shared.registerKeys()
    }
}

final class Capture {
    static let shared = Capture()
    let prefs = CapturePrefs.shared
    private var overlay: SelectionOverlay?
    private var content: SCShareableContent?
    private var previousApp: NSRunningApplication?
    var scrolling: ScrollCapture?
    let toast = CaptureToast()

    func registerKeys() {
        for a in CaptureAction.allCases {
            HotKeys.shared.set(a.hotKeyID, mask: prefs.mask(a), key: prefs.key(a)) { Capture.shared.run(a) }
        }
    }

    func run(_ action: CaptureAction) {
        guard overlay == nil, scrolling == nil else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            guard let shots = await self.grabDisplays(), !shots.isEmpty else {
                self.toast.show("Screen Recording permission is off for Taru Tweaks")
                return
            }
            if action == .full {
                let mouse = NSEvent.mouseLocation
                let shot = shots.first { NSMouseInRect(mouse, $0.screen.frame, false) } ?? shots[0]
                self.finish(shot.image, scale: shot.scale)
                return
            }
            let mode: SelectionOverlay.Mode = action == .text ? .text : action == .scroll ? .scroll : .area
            self.overlay = SelectionOverlay(shots: shots, mode: mode) { [weak self] result in self?.handle(result) }
        }
    }

    private func handle(_ result: SelectionOverlay.Result) {
        overlay = nil
        switch result {
        case .cancel:
            restoreFocus()
        case .full(let shot):
            restoreFocus()
            finish(shot.image, scale: shot.scale)
        case .color(let hex):
            restoreFocus()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            toast.show("Copied \(hex)", swatch: NSColor(hexString: hex))
        case .area(let shot, let rect, let mode):
            restoreFocus()
            switch mode {
            case .text:
                if let img = shot.crop(rect) { recognize(img) }
            case .scroll:
                scrolling = ScrollCapture(rect: rect, screen: shot.screen) { [weak self] img in
                    self?.scrolling = nil
                    if let img { self?.finish(img, scale: shot.scale) }
                }
                scrolling?.start()
            case .area:
                if let img = shot.crop(rect) { finish(img, scale: shot.scale) }
            }
        case .window(let id, let shot, let rect):
            restoreFocus()
            Task { @MainActor in
                let img = await self.captureWindow(id, scale: shot.scale) ?? shot.crop(rect)
                if let img { self.finish(img, scale: shot.scale) }
            }
        }
    }

    private func restoreFocus() {
        if let app = previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier { app.activate() }
    }

    func grabDisplays() async -> [DisplayShot]? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        self.content = content
        var out: [DisplayShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            cfg.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                out.append(DisplayShot(screen: screen, displayID: id, image: img, scale: screen.backingScaleFactor))
            }
        }
        return out
    }

    private func captureWindow(_ id: CGWindowID, scale: CGFloat) async -> CGImage? {
        guard let w = content?.windows.first(where: { $0.windowID == id }) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width * scale)
        cfg.height = Int(w.frame.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
    }

    func finish(_ image: CGImage, scale: CGFloat) {
        if prefs.sound { NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play() }
        let url = prefs.save ? write(image, scale: scale) : nil
        if prefs.copy { copy(image, scale: scale) }
        if prefs.openEditor {
            EditorController.show(image, scale: scale, savedURL: url)
        } else {
            toast.show(prefs.copy ? "Copied" + (url != nil ? " and saved" : "") : (url != nil ? "Saved" : "Captured"), thumbnail: NSImage(cgImage: image, size: .zero)) {
                EditorController.show(image, scale: scale, savedURL: url)
            }
        }
    }

    func copy(_ image: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    @discardableResult
    func write(_ image: CGImage, scale: CGFloat, to target: URL? = nil) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = URL(fileURLWithPath: prefs.folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = target ?? dir.appendingPathComponent("Screenshot \(f.string(from: Date())).png")
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    func recognize(_ image: CGImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let codes = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([text, codes])
            let payload = (codes.results ?? []).compactMap(\.payloadStringValue).first
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async {
                let result = payload ?? lines.joined(separator: "\n")
                guard !result.isEmpty else { self.toast.show("No text found"); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                if payload != nil {
                    self.toast.show("Copied code: \(result.prefix(60))")
                } else {
                    let words = result.split { $0.isWhitespace || $0.isNewline }.count
                    self.toast.show("Copied text · \(words) word\(words == 1 ? "" : "s")")
                }
            }
        }
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

final class CaptureToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var action: (() -> Void)?

    func show(_ text: String, thumbnail: NSImage? = nil, swatch: NSColor? = nil, onClick: (() -> Void)? = nil) {
        action = onClick
        let p = panel ?? ToastPanel()
        (p as? ToastPanel)?.onClick = { [weak self] in self?.action?(); self?.hide() }
        let root = NSHostingView(rootView: ToastView(text: text, thumbnail: thumbnail, swatch: swatch))
        p.contentView = root
        let size = root.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        p.setFrame(NSRect(x: vf.maxX - size.width - 18, y: vf.minY + 18, width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (thumbnail != nil ? 5 : 2.2), execute: w)
    }

    func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

final class ToastPanel: NSPanel {
    var onClick: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

struct ToastView: View {
    let text: String
    let thumbnail: NSImage?
    let swatch: NSColor?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 220, maxHeight: 140)
                    .overlay(Rectangle().stroke(Palette.rule))
            }
            HStack(spacing: 8) {
                if let swatch { Rectangle().fill(Color(nsColor: swatch)).frame(width: 14, height: 14).overlay(Rectangle().stroke(Palette.rule)) }
                Text(text.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(Palette.bone).lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.94))
        .overlay(Rectangle().stroke(Palette.rule))
        .fixedSize()
    }
}

struct CaptureSettings: View {
    @ObservedObject var prefs = CapturePrefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Screenshots", subtitle: "Freeze the screen, pick an area or click a window, then mark it up. Copy text out of anything, scroll long pages, pin shots on top.")
            SectionLabel(text: "Shortcuts")
            ForEach(CaptureAction.allCases) { a in
                SettingRow(title: a.title) {
                    KeyRecorder(mask: Binding(get: { prefs.mask(a) }, set: { prefs.setKey(a, mask: $0, key: prefs.key(a)) }),
                                key: Binding(get: { prefs.key(a) }, set: { prefs.setKey(a, mask: prefs.mask(a), key: $0) }))
                }
            }
            Text("While picking an area: drag to select, click a window to grab just it, Space for the whole screen, T copies text instead, C copies the color under the cursor, Esc cancels.")
                .font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 8)
            SectionLabel(text: "After a capture")
            SettingRow(title: "Open the editor") { Switch(on: $prefs.openEditor) }
            SettingRow(title: "Copy to clipboard") { Switch(on: $prefs.copy) }
            SettingRow(title: "Save to folder", detail: prefs.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                HStack(spacing: 10) {
                    TweakButton(title: "Change") { pickFolder() }
                    Switch(on: $prefs.save)
                }
            }
            SettingRow(title: "Shutter sound") { Switch(on: $prefs.sound) }
            SectionLabel(text: "Capture now")
            HStack(spacing: 10) {
                ForEach(CaptureAction.allCases) { a in TweakButton(title: a == .area ? "Area" : a == .full ? "Screen" : a == .text ? "Text" : "Scrolling") { Capture.shared.run(a) } }
            }
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url { prefs.folder = url.path }
    }
}
