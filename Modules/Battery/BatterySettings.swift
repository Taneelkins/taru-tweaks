import SwiftUI
import ServiceManagement

struct BatterySettings: View {
    let page: String
    @ObservedObject var model = BatteryModel.shared
    @ObservedObject var theme = Theme.shared

    func bind<T>(_ kp: WritableKeyPath<BatteryConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }

    var body: some View {
        switch page {
        case "battery.charging": charging
        case "battery.protection": protection
        case "battery.automation": automation
        default: display
        }
    }

    var helperRow: some View {
        SettingRow(title: "Charging helper", detail: helperText) {
            if model.helperAlive && !model.helperOutdated { Text("RUNNING").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent) }
            else { TweakButton(title: model.helperState == .requiresApproval ? "Approve" : "Install") { model.installHelper() } }
        }
    }

    var helperText: String {
        if model.helperAlive && !model.helperOutdated { return "Controls charging in the background, even when Taru Tweaks is closed" }
        switch model.helperState {
        case .requiresApproval: return "Waiting for approval: System Settings → General → Login Items → allow Taru Tweaks"
        case .enabled: return "Starting…"
        default: return "Needed for everything on this page. Installs once; macOS asks you to approve it."
        }
    }

    var charging: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Charging", subtitle: "Everything AlDente Pro does, running on your M5's newer charge controls.")
            helperRow
            SettingRow(title: "Battery control", detail: "Off hands charging back to macOS") { Switch(on: bind(\.enabled)) }
            SettingRow(title: "Mode") { Seg(options: [("Limit", "limit"), ("Sail", "sail"), ("Discharge", "drain"), ("Top up", "topup")], value: bind(\.mode)) }
            SettingRow(title: "Charge limit", detail: "\(model.config.limit)%") {
                Slider(value: Binding(get: { Double(model.config.limit) }, set: { v in model.update { $0.limit = Int(v) } }), in: 20...100, step: 1).frame(width: 220)
            }
            SettingRow(title: "Sailing range", detail: "Drifts down to \(model.config.sailFloor)% before charging back to the limit. Fewer micro-cycles.") {
                Slider(value: Binding(get: { Double(model.config.sailFloor) }, set: { v in model.update { $0.sailFloor = min(Int(v), $0.limit - 2) } }), in: 20...98, step: 1).frame(width: 220)
            }
            SettingRow(title: "Discharge target", detail: "\(model.config.drainTarget)% · used by Discharge mode") {
                Slider(value: Binding(get: { Double(model.config.drainTarget) }, set: { v in model.update { $0.drainTarget = Int(v) } }), in: 15...95, step: 1).frame(width: 220)
            }
            SettingRow(title: "Automatic discharge", detail: "If the limit is below the current level, run on battery down to it") { Switch(on: bind(\.autoDischarge)) }
            SettingRow(title: "Pause charging") { Switch(on: bind(\.paused)) }
            SettingRow(title: "Keep the limit when Taru Tweaks is closed", detail: "Off: macOS charges normally whenever the app isn't running") { Switch(on: bind(\.keepWhenAppClosed)) }
        }
    }

    var protection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Protection", subtitle: "Heat, sleep and calibration.")
            SettingRow(title: "Heat protection", detail: "Pause charging above \(Int(model.config.heatMax)) °C, resume 3 °C below") {
                HStack { Slider(value: bind(\.heatMax), in: 30...45, step: 1).frame(width: 160); Switch(on: bind(\.heatProtection)) }
            }
            SettingRow(title: "Stop charging when asleep", detail: "Never creeps past the limit overnight") { Switch(on: bind(\.stopWhenAsleep)) }
            SettingRow(title: "Stay awake until the limit is reached", detail: "Blocks idle sleep while charging up to the limit") { Switch(on: bind(\.preventSleepUntilLimit)) }
            SettingRow(title: "Clamshell support", detail: "Keeps the Mac awake with the lid closed while discharging") { Switch(on: bind(\.clamshellDischarge)) }
            SettingRow(title: "MagSafe LED") { Seg(options: [("macOS", "system"), ("Smart", "smart"), ("Off", "off")], value: bind(\.ledMode)) }
            SectionLabel(text: "Calibration")
            SettingRow(title: "Automatic calibration", detail: "15% → 100% → hold 1 h → back to the limit") { Switch(on: bind(\.calibrationMonthly)) }
            SettingRow(title: "Every", detail: "\(model.config.calibrationDays) days") { Stepper("", value: bind(\.calibrationDays), in: 7...90, step: 1).labelsHidden() }
            SettingRow(title: "Calibrate now") { TweakButton(title: "Start") { model.update { $0.calibrateNow = true } } }
        }
    }

    var automation: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Automation", subtitle: "Scheduled tasks run by the helper, even when the app is closed. Apple Shortcuts actions are under Taru Tweaks in the Shortcuts app.")
            SettingRow(title: "Power mode", detail: "Applied by the helper") { Seg(options: [("Leave", "unchanged"), ("Automatic", "auto"), ("Low Power", "low"), ("High Power", "high")], value: bind(\.powerMode)) }
            SectionLabel(text: "Schedule")
            ForEach(model.config.tasks) { t in
                TaskRow(task: t)
            }
            HStack {
                TweakButton(title: "Add task") { model.update { $0.tasks.append(ScheduledTask()) } }
                TweakButton(title: "Monthly calibration template") { model.update { var t = ScheduledTask(); t.action = "calibrate"; t.hour = 10; t.weekdays = [7]; $0.tasks.append(t) } }
            }.padding(.top, 10)
            SectionLabel(text: "History")
            if model.taskLog.isEmpty { Text("Nothing has run yet.").font(.system(size: 12)).foregroundStyle(Palette.ash) }
            ForEach(model.taskLog.prefix(12)) { r in
                HStack { Text(r.title).font(.system(size: 12)).foregroundStyle(Palette.bone); Spacer(); Text(Date(timeIntervalSince1970: r.date).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash) }.padding(.vertical, 3)
            }
        }
    }

    var display: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Display", subtitle: "Menu bar item, notifications and the dashboard.")
            SettingRow(title: "Show in the menu bar") { Switch(on: MenuItems.shared.binding(\.battery, "battery.menu.show")) }
            SettingRow(title: "Live status icon", detail: "Charging · holding · sailing · draining · hot · calibrating") { Switch(on: $model.menuIcon) }
            SettingRow(title: "Percentage") { Switch(on: $model.menuPercent) }
            SettingRow(title: "Watts in/out") { Switch(on: $model.menuWatts) }
            SettingRow(title: "Time to full / empty") { Switch(on: $model.menuTime) }
            SettingRow(title: "Notifications", detail: "Limit reached, too hot, calibration and discharge finished") { Switch(on: $model.notify) }
            SectionLabel(text: "Dashboard")
            BatteryDashboard().frame(maxWidth: .infinity)
        }
    }
}

struct TaskRow: View {
    let task: ScheduledTask
    @ObservedObject var model = BatteryModel.shared
    let days = ["S", "M", "T", "W", "T", "F", "S"]

    func set(_ change: @escaping (inout ScheduledTask) -> Void) {
        model.update { c in if let i = c.tasks.firstIndex(where: { $0.id == task.id }) { change(&c.tasks[i]) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { task.enabled }, set: { v in set { $0.enabled = v } })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                Picker("", selection: Binding(get: { task.action }, set: { v in set { $0.action = v } })) {
                    Text("Set limit").tag("limit"); Text("Top up").tag("topup"); Text("Discharge to").tag("drain"); Text("Calibrate").tag("calibrate")
                    Text("Pause charging").tag("pause"); Text("Resume charging").tag("resume"); Text("Low Power Mode").tag("lowpower")
                }.labelsHidden().frame(width: 150)
                if ["limit", "drain"].contains(task.action) {
                    Stepper("\(task.value)%", value: Binding(get: { task.value }, set: { v in set { $0.value = v } }), in: 20...100, step: 5).font(.system(size: 12, design: .monospaced)).frame(width: 90)
                }
                if task.action == "lowpower" {
                    Picker("", selection: Binding(get: { task.value }, set: { v in set { $0.value = v } })) { Text("On").tag(1); Text("Off").tag(0) }.labelsHidden().frame(width: 70)
                }
                DatePicker("", selection: Binding(get: {
                    Calendar.current.date(bySettingHour: task.hour, minute: task.minute, second: 0, of: Date()) ?? Date()
                }, set: { d in let c = Calendar.current.dateComponents([.hour, .minute], from: d); set { $0.hour = c.hour ?? 0; $0.minute = c.minute ?? 0 } }), displayedComponents: .hourAndMinute).labelsHidden().frame(width: 90)
                HStack(spacing: 2) {
                    ForEach(1...7, id: \.self) { d in
                        Button { set { t in if t.weekdays.contains(d) { t.weekdays.removeAll { $0 == d } } else { t.weekdays.append(d) } } } label: {
                            Text(days[d - 1]).font(.system(size: 10, weight: .bold, design: .monospaced)).frame(width: 18, height: 18)
                                .foregroundStyle(task.weekdays.contains(d) ? Color.black : Palette.ash)
                                .background(task.weekdays.contains(d) ? Theme.shared.accent : Color.black)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Button { model.update { $0.tasks.removeAll { $0.id == task.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Palette.ash)
            }.padding(.vertical, 8)
            Rectangle().fill(Palette.rule).frame(height: 1)
        }
    }
}
