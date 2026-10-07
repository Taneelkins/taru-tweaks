import AppKit
import Darwin

struct ProcRow: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let path: String
    let user: String
    var cpu: Double
    var memory: UInt64
    var threads: Int
    let ppid: pid_t
    let isApp: Bool
    var notResponding = false
    var children: [pid_t] = []
    var groupCPU: Double = 0
    var groupMemory: UInt64 = 0
}

enum Unresponsive {
    typealias ConnFn = @convention(c) () -> Int32
    static let connection: Int32 = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), "SLSMainConnectionID").map { unsafeBitCast($0, to: ConnFn.self)() } ?? 0
    typealias Fn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    static let fn: Fn? = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), "SLSEventIsAppUnresponsive").map { unsafeBitCast($0, to: Fn.self) }
    typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    static let psnFor: PSNFn? = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY), "GetProcessForPID").map { unsafeBitCast($0, to: PSNFn.self) }
    static func check(_ pid: pid_t) -> Bool {
        guard let fn, let psnFor else { return false }
        var psn = ProcessSerialNumber()
        guard psnFor(pid, &psn) == noErr else { return false }
        return withUnsafePointer(to: &psn) { fn(connection, $0) }
    }
}

final class ProcessStore: ObservableObject {
    static let shared = ProcessStore()
    @Published var apps: [ProcRow] = []
    @Published var background: [ProcRow] = []
    @Published var hiddenSystemCount = 0
    private var last: [pid_t: (UInt64, Double)] = [:]
    private var timer: Timer?
    private let tb: Double = { var i = mach_timebase_info(); mach_timebase_info(&i); return Double(i.numer) / Double(i.denom) }()
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func sample() {
        let me = getuid()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let n = proc_listallpids(nil, 0)
            var pids = [pid_t](repeating: 0, count: Int(n) + 64)
            let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            let now = Date().timeIntervalSince1970
            var rows: [pid_t: ProcRow] = [:]
            var hidden = 0
            var next: [pid_t: (UInt64, Double)] = [:]
            let regular = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            for pid in pids.prefix(Int(got)) where pid > 0 {
                var bsd = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { hidden += 1; continue }
                var task = proc_taskinfo()
                let ok = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
                if !ok && bsd.pbi_uid != me { hidden += 1; continue }
                var pathBuf = [CChar](repeating: 0, count: 4096)
                proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                let path = String(cString: pathBuf)
                let comm = withUnsafePointer(to: bsd.pbi_name) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
                let total = ok ? task.pti_total_user + task.pti_total_system : 0
                var cpu = 0.0
                if let prev = last[pid], now > prev.1 { cpu = Double(total - min(total, prev.0)) * tb / 1e9 / (now - prev.1) * 100 }
                next[pid] = (total, now)
                let app = regular[pid]
                let name = app?.localizedName ?? (comm.isEmpty ? (path as NSString).lastPathComponent : comm)
                let user = bsd.pbi_uid == me ? NSUserName() : (bsd.pbi_uid == 0 ? "root" : "\(bsd.pbi_uid)")
                rows[pid] = ProcRow(id: pid, name: name, path: path, user: user, cpu: cpu, memory: ok ? task.pti_resident_size : 0, threads: ok ? Int(task.pti_threadnum) : 0, ppid: pid_t(bsd.pbi_ppid), isApp: app != nil)
            }
            var apps: [ProcRow] = [], bg: [ProcRow] = []
            for (pid, r) in rows where r.isApp {
                var row = r
                var stack = [pid], kids: [pid_t] = []
                while let p = stack.popLast() { for (cp, c) in rows where c.ppid == p && !c.isApp { kids.append(cp); stack.append(cp) } }
                let appBundle = (r.path as NSString).deletingLastPathComponent.components(separatedBy: ".app/").first ?? ""
                for (cp, c) in rows where !c.isApp && !kids.contains(cp) && !appBundle.isEmpty && c.path.hasPrefix(appBundle + ".app/") { kids.append(cp) }
                row.children = kids
                row.groupCPU = r.cpu + kids.compactMap { rows[$0]?.cpu }.reduce(0, +)
                row.groupMemory = r.memory + kids.compactMap { rows[$0]?.memory }.reduce(0, +)
                row.notResponding = Unresponsive.check(pid)
                apps.append(row)
            }
            let owned = Set(apps.flatMap { $0.children })
            for (pid, r) in rows where !r.isApp && !owned.contains(pid) { var x = r; x.groupCPU = r.cpu; x.groupMemory = r.memory; bg.append(x) }
            DispatchQueue.main.async {
                self.last = next
                self.apps = apps
                self.background = bg
                self.hiddenSystemCount = hidden
            }
        }
    }

    func end(_ pid: pid_t, force: Bool, tree: Bool = false, children: [pid_t] = []) {
        if let app = NSRunningApplication(processIdentifier: pid), !force { app.terminate() }
        else { kill(pid, force ? SIGKILL : SIGTERM) }
        if tree { for c in children { kill(c, force ? SIGKILL : SIGTERM) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.sample() }
    }
}

func bytes(_ b: UInt64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .memory; f.allowedUnits = [.useMB, .useGB]
    return f.string(fromByteCount: Int64(b))
}
