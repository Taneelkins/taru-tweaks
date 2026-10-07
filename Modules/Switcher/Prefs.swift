import Foundation
import Combine

enum Visibility: String, Codable, CaseIterable { case show, hide, end }
enum AppsFilter: String, Codable, CaseIterable { case all, active, others }
enum SpacesFilter: String, Codable, CaseIterable { case all, current }
enum ScreensFilter: String, Codable, CaseIterable { case all, mouse }
enum Ordering: String, Codable, CaseIterable { case recent, created, alphabetical, space }
enum Release: String, Codable, CaseIterable { case focus, stay }
enum Style: String, Codable, CaseIterable { case thumbs, icons, titles }
enum TileSize: String, Codable, CaseIterable { case small, medium, large, auto }
enum ShowOn: String, Codable, CaseIterable { case active, mouse, main }

struct Shortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var holdMask: UInt64 = 0x100000
    var key: Int64 = 48
    var apps: AppsFilter = .all
    var spaces: SpacesFilter = .all
    var screens: ScreensFilter = .all
    var minimized: Visibility = .end
    var hidden: Visibility = .end
    var fullscreen: Visibility = .show
    var windowless: Visibility = .hide
    var ordering: Ordering = .recent
    var release: Release = .focus
    var skipSameApp = true
    var appsOnly = false

    static let defaults: [Shortcut] = [
        Shortcut(),
        Shortcut(holdMask: 0x100000, key: 50, apps: .active, skipSameApp: false),
        Shortcut(holdMask: 0x80000, key: 48, minimized: .show, hidden: .show, windowless: .show, appsOnly: true)
    ]

    init(id: UUID = UUID(), enabled: Bool = true, holdMask: UInt64 = 0x100000, key: Int64 = 48, apps: AppsFilter = .all, spaces: SpacesFilter = .all, screens: ScreensFilter = .all,
         minimized: Visibility = .end, hidden: Visibility = .end, fullscreen: Visibility = .show, windowless: Visibility = .hide, ordering: Ordering = .recent, release: Release = .focus,
         skipSameApp: Bool = true, appsOnly: Bool = false) {
        self.id = id; self.enabled = enabled; self.holdMask = holdMask; self.key = key; self.apps = apps; self.spaces = spaces; self.screens = screens
        self.minimized = minimized; self.hidden = hidden; self.fullscreen = fullscreen; self.windowless = windowless; self.ordering = ordering; self.release = release
        self.skipSameApp = skipSameApp; self.appsOnly = appsOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Shortcut()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = v(.id, d.id); enabled = v(.enabled, d.enabled); holdMask = v(.holdMask, d.holdMask); key = v(.key, d.key); apps = v(.apps, d.apps)
        spaces = v(.spaces, d.spaces); screens = v(.screens, d.screens); minimized = v(.minimized, d.minimized); hidden = v(.hidden, d.hidden)
        fullscreen = v(.fullscreen, d.fullscreen); windowless = v(.windowless, d.windowless); ordering = v(.ordering, d.ordering); release = v(.release, d.release)
        skipSameApp = v(.skipSameApp, d.skipSameApp); appsOnly = v(.appsOnly, d.appsOnly)
    }
}

struct AppException: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var hide: String = "never"
    var ignoreShortcuts = false
}

final class SwitcherPrefs: ObservableObject {
    static let shared = SwitcherPrefs()
    private let d = UserDefaults.standard

    @Published var shortcuts: [Shortcut] { didSet { save("shortcuts", shortcuts) } }
    @Published var exceptions: [AppException] { didSet { save("exceptions", exceptions) } }
    @Published var style: Style { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var size: TileSize { didSet { d.set(size.rawValue, forKey: "size") } }
    @Published var maxRows: Int { didSet { d.set(maxRows, forKey: "maxRows") } }
    @Published var maxWidth: Double { didSet { d.set(maxWidth, forKey: "maxWidth") } }
    @Published var showOn: ShowOn { didSet { d.set(showOn.rawValue, forKey: "showOn") } }
    @Published var delay: Double { didSet { d.set(delay, forKey: "delay") } }
    @Published var previewWindow: Bool { didSet { d.set(previewWindow, forKey: "previewWindow") } }
    @Published var badges: Bool { didSet { d.set(badges, forKey: "badges") } }
    @Published var numberKeys: Bool { didSet { d.set(numberKeys, forKey: "numberKeys") } }
    @Published var arrowKeys: Bool { didSet { d.set(arrowKeys, forKey: "arrowKeys") } }
    @Published var vimKeys: Bool { didSet { d.set(vimKeys, forKey: "vimKeys") } }
    @Published var hoverSelects: Bool { didSet { d.set(hoverSelects, forKey: "hoverSelects") } }
    @Published var cursorFollows: Bool { didSet { d.set(cursorFollows, forKey: "cursorFollows") } }
    @Published var gesture: Int { didSet { d.set(gesture, forKey: "gesture") } }
    @Published var showDesktop: Bool { didSet { d.set(showDesktop, forKey: "showDesktop") } }
    @Published var desktopMask: UInt64 { didSet { d.set(desktopMask, forKey: "desktopMask") } }
    @Published var desktopKey: Int64 { didSet { d.set(desktopKey, forKey: "desktopKey") } }
    @Published var dockForceQuit: Bool { didSet { d.set(dockForceQuit, forKey: "dockForceQuit") } }
    @Published var groupByApp: Bool { didSet { d.set(groupByApp, forKey: "groupByApp") } }
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "switcherEnabled"); enabled ? SkyLight.moveNativeSwitcherToOption() : SkyLight.restoreNativeSwitcher() } }

    init() {
        var sc: [Shortcut] = SwitcherPrefs.load("shortcuts") ?? Shortcut.defaults
        if !d.bool(forKey: "migrated.appsShortcut"), !sc.contains(where: { $0.appsOnly }), sc.count < 5 { sc.append(Shortcut.defaults[2]) }
        d.set(true, forKey: "migrated.appsShortcut")
        shortcuts = sc
        exceptions = SwitcherPrefs.load("exceptions") ?? []
        style = Style(rawValue: d.string(forKey: "style") ?? "") ?? .thumbs
        size = TileSize(rawValue: d.string(forKey: "size") ?? "") ?? .auto
        maxRows = d.object(forKey: "maxRows") as? Int ?? 3
        maxWidth = d.object(forKey: "maxWidth") as? Double ?? 0.85
        showOn = ShowOn(rawValue: d.string(forKey: "showOn") ?? "") ?? .active
        delay = d.object(forKey: "delay") as? Double ?? 0.1
        previewWindow = d.object(forKey: "previewWindow") as? Bool ?? true
        badges = d.object(forKey: "badges") as? Bool ?? true
        numberKeys = d.object(forKey: "numberKeys") as? Bool ?? true
        arrowKeys = d.object(forKey: "arrowKeys") as? Bool ?? true
        vimKeys = d.object(forKey: "vimKeys") as? Bool ?? false
        hoverSelects = d.object(forKey: "hoverSelects") as? Bool ?? true
        cursorFollows = d.object(forKey: "cursorFollows") as? Bool ?? false
        gesture = d.object(forKey: "gesture") as? Int ?? 0
        showDesktop = d.object(forKey: "showDesktop") as? Bool ?? true
        desktopMask = (d.object(forKey: "desktopMask") as? NSNumber)?.uint64Value ?? 0x100000
        desktopKey = (d.object(forKey: "desktopKey") as? NSNumber)?.int64Value ?? 2
        dockForceQuit = d.object(forKey: "dockForceQuit") as? Bool ?? true
        groupByApp = d.object(forKey: "groupByApp") as? Bool ?? true
        enabled = d.object(forKey: "switcherEnabled") as? Bool ?? true
    }

    private func save<T: Encodable>(_ k: String, _ v: T) { d.set(try? JSONEncoder().encode(v), forKey: k) }
    private static func load<T: Decodable>(_ k: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: k) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func exception(for bundleID: String?) -> AppException? {
        guard let b = bundleID else { return nil }
        return exceptions.first { $0.bundleID == b }
    }
}

