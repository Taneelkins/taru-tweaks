import SwiftUI
import Charts
import AppKit

struct TaskManagerView: View {
    @State var tab = "processes"
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("TASK MANAGER").font(.system(size: 16, weight: .heavy, design: .monospaced)).tracking(3).foregroundStyle(theme.accent)
                ForEach([("processes", "Processes"), ("performance", "Performance"), ("startup", "Startup apps")], id: \.0) { t in
                    Button { tab = t.0 } label: {
                        VStack(spacing: 4) {
                            Text(t.1.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(tab == t.0 ? Palette.bone : Palette.ash)
                            Rectangle().fill(tab == t.0 ? theme.accent : .clear).frame(height: 2)
                        }.fixedSize()
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 10).background(Color.black)
            Rectangle().fill(Palette.rule).frame(height: 1)
            Group {
                switch tab {
                case "performance": PerformanceTab()
                case "startup": StartupTab()
                default: ProcessesTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.pit)
        }
        .frame(minWidth: 820, minHeight: 560)
        .preferredColorScheme(.dark)
        .tint(theme.accent)
        .onAppear { ProcessStore.shared.start(); PerfStore.shared.start() }
        .onDisappear { ProcessStore.shared.stop(); PerfStore.shared.stop() }
    }
}

struct ProcessesTab: View {
    @ObservedObject var store = ProcessStore.shared
    @ObservedObject var theme = Theme.shared
    @State var query = ""
    @State var sort = "cpu"
    @State var selected: pid_t?
    @State var expanded: Set<pid_t> = []

    func sorted(_ rows: [ProcRow]) -> [ProcRow] {
        let f = query.isEmpty ? rows : rows.filter { $0.name.localizedCaseInsensitiveContains(query) || "\($0.id)".contains(query) }
        switch sort {
        case "name": return f.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "memory": return f.sorted { $0.groupMemory > $1.groupMemory }
        case "pid": return f.sorted { $0.id < $1.id }
        default: return f.sorted { $0.groupCPU > $1.groupCPU }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.ash)
                TextField("Search by name or PID", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                Spacer()
                Text("\(store.apps.count) apps · \(store.background.count) background · \(store.hiddenSystemCount) system").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash)
            }.padding(.horizontal, 16).padding(.vertical, 9)
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    group("APPS (\(store.apps.count))")
                    ForEach(sorted(store.apps)) { r in
                        row(r, depth: 0)
                        if expanded.contains(r.id) {
                            ForEach(r.children.compactMap { c in store.background.first { $0.id == c } ?? allRows.first { $0.id == c } }) { c in row(c, depth: 1) }
                        }
                    }
                    group("BACKGROUND PROCESSES (\(store.background.count))")
                    ForEach(sorted(store.background)) { r in row(r, depth: 0) }
                }
            }
            HStack {
                Spacer()
                if let pid = selected, let r = (store.apps + store.background).first(where: { $0.id == pid }) {
                    Text(r.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ash)
                    TweakButton(title: "End task") { store.end(r.id, force: false, tree: r.isApp, children: r.children) }
                    TweakButton(title: "Force quit") { store.end(r.id, force: true, tree: r.isApp, children: r.children) }
                }
            }.padding(12).background(Color.black)
        }
    }

    var allRows: [ProcRow] { store.apps + store.background }

    var header: some View {
        HStack(spacing: 0) {
            col("Name", "name").frame(maxWidth: .infinity, alignment: .leading)
            Text("STATUS").frame(width: 110, alignment: .leading)
            col("CPU", "cpu").frame(width: 80, alignment: .trailing)
            col("Memory", "memory").frame(width: 100, alignment: .trailing)
            Text("THREADS").frame(width: 70, alignment: .trailing)
            col("PID", "pid").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
        .padding(.horizontal, 16).padding(.vertical, 6).background(Color.black.opacity(0.5))
    }

    func col(_ t: String, _ key: String) -> some View {
        Button { sort = key } label: { Text(t.uppercased() + (sort == key ? " ▾" : "")).foregroundStyle(sort == key ? theme.accent : Palette.ash) }.buttonStyle(.plain)
    }

    func group(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    func heat(_ v: Double, _ max: Double) -> Color { theme.accent.opacity(min(0.55, v / max * 0.55)) }

    func row(_ r: ProcRow, depth: Int) -> some View {
        let cpu = depth == 0 ? r.groupCPU : r.cpu
        let mem = depth == 0 ? r.groupMemory : r.memory
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                if depth == 0 && !r.children.isEmpty {
                    Button { if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) } } label: {
                        Image(systemName: expanded.contains(r.id) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.ash).frame(width: 12)
                    }.buttonStyle(.plain)
                } else { Spacer().frame(width: 12 + CGFloat(depth) * 14) }
                Image(nsImage: NSWorkspace.shared.icon(forFile: r.isApp ? (r.path.components(separatedBy: ".app/").first.map { $0 + ".app" } ?? r.path) : r.path)).resizable().frame(width: 18, height: 18)
                Text(r.name).font(.system(size: 12.5)).foregroundStyle(Palette.bone).lineLimit(1)
                if depth == 0 && !r.children.isEmpty { Text("(\(r.children.count + 1))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(r.notResponding ? "Not responding" : "").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent).frame(width: 110, alignment: .leading)
            Text(String(format: "%.1f%%", cpu / ProcessStore.shared.cores)).frame(width: 80, alignment: .trailing).background(heat(cpu / ProcessStore.shared.cores, 50))
            Text(bytes(mem)).frame(width: 100, alignment: .trailing).background(heat(Double(mem), 4e9))
            Text("\(r.threads)").frame(width: 70, alignment: .trailing)
            Text("\(r.id)").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.bone)
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(selected == r.id ? theme.accent.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = r.id }
        .contextMenu {
            Button("End task") { ProcessStore.shared.end(r.id, force: false) }
            Button("Force quit") { ProcessStore.shared.end(r.id, force: true) }
            if !r.children.isEmpty { Button("End process tree") { ProcessStore.shared.end(r.id, force: true, tree: true, children: r.children) } }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            Button("Copy PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(r.id)", forType: .string) }
        }
    }
}

struct Spark: View {
    let values: [Double]
    let maxValue: Double?
    @ObservedObject var theme = Theme.shared
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(theme.accent.opacity(0.18))
            LineMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(theme.accent)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...(maxValue ?? max(1, (values.max() ?? 1) * 1.2)))
        .chartXScale(domain: 0...59)
    }
}

struct PerformanceTab: View {
    @ObservedObject var p = PerfStore.shared
    @State var metric = "cpu"
    @ObservedObject var theme = Theme.shared

    var metrics: [(String, String, String, [Double], Double?)] {[
        ("cpu", "CPU", String(format: "%.0f%%", p.cpu.last ?? 0), p.cpu, 100),
        ("memory", "Memory", String(format: "%@ / %@", bytes(UInt64(p.memUsed)), bytes(UInt64(p.memTotal))), p.memHistory, 100),
        ("gpu", "GPU", String(format: "%.0f%%", p.gpu.last ?? 0), p.gpu, 100),
        ("net", "Network", "↓ \(rate(p.netIn.last ?? 0))  ↑ \(rate(p.netOut.last ?? 0))", p.netIn, nil),
        ("disk", "Disk", "R \(rate(p.diskRead.last ?? 0))  W \(rate(p.diskWrite.last ?? 0))", p.diskRead, nil)
    ]}

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                ForEach(metrics, id: \.0) { m in
                    Button { metric = m.0 } label: {
                        HStack(spacing: 10) {
                            Spark(values: m.3, maxValue: m.4).frame(width: 70, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.1.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(metric == m.0 ? theme.accent : Palette.bone)
                                Text(m.2).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(10).background(metric == m.0 ? theme.accent.opacity(0.12) : Color.black.opacity(0.3)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.frame(width: 260)
            Rectangle().fill(Palette.rule).frame(width: 1)
            VStack(alignment: .leading, spacing: 14) {
                let m = metrics.first { $0.0 == metric }!
                HStack(alignment: .firstTextBaseline) {
                    Text(m.1.uppercased()).font(.system(size: 26, weight: .heavy, design: .monospaced)).foregroundStyle(theme.accent)
                    Spacer()
                    Text(m.2).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Palette.bone)
                }
                Spark(values: m.3, maxValue: m.4).frame(height: 220).padding(8).overlay(Rectangle().stroke(Palette.rule))
                if metric == "net" { Text("UPLOAD").font(.label).foregroundStyle(Palette.ash); Spark(values: p.netOut, maxValue: nil).frame(height: 90) }
                if metric == "disk" { Text("WRITE").font(.label).foregroundStyle(Palette.ash); Spark(values: p.diskWrite, maxValue: nil).frame(height: 90) }
                if metric == "cpu" {
                    Text("CORES").font(.label).foregroundStyle(Palette.ash)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(Array(p.cores.enumerated()), id: \.offset) { i, v in
                            VStack(spacing: 3) {
                                GeometryReader { g in
                                    ZStack(alignment: .bottom) { Rectangle().fill(Palette.rule); Rectangle().fill(theme.accent).frame(height: g.size.height * v / 100) }
                                }.frame(height: 46)
                                Text("\(i + 1) · \(Int(v))%").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ash)
                            }
                        }
                    }
                }
                Text("UP \(Duration.seconds(p.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))").font(.label).foregroundStyle(Palette.ash)
                Spacer()
            }.padding(20)
        }
    }
}

struct StartupTab: View {
    @ObservedObject var store = StartupStore.shared
    @ObservedObject var theme = Theme.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Apps and agents that start when you log in.").font(.system(size: 12)).foregroundStyle(Palette.ash)
                    Spacer()
                    TweakButton(title: "Login Items settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }.padding(.bottom, 10)
                ForEach(["login", "agent", "system agent", "daemon"], id: \.self) { kind in
                    let rows = store.items.filter { $0.kind == kind }
                    if !rows.isEmpty {
                        SectionLabel(text: ["login": "Login items", "agent": "Your background agents", "system agent": "System-wide agents (read-only)", "daemon": "Daemons (read-only)"][kind]!)
                        ForEach(rows) { item in
                            SettingRow(title: item.name, detail: item.path) {
                                if item.editable { Switch(on: Binding(get: { item.enabled }, set: { store.set(item, enabled: $0) })) }
                                else { Text(item.enabled ? "ON" : "OFF").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(item.enabled ? theme.accent : Palette.ash) }
                            }
                        }
                    }
                }
            }.padding(20)
        }
        .onAppear { store.reload() }
    }
}
