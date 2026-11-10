import SwiftUI
import AppKit

// the Model Viewer as its own app (like Task Manager): a crash on a bad model file stays here, and quitting frees the memory
final class MVDelegate: NSObject, NSApplicationDelegate {
    private var openedFiles = false

    // Finder's Open With, a drop on the Dock icon, `open -a`, Taru Tweaks handing a file over
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFiles = true
        ModelViewer.shared.open(urls)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        migratePrefs()
        ModelViewer.shared.start()
        // launched without a file (Dock, flame menu): show an empty viewer with the recent list
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if !openedFiles && ModelViewer.shared.docs.isEmpty && !CommandLine.arguments.contains("--background") { ModelViewer.shared.open(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { ModelViewer.shared.open(nil) }
        return true
    }

    @objc func openFile(_ sender: Any?) { ModelViewer.shared.pick() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // settings and recent files used to live in Taru Tweaks' prefs; bring them over once
    private func migratePrefs() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "model.migrated"), let old = UserDefaults(suiteName: "com.taru.tweaks") else { return }
        for (k, v) in old.dictionaryRepresentation() where k.hasPrefix("model.") && d.object(forKey: k) == nil { d.set(v, forKey: k) }
        d.set(true, forKey: "model.migrated")
    }
}

@main
enum ModelViewerMain {
    static let delegate = MVDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = {
            let m = NSMenu()
            let appItem = NSMenuItem(); m.addItem(appItem)
            let appMenu = NSMenu()
            appMenu.addItem(withTitle: "Hide Model Viewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            appMenu.addItem(withTitle: "Quit Model Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            let fileItem = NSMenuItem(); m.addItem(fileItem)
            let file = NSMenu(title: "File")
            let open = file.addItem(withTitle: "Open…", action: #selector(MVDelegate.openFile(_:)), keyEquivalent: "o"); open.target = delegate
            file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            fileItem.submenu = file
            return m
        }()
        app.run()
    }
}
