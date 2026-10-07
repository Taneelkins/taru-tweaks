import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision

enum CaptureAction: String, CaseIterable, Identifiable {
    case area, full
    var id: String { rawValue }
    var hotKeyID: UInt32 { [.area: 501, .full: 502][self]! }
    var title: String { [.area: "Capture (area or window)", .full: "Full screen, straight to clipboard"][self]! }
    var defaultMask: UInt64 { 0x120000 }
    var defaultKey: Int64 { [.area: 19, .full: 18][self]! }
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
    @Published var saveOnCopy: Bool { didSet { d.set(saveOnCopy, forKey: "cap.saveOnCopy") } }
    @Published var enterAction: String { didSet { d.set(enterAction, forKey: "cap.enter") } }
    @Published var magnifier: Bool { didSet { d.set(magnifier, forKey: "cap.loupe") } }

    init() {
        openEditor = d.object(forKey: "cap.editor") as? Bool ?? false
        saveOnCopy = d.object(forKey: "cap.saveOnCopy") as? Bool ?? true
        enterAction = d.string(forKey: "cap.enter") ?? "both"
        magnifier = d.object(forKey: "cap.loupe") as? Bool ?? true
        copy = d.object(forKey: "cap.copy") as? Bool ?? true
        save = d.object(forKey: "cap.save") as? Bool ?? true
        sound = d.object(forKey: "cap.sound") as? Bool ?? false
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
        for retired: UInt32 in [503, 504] { HotKeys.shared.set(retired, mask: 0, key: 0, enabled: false) {} }
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
                self.deliver(shot.image, scale: shot.scale, copy: true, save: self.prefs.save)
                return
            }
            self.overlay = SelectionOverlay(shots: shots) { [weak self] result in self?.handle(result) }
        }
    }

    private func handle(_ result: SelectionOverlay.Result) {
        overlay = nil
        restoreFocus()
        switch result {
        case .cancel, .finished:
            break
        case .full(let shot):
            deliver(shot.image, scale: shot.scale, copy: true, save: prefs.save)
        case .color(let hex):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            toast.show("Copied \(hex)", swatch: NSColor(hexString: hex))
        case .scroll(let shot, let rect):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.scrolling = ScrollCapture(rect: rect, screen: shot.screen) { [weak self] img in
                    self?.scrolling = nil
                    if let img { EditorController.show(img, scale: shot.scale, savedURL: nil) }
                }
                self.scrolling?.start()
            }
        case .window(let id, let shot, let rect):
            Task { @MainActor in
                let img = await self.captureWindow(id, scale: shot.scale) ?? shot.crop(rect)
                if let img { self.deliver(img, scale: shot.scale, copy: true, save: self.prefs.save) }
            }
        }
    }

    func deliver(_ image: CGImage, scale: CGFloat, copy doCopy: Bool, save doSave: Bool) {
        if prefs.sound { NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play() }
        let url = doSave ? write(image, scale: scale) : nil
        if doCopy { copy(image, scale: scale) }
        if prefs.openEditor { EditorController.show(image, scale: scale, savedURL: url); return }
        let what = doCopy && url != nil ? "Copied and saved" : doCopy ? "Copied" : url != nil ? "Saved" : "Captured"
        toast.show(what, thumbnail: NSImage(cgImage: image, size: .zero)) { EditorController.show(image, scale: scale, savedURL: url) }
    }

    func saveAs(_ image: CGImage, scale: CGFloat) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        p.nameFieldStringValue = "Screenshot \(f.string(from: Date())).png"
        p.directoryURL = URL(fileURLWithPath: prefs.folder)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url, write(image, scale: scale, to: url) != nil { toast.show("Saved \(url.lastPathComponent)") }
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
            PageTitle(title: "Screenshots", subtitle: "Lightshot-style: drag an area (or click a window) on the frozen screen, then draw, resize and move it, and finish from the bar underneath. Copy, save, copy text, pin, scroll or open the editor, all after the drag.")
            SectionLabel(text: "Shortcuts")
            ForEach(CaptureAction.allCases) { a in
                SettingRow(title: a.title) {
                    KeyRecorder(mask: Binding(get: { prefs.mask(a) }, set: { prefs.setKey(a, mask: $0, key: prefs.key(a)) }),
                                key: Binding(get: { prefs.key(a) }, set: { prefs.setKey(a, mask: prefs.mask(a), key: $0) }))
                }
            }
            Text("After the drag: drag the handles to resize, drag inside with Move (V) to reposition, arrow keys nudge (⇧ for 10). Tools: D pen, A arrow, R box, L line, T text, H highlight, B blur, N steps, M measure, I color. 1–6 colors, ⌘Z undo, ⌘C copy, ⌘S save, O copy text, S scrolling capture, P pin, E editor, Return finish, Esc cancel.")
                .font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            SectionLabel(text: "Finishing")
            SettingRow(title: "Return does") { Seg(options: [("Copy + save", "both"), ("Copy", "copy"), ("Save", "save")], value: $prefs.enterAction) }
            SettingRow(title: "Copy also saves a file", detail: "Keeps every capture in the folder, even ones you only copy.") { Switch(on: $prefs.saveOnCopy) }
            SettingRow(title: "Save folder", detail: prefs.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                HStack(spacing: 10) {
                    TweakButton(title: "Change") { pickFolder() }
                    Switch(on: $prefs.save)
                }
            }
            SettingRow(title: "Open the big editor after copying", detail: "Off: a thumbnail shows in the corner; click it to edit.") { Switch(on: $prefs.openEditor) }
            SectionLabel(text: "Feel")
            SettingRow(title: "Magnifier", detail: "Pixel grid, coordinates and color while you aim.") { Switch(on: $prefs.magnifier) }
            SettingRow(title: "Shutter sound") { Switch(on: $prefs.sound) }
            SectionLabel(text: "Capture now")
            HStack(spacing: 10) {
                TweakButton(title: "Area") { Capture.shared.run(.area) }
                TweakButton(title: "Full screen") { Capture.shared.run(.full) }
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
