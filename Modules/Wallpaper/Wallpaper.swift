import AppKit
import AVFoundation
import SwiftUI

final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()
    @Published var enabled = UserDefaults.standard.object(forKey: "wp.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(enabled, forKey: "wp.enabled"); apply() } }
    @Published var current = UserDefaults.standard.string(forKey: "wp.current") ?? "" { didSet { UserDefaults.standard.set(current, forKey: "wp.current") } }
    @Published var pauseHidden = UserDefaults.standard.object(forKey: "wp.pauseHidden") as? Bool ?? true { didSet { UserDefaults.standard.set(pauseHidden, forKey: "wp.pauseHidden"); updatePlayback() } }
    @Published var fill = UserDefaults.standard.object(forKey: "wp.fill") as? Bool ?? true { didSet { UserDefaults.standard.set(fill, forKey: "wp.fill"); windows.values.forEach { $0.gravity(fill) } } }
    @Published var library: [URL] = []
    @Published var playing = false
    @Published var systemActive = false
    @Published var systemReady = false

    let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/Wallpapers")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var asleep = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        reload()
        if current.isEmpty, let first = library.first { current = first.path }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                                 (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.asleep = sleeping; self?.updatePlayback() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layoutWindows() }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.layoutWindows() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.layoutWindows() }
        checkSystem()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkSystem() }
        apply()
    }

    func checkSystem() {
        let ready = SystemWallpaper.ready
        if ready && !systemReady { Task { await SystemWallpaper.sync(library) } }
        if ready != systemReady { systemReady = ready }
        let active = SystemWallpaper.isActive
        if active != systemActive { systemActive = active; apply() }
    }

    func setUpLockScreen() {
        SystemWallpaper.openSettings()
        Task { await SystemWallpaper.sync(library) }
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        library = files.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func importVideo(_ url: URL) {
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: url, to: dest) }
        reload()
        choose(dest)
        Task { await SystemWallpaper.sync(library) }
    }

    func remove(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: still(for: url))
        reload()
        if current == url.path { current = library.first?.path ?? ""; apply() }
    }

    func choose(_ url: URL) {
        current = url.path
        apply()
    }

    private func apply() {
        guard started else { return }
        guard enabled, !systemActive, FileManager.default.fileExists(atPath: current) else {
            player.pause(); looper?.disableLooping(); looper = nil; player.removeAllItems()
            windows.values.forEach { $0.orderOut(nil) }
            windows = [:]
            playing = false
            return
        }
        let url = URL(fileURLWithPath: current)
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        layoutWindows()
        setSystemStill(for: url)
        updatePlayback()
    }

    private func layoutWindows() {
        guard enabled, !systemActive, looper != nil else { return }
        var live: [CGDirectDisplayID: WallpaperWindow] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let w = windows[id] ?? WallpaperWindow(player: player) { [weak self] in self?.updatePlayback() }
            w.place(on: screen, fill: fill)
            live[id] = w
        }
        for (id, w) in windows where live[id] == nil { w.orderOut(nil) }
        windows = live
    }

    func updatePlayback() {
        let visible = windows.values.contains { $0.occlusionState.contains(.visible) }
        let run = enabled && looper != nil && !asleep && (visible || !pauseHidden)
        if run && player.rate == 0 { player.play() } else if !run && player.rate != 0 { player.pause() }
        if playing != run { playing = run }
    }

    private func still(for url: URL) -> URL { dir.appendingPathComponent(".stills").appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png") }

    private func setSystemStill(for url: URL) {
        let out = still(for: url)
        let setAll = { for s in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(out, for: s, options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]) } }
        if FileManager.default.fileExists(atPath: out.path) { setAll(); return }
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { image, _, _ in
            guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: out)
            DispatchQueue.main.async(execute: setAll)
        }
    }

    func thumbnail(for url: URL) -> NSImage? {
        let out = still(for: url)
        if let img = NSImage(contentsOf: out) { return img }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

final class WallpaperWindow: NSWindow {
    private let videoLayer: AVPlayerLayer
    private let onVisibility: () -> Void

    init(player: AVPlayer, onVisibility: @escaping () -> Void) {
        videoLayer = AVPlayerLayer(player: player)
        self.onVisibility = onVisibility
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.frame = v.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(videoLayer)
        contentView = v
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main) { [weak self] _ in self?.onVisibility() }
    }

    func gravity(_ fill: Bool) { videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect }

    func place(on screen: NSScreen, fill: Bool) {
        gravity(fill)
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let others = info.filter { ($0[kCGWindowLayer as String] as? Int) == level.rawValue && ($0[kCGWindowOwnerPID as String] as? Int32) != getpid() }
        if let bottom = others.last?[kCGWindowNumber as String] as? Int { order(.below, relativeTo: bottom) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct WallpaperSettings: View {
    @ObservedObject var wp = Wallpaper.shared
    @ObservedObject var theme = Theme.shared
    @State private var thumbs: [String: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Live Wallpaper", subtitle: "Plays your video wallpaper on every Space and display, 24/7, from inside Taru Tweaks. The lock screen and Mission Control show a still from the same video.")
            SettingRow(title: "Lock screen + desktop", detail: wp.systemActive ? "On: macOS plays it everywhere, lock screen included" : "Pick \"Taru Tweaks — Live Wallpapers\" in System Settings → Wallpaper, then your video") {
                if wp.systemActive { Text("ACTIVE").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.shared.accent) }
                else { TweakButton(title: "Set up") { wp.setUpLockScreen() } }
            }
            SettingRow(title: "Desktop-only player", detail: wp.systemActive ? "Not needed while the lock screen version is active" : (wp.playing ? "Playing" : (wp.enabled ? "Paused, nothing on screen can see it" : "Off"))) { Switch(on: $wp.enabled) }
            SettingRow(title: "Pause when it can't be seen", detail: "Stops decoding while a window covers the whole desktop or the screen is locked. You'll never notice, and it saves battery.") { Switch(on: $wp.pauseHidden) }
            SettingRow(title: "Scaling") { Seg(options: [("Fill", true), ("Fit", false)], value: $wp.fill) }
            SectionLabel(text: "Videos")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(wp.library, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { wp.choose(url) } label: {
                            ZStack {
                                Rectangle().fill(Color.black)
                                if let img = thumbs[url.path] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                            }
                            .frame(height: 96).clipped()
                            .overlay(Rectangle().stroke(wp.current == url.path ? theme.accent : Palette.rule, lineWidth: wp.current == url.path ? 2 : 1))
                        }.buttonStyle(.plain)
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.bone).lineLimit(1)
                            Spacer()
                            if wp.current != url.path {
                                Button("REMOVE") { wp.remove(url) }.buttonStyle(.plain).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
                            }
                        }
                    }
                }
            }
            .onAppear(perform: loadThumbs)
            .onChange(of: wp.library) { _ in loadThumbs() }
            HStack { TweakButton(title: "Add video…") { pick() }; Spacer() }.padding(.top, 14)
            Text("MP4 or MOV. HEVC (H.265) uses the least power. Files are copied into Taru Tweaks, so the original can move.")
                .font(.system(size: 11)).foregroundStyle(Palette.ash).padding(.top, 8)
        }
    }

    private func loadThumbs() {
        for url in wp.library where thumbs[url.path] == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = Wallpaper.shared.thumbnail(for: url)
                DispatchQueue.main.async { thumbs[url.path] = img }
            }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url { wp.importVideo(url) }
    }
}

enum SystemWallpaper {
    static let extensionID = "com.taru.tweaks.wallpaper"
    static var container: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(extensionID)") }
    static var videosDir: URL { container.appendingPathComponent("Data/Documents/videos") }
    static var ready: Bool { FileManager.default.fileExists(atPath: container.path) }

    struct Entry: Codable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
    }

    static var isActive: Bool {
        let index = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: index) else { return false }
        return data.range(of: Data(extensionID.utf8)) != nil
    }

    static func existing() -> Set<String> {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil)) ?? []
        return Set(dirs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("metadata.json"))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }?.filename
        })
    }

    static func sync(_ videos: [URL]) async {
        guard ready else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        let have = existing()
        var changed = false
        for url in videos where !have.contains(url.lastPathComponent) {
            let id = UUID().uuidString
            let dir = videosDir.appendingPathComponent(id)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                do { try fm.linkItem(at: url, to: dest) } catch { try fm.copyItem(at: url, to: dest) }
                let asset = AVURLAsset(url: dest)
                var fps = 0.0, size = CGSize.zero, duration = 0.0
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
                    size = (try? await track.load(.naturalSize)) ?? .zero
                }
                if let d = try? await asset.load(.duration) { duration = CMTimeGetSeconds(d) }
                let entry = Entry(id: id, name: url.deletingPathExtension().lastPathComponent, filename: url.lastPathComponent, duration: duration, fps: fps, resolution: size, dateAdded: Date())
                try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("metadata.json"))
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 960, height: 540)
                if let cg = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image,
                   let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                    try? jpg.write(to: dir.appendingPathComponent("thumbnail.jpg"))
                }
                changed = true
            } catch {
                try? fm.removeItem(at: dir)
            }
        }
        if changed { notify() }
    }

    static func notify() {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        if length > 0 {
            let cacheDir = URL(fileURLWithPath: String(cString: buf)).appendingPathComponent("com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache")
            for surface in ["desktop", "screenSaver"] {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("extension-\(extensionID)-\(surface)"))
            }
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("\(extensionID).libraryChanged" as CFString), nil, nil, true)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }
}
