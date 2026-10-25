import AppKit
import SwiftUI

// Hold ⌘Q to quit. A tap of ⌘Q just shows the bar and does nothing, so a slip can't kill Studio
// with unsaved work. Rides on Input's event tap, no second tap. Idea from Vorssaint's Quit protection.
final class QuitGuard: ObservableObject {
    static let shared = QuitGuard()
    private static let qKey: Int64 = 12, escKey: Int64 = 53, cmd: UInt64 = 0x100000

    @Published var enabled = UserDefaults.standard.object(forKey: "quit.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(enabled, forKey: "quit.enabled"); if !enabled { cancel() } } }
    @Published var hold = UserDefaults.standard.object(forKey: "quit.hold") as? Double ?? 0.7 { didSet { UserDefaults.standard.set(hold, forKey: "quit.hold") } }

    private var target: NSRunningApplication?
    private var timer: Timer?
    // the Q is still down after a quit went through, eat its repeats and release
    private var swallowUp = false
    private lazy var hud = QuitHUD()

    var pending: Bool { target != nil }

    // called from Input's tap on the main thread for every key, so plain typing bails on the first line. true = eat it
    func key(_ key: Int64, down: Bool, repeating: Bool, flags: UInt64, ignored: @autoclosure () -> Bool) -> Bool {
        if key == Self.escKey, down, pending { cancel(); return true }
        guard key == Self.qKey else { return false }
        if !down {
            if swallowUp { swallowUp = false; return true }
            if pending { cancel(); return true }
            return false
        }
        if pending || swallowUp { return true }
        guard enabled, !repeating, flags == Self.cmd, !ignored(),
              let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              app.processIdentifier != getpid() else { return false }
        begin(app)
        return true
    }

    // ⌘ let go before the bar filled
    func modifiers(_ flags: UInt64) {
        guard flags & Self.cmd == 0 else { return }
        swallowUp = false
        if pending { cancel() }
    }

    private func begin(_ app: NSRunningApplication) {
        target = app
        hud.show(app: app.localizedName ?? "app", icon: app.icon, duration: hold)
        timer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in self?.fire() }
    }

    private func fire() {
        guard let app = target else { return }
        timer = nil; target = nil; swallowUp = true
        // a real quit request, so the app still gets to ask about unsaved changes
        app.terminate()
        hud.done()
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        guard target != nil else { return }
        target = nil
        hud.hide()
    }
}

final class QuitHUD {
    private let model = QuitHUDModel()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 74), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.ignoresMouseEvents = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.level = .screenSaver
        let host = NSHostingView(rootView: QuitHUDView(model: model))
        host.sizingOptions = []
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        return p
    }()
    private var fade: DispatchWorkItem?

    func show(app: String, icon: NSImage?, duration: Double) {
        fade?.cancel()
        model.app = app; model.icon = icon; model.state = .holding; model.progress = 0
        let s = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = s?.visibleFrame { panel.setFrameOrigin(NSPoint(x: f.midX - 170, y: f.minY + f.height * 0.22)) }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        // next runloop so SwiftUI sees 0 first and animates the fill all the way
        DispatchQueue.main.async { withAnimation(.linear(duration: duration)) { self.model.progress = 1 } }
    }

    func done() {
        withAnimation(.easeOut(duration: 0.15)) { model.state = .quitting }
        out(after: 0.35)
    }

    func hide() {
        withAnimation(.easeOut(duration: 0.12)) { model.state = .cancelled; model.progress = 0 }
        out(after: 0.18)
    }

    private func out(after delay: Double) {
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; self.panel.animator().alphaValue = 0 }) { self.panel.orderOut(nil) }
        }
        fade = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

final class QuitHUDModel: ObservableObject {
    enum State { case holding, quitting, cancelled }
    @Published var app = ""
    @Published var icon: NSImage?
    @Published var state = State.holding
    @Published var progress = 0.0
}

struct QuitHUDView: View {
    @ObservedObject var model: QuitHUDModel
    @ObservedObject var theme = Theme.shared

    var body: some View {
        HStack(spacing: 12) {
            if let icon = model.icon { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(model.state == .quitting ? theme.accent : Palette.bone)
                    Text(model.app.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent).lineLimit(1)
                }
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.rule)
                    GeometryReader { g in Rectangle().fill(theme.accent).frame(width: g.size.width * model.progress).shadow(color: theme.accent.opacity(0.8), radius: 6) }
                }
                .frame(height: 5)
                Text(model.state == .holding ? "let go or press esc to cancel" : " ").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ash)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 340, height: 74)
        .background(Palette.pit.opacity(0.96))
        .overlay(Rectangle().stroke(model.state == .quitting ? theme.accent : Palette.rule, lineWidth: model.state == .quitting ? 2 : 1))
        .scaleEffect(model.state == .quitting ? 1.04 : 1)
    }

    private var label: String {
        switch model.state {
        case .holding: "HOLD ⌘Q TO QUIT"
        case .quitting: "QUITTING"
        case .cancelled: "CANCELLED"
        }
    }
}

struct QuitGuardSettings: View {
    @ObservedObject var guardian = QuitGuard.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Quit Protection", subtitle: "Hold ⌘Q to quit instead of tapping it, so a slip can't close Studio or Blender with unsaved work.")
            SettingRow(title: "Hold ⌘Q to quit", detail: "A quick tap shows the bar and does nothing. Apps still ask about unsaved changes.") { Switch(on: $guardian.enabled) }
            SettingRow(title: "Hold for") { Seg(options: [("0.4 s", 0.4), ("0.7 s", 0.7), ("1 s", 1.0)], value: $guardian.hold) }
            Text("Apps on the Switcher's Exceptions list with \"ignore shortcuts\" quit normally. Needs Accessibility, same as the Switcher.")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 12)
        }
    }
}
