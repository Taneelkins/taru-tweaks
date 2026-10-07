import AppKit
import SwiftUI

struct DockItem: Codable, Hashable {
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
    var isApp: Bool { path.hasSuffix(".app") }
    var isFolder: Bool {
        var dir: ObjCBool = false
        return !isApp && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
    var name: String { FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "") }
}

struct DockPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [DockItem]
}

private struct LegacyPreset: Codable {
    var id: UUID
    var name: String
    var apps: Data
    var others: Data
}

final class DockPresets: ObservableObject {
    static let shared = DockPresets()
    @Published var presets: [DockPreset] = [] { didSet { if presets != oldValue { save() } } }
    @Published var active: UUID? { didSet { UserDefaults.standard.set(active?.uuidString, forKey: "dock.active") } }
    @Published var enabled = UserDefaults.standard.object(forKey: "dock.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(enabled, forKey: "dock.enabled") } }
    @Published var iconSize = UserDefaults.standard.object(forKey: "dock.iconSize") as? Double ?? 48 { didSet { UserDefaults.standard.set(iconSize, forKey: "dock.iconSize") } }
    @Published var autohide = UserDefaults.standard.object(forKey: "dock.autohide") as? Bool ?? true { didSet { UserDefaults.standard.set(autohide, forKey: "dock.autohide") } }
    @Published var showRunning = UserDefaults.standard.object(forKey: "dock.showRunning") as? Bool ?? true { didSet { UserDefaults.standard.set(showRunning, forKey: "dock.showRunning") } }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DockPresets.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url) {
            if let p = try? JSONDecoder().decode([DockPreset].self, from: d) {
                presets = p
            } else if let old = try? JSONDecoder().decode([LegacyPreset].self, from: d) {
                presets = old.map { DockPreset(id: $0.id, name: $0.name, items: Self.items(from: $0.apps) + Self.items(from: $0.others)) }
            }
        }
        active = UserDefaults.standard.string(forKey: "dock.active").flatMap(UUID.init)
        if presets.isEmpty { presets = [DockPreset(name: "Main", items: Self.macDockItems())] }
        if active == nil || !presets.contains(where: { $0.id == active }) { active = presets.first?.id }
    }

    var activeIndex: Int { presets.firstIndex { $0.id == active } ?? 0 }
    var activeName: String { presets.first { $0.id == active }?.name ?? "" }

    func select(_ i: Int) {
        guard presets.indices.contains(i), presets[i].id != active else { return }
        active = presets[i].id
    }

    private func save() {
        if let d = try? JSONEncoder().encode(presets) { try? d.write(to: url, options: .atomic) }
    }

    static func items(from blob: Data) -> [DockItem] {
        guard let tiles = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [[String: Any]] else { return [] }
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any], let s = file["_CFURLString"] as? String else { return nil }
            let u = s.hasPrefix("/") ? URL(fileURLWithPath: s) : (URL(string: s) ?? URL(fileURLWithPath: s))
            return u.isFileURL ? DockItem(path: u.path) : nil
        }
    }

    static func macDockItems() -> [DockItem] {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        func blob(_ key: String) -> Data {
            let v = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) ?? ([] as CFArray)
            return (try? PropertyListSerialization.data(fromPropertyList: v, format: .binary, options: 0)) ?? Data()
        }
        return items(from: blob("persistent-apps")) + items(from: blob("persistent-others"))
    }

    func addEmpty(_ name: String) { presets.append(DockPreset(name: name, items: [])) }
    func addCopy(_ name: String) { presets.append(DockPreset(name: name, items: presets[activeIndex].items)) }
}

struct DockPresetsSettings: View {
    @ObservedObject var dock = DockPresets.shared
    @State var newName = ""
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Taru Dock", subtitle: "Your own Dock with presets. Swipe two fingers sideways on it to slide between presets. Drag apps in from Finder to add them, drag an icon up and away to remove it, right-click for options.")
            SettingRow(title: "Use Taru Dock", detail: "Hides the macOS Dock. Turning this off brings it back.") { Switch(on: $dock.enabled) }
            SettingRow(title: "Icon size") { Seg(options: [("Small", 40.0), ("Medium", 48.0), ("Large", 56.0)], value: $dock.iconSize) }
            SettingRow(title: "Auto-hide", detail: "Slides up when the pointer touches the bottom edge.") { Switch(on: $dock.autohide) }
            SettingRow(title: "Show running apps", detail: "Open apps that aren't in the preset sit after the divider.") { Switch(on: $dock.showRunning) }
            SectionLabel(text: "Presets")
            ForEach(Array(dock.presets.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 10) {
                    Rectangle().fill(p.id == dock.active ? theme.accent : Color.clear).frame(width: 2, height: 22)
                    TextField("", text: Binding(get: { dock.presets.indices.contains(i) ? dock.presets[i].name : "" }, set: { if dock.presets.indices.contains(i) { dock.presets[i].name = $0 } }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.bone)
                    Text("\(p.items.count) items").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash)
                    Spacer()
                    Button("↑") { dock.presets.swapAt(i, i - 1) }.buttonStyle(.plain).foregroundStyle(Palette.ash).disabled(i == 0)
                    Button("↓") { dock.presets.swapAt(i, i + 1) }.buttonStyle(.plain).foregroundStyle(Palette.ash).disabled(i == dock.presets.count - 1)
                    if p.id == dock.active {
                        Text("ACTIVE").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(theme.accent).frame(width: 70)
                    } else {
                        TweakButton(title: "Switch") { dock.select(i) }
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
                TweakButton(title: "Copy active") { add(empty: false) }
            }.padding(.top, 14)
            Text("Right-click any app in the Dock → Also in Preset to add it to another preset without switching.")
                .font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 8)
        }
    }

    func add(empty: Bool) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        empty ? dock.addEmpty(name) : dock.addCopy(name)
        newName = ""
    }
}
