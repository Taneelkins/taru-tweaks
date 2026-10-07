import SwiftUI
import AppKit

extension Font {
    static let label = Font.system(size: 10, weight: .medium, design: .monospaced)
}

final class TMDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) { show() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.title = "Task Manager"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TaskManagerView())
            w.setFrameAutosaveName("TaskManagerWindow")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@main
enum TaskManagerMain {
    static let delegate = TMDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = {
            let m = NSMenu(), item = NSMenuItem(); m.addItem(item)
            let sub = NSMenu(); sub.addItem(withTitle: "Quit Task Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.submenu = sub; return m
        }()
        app.run()
    }
}
