import AppKit
import IOKit.pwr_mgt
import SwiftUI

final class Awake: ObservableObject {
    static let shared = Awake()

    @Published var enabled: Bool { didSet { save("awake.enabled", enabled); tick() } }
    @Published var keepDisplay: Bool { didSet { save("awake.display", keepDisplay); release(); tick() } }
    @Published var grace: Double { didSet { save("awake.grace", grace) } }
    @Published var manual = false { didSet { tick() } }
    @Published private(set) var claudeBusy = false
    @Published private(set) var holding = false
    @Published private(set) var reason = ""

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "awake.enabled") as? Bool ?? true
        keepDisplay = d.object(forKey: "awake.display") as? Bool ?? true
        grace = d.object(forKey: "awake.grace") as? Double ?? 5
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() { release() }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    func tick() {
        let busy = enabled ? detect() : nil
        claudeBusy = busy != nil
        if manual { hold("Kept awake by hand") }
        else if let busy { hold(busy) }
        else { release() }
    }

    private func detect() -> String? {
        if toolRunning() { return "Claude is running a command" }
        let cutoff = Date().addingTimeInterval(-grace * 60)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > cutoff { return "Claude is working" }
            }
        }
        return nil
    }

    private func toolRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var claude = Set<String>()
        var rows: [(ppid: String, comm: String)] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let comm = String(parts[2])
            if comm.hasSuffix("/MacOS/claude") || comm == "claude" { claude.insert(String(parts[0])) }
            rows.append((String(parts[1]), comm))
        }
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"]
        return rows.contains { claude.contains($0.ppid) && shells.contains($0.comm) }
    }

    private func hold(_ why: String) {
        reason = why
        guard !holding else { return }
        let type = (keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        holding = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Taru Tweaks: \(why)" as CFString, &assertion) == kIOReturnSuccess
    }

    private func release() {
        reason = ""
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        holding = false
    }
}

struct AwakeSettings: View {
    @ObservedObject var awake = Awake.shared
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Stay Awake", subtitle: "Keeps the Mac from sleeping while Claude is working, then lets it sleep normally once the session goes quiet.")
            SettingRow(title: "Status", detail: awake.holding ? awake.reason : (awake.enabled ? "Idle, the Mac sleeps on its normal timer" : "Off")) {
                Text(awake.holding ? "AWAKE" : "IDLE").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(awake.holding ? theme.accent : Palette.ash)
            }
            SettingRow(title: "Stay awake while Claude works", detail: "Watches Claude Code sessions, including long commands") { Switch(on: $awake.enabled) }
            SettingRow(title: "Keep the screen on", detail: awake.keepDisplay ? "Screen stays lit so you can watch it" : "Screen can turn off, the Mac keeps running") { Switch(on: $awake.keepDisplay) }
            SettingRow(title: "Quiet time before sleeping", detail: "How long after Claude's last activity to let go") {
                Seg(options: [("2 min", 2.0), ("5 min", 5.0), ("15 min", 15.0), ("30 min", 30.0)], value: $awake.grace)
            }
            SettingRow(title: "Keep awake now", detail: "Manual override, until you turn it off") { Switch(on: $awake.manual) }
            Text("Closing the lid still sleeps the Mac unless it's plugged into a display.")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 12)
        }
    }
}
