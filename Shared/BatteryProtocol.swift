import Foundation

let TweaksDir = URL(fileURLWithPath: "/Library/Application Support/TaruTweaks")

struct ScheduledTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var action = "limit"
    var value = 80
    var hour = 22
    var minute = 0
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var lastRun: Double = 0

    var title: String {
        switch action {
        case "limit": return "Set charge limit to \(value)%"
        case "topup": return "Top up to 100%"
        case "drain": return "Discharge to \(value)%"
        case "calibrate": return "Start calibration"
        case "pause": return "Pause charging"
        case "resume": return "Resume charging"
        case "lowpower": return value == 1 ? "Low Power Mode on" : "Low Power Mode off"
        default: return action
        }
    }
}

struct TaskRecord: Codable, Identifiable {
    var id = UUID()
    var date: Double
    var title: String
}

struct BatteryConfig: Codable, Equatable {
    var enabled = true
    var mode = "limit"
    var limit = 80
    var sailFloor = 70
    var drainTarget = 80
    var autoDischarge = false
    var paused = false
    var heatProtection = true
    var heatMax = 35.0
    var stopWhenAsleep = true
    var keepWhenAppClosed = true
    var preventSleepUntilLimit = false
    var clamshellDischarge = false
    var ledMode = "system"
    var calibrationMonthly = true
    var calibrationDays = 30
    var calibrateNow = false
    var lastCalibration: Double = 0
    var powerMode = "unchanged"
    var tasks: [ScheduledTask] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BatteryConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        enabled = v(.enabled, d.enabled); mode = v(.mode, d.mode); limit = v(.limit, d.limit); sailFloor = v(.sailFloor, d.sailFloor)
        drainTarget = v(.drainTarget, d.drainTarget); autoDischarge = v(.autoDischarge, d.autoDischarge); paused = v(.paused, d.paused)
        heatProtection = v(.heatProtection, d.heatProtection); heatMax = v(.heatMax, d.heatMax); stopWhenAsleep = v(.stopWhenAsleep, d.stopWhenAsleep)
        keepWhenAppClosed = v(.keepWhenAppClosed, d.keepWhenAppClosed); preventSleepUntilLimit = v(.preventSleepUntilLimit, d.preventSleepUntilLimit)
        clamshellDischarge = v(.clamshellDischarge, d.clamshellDischarge); ledMode = v(.ledMode, d.ledMode)
        calibrationMonthly = v(.calibrationMonthly, d.calibrationMonthly); calibrationDays = v(.calibrationDays, d.calibrationDays)
        calibrateNow = v(.calibrateNow, d.calibrateNow); lastCalibration = v(.lastCalibration, d.lastCalibration)
        powerMode = v(.powerMode, d.powerMode); tasks = v(.tasks, d.tasks)
    }
}

struct BatteryStatus: Codable {
    var updated: Double
    var percent: Int
    var plugged: Bool
    var charging: Bool
    var chargeInhibited: Bool
    var adapterInhibited: Bool
    var temperature: Double
    var reason: String
    var state: String
    var calibrationPhase: String
    var nextCalibration: Double
    var helperVersion: Int
}

let HelperVersion = 4
