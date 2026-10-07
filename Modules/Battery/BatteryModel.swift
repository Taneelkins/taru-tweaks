import Foundation
import IOKit
import SwiftUI
import ServiceManagement
import UserNotifications

struct Sample: Identifiable {
    let id: Double
    let date: Date
    let percent: Int
    let temperature: Double
    let watts: Double
}

struct EnergyApp: Identifiable {
    let id = UUID()
    let name: String
    let impact: Double
}

struct BatteryInfo {
    var percent = 0, plugged = false, charging = false, fullyCharged = false
    var temperature = 0.0, voltage = 0.0, amperage = 0.0
    var cycles = 0, designCapacity = 0, rawMax = 0, rawCurrent = 0, nominal = 0
    var timeToFull = 0, timeToEmpty = 0
    var chip = "", serial = ""
    var adapterName = "", adapterWatts = 0, adapterVolts = 0.0, adapterAmps = 0.0, adapterFirmware = ""
    var wallWatts = 0.0, efficiencyLoss = 0.0
    var telemetryBattery: Double?

    var batteryWatts: Double { telemetryBattery ?? voltage * amperage }
    var systemWatts: Double { plugged ? max(0, wallWatts - batteryWatts - efficiencyLoss) : abs(batteryWatts) }
    var health: Double { designCapacity > 0 ? Double(rawMax) / Double(designCapacity) * 100 : 0 }
    var macHealth: Double { designCapacity > 0 ? min(100, Double(nominal) / Double(designCapacity) * 100) : 0 }
    var hardwarePercent: Double { rawMax > 0 ? Double(rawCurrent) / Double(rawMax) * 100 : 0 }
}

func readBatteryInfo() -> BatteryInfo {
    var b = BatteryInfo()
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return b }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any] else { return b }
    func int(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
    func signed(_ k: String) -> Int { Int(Int64(bitPattern: (d[k] as? NSNumber)?.uint64Value ?? 0)) }
    b.percent = int("CurrentCapacity")
    let adapter = d["AdapterDetails"] as? [String: Any]
    b.plugged = (d["ExternalConnected"] as? Bool ?? false) || ((adapter?["Watts"] as? NSNumber)?.intValue ?? 0) > 0
    b.charging = d["IsCharging"] as? Bool ?? false
    b.fullyCharged = d["FullyCharged"] as? Bool ?? false
    b.temperature = Double(int("Temperature")) / 100
    b.voltage = Double(int("Voltage")) / 1000
    b.amperage = Double(signed("Amperage")) / 1000
    b.cycles = int("CycleCount"); b.designCapacity = int("DesignCapacity")
    b.rawMax = int("AppleRawMaxCapacity"); b.rawCurrent = int("AppleRawCurrentCapacity"); b.nominal = int("NominalChargeCapacity")
    b.timeToFull = int("AvgTimeToFull"); b.timeToEmpty = int("AvgTimeToEmpty")
    b.chip = d["DeviceName"] as? String ?? ""; b.serial = d["Serial"] as? String ?? ""
    if let a = adapter {
        b.adapterName = (a["Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        b.adapterWatts = (a["Watts"] as? NSNumber)?.intValue ?? 0
        b.adapterVolts = Double((a["AdapterVoltage"] as? NSNumber)?.intValue ?? 0) / 1000
        b.adapterAmps = Double((a["Current"] as? NSNumber)?.intValue ?? 0) / 1000
        b.adapterFirmware = a["FwVersion"] as? String ?? ""
    }
    if let t = d["PowerTelemetryData"] as? [String: Any] {
        b.wallWatts = Double((t["SystemPowerIn"] as? NSNumber)?.intValue ?? 0) / 1000
        b.efficiencyLoss = Double((t["AdapterEfficiencyLoss"] as? NSNumber)?.intValue ?? 0) / 1000
        if let raw = (t["BatteryPower"] as? NSNumber)?.uint64Value { b.telemetryBattery = -Double(Int64(bitPattern: raw)) / 1000 }
    }
    if !b.plugged { b.wallWatts = 0; b.efficiencyLoss = 0 }
    return b
}

final class BatteryModel: ObservableObject {
    static let shared = BatteryModel()
    @Published var battery = BatteryInfo()
    @Published var status: BatteryStatus?
    @Published var config = BatteryConfig()
    @Published var history: [Sample] = []
    @Published var taskLog: [TaskRecord] = []
    @Published var energyApps: [EnergyApp] = []
    @Published var helperState: SMAppService.Status = .notRegistered

    @AppStorage("battery.menu.icon") var menuIcon = true
    @AppStorage("battery.menu.percent") var menuPercent = true
    @AppStorage("battery.menu.watts") var menuWatts = false
    @AppStorage("battery.menu.time") var menuTime = false
    @AppStorage("battery.notify") var notify = true

    private var timer: Timer?
    private var slow: Timer?
    private var saving = false
    private var lastState = ""
    let service = SMAppService.daemon(plistName: "com.taru.tweaks.helper.plist")

    init() {
        helperState = service.status
        refresh(); loadHistory(); refreshEnergy()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        slow = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.loadHistory(); self?.refreshEnergy(); self?.beat()
        }
        beat()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var helperAlive: Bool { guard let s = status else { return false }; return Date().timeIntervalSince1970 - s.updated < 90 }
    var helperOutdated: Bool { (status?.helperVersion ?? 0) < HelperVersion }

    func beat() {
        let url = TweaksDir.appendingPathComponent("heartbeat")
        if FileManager.default.fileExists(atPath: TweaksDir.path) {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    private var upgrading = false
    func upgradeIfNeeded() {
        guard helperAlive, helperOutdated, !upgrading else { return }
        upgrading = true
        Task {
            try? await service.unregister()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? service.register()
            await MainActor.run { self.helperState = self.service.status; self.upgrading = false }
        }
    }

    func installHelper() {
        do { try service.register() } catch { NSLog("helper register: \(error)") }
        helperState = service.status
        if helperState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func refresh() {
        battery = readBatteryInfo()
        helperState = service.status
        if let d = try? Data(contentsOf: TweaksDir.appendingPathComponent("status.json")), let s = try? JSONDecoder().decode(BatteryStatus.self, from: d) {
            status = s
            upgradeIfNeeded()
            if s.state != lastState { if !lastState.isEmpty { announce(from: lastState, to: s) }; lastState = s.state }
        }
        if !saving, let d = try? Data(contentsOf: TweaksDir.appendingPathComponent("config.json")),
           let c = try? JSONDecoder().decode(BatteryConfig.self, from: d), c != config { config = c }
    }

    func update(_ change: (inout BatteryConfig) -> Void) {
        change(&config)
        saving = true
        let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
        if let d = try? e.encode(config) { try? d.write(to: TweaksDir.appendingPathComponent("config.json"), options: .atomic) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.saving = false }
    }

    func announce(from: String, to s: BatteryStatus) {
        guard notify else { return }
        var text: String?
        if s.state == "holding" && from == "charging" { text = "Charge limit reached at \(s.percent)%" }
        if s.state == "hot" { text = String(format: "Battery at %.1f °C. Charging paused until it cools.", s.temperature) }
        if from == "calibrating" && s.state != "calibrating" { text = "Calibration finished" }
        if from == "draining" && s.state != "draining" { text = "Discharge finished at \(s.percent)%" }
        guard let t = text else { return }
        let c = UNMutableNotificationContent(); c.title = "Battery"; c.body = t
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func loadHistory() {
        if let text = try? String(contentsOf: TweaksDir.appendingPathComponent("history.csv"), encoding: .utf8) {
            let cutoff = Date().timeIntervalSince1970 - 86400
            history = text.split(separator: "\n").compactMap { line in
                let p = line.split(separator: ",")
                guard p.count >= 4, let t = Double(p[0]), t >= cutoff, let pct = Int(p[1]), let temp = Double(p[2]), let w = Double(p[3]) else { return nil }
                return Sample(id: t, date: Date(timeIntervalSince1970: t), percent: pct, temperature: temp, watts: w)
            }
        }
        if let d = try? Data(contentsOf: TweaksDir.appendingPathComponent("tasks-history.json")) {
            taskLog = (try? JSONDecoder().decode([TaskRecord].self, from: d)) ?? []
        }
    }

    func refreshEnergy() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
            p.arguments = ["-l", "2", "-s", "1", "-n", "8", "-o", "power", "-stats", "command,power"]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let last = out.components(separatedBy: "COMMAND").last else { return }
            let apps: [EnergyApp] = last.split(separator: "\n").dropFirst().compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let v = Double(parts.last!), v >= 1 else { return nil }
                return EnergyApp(name: parts.dropLast().joined(separator: " "), impact: v)
            }
            DispatchQueue.main.async { self.energyApps = Array(apps.prefix(6)) }
        }
    }

    var menuSymbol: String {
        guard let s = status, helperAlive else { return battery.charging ? "bolt.fill" : "battery.75percent" }
        switch s.state {
        case "charging", "topup": return "bolt.fill"
        case "holding": return "pause.fill"
        case "sailing": return "sailboat.fill"
        case "draining": return "arrow.down.circle.fill"
        case "hot": return "thermometer.high"
        case "calibrating": return "arrow.triangle.2.circlepath"
        case "paused": return "pause.circle"
        default: return "drop.fill"
        }
    }

    var menuText: String {
        var parts: [String] = []
        if menuPercent { parts.append("\(battery.percent)%") }
        if menuWatts { parts.append(String(format: "%+.0fW", battery.batteryWatts)) }
        if menuTime { parts.append(minutes(battery.charging ? battery.timeToFull : battery.timeToEmpty)) }
        return parts.joined(separator: " ")
    }
}

func minutes(_ m: Int) -> String {
    guard m > 0, m < 6000 else { return "--" }
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

extension Font {
    static func term(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .monospaced) }
    static let label = Font.system(size: 10, weight: .medium, design: .monospaced)
}
