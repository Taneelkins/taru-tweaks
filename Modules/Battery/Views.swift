import SwiftUI
import Charts
import ServiceManagement

struct ChargeBar: View {
    let percent: Int
    let limit: Int
    let floor: Int?
    @ObservedObject var theme = Theme.shared
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().stroke(theme.accent, lineWidth: 1)
                if let f = floor {
                    Rectangle().fill(Palette.bone.opacity(0.14)).frame(width: g.size.width * CGFloat(limit - f) / 100).offset(x: g.size.width * CGFloat(f) / 100)
                }
                Rectangle().fill(theme.accent).shadow(color: theme.accent, radius: 6)
                    .frame(width: max(0, (g.size.width - 4) * CGFloat(percent) / 100)).padding(2)
                Rectangle().fill(Palette.bone).frame(width: 2, height: g.size.height + 8).offset(x: g.size.width * CGFloat(limit) / 100 - 1)
            }
        }.frame(height: 16)
    }
}

struct MiniToggle: View {
    let title: String
    let detail: String
    @Binding var on: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
                Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
            }
            Spacer()
            Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

struct BatteryMenuView: View {
    @ObservedObject var model = BatteryModel.shared
    @ObservedObject var theme = Theme.shared
    let openDashboard: () -> Void
    let openSettings: () -> Void

    var body: some View {
        let b = model.battery
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(b.percent)%").font(.term(54)).foregroundStyle(theme.accent).shadow(color: theme.accent.opacity(0.6), radius: 8)
                    Text(String(format: "HARDWARE %.1f%%", b.hardwarePercent)).font(.label).foregroundStyle(Palette.ash)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text((model.status?.state ?? (b.charging ? "charging" : "battery")).uppercased()).font(.label).foregroundStyle(theme.accent)
                    Text(model.status?.reason ?? "helper not running").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.bone)
                    Text(b.charging ? "\(minutes(b.timeToFull)) to full" : (b.plugged ? String(format: "%.1f °C", b.temperature) : "\(minutes(b.timeToEmpty)) left"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
                }
            }
            ChargeBar(percent: b.percent, limit: model.config.limit, floor: model.config.mode == "sail" ? model.config.sailFloor : nil)
            HStack(spacing: 6) {
                ForEach([("limit", "LIMIT"), ("sail", "SAIL"), ("drain", "DRAIN"), ("topup", "TOP UP")], id: \.0) { m in
                    Button { model.update { $0.mode = m.0; if m.0 == "drain" { $0.drainTarget = $0.limit } } } label: {
                        Text(m.1).font(.label).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .foregroundStyle(model.config.mode == m.0 ? Color.black : Palette.ash)
                            .background(model.config.mode == m.0 ? theme.accent : Color.clear)
                            .overlay(Rectangle().stroke(model.config.mode == m.0 ? theme.accent : Palette.rule))
                    }.buttonStyle(.plain)
                }
            }
            HStack { Text("Charge limit").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone); Spacer(); Text("\(model.config.limit)%").font(.label).foregroundStyle(Palette.ash) }
            Slider(value: Binding(get: { Double(model.config.limit) }, set: { v in model.update { $0.limit = Int(v); if $0.sailFloor >= $0.limit { $0.sailFloor = $0.limit - 5 } } }), in: 50...100, step: 5)
            if model.config.mode == "sail" {
                HStack { Text("Sail down to").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone); Spacer(); Text("\(model.config.sailFloor)%").font(.label).foregroundStyle(Palette.ash) }
                Slider(value: Binding(get: { Double(model.config.sailFloor) }, set: { v in model.update { $0.sailFloor = min(Int(v), $0.limit - 5) } }), in: 40...95, step: 5)
            }
            Rectangle().fill(Palette.rule).frame(height: 1)
            MiniToggle(title: "Pause charging", detail: "Hold the current level", on: Binding(get: { model.config.paused }, set: { v in model.update { $0.paused = v } }))
            MiniToggle(title: "Heat protection", detail: "Pause above \(Int(model.config.heatMax)) °C", on: Binding(get: { model.config.heatProtection }, set: { v in model.update { $0.heatProtection = v } }))
            MiniToggle(title: "Low Power Mode", detail: "macOS power saving", on: Binding(get: { model.config.powerMode == "low" }, set: { v in model.update { $0.powerMode = v ? "low" : "auto" } }))
            HStack(spacing: 8) {
                TweakButton(title: "Dashboard", action: openDashboard)
                TweakButton(title: "Settings", action: openSettings)
            }
            if !model.helperAlive {
                Button { model.installHelper() } label: {
                    Text(model.helperState == .requiresApproval ? "APPROVE THE HELPER IN LOGIN ITEMS" : "INSTALL CHARGING HELPER").font(.label).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(Color.black).background(theme.accent)
                }.buttonStyle(.plain)
            }
        }
        .padding(16).frame(width: 320).background(Palette.pit).tint(theme.accent)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.label).tracking(1.6).foregroundStyle(Palette.ash)
            content
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.pit)
    }
}

struct KV: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.system(size: 12.5)).foregroundStyle(Palette.ash)
                    Spacer()
                    Text(r.1).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.bone)
                }
            }
        }
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var color: Color = Palette.bone
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.term(36)).foregroundStyle(color)
            Text(unit).font(.term(15)).foregroundStyle(Palette.ash)
        }
    }
}

struct PowerSankey: View {
    let b: BatteryInfo
    @ObservedObject var theme = Theme.shared
    var body: some View {
        Canvas { ctx, size in
            let wall = b.plugged ? max(b.wallWatts, 0.1) : 0
            let intoBattery = max(0, b.batteryWatts)
            let fromBattery = max(0, -b.batteryWatts)
            let system = b.systemWatts
            let loss = b.efficiencyLoss
            let total = max(wall + fromBattery, 1)
            let h = size.height - 24, unit = h / total
            let lx: CGFloat = 70, rx = size.width - 110
            func band(_ y0: CGFloat, _ hh: CGFloat, _ y1: CGFloat, _ color: Color) {
                guard hh > 0.5 else { return }
                var p = Path()
                p.move(to: CGPoint(x: lx, y: y0))
                p.addCurve(to: CGPoint(x: rx, y: y1), control1: CGPoint(x: (lx + rx) / 2, y: y0), control2: CGPoint(x: (lx + rx) / 2, y: y1))
                p.addLine(to: CGPoint(x: rx, y: y1 + hh))
                p.addCurve(to: CGPoint(x: lx, y: y0 + hh), control1: CGPoint(x: (lx + rx) / 2, y: y1 + hh), control2: CGPoint(x: (lx + rx) / 2, y: y0 + hh))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
            var leftY: CGFloat = 12
            var rightY: CGFloat = 12
            let gap: CGFloat = 10
            let src: [(String, Double, Color)] = [("WALL", wall, theme.accent.opacity(0.55)), ("BATTERY", fromBattery, Palette.bone.opacity(0.45))]
            let dst: [(String, Double)] = [("SYSTEM", system), ("INTO BATTERY", intoBattery), ("ADAPTER LOSS", loss)]
            var flows: [(Int, Int, Double)] = []
            if wall > 0 {
                flows.append((0, 0, max(0, system - fromBattery))); flows.append((0, 1, intoBattery)); flows.append((0, 2, loss))
            }
            if fromBattery > 0 { flows.append((1, 0, fromBattery)) }
            var srcY: [CGFloat] = [], dstY: [CGFloat] = []
            for s in src { srcY.append(leftY); if s.1 > 0 { leftY += CGFloat(s.1) * unit + gap } }
            for d in dst { dstY.append(rightY); if d.1 > 0.05 { rightY += CGFloat(d.1) * unit + gap } }
            var srcOff = srcY, dstOff = dstY
            for f in flows where f.2 > 0.05 {
                let hh = CGFloat(f.2) * unit
                band(srcOff[f.0], hh, dstOff[f.1], src[f.0].2)
                srcOff[f.0] += hh; dstOff[f.1] += hh
            }
            for (i, s) in src.enumerated() where s.1 > 0 {
                ctx.fill(Path(CGRect(x: lx - 6, y: srcY[i], width: 6, height: CGFloat(s.1) * unit)), with: .color(theme.accent))
                ctx.draw(Text("\(s.0)\n\(String(format: "%.1f W", s.1))").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(Palette.bone), at: CGPoint(x: lx - 12, y: srcY[i] + CGFloat(s.1) * unit / 2), anchor: .trailing)
            }
            for (i, d) in dst.enumerated() where d.1 > 0.05 {
                ctx.fill(Path(CGRect(x: rx, y: dstY[i], width: 6, height: max(2, CGFloat(d.1) * unit))), with: .color(i == 1 ? theme.accent : Palette.bone))
                ctx.draw(Text("\(d.0)\n\(String(format: "%.1f W", d.1))").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(i == 1 ? theme.accent : Palette.bone), at: CGPoint(x: rx + 12, y: dstY[i] + CGFloat(d.1) * unit / 2), anchor: .leading)
            }
        }
        .frame(height: 170)
    }
}

struct BatteryDashboard: View {
    @ObservedObject var model = BatteryModel.shared
    @ObservedObject var theme = Theme.shared

    var body: some View {
        let b = model.battery
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("BATTERY // DASHBOARD").font(.term(18)).tracking(2).foregroundStyle(theme.accent)
                Spacer()
                Text((model.status?.reason ?? "helper not running").uppercased()).font(.label).foregroundStyle(Palette.ash)
            }.padding(.horizontal, 16).padding(.vertical, 12).background(Color.black)
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    Card(title: "Battery health") {
                        BigNumber(value: String(format: "%.0f", b.health), unit: "%", color: theme.accent)
                        HStack(spacing: 3) { ForEach(0..<20, id: \.self) { i in Rectangle().fill(Double(i) < b.health / 5 ? theme.accent : Palette.rule).frame(height: 8) } }
                        KV(rows: [("Design", "\(b.designCapacity) mAh"), ("Real max", "\(b.rawMax) mAh"), ("macOS reports", String(format: "%.0f %%", b.macHealth)), ("Cycles", "\(b.cycles)")])
                    }
                    Card(title: "Battery specs") {
                        BigNumber(value: String(format: "%.1f", b.temperature), unit: "°C")
                        KV(rows: [("macOS / hardware", String(format: "%d%% / %.1f%%", b.percent, b.hardwarePercent)), ("Charge", "\(b.rawCurrent) mAh"), ("Voltage", String(format: "%.2f V", b.voltage)), ("Current", String(format: "%+.2f A", b.amperage)), ("Chip", b.chip)])
                    }
                    Card(title: "Power adapter") {
                        BigNumber(value: b.plugged ? "\(b.adapterWatts)" : "--", unit: "W")
                        KV(rows: [("Model", b.plugged ? b.adapterName : "unplugged"), ("Negotiated", b.plugged ? String(format: "%.1f V · %.2f A", b.adapterVolts, b.adapterAmps) : "--"), ("Firmware", b.plugged ? b.adapterFirmware : "--"), ("Efficiency loss", String(format: "%.1f W", b.efficiencyLoss))])
                    }
                }
                GridRow {
                    Card(title: "Power flow, live") { PowerSankey(b: b) }.gridCellColumns(2)
                    Card(title: "Calibration") {
                        KV(rows: [("Last run", day(model.config.lastCalibration)), ("Next", day(model.status?.nextCalibration ?? 0)), ("Phase", model.status?.calibrationPhase ?? "--")])
                        TweakButton(title: model.status?.calibrationPhase ?? "idle" == "idle" ? "Start now" : "Running") { model.update { $0.calibrateNow = true } }
                    }
                }
                GridRow {
                    Card(title: "Charge, last 24 h") { chargeChart }.gridCellColumns(2)
                    Card(title: "Temperature, 24 h") { tempChart }
                }
                GridRow {
                    Card(title: "Apps using significant energy") {
                        if model.energyApps.isEmpty { Text("Nothing heavy right now").font(.system(size: 12)).foregroundStyle(Palette.ash) }
                        ForEach(model.energyApps) { a in
                            HStack { Text(a.name).font(.system(size: 12.5)).foregroundStyle(Palette.bone).lineLimit(1); Spacer(); Text(String(format: "%.1f", a.impact)).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.accent) }
                        }
                    }.gridCellColumns(2)
                    Card(title: "Task history") {
                        if model.taskLog.isEmpty { Text("No scheduled tasks have run yet").font(.system(size: 12)).foregroundStyle(Palette.ash) }
                        ForEach(model.taskLog.prefix(6)) { t in
                            HStack { Text(t.title).font(.system(size: 12)).foregroundStyle(Palette.bone).lineLimit(1); Spacer(); Text(day(t.date, time: true)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash) }
                        }
                    }
                }
            }.background(Palette.rule)
        }
        .background(Color.black)
    }

    func day(_ t: Double, time: Bool = false) -> String {
        guard t > 0 else { return "never" }
        let f = DateFormatter(); f.dateFormat = time ? "d MMM HH:mm" : "d MMM"; return f.string(from: Date(timeIntervalSince1970: t))
    }

    @ViewBuilder var chargeChart: some View {
        if model.history.count < 2 {
            Text("Collecting, one point a minute.").font(.system(size: 12)).foregroundStyle(Palette.ash).frame(height: 150)
        } else {
            Chart(model.history) { s in
                AreaMark(x: .value("Time", s.date), y: .value("%", s.percent)).foregroundStyle(theme.accent.opacity(0.15))
                LineMark(x: .value("Time", s.date), y: .value("%", s.percent)).foregroundStyle(theme.accent)
                RuleMark(y: .value("Limit", model.config.limit)).foregroundStyle(Palette.bone.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }.chartYScale(domain: 0...100).frame(height: 150)
        }
    }

    @ViewBuilder var tempChart: some View {
        if model.history.count < 2 {
            Text("Collecting.").font(.system(size: 12)).foregroundStyle(Palette.ash).frame(height: 150)
        } else {
            Chart(model.history) { s in
                LineMark(x: .value("Time", s.date), y: .value("°C", s.temperature)).foregroundStyle(theme.accent)
                RuleMark(y: .value("Max", model.config.heatMax)).foregroundStyle(Palette.bone.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }.chartYScale(domain: 20...45).frame(height: 150)
        }
    }
}

struct DashboardWindow: View {
    var body: some View {
        ScrollView { BatteryDashboard() }.background(Color.black).frame(minWidth: 900, minHeight: 680).preferredColorScheme(.dark)
    }
}
