import AppKit

// reopens Taru Tweaks if it dies without a normal quit. Sleeps on NSWorkspace notifications, no polling.
// A normal quit (menu, SIGTERM, logout) writes the clean-exit marker first; a crash or kill -9 doesn't.
let bundleID = "com.taru.tweaks"
let marker = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/clean-exit")
let logURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/watchdog.log")
var recent: [Date] = []

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? Data(line.utf8).write(to: logURL) }
}

func cleanExit() -> Bool {
    guard let d = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(d) < 15
}

NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
    guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == bundleID, let url = app.bundleURL else { return }
    if cleanExit() { log("quit normally, not reopening"); return }
    // a crash loop gives up after 3 tries in 2 minutes instead of flashing forever
    recent = recent.filter { Date().timeIntervalSince($0) < 120 }
    guard recent.count < 3 else { log("crashed again, 3 restarts in 2 min, giving up"); return }
    recent.append(Date())
    log("ended without a normal quit, reopening")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.arguments = ["--background"]
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, e in if let e { log("reopen failed: \(e)") } }
    }
}
log("watching")
RunLoop.main.run()
