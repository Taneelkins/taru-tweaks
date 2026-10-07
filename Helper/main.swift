import Foundation
import IOKit
import IOKit.pwr_mgt

let ConfigURL = TweaksDir.appendingPathComponent("config.json")
let StatusURL = TweaksDir.appendingPathComponent("status.json")
let HistoryURL = TweaksDir.appendingPathComponent("history.csv")
let TasksLogURL = TweaksDir.appendingPathComponent("tasks-history.json")
let HeartbeatURL = TweaksDir.appendingPathComponent("heartbeat")

struct Battery { var percent = 0, plugged = false, adapterPresent = false, charging = false, temperature = 0.0, voltage = 0.0, amperage = 0.0 }

func readBattery() -> Battery {
    var b = Battery()
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return b }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any] else { return b }
    b.percent = (d["CurrentCapacity"] as? NSNumber)?.intValue ?? 0
    b.plugged = d["ExternalConnected"] as? Bool ?? false
    b.adapterPresent = b.plugged || (((d["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber)?.intValue ?? 0) > 0
    b.charging = d["IsCharging"] as? Bool ?? false
    b.temperature = Double((d["Temperature"] as? NSNumber)?.intValue ?? 0) / 100
    b.voltage = Double((d["Voltage"] as? NSNumber)?.intValue ?? 0) / 1000
    b.amperage = Double(Int64(bitPattern: (d["Amperage"] as? NSNumber)?.uint64Value ?? 0)) / 1000
    return b
}

func smcGet(_ key: String) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: 32); var n: UInt32 = 0
    var t: (CChar, CChar, CChar, CChar, CChar) = (0, 0, 0, 0, 0)
    let r = withUnsafeMutablePointer(to: &t) { $0.withMemoryRebound(to: CChar.self, capacity: 5) { smc_read(key, &buf, &n, $0) } }
    return r == 0 ? Array(buf[0..<Int(n)]) : nil
}

@discardableResult
func smcSet(_ key: String, _ bytes: [UInt8]) -> Bool {
    if smcGet(key) == bytes { return true }
    var b = bytes
    let r = smc_write(key, &b, UInt32(b.count))
    if r != 0 { log("write \(key) failed: \(r)") }
    return r == 0
}

func log(_ s: String) { FileHandle.standardError.write("[\(Date())] \(s)\n".data(using: .utf8)!) }

func run(_ path: String, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    try? p.run(); p.waitUntilExit()
}

func loadConfig() -> BatteryConfig {
    guard let d = try? Data(contentsOf: ConfigURL), let c = try? JSONDecoder().decode(BatteryConfig.self, from: d) else { return BatteryConfig() }
    return c
}

func saveConfig(_ c: BatteryConfig) {
    let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
    if let d = try? e.encode(c) { try? d.write(to: ConfigURL, options: .atomic) }
    chmod(ConfigURL.path, 0o666)
}

func appendTaskLog(_ title: String) {
    var log = (try? JSONDecoder().decode([TaskRecord].self, from: Data(contentsOf: TasksLogURL))) ?? []
    log.insert(TaskRecord(date: Date().timeIntervalSince1970, title: title), at: 0)
    if log.count > 100 { log.removeLast(log.count - 100) }
    if let d = try? JSONEncoder().encode(log) { try? d.write(to: TasksLogURL, options: .atomic); chmod(TasksLogURL.path, 0o644) }
}

final class Engine {
    var inhibitCharge = false
    var inhibitAdapter = false
    var hot = false
    var asleep = false
    var calPhase = "idle"
    var calHoldUntil: Double = 0
    var lastHistory: Double = 0
    var reason = "starting"
    var state = "idle"
    var sleepAssertion: IOPMAssertionID = 0
    var clamshellOn = false
    var appliedPowerMode = ""

    func setSleepBlocked(_ on: Bool) {
        if on && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Taru Tweaks: charging to limit" as CFString, &sleepAssertion)
        } else if !on && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }

    func setClamshell(_ on: Bool) {
        guard on != clamshellOn else { return }
        clamshellOn = on
        run("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"])
    }

    func runTasks(_ c: inout BatteryConfig) -> Bool {
        let cal = Calendar.current, now = Date()
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        var changed = false
        for i in c.tasks.indices where c.tasks[i].enabled {
            let t = c.tasks[i]
            guard t.weekdays.contains(comps.weekday ?? 0), t.hour == comps.hour, t.minute == comps.minute,
                  now.timeIntervalSince1970 - t.lastRun > 90 else { continue }
            switch t.action {
            case "limit": c.limit = t.value; c.mode = "limit"
            case "topup": c.mode = "topup"
            case "drain": c.mode = "drain"; c.drainTarget = t.value
            case "calibrate": c.calibrateNow = true
            case "pause": c.paused = true
            case "resume": c.paused = false
            case "lowpower": c.powerMode = t.value == 1 ? "low" : "auto"
            default: break
            }
            c.tasks[i].lastRun = now.timeIntervalSince1970
            appendTaskLog(t.title)
            changed = true
        }
        return changed
    }

    func tick() {
        var c = loadConfig()
        let b = readBattery()
        let now = Date().timeIntervalSince1970
        if runTasks(&c) { saveConfig(c) }

        if c.powerMode != appliedPowerMode {
            switch c.powerMode {
            case "low": run("/usr/bin/pmset", ["-a", "powermode", "1"]); run("/usr/bin/pmset", ["-a", "lowpowermode", "1"])
            case "high": run("/usr/bin/pmset", ["-a", "powermode", "2"])
            case "auto": run("/usr/bin/pmset", ["-a", "powermode", "0"]); run("/usr/bin/pmset", ["-a", "lowpowermode", "0"])
            default: break
            }
            appliedPowerMode = c.powerMode
        }

        let heartbeat = (try? FileManager.default.attributesOfItem(atPath: HeartbeatURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let appAlive = now - heartbeat < 90
        if !c.enabled || (!c.keepWhenAppClosed && !appAlive) {
            restore(); setSleepBlocked(false); setClamshell(false)
            reason = c.enabled ? "app closed, macOS in control" : "battery module off"
            state = "off"
            writeStatus(b, c, now)
            return
        }

        if c.lastCalibration == 0 { c.lastCalibration = now; saveConfig(c) }
        let nextCal = c.lastCalibration + Double(c.calibrationDays) * 86400
        if c.calibrateNow || (c.calibrationMonthly && now >= nextCal && b.adapterPresent && calPhase == "idle") {
            if calPhase == "idle" { calPhase = "draining"; log("calibration started") }
            if c.calibrateNow { c.calibrateNow = false; saveConfig(c) }
        }

        if c.heatProtection {
            if b.temperature >= c.heatMax { hot = true } else if b.temperature <= c.heatMax - 3 { hot = false }
        } else { hot = false }

        var charge = !inhibitCharge
        var adapter = true
        var draining = false

        switch calPhase {
        case "draining":
            adapter = false; charge = false; draining = true; reason = "calibration: draining to 15%"; state = "calibrating"
            if b.percent <= 15 || !b.adapterPresent { calPhase = b.adapterPresent ? "filling" : "idle" }
        case "filling":
            charge = !hot; reason = hot ? "calibration paused, too hot" : "calibration: charging to 100%"; state = "calibrating"
            if b.percent >= 100 { calPhase = "holding"; calHoldUntil = now + 3600 }
        case "holding":
            charge = true; reason = "calibration: holding at 100%"; state = "calibrating"
            if now >= calHoldUntil { calPhase = "idle"; c.lastCalibration = now; saveConfig(c); appendTaskLog("Calibration finished") }
        default:
            switch c.mode {
            case "topup":
                charge = true; reason = "topping up to 100%"; state = "topup"
                if b.percent >= 100 || !b.adapterPresent { c.mode = "limit"; saveConfig(c) }
            case "drain":
                adapter = false; charge = false; draining = true; reason = "discharging to \(c.drainTarget)%"; state = "draining"
                if b.percent <= c.drainTarget || !b.adapterPresent { c.mode = "limit"; saveConfig(c); adapter = true; draining = false }
            case "sail":
                if b.percent >= c.limit { charge = false } else if b.percent <= c.sailFloor { charge = true }
                reason = charge ? "charging to \(c.limit)%" : "sailing \(c.limit)% → \(c.sailFloor)%"; state = charge ? "charging" : "sailing"
            default:
                if b.percent >= c.limit { charge = false } else if b.percent <= c.limit - 2 { charge = true }
                reason = charge ? "charging to \(c.limit)%" : "holding at \(c.limit)%"; state = charge ? "charging" : "holding"
                if c.autoDischarge && b.adapterPresent && b.percent > c.limit + 1 {
                    adapter = false; draining = true; reason = "auto-discharging to \(c.limit)%"; state = "draining"
                }
            }
            if c.paused && charge { charge = false; reason = "charging paused"; state = "paused" }
            if hot && charge { charge = false; reason = String(format: "too hot (%.1f °C), paused", b.temperature); state = "hot" }
            if asleep && c.stopWhenAsleep && c.mode != "topup" && charge { charge = false; reason = "asleep"; state = "holding" }
        }

        if b.percent < 10 { charge = true; adapter = true; draining = false; reason = "below 10%, charging for safety"; state = "charging" }
        if !b.adapterPresent { state = "battery"; reason = "on battery" }

        inhibitCharge = !charge
        inhibitAdapter = !adapter
        smcSet("CHTE", inhibitCharge ? [1, 0, 0, 0] : [0, 0, 0, 0])
        smcSet("CHIE", [inhibitAdapter ? 0x08 : 0x00])

        switch c.ledMode {
        case "smart" where b.adapterPresent: smcSet("ACLC", [inhibitCharge || b.percent >= 100 ? 0x03 : 0x04])
        case "off": smcSet("ACLC", [0x01])
        default: smcSet("ACLC", [0x00])
        }

        setSleepBlocked(c.preventSleepUntilLimit && b.adapterPresent && charge && b.percent < c.limit)
        setClamshell(c.clamshellDischarge && draining)
        writeStatus(b, c, now)

        if now - lastHistory >= 60 {
            lastHistory = now
            appendHistory(String(format: "%.0f,%d,%.2f,%.2f,%d\n", now, b.percent, b.temperature, b.voltage * b.amperage, b.adapterPresent ? 1 : 0))
        }
    }

    func writeStatus(_ b: Battery, _ c: BatteryConfig, _ now: Double) {
        let st = BatteryStatus(updated: now, percent: b.percent, plugged: b.adapterPresent, charging: b.charging, chargeInhibited: inhibitCharge, adapterInhibited: inhibitAdapter,
                               temperature: b.temperature, reason: reason, state: state, calibrationPhase: calPhase,
                               nextCalibration: c.lastCalibration + Double(c.calibrationDays) * 86400, helperVersion: HelperVersion)
        if let d = try? JSONEncoder().encode(st) { try? d.write(to: StatusURL, options: .atomic); chmod(StatusURL.path, 0o644) }
    }

    func appendHistory(_ line: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: HistoryURL.path) { fm.createFile(atPath: HistoryURL.path, contents: nil); chmod(HistoryURL.path, 0o644) }
        if let h = try? FileHandle(forWritingTo: HistoryURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        if let size = try? fm.attributesOfItem(atPath: HistoryURL.path)[.size] as? Int, size > 900_000,
           let text = try? String(contentsOf: HistoryURL, encoding: .utf8) {
            try? (text.split(separator: "\n").suffix(7 * 1440).joined(separator: "\n") + "\n").write(to: HistoryURL, atomically: true, encoding: .utf8)
        }
    }

    func restore() {
        inhibitCharge = false; inhibitAdapter = false
        smcSet("CHTE", [0, 0, 0, 0]); smcSet("CHIE", [0x00]); smcSet("ACLC", [0x00])
    }
}

func migrateOldFuel() {
    let old = "/Library/LaunchDaemons/com.taru.fueld.plist"
    guard FileManager.default.fileExists(atPath: old) else { return }
    let oldConfig = URL(fileURLWithPath: "/Library/Application Support/Fuel/config.json")
    if !FileManager.default.fileExists(atPath: ConfigURL.path), let d = try? Data(contentsOf: oldConfig), let c = try? JSONDecoder().decode(BatteryConfig.self, from: d) {
        saveConfig(c)
    }
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/Library/Application Support/Fuel/history.csv"), to: HistoryURL)
    run("/bin/launchctl", ["bootout", "system/com.taru.fueld"])
    try? FileManager.default.removeItem(atPath: old)
    try? FileManager.default.removeItem(atPath: "/Library/PrivilegedHelperTools/com.taru.fueld")
    try? FileManager.default.removeItem(atPath: "/Library/Application Support/Fuel")
    log("migrated from Fuel")
}

let engine = Engine()
var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var notifyPort: IONotificationPortRef?

func powerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ type: UInt32, _ arg: UnsafeMutableRawPointer?) {
    switch type {
    case 0xE0000280: IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case 0xE0000270: engine.asleep = true; engine.tick(); IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case 0xE0000120, 0xE0000300: engine.asleep = false; engine.tick()
    default: break
    }
}

try? FileManager.default.createDirectory(at: TweaksDir, withIntermediateDirectories: true)
chmod(TweaksDir.path, 0o777)
migrateOldFuel()
if !FileManager.default.fileExists(atPath: ConfigURL.path) { saveConfig(BatteryConfig()) }
guard smc_open() == 0 else { log("cannot open SMC"); exit(1) }

rootPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
if let p = notifyPort { CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .defaultMode) }

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { engine.restore(); engine.setClamshell(false); smc_close(); exit(0) }
    src.resume(); _ = Unmanaged.passRetained(src)
}

RunLoop.main.add(Timer(timeInterval: 20, repeats: true) { _ in engine.tick() }, forMode: .common)
var configStamp = Date.distantPast
RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { _ in
    let m = (try? FileManager.default.attributesOfItem(atPath: ConfigURL.path)[.modificationDate] as? Date) ?? .distantPast
    if m != configStamp { configStamp = m; engine.tick() }
}, forMode: .common)

log("Taru Tweaks helper running")
engine.tick()
RunLoop.main.run()
