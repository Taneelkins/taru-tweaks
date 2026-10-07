import AppKit
import ApplicationServices

final class Responsiveness {
    static let shared = Responsiveness()
    static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/hung.json")
    private let queue = DispatchQueue(label: "responsiveness", qos: .utility)
    private var timer: Timer?
    private var slow: [pid_t: Int] = [:]

    func start() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.probe() }
    }

    private func probe() {
        guard AXIsProcessTrusted() else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.isFinishedLaunching }.map(\.processIdentifier)
        queue.async { [self] in
            var hung: [pid_t] = []
            for pid in pids {
                let el = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(el, 0.25)
                var v: CFTypeRef?
                let r = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
                let miss = r == .cannotComplete
                slow[pid] = miss ? (slow[pid] ?? 0) + 1 : 0
                if (slow[pid] ?? 0) >= 2 { hung.append(pid) }
            }
            slow = slow.filter { pids.contains($0.key) }
            let obj: [String: Any] = ["updated": Date().timeIntervalSince1970, "hung": hung.map { Int($0) }]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: Self.file, options: .atomic) }
        }
    }
}

