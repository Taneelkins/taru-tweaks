import AppKit
import SwiftUI

// shows the windows on your other screens (the UC Test Display mostly) and swaps them over to the one you're looking at
final class ScreenSwap: ObservableObject {
    static let shared = ScreenSwap()
    static let hotKeyID: UInt32 = 701

    @Published var enabled = UserDefaults.standard.object(forKey: "swap.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(enabled, forKey: "swap.enabled"); registerKey() } }
    @Published var mask = (UserDefaults.standard.object(forKey: "swap.mask") as? NSNumber)?.uint64Value ?? 0xC0000 { didSet { UserDefaults.standard.set(mask, forKey: "swap.mask"); registerKey() } }
    @Published var key = (UserDefaults.standard.object(forKey: "swap.key") as? NSNumber)?.int64Value ?? 9 { didSet { UserDefaults.standard.set(key, forKey: "swap.key"); registerKey() } }

    private lazy var panel = SwapPanelController()

    func start() {
        registerKey()
        DistributedNotificationCenter.default().addObserver(forName: .init("com.taru.tweaks.swap"), object: nil, queue: .main) { [weak self] n in self?.debug(n.object as? String ?? "") }
    }

    func registerKey() {
        HotKeys.shared.set(Self.hotKeyID, mask: mask, key: key, enabled: enabled) { ScreenSwap.shared.toggle() }
    }

    func toggle() { panel.toggle() }

    // the screen you're on = the one with the pointer
    static var here: NSScreen? { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }

    // NSScreen is bottom-left based, window frames are top-left of the main screen
    static func cgRect(_ s: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: s.frame.minX, y: top - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }
    static func cgVisible(_ s: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
    }

    static func screen(of w: Win) -> NSScreen? {
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        return NSScreen.screens.first { cgRect($0).contains(c) }
            ?? NSScreen.screens.max { cgRect($0).intersection(w.frame).area < cgRect($1).intersection(w.frame).area }
    }

    func windows(on s: NSScreen) -> [Win] {
        let me = getpid()
        return WindowEngine.shared.all().filter { !$0.windowless && $0.pid != me && Self.screen(of: $0) == s }
    }

    // keeps the window's spot relative to the screen, shrinks it if it doesn't fit
    func move(_ w: Win, to s: NSScreen, focus: Bool) {
        guard !w.fullscreen, let src = Self.screen(of: w) else { return }
        let from = Self.cgVisible(src), to = Self.cgVisible(s)
        let size = CGSize(width: min(w.frame.width, to.width), height: min(w.frame.height, to.height))
        let fx = from.width > w.frame.width ? (w.frame.minX - from.minX) / (from.width - w.frame.width) : 0.5
        let fy = from.height > w.frame.height ? (w.frame.minY - from.minY) / (from.height - w.frame.height) : 0.5
        var origin = CGPoint(x: to.minX + (to.width - size.width) * min(max(fx, 0), 1), y: to.minY + (to.height - size.height) * min(max(fy, 0), 1))
        origin.x = origin.x.rounded(); origin.y = origin.y.rounded()
        log("move \(w.appName) '\(w.title)' \(NSStringFromRect(w.frame)) → \(s.localizedName) \(NSStringFromRect(CGRect(origin: origin, size: size)))")
        DispatchQueue.global(qos: .userInitiated).async {
            guard let el = WindowEngine.shared.axWindow(w) else { self.log("no AX window"); return }
            if w.minimized { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse); usleep(300_000) }
            var p = origin, sz = size
            // size first so the position isn't clamped against the old size, then size again in case the app snapped it
            if let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
            if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
            if let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
            if focus {
                DispatchQueue.main.async {
                    var moved = w; moved.minimized = false
                    WindowEngine.shared.focus(moved)
                }
            }
        }
    }

    private func log(_ s: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/swap.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? Data(line.utf8).write(to: url) }
    }

    // dump | open | close | bring:<id> | send:<id>
    private func debug(_ cmd: String) {
        let parts = cmd.split(separator: ":").map(String.init)
        let all = WindowEngine.shared.all()
        let others = NSScreen.screens.filter { $0 != Self.here }
        switch parts.first {
        case "open": panel.show()
        case "close": panel.hide()
        case "bring": if let id = parts.last.flatMap(UInt32.init), let w = all.first(where: { $0.id == id }), let h = Self.here { move(w, to: h, focus: false) }
        case "send": if let id = parts.last.flatMap(UInt32.init), let w = all.first(where: { $0.id == id }), let o = others.first { move(w, to: o, focus: false) }
        default: break
        }
        let out: [String: Any] = ["here": Self.here?.localizedName ?? "", "panel": panel.visible,
                                  "windows": all.filter { !$0.windowless }.map { ["id": $0.id, "app": $0.appName, "title": $0.title, "frame": NSStringFromRect($0.frame), "screen": Self.screen(of: $0)?.localizedName ?? "?"] }]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: .prettyPrinted) { try? d.write(to: URL(fileURLWithPath: "/tmp/tarutweaks-swap.json")) }
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

final class SwapPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SwapState: ObservableObject {
    struct Group: Identifiable { let id: String; let name: String; let screen: NSScreen; var wins: [Win] }
    @Published var others: [Group] = []
    @Published var mine: [Win] = []
    @Published var hereName = ""
    @Published var tick = 0
}

final class SwapPanelController {
    private var panel: SwapPanel?
    private var monitor: Any?
    private var resign: Any?
    private var timer: Timer?
    private var here: NSScreen?
    let state = SwapState()

    var visible: Bool { panel?.isVisible == true }

    func toggle() { visible ? hide() : show() }

    func show() {
        here = ScreenSwap.here
        reload()
        let p = panel ?? make()
        if let f = here?.visibleFrame { p.setFrameOrigin(NSPoint(x: (f.midX - p.frame.width / 2).rounded(), y: (f.midY - p.frame.height / 2).rounded())) }
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; p.animator().alphaValue = 1 }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in if e.keyCode == 53 { self?.hide(); return nil }; return e }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in self?.hide() }
        // pictures only refresh while it's open, nothing runs when it's closed
        timer?.invalidate()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.reload() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }; resign = nil
        panel?.orderOut(nil)
    }

    private func reload() {
        guard let here else { return }
        let swap = ScreenSwap.shared
        state.hereName = here.localizedName
        state.others = NSScreen.screens.filter { $0 != here }.map { SwapState.Group(id: $0.localizedName, name: $0.localizedName, screen: $0, wins: swap.windows(on: $0)) }
        state.mine = swap.windows(on: here)
        Thumbnails.shared.refresh(state.others.flatMap(\.wins) + state.mine) { [weak self] in self?.state.tick += 1 }
    }

    private func make() -> SwapPanel {
        let p = SwapPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .modalPanel; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: SwapView(state: state,
            onBring: { [weak self] w in self?.hide(); if let h = self?.here { ScreenSwap.shared.move(w, to: h, focus: true) } },
            onSend: { [weak self] w, s in ScreenSwap.shared.move(w, to: s, focus: false); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reload() } },
            onPlugIn: { ExtraDisplay.shared.set(true); DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reload() } }))
        host.sizingOptions = []
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        panel = p
        return p
    }
}

struct SwapView: View {
    @ObservedObject var state: SwapState
    @ObservedObject var theme = Theme.shared
    @ObservedObject var extra = ExtraDisplay.shared
    let onBring: (Win) -> Void
    let onSend: (Win, NSScreen) -> Void
    let onPlugIn: () -> Void
    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.2.swap").foregroundStyle(theme.accent)
                Text("SCREEN SWAP").font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(2).foregroundStyle(Palette.bone)
                Spacer()
                Text("you're on \(state.hereName)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            Rectangle().fill(Palette.rule).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.others.isEmpty {
                        VStack(spacing: 10) {
                            Text("There's no other screen plugged in.").font(.system(size: 12)).foregroundStyle(Palette.ash)
                            if extra.installed { TweakButton(title: extra.busy ? "Plugging in…" : "Plug in \(extra.name)") { onPlugIn() } }
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(state.others) { g in
                        label("ON \(g.name.uppercased())", "click to bring it here")
                        if g.wins.isEmpty { empty("No windows on this screen.") }
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(g.wins) { w in SwapCard(win: w, tick: state.tick) { onBring(w) } }
                        }
                    }
                    if let target = state.others.first {
                        label("ON THIS SCREEN", "click to send it to \(target.name)")
                        if state.mine.isEmpty { empty("No windows here.") }
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(state.mine) { w in SwapCard(win: w, tick: state.tick) { onSend(w, target.screen) } }
                        }
                    }
                }
                .padding(14)
            }
            Rectangle().fill(Palette.rule).frame(height: 1)
            Text("click a window to swap it over   esc close").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ash)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(width: 760, height: 560)
        .background(Palette.pit.opacity(0.97))
        .overlay(Rectangle().stroke(Palette.rule, lineWidth: 1))
        .tint(theme.accent)
    }

    func label(_ t: String, _ d: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(theme.accent)
            Text(d).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash)
        }
    }
    func empty(_ t: String) -> some View { Text(t).font(.system(size: 11)).foregroundStyle(Palette.ash) }
}

struct SwapCard: View {
    let win: Win
    let tick: Int
    let action: () -> Void
    @ObservedObject var theme = Theme.shared
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.35))
                if let img = Thumbnails.shared.cache[win.id] {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "macwindow").font(.system(size: 26)).foregroundStyle(Palette.ash)
                }
            }
            .frame(height: 104).clipped()
            HStack(spacing: 6) {
                if let icon = NSRunningApplication(processIdentifier: win.pid)?.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(win.appName).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.bone).lineLimit(1)
                    Text(win.fullscreen ? "full screen, can't move" : win.minimized ? "minimized · \(win.title)" : win.title.isEmpty ? " " : win.title)
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
                }
            }
        }
        .padding(7)
        .background(hover ? theme.accent.opacity(0.16) : Color.white.opacity(0.03))
        .overlay(Rectangle().stroke(hover ? theme.accent : Palette.rule, lineWidth: 1))
        .opacity(win.fullscreen ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if !win.fullscreen { action() } }
        .id("\(win.id)-\(tick)")
    }
}

struct ScreenSwapRow: View {
    @ObservedObject var swap = ScreenSwap.shared
    var body: some View {
        HStack {
            Text("Screen Swap").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
            Spacer()
            Text("\(modifierString(swap.mask))\(keyString(swap.key))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
        }
        .contentShape(Rectangle())
        .onTapGesture { swap.toggle() }
    }
}

struct ScreenSwapSettings: View {
    @ObservedObject var swap = ScreenSwap.shared
    @ObservedObject var extra = ExtraDisplay.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Screen Swap", subtitle: "See the windows on your other screen (like the \(extra.name) virtual display) and swap them over. Click a window from the other screen to bring it here, or click one of yours to send it there.")
            SettingRow(title: "Use the shortcut", detail: "Off = the shortcut does nothing; the flame menu row still works") { Switch(on: $swap.enabled) }
            SettingRow(title: "Shortcut", detail: "\(modifierString(swap.mask))\(keyString(swap.key))") { KeyRecorder(mask: $swap.mask, key: $swap.key) }
            SettingRow(title: "Virtual display", detail: "\(extra.name) · \(extra.connected ? "plugged in" : "unplugged")") { Switch(on: extra.on) }
            SettingRow(title: "Open it now") { TweakButton(title: "Open") { swap.toggle() } }
            Text("Windows keep their spot on the screen and shrink if they don't fit. Full-screen windows can't be moved. Nothing runs while the panel is closed.")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 12)
        }
    }
}
