import AppKit
import ApplicationServices
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct Win: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    var title: String
    let frame: CGRect
    var minimized = false
    var hidden = false
    var fullscreen = false
    var onCurrentSpace = true
    var spaceNumber: Int?
    var windowless = false
    static func == (a: Win, b: Win) -> Bool { a.id == b.id && a.pid == b.pid && a.title == b.title && a.minimized == b.minimized }
}

func ax<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

final class WindowEngine {
    static let shared = WindowEngine()
    private(set) var mru: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private let skipped: Set<String> = ["com.taru.arsenal", "com.taru.fuel", "com.taru.overdrive", "com.apple.dock", "com.apple.WindowManager", "tracesOf.Uebersicht", "theboringteam.boringnotch", "com.mrrockysl.muro", "com.jordanbaird.Ice", "eu.exelban.Stats", "com.raycast.macos", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight"]

    func start() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { observe(app) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.observe(app) } }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observers[app.processIdentifier] = nil }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.noteFocus(app.processIdentifier) }
        }
        if let f = NSWorkspace.shared.frontmostApplication { noteFocus(f.processIdentifier) }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, app.activationPolicy == .regular else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, ctx in
            guard let ctx else { return }
            let pid = pid_t(Int(bitPattern: ctx))
            DispatchQueue.main.async { WindowEngine.shared.noteFocus(pid) }
        }, &obs) == .success, let o = obs else { return }
        let el = AXUIElementCreateApplication(pid)
        let ctx = UnsafeMutableRawPointer(bitPattern: Int(pid))
        AXObserverAddNotification(o, el, kAXFocusedWindowChangedNotification as CFString, ctx)
        AXObserverAddNotification(o, el, kAXMainWindowChangedNotification as CFString, ctx)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observers[pid] = o
    }

    func noteFocus(_ pid: pid_t) {
        let el = appElement(pid)
        guard let w: AXUIElement = ax(el, kAXFocusedWindowAttribute) else { return }
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(w, &id)
        guard id != 0 else { return }
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 200 { mru.removeLast(mru.count - 200) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Thumbnails.shared.capture([id]) }
    }

    func appElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    func axWindows(_ pid: pid_t) -> [AXUIElement] { ax(appElement(pid), kAXWindowsAttribute) ?? [] }

    func axWindow(_ w: Win) -> AXUIElement? {
        axWindows(w.pid).first { var id: CGWindowID = 0; _ = _AXUIElementGetWindow($0, &id); return id == w.id }
    }

    func all() -> [Win] {
        let me = ProcessInfo.processInfo.processIdentifier
        let spaces = SkyLight.spaceIndex()
        var apps: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && a.processIdentifier != me && !skipped.contains(a.bundleIdentifier ?? "") {
            apps[a.processIdentifier] = a
        }
        var axInfo: [CGWindowID: (minimized: Bool, fullscreen: Bool, title: String, standard: Bool)] = [:]
        for (pid, _) in apps {
            for el in axWindows(pid) {
                var id: CGWindowID = 0; _ = _AXUIElementGetWindow(el, &id)
                guard id != 0 else { continue }
                let sub: String = ax(el, kAXSubroleAttribute) ?? ""
                axInfo[id] = (ax(el, kAXMinimizedAttribute) ?? false, ax(el, "AXFullScreen") ?? false, ax(el, kAXTitleAttribute) ?? "", sub == kAXStandardWindowSubrole as String || sub == "AXDialog")
            }
        }
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [Win] = []
        var withWindows = Set<pid_t>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, let app = apps[pid],
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard frame.width >= 100, frame.height >= 60 else { continue }
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let info = axInfo[id]
            let winSpaces = SkyLight.spaces(of: id)
            if let info {
                if !info.standard { continue }
            } else {
                guard !winSpaces.isEmpty, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
                if !onscreen && (w[kCGWindowName as String] as? String ?? "").isEmpty { continue }
            }
            let title = info?.title.isEmpty == false ? info!.title : (w[kCGWindowName as String] as? String ?? "")
            let current = winSpaces.isEmpty || winSpaces.contains { spaces.current.contains($0) }
            var win = Win(id: id, pid: pid, bundleID: app.bundleIdentifier, appName: app.localizedName ?? "", title: title, frame: frame)
            win.minimized = info?.minimized ?? false
            win.fullscreen = info?.fullscreen ?? false
            win.hidden = app.isHidden
            win.onCurrentSpace = current
            win.spaceNumber = winSpaces.first.flatMap { spaces.index[$0] }
            result.append(win)
            withWindows.insert(pid)
        }
        for (pid, app) in apps where !withWindows.contains(pid) {
            var w = Win(id: CGWindowID(UInt32.max - UInt32(pid)), pid: pid, bundleID: app.bundleIdentifier, appName: app.localizedName ?? "", title: app.localizedName ?? "", frame: .zero)
            w.windowless = true
            w.hidden = app.isHidden
            result.append(w)
        }
        return result
    }

    func list(for s: Shortcut) -> [Win] {
        let prefs = SwitcherPrefs.shared
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var wins = all().filter { w in
            if let e = prefs.exception(for: w.bundleID) {
                if e.hide == "always" { return false }
                if e.hide == "fullscreen" && w.fullscreen { return false }
            }
            switch s.apps { case .active: if w.pid != front { return false }; case .others: if w.pid == front { return false }; case .all: break }
            if s.spaces == .current && !w.onCurrentSpace && !w.minimized { return false }
            if s.screens == .mouse, let ms = mouseScreen, !w.windowless, !w.minimized {
                let flipped = CGRect(x: w.frame.minX, y: primaryHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height)
                if !ms.frame.intersects(flipped) { return false }
            }
            for (flag, vis) in [(w.minimized, s.minimized), (w.hidden, s.hidden), (w.fullscreen, s.fullscreen), (w.windowless, s.windowless)] where flag && vis == .hide { return false }
            return true
        }
        let rank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        switch s.ordering {
        case .recent: wins.sort { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        case .created: wins.sort { $0.id > $1.id }
        case .alphabetical: wins.sort { ($0.appName + $0.title).localizedCaseInsensitiveCompare($1.appName + $1.title) == .orderedAscending }
        case .space: wins.sort { ($0.spaceNumber ?? 0, rank[$0.id] ?? Int.max) < ($1.spaceNumber ?? 0, rank[$1.id] ?? Int.max) }
        }
        if s.ordering == .recent, let first = wins.first(where: { !$0.minimized && !$0.hidden && $0.pid == front }) {
            wins.removeAll { $0.id == first.id }
            wins.insert(first, at: 0)
        }
        func atEnd(_ w: Win) -> Bool {
            (w.minimized && s.minimized == .end) || (w.hidden && s.hidden == .end) || (w.fullscreen && s.fullscreen == .end) || (w.windowless && s.windowless == .end)
        }
        let head = wins.filter { !atEnd($0) }, tail = wins.filter(atEnd)
        wins = head + tail
        if s.skipSameApp, s.apps == .all, wins.count > 2, let f = wins.first {
            let same = wins.dropFirst().filter { $0.pid == f.pid }
            let rest = wins.dropFirst().filter { $0.pid != f.pid }
            wins = [f] + rest + same
        }
        return wins
    }

    func focus(_ w: Win) {
        guard let app = NSRunningApplication(processIdentifier: w.pid) else { return }
        if app.isHidden { app.unhide() }
        if w.windowless { app.activate(); return }
        let el = axWindow(w)
        if let el, w.minimized { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let raise = { [weak self] in
            guard let self, let e = el ?? self.axWindow(w) else { return }
            AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        }
        raise()
        if !w.onCurrentSpace || el == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: raise) }
        mru.removeAll { $0 == w.id }; mru.insert(w.id, at: 0)
        if SwitcherPrefs.shared.cursorFollows, !w.frame.isEmpty {
            CGWarpMouseCursorPosition(CGPoint(x: w.frame.midX, y: w.frame.midY))
        }
    }

    func close(_ w: Win) {
        guard let el = axWindow(w), let b: AXUIElement = ax(el, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
    }
    func minimize(_ w: Win) {
        guard let el = axWindow(w) else { return }
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, (!w.minimized) as CFBoolean)
    }
    func fullscreen(_ w: Win) {
        guard let el = axWindow(w) else { return }
        AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, (!w.fullscreen) as CFBoolean)
    }
    func hide(_ w: Win) { NSRunningApplication(processIdentifier: w.pid)?.hide() }
    func quit(_ w: Win) { NSRunningApplication(processIdentifier: w.pid)?.terminate() }
    func forceQuit(_ w: Win) { NSRunningApplication(processIdentifier: w.pid)?.forceTerminate() }

    private var desktopStash: [(pid_t, CGWindowID)] = []
    func snapshotVisible() {
        let ids = all().filter { $0.onCurrentSpace && !$0.minimized && !$0.hidden && !$0.windowless }.map(\.id)
        Thumbnails.shared.capture(ids)
    }

    func toggleShowDesktop() {
        if !desktopStash.isEmpty {
            for (pid, id) in desktopStash.reversed() {
                if let el = axWindows(pid).first(where: { var w: CGWindowID = 0; _ = _AXUIElementGetWindow($0, &w); return w == id }) {
                    AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }
            if let top = desktopStash.first, let app = NSRunningApplication(processIdentifier: top.0) { app.activate() }
            desktopStash = []
            return
        }
        let wins = all().filter { $0.onCurrentSpace && !$0.minimized && !$0.hidden && !$0.windowless && !$0.fullscreen }
        let rank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = wins.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        desktopStash = ordered.map { ($0.pid, $0.id) }
        Thumbnails.shared.capture(ordered.map(\.id))
        for w in ordered { if let el = axWindow(w) { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanTrue) } }
    }
}

final class Thumbnails {
    static let shared = Thumbnails()
    private(set) var cache: [CGWindowID: CGImage] = [:]
    var allowed: Bool { CGPreflightScreenCaptureAccess() }
    var count: Int { cache.count }
    var lastError = ""

    var onUpdate: (() -> Void)?

    func capture(_ ids: [CGWindowID]) {
        guard allowed, !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for sw in content.windows where ids.contains(sw.windowID) {
                if let img = await shot(sw) { await MainActor.run { self.cache[sw.windowID] = img; self.onUpdate?() } }
            }
        }
    }

    private func shot(_ sw: SCWindow) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        let scale = min(1, 640 / max(sw.frame.width, 1))
        cfg.width = max(2, Int(sw.frame.width * scale * 2)); cfg.height = max(2, Int(sw.frame.height * scale * 2))
        cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
    }

    func refresh(_ wins: [Win], done: @escaping () -> Void) {
        guard allowed else { return }
        Task {
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) } catch { await MainActor.run { self.lastError = "\(error)" }; return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for w in wins where !w.windowless && !w.minimized {
                    guard let sw = byID[w.id] else { continue }
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, 640 / max(sw.frame.width, 1))
                        cfg.width = max(2, Int(sw.frame.width * scale * 2))
                        cfg.height = max(2, Int(sw.frame.height * scale * 2))
                        cfg.showsCursor = false
                        cfg.ignoreShadowsSingleWindow = true
                        let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                        return (w.id, img)
                    }
                }
                for await (id, img) in group {
                    if let img { await MainActor.run { self.cache[id] = img; done() } }
                }
            }
        }
    }
}
