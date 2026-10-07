import AppKit
import ScreenCaptureKit
import SwiftUI

struct StatusIcon: Identifiable {
    let id: String
    let appName: String
    let label: String
    let element: AXUIElement
    let frame: CGRect
    var image: NSImage?
    var appIcon: NSImage?
}

final class TaruBarModel: ObservableObject {
    static let shared = TaruBarModel()
    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "bar.enabled"); TaruBar.shared.apply() } }
    @Published var collapsed: Bool { didSet { d.set(collapsed, forKey: "bar.collapsed") } }
    @Published var showStats: Bool { didSet { d.set(showStats, forKey: "bar.stats") } }
    @Published var showMusic: Bool { didSet { d.set(showMusic, forKey: "bar.music") } }
    @Published var showWeather: Bool { didSet { d.set(showWeather, forKey: "bar.weather"); if showWeather { TaruBar.shared.fetchWeather() } } }
    @Published var city: String { didSet { d.set(city, forKey: "bar.city") } }
    @Published var latitude: Double { didSet { d.set(latitude, forKey: "bar.lat") } }
    @Published var longitude: Double { didSet { d.set(longitude, forKey: "bar.lon") } }
    @Published var fahrenheit: Bool { didSet { d.set(fahrenheit, forKey: "bar.f"); TaruBar.shared.fetchWeather() } }

    @Published var icons: [StatusIcon] = []
    @Published var pinned: [StatusIcon] = []
    var clock: StatusIcon?
    @Published var cpu: [Double] = Array(repeating: 0, count: 14)
    @Published var memory: Double = 0
    @Published var track = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var temperature: Double?
    @Published var weatherCode = 0
    @Published var now = Date()

    init() {
        enabled = d.object(forKey: "bar.enabled") as? Bool ?? true
        collapsed = d.object(forKey: "bar.collapsed") as? Bool ?? false
        showStats = d.object(forKey: "bar.stats") as? Bool ?? true
        showMusic = d.object(forKey: "bar.music") as? Bool ?? true
        showWeather = d.object(forKey: "bar.weather") as? Bool ?? true
        city = d.string(forKey: "bar.city") ?? "Toledo, Ohio"
        latitude = d.object(forKey: "bar.lat") as? Double ?? 41.6528
        longitude = d.object(forKey: "bar.lon") as? Double ?? -83.5379
        fahrenheit = d.object(forKey: "bar.f") as? Bool ?? true
    }

    var weatherText: String {
        guard let t = temperature else { return "" }
        let words: String
        switch weatherCode {
        case 0: words = "CLEAR"
        case 1, 2: words = "PARTLY CLOUDY"
        case 3: words = "CLOUDY"
        case 45, 48: words = "FOG"
        case 51...57: words = "DRIZZLE"
        case 61...67, 80...82: words = "RAIN"
        case 71...77, 85, 86: words = "SNOW"
        case 95...99: words = "STORM"
        default: words = ""
        }
        return "\(Int(t.rounded()))° \(words)"
    }
}

final class TaruBar {
    static let shared = TaruBar()
    let model = TaruBarModel.shared
    private var panel: TaruBarPanel?
    private var timers: [Timer] = []
    private var lastTicks: [(UInt64, UInt64)] = []
    private var started = false
    private let me = Bundle.main.bundleIdentifier ?? ""

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.place() }
        }
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.scan() } }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.place() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.place() }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in self?.music(n.userInfo, nameKey: "Name") }
        dc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in self?.music(n.userInfo, nameKey: "Name") }
        apply()
    }

    func apply() {
        guard started else { return }
        if model.enabled {
            if MenuBarManager.shared.enabled { MenuBarManager.shared.enabled = false; UserDefaults.standard.set(true, forKey: "bar.restoreMB") }
            if panel == nil {
                let p = TaruBarPanel()
                p.contentView = NSHostingView(rootView: TaruBarView(model: model))
                panel = p
            }
            place()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.scan() }
            timers.forEach { $0.invalidate() }
            timers = [
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() },
                Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.model.now = Date(); self?.scan() },
                Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.fetchWeather() }
            ]
            sample()
            fetchWeather()
        } else {
            timers.forEach { $0.invalidate() }
            timers = []
            panel?.orderOut(nil)
            if UserDefaults.standard.bool(forKey: "bar.restoreMB") {
                UserDefaults.standard.set(false, forKey: "bar.restoreMB")
                MenuBarManager.shared.enabled = true
            }
        }
    }

    // MARK: Placement

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func appMenusMaxX() -> CGFloat {
        guard let front = NSWorkspace.shared.frontmostApplication else { return 0 }
        let el = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXMenuBarAttribute as CFString, &bar) == .success, let b = bar else { return 0 }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
        var maxX: CGFloat = 0
        for k in (kids as? [AXUIElement]) ?? [] {
            var p: CFTypeRef?, s: CFTypeRef?
            AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &p)
            AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &s)
            var pt = CGPoint.zero, sz = CGSize.zero
            if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
            if let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
            if pt.x < screen.frame.width { maxX = max(maxX, pt.x + sz.width) }
        }
        return maxX
    }

    func place() {
        guard model.enabled, let panel else { return }
        let f = screen.frame
        let barHeight = max(f.maxY - screen.visibleFrame.maxY, screen.auxiliaryTopRightArea?.height ?? 0, 24)
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? f.minX
        let start = max(notchRight + 4, f.minX + appMenusMaxX() + 10)
        panel.setFrame(NSRect(x: start, y: f.maxY - barHeight, width: f.maxX - start, height: barHeight), display: true)
        panel.orderFrontRegardless()
    }

    // MARK: Status icons

    func scan() {
        guard model.enabled else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && $0.bundleIdentifier != nil }
        DispatchQueue.global(qos: .utility).async { [self] in
            var found: [StatusIcon] = []
            var pins: [StatusIcon] = []
            var clock: StatusIcon?
            for app in apps {
                let bid = app.bundleIdentifier!
                let el = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(el, 0.25)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success, let b = bar else { continue }
                var kids: CFTypeRef?
                AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
                for (i, k) in ((kids as? [AXUIElement]) ?? []).enumerated() {
                    var p: CFTypeRef?, s: CFTypeRef?, dsc: CFTypeRef?, ttl: CFTypeRef?, ident: CFTypeRef?
                    AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &p)
                    AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &s)
                    AXUIElementCopyAttributeValue(k, kAXDescriptionAttribute as CFString, &dsc)
                    AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &ttl)
                    AXUIElementCopyAttributeValue(k, kAXIdentifierAttribute as CFString, &ident)
                    var pt = CGPoint.zero, sz = CGSize.zero
                    if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
                    if let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
                    guard sz.width > 0, sz.width < 400 else { continue }
                    let label = (dsc as? String) ?? (ttl as? String) ?? ""
                    let idText = (ident as? String) ?? ""
                    if bid == me { continue }
                    let lower = (label + " " + idText).lowercased()
                    let icon = StatusIcon(id: "\(bid)#\(i)#\(label)", appName: app.localizedName ?? bid, label: label.isEmpty ? (app.localizedName ?? bid) : label, element: k,
                                          frame: CGRect(origin: pt, size: sz), image: nil, appIcon: app.icon)
                    if bid.hasPrefix("com.apple.controlcenter") || bid == "com.apple.systemuiserver" {
                        if lower.contains("clock") { clock = icon; continue }
                        if lower.contains("battery") { continue }
                    }
                    if bid.hasPrefix("com.apple.controlcenter") && (lower.contains("control center") || lower.contains("controlcenter") || lower.contains("wi-fi") || lower.contains("wifi")) {
                        pins.append(icon)
                    } else {
                        found.append(icon)
                    }
                }
            }
            found.sort { $0.frame.minX < $1.frame.minX }
            pins.sort { $0.frame.minX < $1.frame.minX }
            Task { @MainActor in
                await self.captureIcons(found + pins)
                func withImage(_ i: StatusIcon) -> StatusIcon { var c = i; c.image = self.iconCache[self.cacheKey(i)]; return c }
                self.model.icons = found.map(withImage)
                self.model.pinned = pins.map(withImage)
                self.model.clock = clock
            }
        }
    }

    private var iconCache: [String: NSImage] = [:]
    private lazy var cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/baricons")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func cacheKey(_ i: StatusIcon) -> String {
        let parts = i.id.split(separator: "#")
        return parts.prefix(2).joined(separator: "#")
    }

    private func fileFor(_ key: String) -> URL {
        cacheDir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    private func captureIcons(_ icons: [StatusIcon]) async {
        for i in icons where iconCache[cacheKey(i)] == nil {
            if let img = NSImage(contentsOf: fileFor(cacheKey(i))) { iconCache[cacheKey(i)] = img }
        }
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let primaryHeight = screen.frame.height
        let wins = content.windows.filter { $0.windowLayer == 25 && $0.isOnScreen && $0.frame.minY < 40 }
        for i in icons {
            guard let w = wins.filter({ abs($0.frame.midX - i.frame.midX) <= 8 }).min(by: { abs($0.frame.midX - i.frame.midX) < abs($1.frame.midX - i.frame.midX) }) else { continue }
            _ = primaryHeight
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * screen.backingScaleFactor)
            cfg.height = Int(w.frame.height * screen.backingScaleFactor)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { continue }
            let img = NSImage(cgImage: cg, size: w.frame.size)
            iconCache[cacheKey(i)] = img
            if let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? png.write(to: fileFor(cacheKey(i))) }
        }
    }

    func press(_ icon: StatusIcon) {
        DispatchQueue.global(qos: .userInteractive).async {
            if AXUIElementPerformAction(icon.element, kAXPressAction as CFString) != .success {
                AXUIElementPerformAction(icon.element, "AXShowMenu" as CFString)
            }
        }
    }

    func openClock() {
        if let clock = model.clock { press(clock); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    // MARK: Stats

    private func sample() {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info {
            var ticks: [(UInt64, UInt64)] = []
            for i in 0..<Int(cpus) {
                let base = Int(CPU_STATE_MAX) * i
                let user = UInt64(info[base + Int(CPU_STATE_USER)]), sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
                let idle = UInt64(info[base + Int(CPU_STATE_IDLE)]), nice = UInt64(info[base + Int(CPU_STATE_NICE)])
                ticks.append((user + sys + nice, user + sys + nice + idle))
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
            if lastTicks.count == ticks.count {
                var busy: UInt64 = 0, total: UInt64 = 0
                for (a, b) in zip(ticks, lastTicks) { busy += a.0 &- b.0; total += a.1 &- b.1 }
                let v = total > 0 ? Double(busy) / Double(total) : 0
                model.cpu = Array((model.cpu + [v]).suffix(14))
            }
            lastTicks = ticks
        }
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) } }
        if r == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
            model.memory = used / Double(ProcessInfo.processInfo.physicalMemory)
        }
        model.now = Date()
    }

    private func music(_ info: [AnyHashable: Any]?, nameKey: String) {
        guard let info else { return }
        let state = (info["Player State"] as? String) ?? ""
        model.playing = state == "Playing"
        if state == "Stopped" { model.track = ""; model.artist = ""; return }
        model.track = (info[nameKey] as? String) ?? model.track
        model.artist = (info["Artist"] as? String) ?? model.artist
    }

    func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    func fetchWeather() {
        guard model.enabled, model.showWeather else { return }
        let unit = model.fahrenheit ? "fahrenheit" : "celsius"
        guard let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code&temperature_unit=%@", model.latitude, model.longitude, unit)) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cur = json["current"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.model.temperature = cur["temperature_2m"] as? Double
                self.model.weatherCode = cur["weather_code"] as? Int ?? 0
            }
        }.resume()
    }

    func geocode(_ name: String, done: @escaping (Bool) -> Void) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: name.components(separatedBy: ",").first ?? name), URLQueryItem(name: "count", value: "10")]
        guard let url = c.url else { done(false); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let results = json["results"] as? [[String: Any]], !results.isEmpty else {
                DispatchQueue.main.async { done(false) }; return
            }
            let hint = name.components(separatedBy: ",").dropFirst().joined().trimmingCharacters(in: .whitespaces).lowercased()
            let pick = results.first { r in hint.isEmpty || ((r["admin1"] as? String ?? "") + " " + (r["country"] as? String ?? "")).lowercased().contains(hint) } ?? results[0]
            DispatchQueue.main.async {
                self.model.latitude = pick["latitude"] as? Double ?? self.model.latitude
                self.model.longitude = pick["longitude"] as? Double ?? self.model.longitude
                self.model.city = [pick["name"] as? String, pick["admin1"] as? String].compactMap { $0 }.joined(separator: ", ")
                self.fetchWeather()
                done(true)
            }
        }.resume()
    }
}

final class TaruBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct TaruBarView: View {
    @ObservedObject var model: TaruBarModel
    @ObservedObject var theme = Theme.shared
    @State private var hover: String?

    private var mono: Font { .system(size: 11.5, weight: .semibold, design: .monospaced) }

    var body: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { model.collapsed.toggle() } } label: {
                Text(model.collapsed ? "›" : "‹").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent).frame(width: 22, height: 22)
            }.buttonStyle(.plain).help(model.collapsed ? "Show menu bar icons" : "Hide menu bar icons")
            if model.collapsed {
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) { ForEach(model.icons) { icon in iconButton(icon) } }
                            .frame(minWidth: geo.size.width, alignment: .trailing)
                    }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04), .init(color: .black, location: 0.97), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                }
                .frame(minWidth: 40)
                .transition(.opacity)
            }
            HStack(spacing: 2) { ForEach(model.pinned) { icon in iconButton(icon) } }.padding(.horizontal, 4)
            HStack(spacing: 0) {
                if model.showStats {
                    segment {
                        Text("CPU").foregroundStyle(Palette.ash).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        Spark(values: model.cpu, color: theme.accent).frame(width: 30, height: 13)
                        Text("\(Int((model.cpu.last ?? 0) * 100))%").frame(minWidth: 30, alignment: .trailing)
                    } action: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Task Manager.app")) }
                    segment {
                        Text("RAM").foregroundStyle(Palette.ash).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        Text("\(Int(model.memory * 100))%")
                    } action: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Task Manager.app")) }
                }
                if model.showMusic && !model.track.isEmpty {
                    segment {
                        Image(systemName: model.playing ? "waveform" : "pause.fill").foregroundStyle(theme.accent).font(.system(size: 10, weight: .bold))
                        Text(model.track).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                    } action: { TaruBar.shared.mediaKey(16) }
                    .help("\(model.track) · \(model.artist)\nClick: play/pause")
                }
                segment {
                    Image(systemName: BatteryModel.shared.battery.plugged ? "bolt.fill" : "battery.75percent").foregroundStyle(theme.accent).font(.system(size: 10, weight: .bold))
                    Text(batteryText)
                } action: { DistributedNotificationCenter.default().postNotificationName(.init("com.taru.tweaks.open"), object: "battery.display", userInfo: nil, deliverImmediately: true) }
                if model.showWeather && !model.weatherText.isEmpty {
                    segment { Text(model.weatherText) } action: { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app")) }
                        .help(model.city)
                }
                segment { Text(clockText).padding(.trailing, 16) } action: { TaruBar.shared.openClock() }
            }
            .font(mono)
            .foregroundStyle(Palette.bone)
            .fixedSize()
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            HStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0), Color.black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                Color.black
            }
        )
        .overlay(Rectangle().fill(theme.accent.opacity(0.35)).frame(height: 1), alignment: .bottom)
    }

    private var batteryText: String {
        let b = BatteryModel.shared.battery
        return "\(b.percent)%"
    }

    private var clockText: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d · h:mm"
        return f.string(from: model.now).uppercased()
    }

    @ViewBuilder
    private func iconButton(_ icon: StatusIcon) -> some View {
        Button { TaruBar.shared.press(icon) } label: {
            Group {
                if let img = icon.image {
                    Image(nsImage: img).interpolation(.high)
                } else if let app = icon.appIcon {
                    Image(nsImage: app).resizable().frame(width: 16, height: 16)
                }
            }
            .frame(minWidth: 22, minHeight: 22)
            .background(hover == icon.id ? Color.white.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(icon.label == icon.appName ? icon.appName : "\(icon.appName) · \(icon.label)")
        .onHover { hover = $0 ? icon.id : (hover == icon.id ? nil : hover) }
    }

    private func segment<C: View>(@ViewBuilder _ content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().fill(Palette.rule).frame(width: 1).padding(.vertical, 6), alignment: .leading)
    }
}

struct Spark: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    Rectangle().fill(color.opacity(0.85)).frame(height: max(1, g.size.height * CGFloat(min(max(v, 0), 1))))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
    }
}

struct TaruBarSettings: View {
    @ObservedObject var model = TaruBarModel.shared
    @State private var cityField = ""
    @State private var cityNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Taru Bar", subtitle: "Your own right side of the menu bar, past the notch. Every menu bar icon sits in a strip you can swipe sideways and collapse with ‹; click one to open its real menu. App menus on the left stay as they are.")
            SettingRow(title: "Use Taru Bar", detail: "Turning this off brings the normal icons back.") { Switch(on: $model.enabled) }
            SettingRow(title: "CPU and memory") { Switch(on: $model.showStats) }
            SettingRow(title: "Now playing", detail: "Spotify and Music. Click to play or pause.") { Switch(on: $model.showMusic) }
            SettingRow(title: "Weather", detail: model.city) { Switch(on: $model.showWeather) }
            SettingRow(title: "Weather city") {
                HStack(spacing: 8) {
                    TextField("City, region", text: $cityField).textFieldStyle(.plain).font(.system(size: 12.5)).padding(.horizontal, 8).padding(.vertical, 5).background(Color.black).frame(width: 180)
                    TweakButton(title: "Set") {
                        cityNote = "Looking up…"
                        TaruBar.shared.geocode(cityField) { ok in cityNote = ok ? "Set to \(model.city)" : "No match, try \"City, State\"" }
                    }
                }
            }
            if !cityNote.isEmpty { Text(cityNote).font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 4) }
            SettingRow(title: "Units") { Seg(options: [("°F", true), ("°C", false)], value: $model.fahrenheit) }
            Text("Weather comes from Open-Meteo, which only receives the city's coordinates.").font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 10)
        }
        .onAppear { cityField = model.city }
    }
}
