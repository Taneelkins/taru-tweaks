import AppKit
import SwiftUI

final class TaruBarModel: ObservableObject {
    static let shared = TaruBarModel()
    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "bar.enabled"); TaruBar.shared.apply() } }
    @Published var showCPU: Bool { didSet { d.set(showCPU, forKey: "bar.cpu"); changed() } }
    @Published var showRAM: Bool { didSet { d.set(showRAM, forKey: "bar.ram"); changed() } }
    @Published var showMusic: Bool { didSet { d.set(showMusic, forKey: "bar.music"); changed() } }
    @Published var showWeather: Bool { didSet { d.set(showWeather, forKey: "bar.weather"); if showWeather { TaruBar.shared.fetchWeather() }; changed() } }
    @Published var tightSpacing: Bool { didSet { d.set(tightSpacing, forKey: "bar.tight"); TaruBar.shared.applySpacing() } }
    @Published var overlay: Bool { didSet { d.set(overlay, forKey: "bar.overlay"); changed(); TaruBar.shared.updateButton() } }
    @Published var city: String { didSet { d.set(city, forKey: "bar.city") } }
    @Published var latitude: Double { didSet { d.set(latitude, forKey: "bar.lat") } }
    @Published var longitude: Double { didSet { d.set(longitude, forKey: "bar.lon") } }
    @Published var fahrenheit: Bool { didSet { d.set(fahrenheit, forKey: "bar.f"); TaruBar.shared.fetchWeather() } }

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
        showCPU = d.object(forKey: "bar.cpu") as? Bool ?? (d.object(forKey: "bar.stats") as? Bool ?? true)
        showRAM = d.object(forKey: "bar.ram") as? Bool ?? (d.object(forKey: "bar.stats") as? Bool ?? true)
        showMusic = d.object(forKey: "bar.music") as? Bool ?? true
        showWeather = d.object(forKey: "bar.weather") as? Bool ?? true
        tightSpacing = d.object(forKey: "bar.tight") as? Bool ?? true
        overlay = d.object(forKey: "bar.overlay") as? Bool ?? false
        city = d.string(forKey: "bar.city") ?? "Toledo, Ohio"
        latitude = d.object(forKey: "bar.lat") as? Double ?? 41.6528
        longitude = d.object(forKey: "bar.lon") as? Double ?? -83.5379
        fahrenheit = d.object(forKey: "bar.f") as? Bool ?? true
    }

    private func changed() { DispatchQueue.main.async { TaruBar.shared.place() } }

    func minimal() {
        showCPU = false; showRAM = false; showMusic = false; showWeather = false
    }

    func everything() {
        showCPU = true; showRAM = true; showMusic = true; showWeather = true
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
    private var host: BarHost?
    private var timers: [Timer] = []
    private var button: NSStatusItem?
    private var lastTicks: [(UInt64, UInt64)] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.place() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.place() }
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.place() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.place() }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in self?.music(n.userInfo) }
        dc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in self?.music(n.userInfo) }
        apply()
    }

    func apply() {
        guard started else { return }
        if UserDefaults.standard.bool(forKey: "bar.restoreMB") {
            UserDefaults.standard.set(false, forKey: "bar.restoreMB")
            MenuBarManager.shared.enabled = true
        }
        timers.forEach { $0.invalidate() }
        timers = []
        guard model.enabled else {
            panel?.orderOut(nil)
            if let b = button { NSStatusBar.system.removeStatusItem(b); button = nil }
            return
        }
        if button == nil {
            let ud = UserDefaults.standard
            if ud.object(forKey: "NSStatusItem Preferred Position tt.bar.toggle") == nil { ud.set(330.0, forKey: "NSStatusItem Preferred Position tt.bar.toggle") }
            let b = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            b.autosaveName = "tt.bar.toggle"
            b.button?.target = self
            b.button?.action = #selector(buttonClicked)
            b.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.button?.toolTip = "Show or hide Taru Bar readouts · right-click to choose them"
            button = b
            updateButton()
        }
        if panel == nil {
            let p = TaruBarPanel()
            let h = BarHost(rootView: TaruBarView(model: model))
            p.contentView = h
            panel = p
            host = h
        }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample(); self?.place() },
            Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.fetchWeather() }
        ]
        sample()
        fetchWeather()
        applySpacing()
        place()
    }

    func updateButton() {
        guard let b = button?.button else { return }
        let img = NSImage(systemSymbolName: model.overlay ? "chart.bar.fill" : "chart.bar", accessibilityDescription: "Taru Bar")
        img?.isTemplate = true
        b.image = img
    }

    @objc private func buttonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            button?.menu = readoutMenu()
            button?.button?.performClick(nil)
            button?.menu = nil
            return
        }
        model.overlay.toggle()
    }

    func readoutMenu() -> NSMenu {
        let m = NSMenu()
        let header = NSMenuItem(title: "Taru Bar — from Taru Tweaks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        for (title, key) in [("CPU", \TaruBarModel.showCPU), ("Memory", \.showRAM), ("Now playing", \.showMusic), ("Weather", \.showWeather)] as [(String, ReferenceWritableKeyPath<TaruBarModel, Bool>)] {
            let it = ClosureItem(title) { [weak self] in guard let self else { return }; self.model[keyPath: key].toggle() }
            it.state = model[keyPath: key] ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(ClosureItem("Hide all readouts") { [weak self] in self?.model.minimal() })
        m.addItem(ClosureItem("Show all readouts") { [weak self] in self?.model.everything() })
        m.addItem(.separator())
        m.addItem(ClosureItem("Taru Bar settings…") { TaruBar.openSettings() })
        return m
    }

    private var popup: DockPopup?

    func showPopup<V: View>(_ content: V) {
        if let p = popup { p.dismiss(); popup = nil; return }
        let p = DockPopup(content)
        p.onClose = { [weak self, weak p] in if self?.popup === p { self?.popup = nil } }
        popup = p
        let mouse = NSEvent.mouseLocation
        p.show(below: NSRect(x: mouse.x, y: (panel?.frame.minY ?? mouse.y) , width: 0, height: 0), within: screen)
    }

    func topProcesses(_ done: @escaping ([(String, Double)]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Ao", "pcpu=,comm=", "-r"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let rows = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").prefix(6).compactMap { line -> (String, Double)? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " "), let v = Double(t[..<sp]) else { return nil }
                let name = URL(fileURLWithPath: String(t[sp...]).trimmingCharacters(in: .whitespaces)).lastPathComponent
                return (name, v)
            }
            DispatchQueue.main.async { done(Array(rows.prefix(5))) }
        }
    }

    func hourly(_ done: @escaping (_ high: Double?, _ low: Double?, _ hours: [(String, Double, Int)]) -> Void) {
        let unit = model.fahrenheit ? "fahrenheit" : "celsius"
        guard let url = URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&hourly=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&forecast_days=2&timezone=auto&temperature_unit=%@", model.latitude, model.longitude, unit)) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let daily = json["daily"] as? [String: Any]
            let hi = (daily?["temperature_2m_max"] as? [Double])?.first, lo = (daily?["temperature_2m_min"] as? [Double])?.first
            var hours: [(String, Double, Int)] = []
            if let h = json["hourly"] as? [String: Any], let times = h["time"] as? [String], let temps = h["temperature_2m"] as? [Double], let codes = h["weather_code"] as? [Int] {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                let out = DateFormatter(); out.dateFormat = "ha"
                let now = Date()
                for (i, t) in times.enumerated() {
                    guard let d = f.date(from: t), d > now.addingTimeInterval(-3600), hours.count < 6 else { continue }
                    hours.append((out.string(from: d).lowercased(), temps[i], codes[i]))
                }
            }
            DispatchQueue.main.async { done(hi, lo, hours) }
        }.resume()
    }

    func applySpacing() {
        let d = UserDefaults.standard
        let want = model.tightSpacing
        if d.bool(forKey: "bar.tightApplied") == want { return }
        d.set(want, forKey: "bar.tightApplied")
        let args: [[String]] = want
            ? [["-currentHost", "write", "-globalDomain", "NSStatusItemSpacing", "-int", "6"], ["-currentHost", "write", "-globalDomain", "NSStatusItemSelectionPadding", "-int", "6"]]
            : [["-currentHost", "delete", "-globalDomain", "NSStatusItemSpacing"], ["-currentHost", "delete", "-globalDomain", "NSStatusItemSelectionPadding"]]
        for a in args {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p.arguments = a
            try? p.run()
            p.waitUntilExit()
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

    private func leftmostStatusItem(after start: CGFloat) -> CGFloat {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var minX = screen.frame.maxX
        for w in info where (w[kCGWindowLayer as String] as? Int) == 25 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.minY < 40, r.height < 60, r.width < 600, r.minX >= start - 2 else { continue }
            minX = min(minX, r.minX)
        }
        return minX
    }

    func place() {
        guard model.enabled, let panel, let host else { return }
        let anything = model.showCPU || model.showRAM || (model.showMusic && !model.track.isEmpty) || (model.showWeather && !model.weatherText.isEmpty)
        guard anything else { panel.orderOut(nil); return }
        let f = screen.frame
        let barHeight = max(f.maxY - screen.visibleFrame.maxY, screen.auxiliaryTopRightArea?.height ?? 0, 24)
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? f.minX
        let start = max(notchRight + 6, f.minX + appMenusMaxX() + 12)
        let gapEnd = leftmostStatusItem(after: start) - 6
        let want = host.fittingSize.width
        var end = gapEnd
        if model.overlay, gapEnd - start < want, let bf = button?.button?.window?.frame, bf.minX > start { end = bf.minX - 2 }
        let room = end - start
        guard want > 1, room > 60, model.overlay || gapEnd - start >= want else { panel.orderOut(nil); return }
        var x0 = end - min(want, room)
        if model.overlay && end != gapEnd {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in info where (w[kCGWindowLayer as String] as? Int) == 25 {
                guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.minY < 40, r.width < 600 else { continue }
                if r.minX < x0 && r.maxX > x0 { x0 = max(start, r.minX - 2) }
            }
        }
        panel.setFrame(NSRect(x: x0, y: f.maxY - barHeight, width: end - x0, height: barHeight), display: true)
        panel.orderFrontRegardless()
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

    private func music(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = (info["Player State"] as? String) ?? ""
        model.playing = state == "Playing"
        if state == "Stopped" { model.track = ""; model.artist = "" } else {
            model.track = (info["Name"] as? String) ?? model.track
            model.artist = (info["Artist"] as? String) ?? model.artist
        }
        place()
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
                self.place()
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

    static func openSettings() {
        DistributedNotificationCenter.default().postNotificationName(.init("com.taru.tweaks.open"), object: "bar", userInfo: nil, deliverImmediately: true)
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

    var body: some View {
        HStack(spacing: 0) {
            if model.showCPU {
                segment {
                    Text("CPU").foregroundStyle(Palette.ash).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    Spark(values: model.cpu, color: theme.accent).frame(width: 30, height: 13)
                    Text("\(Int((model.cpu.last ?? 0) * 100))%").frame(minWidth: 30, alignment: .trailing)
                } action: { TaruBar.shared.showPopup(StatsPopup(model: model)) }
            }
            if model.showRAM {
                segment {
                    Text("RAM").foregroundStyle(Palette.ash).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    Text("\(Int(model.memory * 100))%")
                } action: { TaruBar.shared.showPopup(StatsPopup(model: model)) }
            }
            if model.showMusic && !model.track.isEmpty {
                segment {
                    Image(systemName: model.playing ? "waveform" : "pause.fill").foregroundStyle(theme.accent).font(.system(size: 10, weight: .bold))
                    Text(model.track).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                } action: { TaruBar.shared.showPopup(MusicPopup(model: model)) }
            }
            if model.showWeather && !model.weatherText.isEmpty {
                segment { Text(model.weatherText) } action: { TaruBar.shared.showPopup(WeatherPopup(model: model)) }
            }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(Palette.bone)
        .fixedSize()
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(model.overlay ? Color.black : Color.clear)
    }

    private var clockText: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d · h:mm"
        return f.string(from: model.now).uppercased()
    }

    private func segment<C: View>(@ViewBuilder _ content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            PageTitle(title: "Taru Bar", subtitle: "Live readouts in the gap between the notch and your menu bar icons. Your icons stay real: menus open right under them and right-click works. Right-click the readouts to switch them on or off.")
            SettingRow(title: "Use Taru Bar") { Switch(on: $model.enabled) }
            HStack(spacing: 10) {
                TweakButton(title: "Hide all") { model.minimal() }
                TweakButton(title: "Show all") { model.everything() }
            }.padding(.vertical, 10)
            SectionLabel(text: "Readouts")
            SettingRow(title: "CPU", detail: "Live graph and percent. Click opens Task Manager.") { Switch(on: $model.showCPU) }
            SettingRow(title: "Memory") { Switch(on: $model.showRAM) }
            SettingRow(title: "Now playing", detail: "Spotify and Music. Click to play or pause.") { Switch(on: $model.showMusic) }
            SettingRow(title: "Weather", detail: model.city) { Switch(on: $model.showWeather) }
            SectionLabel(text: "Weather")
            SettingRow(title: "City") {
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
            SectionLabel(text: "Icons")
            SettingRow(title: "Tighter icon spacing", detail: "Fits more menu bar icons next to the notch. Takes effect after you log out and back in.") { Switch(on: $model.tightSpacing) }
            Text("Hide icons you don't need with the ‹ arrow; set which ones in Menu Bar.").font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 8)
        }
        .onAppear { cityField = model.city }
    }
}

final class BarHost: NSHostingView<TaruBarView> {
    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(TaruBar.shared.readoutMenu(), with: event, for: self)
    }
}

struct PopupCard<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash)
            content
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(Color.black.opacity(0.96))
    }
}

struct StatsPopup: View {
    @ObservedObject var model: TaruBarModel
    @ObservedObject var theme = Theme.shared
    @State private var top: [(String, Double)] = []
    var body: some View {
        PopupCard(title: "CPU · Memory") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((model.cpu.last ?? 0) * 100))%").font(.system(size: 30, weight: .heavy, design: .monospaced)).foregroundStyle(theme.accent)
                Text("CPU").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
                Spacer()
                Text("\(Int(model.memory * 100))%").font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(Palette.bone)
                Text("RAM").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
            }
            Spark(values: model.cpu, color: theme.accent).frame(height: 34)
            VStack(spacing: 6) {
                ForEach(Array(top.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).font(.system(size: 12)).foregroundStyle(Palette.bone).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", row.1)).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ash)
                    }
                }
            }
            TweakButton(title: "Open Task Manager") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Task Manager.app")) }
        }
        .onAppear { TaruBar.shared.topProcesses { top = $0 } }
    }
}

struct MusicPopup: View {
    @ObservedObject var model: TaruBarModel
    @ObservedObject var theme = Theme.shared
    var body: some View {
        PopupCard(title: "Now playing") {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.track).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.bone).lineLimit(2)
                Text(model.artist).font(.system(size: 12)).foregroundStyle(Palette.ash).lineLimit(1)
            }
            HStack(spacing: 18) {
                Button { TaruBar.shared.mediaKey(18) } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
                Button { TaruBar.shared.mediaKey(16) } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 20)) }.buttonStyle(.plain)
                Button { TaruBar.shared.mediaKey(17) } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
            }
            .font(.system(size: 15))
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity)
            TweakButton(title: "Open Spotify") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Spotify.app")) }
        }
    }
}

struct WeatherPopup: View {
    @ObservedObject var model: TaruBarModel
    @ObservedObject var theme = Theme.shared
    @State private var high: Double?
    @State private var low: Double?
    @State private var hours: [(String, Double, Int)] = []
    var body: some View {
        PopupCard(title: model.city) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.temperature.map { "\(Int($0.rounded()))°" } ?? "–").font(.system(size: 30, weight: .heavy, design: .monospaced)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.weatherText.split(separator: " ", maxSplits: 1).dropFirst().joined()).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Palette.bone)
                    if let high, let low { Text("H \(Int(high.rounded()))°  L \(Int(low.rounded()))°").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash) }
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(hours.enumerated()), id: \.offset) { _, h in
                    VStack(spacing: 4) {
                        Text(h.0).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
                        Text("\(Int(h.1.rounded()))°").font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.bone)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            TweakButton(title: "Open Weather") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app")) }
        }
        .onAppear { TaruBar.shared.hourly { hi, lo, hrs in high = hi; low = lo; hours = hrs } }
    }
}
