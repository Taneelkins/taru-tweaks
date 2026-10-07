import AppKit
import SwiftUI

struct DockPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var apps: Data
    var others: Data
}

final class DockPresets: ObservableObject {
    static let shared = DockPresets()
    @Published var presets: [DockPreset] = [] { didSet { save() } }
    @Published var active: UUID? { didSet { UserDefaults.standard.set(active?.uuidString, forKey: "dock.active") } }
    @Published var swipe = UserDefaults.standard.object(forKey: "dock.swipe") as? Bool ?? true { didSet { UserDefaults.standard.set(swipe, forKey: "dock.swipe") } }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DockPresets.json")
    }()
    private var switching = false
    private var overDock = false
    private var dockFrame = CGRect.zero
    private var travel: Double = 0
    private var fired = false
    private let hud = DockHUD()

    init() {
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([DockPreset].self, from: d) { presets = p }
        active = UserDefaults.standard.string(forKey: "dock.active").flatMap(UUID.init)
        if presets.isEmpty {
            let (apps, others) = Self.currentDock()
            let main = DockPreset(name: "Main", apps: apps, others: others)
            presets = [main]
            active = main.id
        }
        if active == nil || !presets.contains(where: { $0.id == active }) { active = presets.first?.id }
        refreshFrame()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshFrame() }
    }

    var activeName: String { presets.first { $0.id == active }?.name ?? "" }

    private func save() {
        if let d = try? JSONEncoder().encode(presets) { try? d.write(to: url, options: .atomic) }
    }

    static func currentDock() -> (Data, Data) {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        func read(_ key: String) -> Data {
            let v = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) ?? ([] as CFArray)
            return (try? PropertyListSerialization.data(fromPropertyList: v, format: .binary, options: 0)) ?? Data()
        }
        return (read("persistent-apps"), read("persistent-others"))
    }

    private static func apply(_ p: DockPreset) {
        func value(_ d: Data) -> CFPropertyList { ((try? PropertyListSerialization.propertyList(from: d, format: nil)) ?? []) as CFPropertyList }
        CFPreferencesSetAppValue("persistent-apps" as CFString, value(p.apps), "com.apple.dock" as CFString)
        CFPreferencesSetAppValue("persistent-others" as CFString, value(p.others), "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); k.arguments = ["Dock"]
        try? k.run()
    }

    func captureActive() {
        guard let i = presets.firstIndex(where: { $0.id == active }) else { return }
        let (apps, others) = Self.currentDock()
        if presets[i].apps != apps || presets[i].others != others { presets[i].apps = apps; presets[i].others = others }
    }

    func activate(_ id: UUID) {
        guard !switching, id != active, let target = presets.first(where: { $0.id == id }) else { return }
        switching = true
        captureActive()
        active = id
        Self.apply(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshFrame() }
        hud.show(name: target.name, index: presets.firstIndex(of: target) ?? 0, count: presets.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.switching = false }
    }

    func step(_ dir: Int) {
        guard presets.count > 1, let i = presets.firstIndex(where: { $0.id == active }) else { return }
        activate(presets[(i + dir + presets.count) % presets.count].id)
    }

    func addEmpty(_ name: String) {
        let empty = (try? PropertyListSerialization.data(fromPropertyList: [Any](), format: .binary, options: 0)) ?? Data()
        presets.append(DockPreset(name: name, apps: empty, others: empty))
    }

    func addFromCurrent(_ name: String) {
        let (apps, others) = Self.currentDock()
        presets.append(DockPreset(name: name, apps: apps, others: others))
    }

    func refreshFrame() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute as CFString, &kids)
        guard let list = (kids as? [AXUIElement])?.first else { return }
        var pos: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size)
        var p = CGPoint.zero, sz = CGSize.zero
        if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &sz) }
        dockFrame = CGRect(origin: p, size: sz)
    }

    private func dockShown(at point: CGPoint) -> Bool {
        guard dockFrame.insetBy(dx: -8, dy: -8).contains(point) else { return false }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { ($0[kCGWindowOwnerName as String] as? String) == "Dock" && ($0[kCGWindowLayer as String] as? Int) == 20 }
    }

    func scroll(_ e: CGEvent) -> Bool {
        guard swipe, presets.count > 1 else { return false }
        let phase = e.getIntegerValueField(.scrollWheelEventScrollPhase)
        if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return overDock }
        if phase == 1 { overDock = dockShown(at: e.location); travel = 0; fired = false }
        guard overDock, phase != 0 else { return false }
        let dx = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if abs(dy) > abs(dx) && travel == 0 { return true }
        travel += dx
        if !fired && abs(travel) > 50 {
            fired = true
            let dir = travel < 0 ? 1 : -1
            DispatchQueue.main.async { self.step(dir) }
        }
        return true
    }
}

final class DockHUD {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(name: String, index: Int, count: Int) {
        let view = NSHostingView(rootView: DockHUDView(name: name, index: index, count: count))
        let size = view.fittingSize
        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = view
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 130, width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        hide?.cancel()
        let work = DispatchWorkItem { [weak p] in NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p?.animator().alphaValue = 0 } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}

struct DockHUDView: View {
    let name: String
    let index: Int
    let count: Int
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(spacing: 8) {
            Text(name.uppercased()).font(.system(size: 15, weight: .heavy, design: .monospaced)).tracking(3).foregroundStyle(Palette.bone)
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { i in Rectangle().fill(i == index ? theme.accent : Palette.rule).frame(width: 18, height: 2) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Color.black.opacity(0.92))
        .overlay(Rectangle().stroke(Palette.rule))
    }
}

struct DockPresetsSettings: View {
    @ObservedObject var dock = DockPresets.shared
    @State var newName = ""
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Dock Presets", subtitle: "Swipe two fingers left or right on the Dock to switch. Each preset remembers the Dock exactly as you leave it, so drag apps on or off like normal.")
            SettingRow(title: "Swipe on the Dock to switch", detail: "Pointer over the Dock, then a two-finger swipe sideways.") { Switch(on: $dock.swipe) }
            SectionLabel(text: "Presets")
            ForEach(Array(dock.presets.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 10) {
                    Rectangle().fill(p.id == dock.active ? theme.accent : Color.clear).frame(width: 2, height: 22)
                    TextField("", text: Binding(get: { dock.presets.indices.contains(i) ? dock.presets[i].name : "" }, set: { if dock.presets.indices.contains(i) { dock.presets[i].name = $0 } }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.bone)
                    Spacer()
                    Button("↑") { dock.presets.swapAt(i, i - 1) }.buttonStyle(.plain).foregroundStyle(Palette.ash).disabled(i == 0)
                    Button("↓") { dock.presets.swapAt(i, i + 1) }.buttonStyle(.plain).foregroundStyle(Palette.ash).disabled(i == dock.presets.count - 1)
                    if p.id == dock.active {
                        Text("ACTIVE").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(theme.accent).frame(width: 70)
                    } else {
                        TweakButton(title: "Switch") { dock.activate(p.id) }
                        Button("DELETE") { dock.presets.removeAll { $0.id == p.id } }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
                    }
                }
                .padding(.vertical, 8)
                .overlay(Rectangle().fill(Palette.rule).frame(height: 1), alignment: .bottom)
            }
            HStack(spacing: 10) {
                TextField("New preset name, e.g. School", text: $newName).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.bone)
                    .padding(.horizontal, 8).padding(.vertical, 6).background(Color.black)
                TweakButton(title: "New empty") { add(empty: true) }
                TweakButton(title: "Copy current Dock") { add(empty: false) }
            }.padding(.top, 14)
            Text("An empty preset starts with only Finder and the Trash. Switch to it, then drag in the apps you want.")
                .font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 8)
        }
    }

    func add(empty: Bool) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        empty ? dock.addEmpty(name) : dock.addFromCurrent(name)
        newName = ""
    }
}
