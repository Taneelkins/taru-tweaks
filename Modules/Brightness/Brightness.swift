import SwiftUI
import AppKit
import Metal
import QuartzCore

final class EDRView: NSView {
    let metal = CAMetalLayer()
    let device = MTLCreateSystemDefaultDevice()
    lazy var queue = device?.makeCommandQueue()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metal.device = device; metal.pixelFormat = .rgba16Float; metal.wantsExtendedDynamicRangeContent = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3); metal.isOpaque = false
        layer = metal
    }
    required init?(coder: NSCoder) { fatalError() }
    func draw(level: Double) {
        metal.drawableSize = CGSize(width: 2, height: 2)
        guard let d = metal.nextDrawable(), let cb = queue?.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: level, green: level, blue: level, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding(); cb.present(d); cb.commit()
    }
}

final class Brightness: ObservableObject {
    static let shared = Brightness()
    @Published var on = false { didSet { if on != oldValue { on ? start() : stop() } } }
    @AppStorage("brightness.factor") var factor: Double = 1.6 { didSet { if on { apply() } } }
    @AppStorage("brightness.minBattery") var minBattery = 20
    @AppStorage("brightness.maxTemp") var maxTemp = 40
    @AppStorage("brightness.timer") var timerMinutes = 0
    @AppStorage("brightness.autoOnCharger") var autoOnCharger = false
    @AppStorage("brightness.allDisplays") var allDisplays = true
    @AppStorage("brightness.step") var step = 0.1
    @AppStorage("brightness.k.toggle.mask") var toggleMask: Int = 0x1C0000
    @AppStorage("brightness.k.toggle.key") var toggleKey: Int = 11
    @AppStorage("brightness.k.up.mask") var upMask: Int = 0x1C0000
    @AppStorage("brightness.k.up.key") var upKey: Int = 24
    @AppStorage("brightness.k.down.mask") var downMask: Int = 0x1C0000
    @AppStorage("brightness.k.down.key") var downKey: Int = 27
    @Published var note = ""
    @Published var offAt: Date?

    private var windows: [CGDirectDisplayID: (NSWindow, EDRView)] = [:]
    private var watchTimer: Timer?
    private var wasPlugged = false

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in if self?.on == true { self?.place(); self?.apply() } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        registerKeys()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.background() }
        if UserDefaults.standard.bool(forKey: "brightness.wasOn") { DispatchQueue.main.async { self.on = true } }
    }

    func registerKeys() {
        HotKeys.shared.set(101, mask: UInt64(toggleMask), key: Int64(toggleKey)) { [weak self] in self?.on.toggle() }
        HotKeys.shared.set(102, mask: UInt64(upMask), key: Int64(upKey)) { [weak self] in guard let self else { return }; self.factor = min(2, self.factor + self.step); if !self.on { self.on = true } }
        HotKeys.shared.set(103, mask: UInt64(downMask), key: Int64(downKey)) { [weak self] in guard let self else { return }; self.factor = max(1.05, self.factor - self.step) }
    }

    var screens: [NSScreen] {
        let xdr = NSScreen.screens.filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
        return allDisplays ? xdr : Array(xdr.prefix(1))
    }
    var supported: Bool { !NSScreen.screens.filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }.isEmpty }
    var nits: Int { on ? Int((500 * factor).rounded()) : 500 }

    func place() {
        for s in screens {
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let r = NSRect(x: s.frame.minX, y: s.frame.minY, width: 1, height: 1)
            if windows[id] == nil {
                let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver; w.ignoresMouseEvents = true; w.hasShadow = false
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                let v = EDRView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)); w.contentView = v
                windows[id] = (w, v)
            }
            windows[id]?.0.setFrame(r, display: true)
            windows[id]?.0.orderFrontRegardless()
        }
    }

    func start() {
        guard supported else { note = "No XDR display found"; on = false; return }
        UserDefaults.standard.set(true, forKey: "brightness.wasOn")
        note = ""
        offAt = timerMinutes > 0 ? Date().addingTimeInterval(Double(timerMinutes) * 60) : nil
        place(); apply()
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.watch() }
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: "brightness.wasOn")
        watchTimer?.invalidate(); watchTimer = nil
        for (_, w) in windows { w.0.orderOut(nil) }
        CGDisplayRestoreColorSyncSettings()
        offAt = nil
    }

    func apply() {
        CGDisplayRestoreColorSyncSettings()
        for (id, w) in windows {
            let head = Double(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
            w.1.draw(level: min(factor, head))
            var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
            var n: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n) == .success else { continue }
            let f = Float(factor)
            for i in 0..<Int(n) { r[i] *= f; g[i] *= f; b[i] *= f }
            CGSetDisplayTransferByTable(id, n, r, g, b)
        }
    }

    func watch() {
        let bat = BatteryModel.shared.battery
        if !bat.plugged && bat.percent < minBattery { note = "Turned off: battery under \(minBattery)%"; on = false; return }
        if bat.temperature >= Double(maxTemp) { note = "Turned off: battery at \(Int(bat.temperature)) °C"; on = false; return }
        if let t = offAt, Date() >= t { note = "Turned off by the timer"; on = false; return }
        for (_, w) in windows { w.1.draw(level: factor) }
    }

    func background() {
        let plugged = BatteryModel.shared.battery.plugged
        if autoOnCharger && plugged && !wasPlugged && !on { on = true }
        wasPlugged = plugged
    }
}

struct BrightnessMenu: View {
    @ObservedObject var b = Brightness.shared
    @ObservedObject var theme = Theme.shared
    let openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("XDR BOOST").font(.system(size: 16, weight: .heavy, design: .monospaced)).tracking(2).foregroundStyle(theme.accent)
                Spacer()
                Toggle("", isOn: $b.on).toggleStyle(.switch).labelsHidden()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(b.nits)").font(.system(size: 42, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                Text("nits").font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ash)
            }
            Slider(value: $b.factor, in: 1.05...2.0)
            Text(b.note.isEmpty ? (b.offAt.map { "Turns off at \($0.formatted(date: .omitted, time: .shortened))" } ?? "\(modifierString(UInt64(b.toggleMask)))\(keyString(Int64(b.toggleKey))) toggles") : b.note)
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
            TweakButton(title: "Settings", action: openSettings)
        }
        .padding(16).frame(width: 280).background(Palette.pit).tint(theme.accent)
    }
}

struct BrightnessSettings: View {
    @ObservedObject var b = Brightness.shared
    func key(_ m: Binding<Int>, _ k: Binding<Int>) -> some View {
        KeyRecorder(mask: Binding(get: { UInt64(m.wrappedValue) }, set: { m.wrappedValue = Int($0); b.registerKeys() }),
                    key: Binding(get: { Int64(k.wrappedValue) }, set: { k.wrappedValue = Int($0); b.registerKeys() }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "XDR Boost", subtitle: "Unlocks your Liquid Retina XDR's extra brightness everywhere, up to 1000 nits full screen. Uses more battery and heat.")
            SettingRow(title: "Boost", detail: b.supported ? "\(b.nits) nits" : "No XDR display connected") { Switch(on: $b.on) }
            SettingRow(title: "Level") { Slider(value: $b.factor, in: 1.05...2.0).frame(width: 240) }
            SettingRow(title: "Step for brighter / dimmer", detail: "\(Int(b.step * 500)) nits") { Slider(value: $b.step, in: 0.05...0.3, step: 0.05).frame(width: 160) }
            SectionLabel(text: "Shortcuts")
            SettingRow(title: "Toggle") { key($b.toggleMask, $b.toggleKey) }
            SettingRow(title: "Brighter") { key($b.upMask, $b.upKey) }
            SettingRow(title: "Dimmer") { key($b.downMask, $b.downKey) }
            SectionLabel(text: "Automation")
            SettingRow(title: "Turn off below battery", detail: "\(b.minBattery)% when unplugged") { Stepper("", value: $b.minBattery, in: 5...80, step: 5).labelsHidden() }
            SettingRow(title: "Turn off above battery temperature", detail: "\(b.maxTemp) °C") { Stepper("", value: $b.maxTemp, in: 32...50).labelsHidden() }
            SettingRow(title: "Auto-off timer", detail: b.timerMinutes == 0 ? "Never" : "\(b.timerMinutes) minutes after turning on") { Stepper("", value: $b.timerMinutes, in: 0...480, step: 15).labelsHidden() }
            SettingRow(title: "Turn on when the charger is connected") { Switch(on: $b.autoOnCharger) }
            SettingRow(title: "All XDR displays", detail: "Includes an external Pro Display XDR") { Switch(on: $b.allDisplays) }
            SettingRow(title: "Show in the menu bar") { Switch(on: MenuItems.shared.binding(\.brightness, "brightness.menu")) }
        }
    }
}
