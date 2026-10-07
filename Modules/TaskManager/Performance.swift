import Foundation
import IOKit
import Darwin

struct PerfPoint: Identifiable { let id: Int; let value: Double }

final class PerfStore: ObservableObject {
    static let shared = PerfStore()
    @Published var cpu: [Double] = []
    @Published var cores: [Double] = []
    @Published var memUsed: Double = 0
    @Published var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var memHistory: [Double] = []
    @Published var gpu: [Double] = []
    @Published var netIn: [Double] = []
    @Published var netOut: [Double] = []
    @Published var diskRead: [Double] = []
    @Published var diskWrite: [Double] = []
    @Published var uptime: TimeInterval = 0
    private var prevTicks: [UInt32] = []
    private var prevNet: (UInt64, UInt64, Double)?
    private var prevDisk: (UInt64, UInt64, Double)?
    private var timer: Timer?
    let keep = 60

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func push(_ arr: inout [Double], _ v: Double) { arr.append(v); if arr.count > keep { arr.removeFirst(arr.count - keep) } }

    func tick() {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var n: natural_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info {
            let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.size))
            if prevTicks.count == ticks.count {
                var per: [Double] = [], busyAll = 0.0, totalAll = 0.0
                for c in 0..<Int(n) {
                    let b = c * Int(CPU_STATE_MAX)
                    let d = (0..<Int(CPU_STATE_MAX)).map { Double(ticks[b + $0] &- prevTicks[b + $0]) }
                    let busy = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
                    let total = busy + d[Int(CPU_STATE_IDLE)]
                    per.append(total > 0 ? busy / total * 100 : 0); busyAll += busy; totalAll += total
                }
                cores = per
                push(&cpu, totalAll > 0 ? busyAll / totalAll * 100 : 0)
            }
            prevTicks = ticks
        }
        var vm = vm_statistics64(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &vm, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }) == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            memUsed = (Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            push(&memHistory, memUsed / memTotal * 100)
        }
        push(&gpu, gpuUtil())
        let now = Date().timeIntervalSince1970
        let (i, o) = netBytes()
        if let p = prevNet, now > p.2 { push(&netIn, Double(i &- p.0) / (now - p.2)); push(&netOut, Double(o &- p.1) / (now - p.2)) }
        prevNet = (i, o, now)
        let (r, w) = diskBytes()
        if let p = prevDisk, now > p.2 { push(&diskRead, Double(r &- p.0) / (now - p.2)); push(&diskWrite, Double(w &- p.1) / (now - p.2)) }
        prevDisk = (r, w, now)
        uptime = ProcessInfo.processInfo.systemUptime
    }

    func gpuUtil() -> Double {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var best = 0.0
        while case let s = IOIteratorNext(it), s != 0 {
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue { best = max(best, u) }
            IOObjectRelease(s)
        }
        return best
    }

    func netBytes() -> (UInt64, UInt64) {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return (0, 0) }
        defer { freeifaddrs(ifa) }
        var i: UInt64 = 0, o: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"), let data = cur.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                i += UInt64(d.ifi_ibytes); o += UInt64(d.ifi_obytes)
            }
            p = cur.pointee.ifa_next
        }
        return (i, o)
    }

    func diskBytes() -> (UInt64, UInt64) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let s = IOIteratorNext(it), s != 0 {
            if let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                r += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(s)
        }
        return (r, w)
    }
}

func rate(_ bps: Double) -> String {
    if bps > 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
    if bps > 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
    return String(format: "%.0f B/s", bps)
}
