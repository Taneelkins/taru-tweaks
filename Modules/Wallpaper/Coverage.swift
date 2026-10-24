import AppKit
import CoreGraphics

// Tells the wallpaper extension when windows cover the desktop, so it stops decoding the video
// nobody can see. The extension is sandboxed and can't read the window list, so the app does it.
// Coverage math is Phosphene's OcclusionMonitor/OcclusionMath (MIT, see WallpaperExtension/LICENSE-Phosphene).
final class Coverage {
    static let shared = Coverage()

    // how much of the usable screen has to be covered before we call it "not looking at the desktop"
    static let threshold = 0.75

    private var occluded: Set<UInt32> = []
    private var fullscreen: Set<UInt32> = []
    private var pushed = false
    private var timer: Timer?

    private var prefsURL: URL { SystemWallpaper.container.appendingPathComponent("Data/Documents/phosphene-prefs.json") }

    func start() {
        guard timer == nil else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.check() }
        }
        // no notification for window moves, minimize or resize, so a slow poll catches those
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    // pauseHidden flipped, write it through even if the coverage didn't change
    func refresh() { pushed = false; check() }

    func check() {
        guard SystemWallpaper.ready else { return }
        let (o, f) = compute()
        guard !pushed || o != occluded || f != fullscreen else { return }
        occluded = o; fullscreen = f; pushed = true
        let all = Set(NSScreen.screens.compactMap(Self.displayID))
        let prefs: [String: Any] = [
            "pauseWhenOccluded": Wallpaper.shared.pauseHidden,
            "occludedDisplays": Array(o),
            "fullscreenDisplays": Wallpaper.shared.pauseHidden ? Array(f) : [],
            "desktopOccluded": !all.isEmpty && o == all,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: prefs) else { return }
        try? data.write(to: prefsURL, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("\(SystemWallpaper.extensionID).prefsChanged" as CFString), nil, nil, true)
    }

    private static func displayID(_ s: NSScreen) -> UInt32? { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

    private struct Win { let rect: CGRect; let layer: Int }

    private func compute() -> (Set<UInt32>, Set<UInt32>) {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else { return ([], []) }
        // popup menus and up are system chrome; only regular apps count (the Dock and Notification Center
        // own screen-sized transparent windows that would otherwise mark the desktop covered forever)
        let chrome = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var regular: [pid_t: Bool] = [:]
        let wins: [Win] = list.compactMap { w in
            guard let layer = w[kCGWindowLayer] as? Int, layer >= 0, layer < chrome,
                  let pid = w[kCGWindowOwnerPID] as? pid_t,
                  let b = w[kCGWindowBounds] as? [String: CGFloat], let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"], wd > 0, h > 0
            else { return nil }
            if regular[pid] == nil { regular[pid] = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular }
            return regular[pid] == true ? Win(rect: CGRect(x: x, y: y, width: wd, height: h), layer: layer) : nil
        }
        var occluded = Set<UInt32>(), fullscreen = Set<UInt32>()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            guard let id = Self.displayID(screen) else { continue }
            let v = screen.visibleFrame, f = screen.frame
            guard v.width > 0, v.height > 0 else { continue }
            // NSScreen is bottom-left origin, the window list is top-left
            let visible = CGRect(x: v.minX, y: mainHeight - v.minY - v.height, width: v.width, height: v.height)
            let full = CGRect(x: f.minX, y: mainHeight - f.minY - f.height, width: f.width, height: f.height)
            if hasFullscreenApp(full: full, visible: visible, wins) { fullscreen.insert(id) }
            if covered(visible, by: wins) >= Self.threshold { occluded.insert(id) }
        }
        return (occluded, fullscreen)
    }

    // one window owning the whole display: a native fullscreen Space, or a borderless game parked above the menu bar
    private func hasFullscreenApp(full: CGRect, visible: CGRect, _ wins: [Win]) -> Bool {
        wins.contains { w in
            let r = w.layer == 0 ? full : visible
            let o = w.rect.intersection(r)
            return o.width * o.height >= r.width * r.height * (w.layer == 0 ? 0.99 : 0.95)
        }
    }

    // rasterize to an 8pt grid so overlapping windows don't count twice
    private func covered(_ screen: CGRect, by wins: [Win]) -> Double {
        let cell: CGFloat = 8
        let cols = Int(ceil(screen.width / cell)), rows = Int(ceil(screen.height / cell))
        guard cols * rows > 0 else { return 0 }
        var grid = [Bool](repeating: false, count: cols * rows), hit = 0
        for w in wins {
            let c = w.rect.intersection(screen)
            guard !c.isNull else { continue }
            let c0 = max(0, Int(floor((c.minX - screen.minX) / cell))), c1 = min(cols - 1, Int(floor((c.maxX - screen.minX - 0.01) / cell)))
            let r0 = max(0, Int(floor((c.minY - screen.minY) / cell))), r1 = min(rows - 1, Int(floor((c.maxY - screen.minY - 0.01) / cell)))
            guard c0 <= c1, r0 <= r1 else { continue }
            for r in r0...r1 { for col in c0...c1 where !grid[r * cols + col] { grid[r * cols + col] = true; hit += 1 } }
            if hit == grid.count { return 1 }
        }
        return Double(hit) / Double(grid.count)
    }
}
