import AppIntents
import Foundation

private func edit(_ change: (inout BatteryConfig) -> Void) {
    let url = TweaksDir.appendingPathComponent("config.json")
    var c = (try? JSONDecoder().decode(BatteryConfig.self, from: Data(contentsOf: url))) ?? BatteryConfig()
    change(&c)
    if let d = try? JSONEncoder().encode(c) { try? d.write(to: url, options: .atomic) }
}

private func status() -> BatteryStatus? {
    try? JSONDecoder().decode(BatteryStatus.self, from: Data(contentsOf: TweaksDir.appendingPathComponent("status.json")))
}

struct SetChargeLimit: AppIntent {
    static var title: LocalizedStringResource = "Set Charge Limit"
    @Parameter(title: "Limit (%)", inclusiveRange: (20, 100)) var limit: Int
    func perform() async throws -> some IntentResult { edit { $0.limit = limit; $0.mode = "limit" }; return .result() }
}

struct GetChargeLimit: AppIntent {
    static var title: LocalizedStringResource = "Get Charge Limit"
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let c = (try? JSONDecoder().decode(BatteryConfig.self, from: Data(contentsOf: TweaksDir.appendingPathComponent("config.json")))) ?? BatteryConfig()
        return .result(value: c.limit)
    }
}

struct TopUp: AppIntent {
    static var title: LocalizedStringResource = "Top Up Battery to 100%"
    func perform() async throws -> some IntentResult { edit { $0.mode = "topup" }; return .result() }
}

struct PauseCharging: AppIntent {
    static var title: LocalizedStringResource = "Pause Charging"
    @Parameter(title: "Paused", default: true) var paused: Bool
    func perform() async throws -> some IntentResult { edit { $0.paused = paused }; return .result() }
}

struct StartDischarge: AppIntent {
    static var title: LocalizedStringResource = "Start Discharge"
    @Parameter(title: "Down to (%)", default: 80, inclusiveRange: (15, 95)) var target: Int
    func perform() async throws -> some IntentResult { edit { $0.mode = "drain"; $0.drainTarget = target }; return .result() }
}

struct StartCalibration: AppIntent {
    static var title: LocalizedStringResource = "Start Battery Calibration"
    func perform() async throws -> some IntentResult { edit { $0.calibrateNow = true }; return .result() }
}

enum LEDMode: String, AppEnum {
    case system, smart, off
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "MagSafe LED"
    static var caseDisplayRepresentations: [LEDMode: DisplayRepresentation] = [.system: "macOS", .smart: "Smart", .off: "Off"]
}

struct SetMagSafeLED: AppIntent {
    static var title: LocalizedStringResource = "Set MagSafe LED"
    @Parameter(title: "Mode") var mode: LEDMode
    func perform() async throws -> some IntentResult { edit { $0.ledMode = mode.rawValue }; return .result() }
}

enum PowerModeOption: String, AppEnum {
    case auto, low, high
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Power Mode"
    static var caseDisplayRepresentations: [PowerModeOption: DisplayRepresentation] = [.auto: "Automatic", .low: "Low Power", .high: "High Power"]
}

struct SetPowerMode: AppIntent {
    static var title: LocalizedStringResource = "Set Power Mode"
    @Parameter(title: "Mode") var mode: PowerModeOption
    func perform() async throws -> some IntentResult { edit { $0.powerMode = mode.rawValue }; return .result() }
}

struct GetBatteryPercentage: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Percentage"
    func perform() async throws -> some IntentResult & ReturnsValue<Int> { .result(value: readBatteryInfo().percent) }
}

struct GetBatteryTemperature: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Temperature"
    func perform() async throws -> some IntentResult & ReturnsValue<Double> { .result(value: readBatteryInfo().temperature) }
}

struct GetBatteryState: AppIntent {
    static var title: LocalizedStringResource = "Get Battery State"
    func perform() async throws -> some IntentResult & ReturnsValue<String> { .result(value: status()?.state ?? "unknown") }
}

struct ToggleXDRBoost: AppIntent {
    static var title: LocalizedStringResource = "Toggle XDR Boost"
    @MainActor func perform() async throws -> some IntentResult { Brightness.shared.on.toggle(); return .result() }
}

struct ShowDesktop: AppIntent {
    static var title: LocalizedStringResource = "Show Desktop"
    @MainActor func perform() async throws -> some IntentResult { WindowEngine.shared.toggleShowDesktop(); return .result() }
}
