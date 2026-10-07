import SwiftUI
import AppKit

struct SwitcherView: View {
    @EnvironmentObject var s: Switcher
    @EnvironmentObject var prefs: SwitcherPrefs
    @ObservedObject var theme = Theme.shared

    static func tileWidth(_ prefs: SwitcherPrefs, count: Int, screen: CGFloat) -> CGFloat {
        switch Switcher.shared.style {
        case .titles: return 420
        case .icons:
            switch prefs.size { case .small: return 92; case .medium: return 120; case .large: return 150; case .auto: return count > 14 ? 96 : 124 }
        case .thumbs:
            switch prefs.size {
            case .small: return 180; case .medium: return 236; case .large: return 320
            case .auto:
                let perRow = Double(count) / Double(max(1, prefs.maxRows))
                let fit = (screen * prefs.maxWidth - 40) / max(1, ceil(perRow)) - 12
                return min(320, max(150, fit))
            }
        }
    }

    static func groupedWidth(visible: Int, expanded: Int, screen: CGRect, prefs: SwitcherPrefs) -> CGFloat {
        let maxW = screen.width * prefs.maxWidth - 40
        let maxH = screen.height * 0.86 - 70
        var w: CGFloat = prefs.size == .large ? 300 : prefs.size == .small ? 170 : 240
        while w > 110 {
            let card = w + 16 + 20
            let perRow = max(1, Int((maxW + 12) / (card + 12)))
            let rows = Int(ceil(Double(visible) / Double(perRow)))
            let h = CGFloat(rows) * (w * 0.62 + 46 + 28 + 20) + CGFloat(rows - 1) * 12
            let groupW = CGFloat(expanded) * (w + 16) + CGFloat(max(expanded - 1, 0)) * 10 + 20
            if h <= maxH && groupW <= maxW { break }
            w -= 10
        }
        return w
    }

    static func columns(count: Int, prefs: SwitcherPrefs, screen: CGFloat) -> Int {
        if Switcher.shared.style == .titles { return 1 }
        let w = tileWidth(prefs, count: count, screen: screen) + 12
        let maxCols = max(1, Int((screen * prefs.maxWidth - 40) / w))
        return max(1, min(count, maxCols))
    }

    var body: some View {
        let width = s.targetScreen.visibleFrame.width
        let tw = Self.tileWidth(prefs, count: s.windows.count, screen: width)
        let cols = Self.columns(count: s.windows.count, prefs: prefs, screen: width)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(s.shortcut?.appsOnly == true ? "APPS" : "SWITCH").font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(3).foregroundStyle(theme.accent)
                if s.searching || !s.query.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.accent)
                        Text(s.query.isEmpty ? "type to search" : s.query).foregroundStyle(s.query.isEmpty ? Palette.ash : Palette.bone)
                            .font(.system(size: 12, design: .monospaced))
                        Rectangle().fill(theme.accent).frame(width: 1.5, height: 13)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3).overlay(Rectangle().stroke(theme.accent.opacity(0.6)))
                }
                Spacer(minLength: 20)
                Text(s.searching ? "↩ OPEN · ESC CLEAR" : "S SEARCH · 1–9 · Q QUIT · ⇧Q FORCE · W CLOSE · M MIN · F FULL · H HIDE")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
            }
            if s.windows.isEmpty {
                Text("No windows match \"\(s.query)\"").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ash).frame(width: 320, height: 60)
            } else if s.grouping {
                let groups = AppGroup.make(s.windows)
                let active = groups.first { g in g.items.contains { $0.0 == s.selected } }
                let visible = groups.count + max(0, (active?.items.count ?? 1) - 1)
                let gw = Self.groupedWidth(visible: visible, expanded: active?.items.count ?? 1, screen: s.targetScreen.visibleFrame, prefs: prefs)
                FlowLayout(spacing: 12, maxWidth: width * prefs.maxWidth - 40) {
                    ForEach(groups) { g in GroupCard(group: g, width: gw) }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.84), value: s.selected)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tw + 16), spacing: 10), count: cols), alignment: .leading, spacing: 10) {
                    ForEach(Array(s.windows.enumerated()), id: \.element.id) { i, w in
                        Tile(win: w, index: i, selected: i == s.selected, width: tw)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.03, green: 0.012, blue: 0.012).opacity(0.88)).background(VisualBlur())
        .overlay(Rectangle().stroke(theme.accent.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .id(theme.accentHex)
    }
}

struct Tile: View {
    let win: Win
    let index: Int
    let selected: Bool
    let width: CGFloat
    @EnvironmentObject var s: Switcher
    @EnvironmentObject var prefs: SwitcherPrefs
    @ObservedObject var theme = Theme.shared
    @State var hovering = false

    var icon: NSImage { NSRunningApplication(processIdentifier: win.pid)?.icon ?? NSWorkspace.shared.icon(for: .application) }
    var label: String { win.title.isEmpty || win.windowless ? win.appName : win.title }

    var body: some View {
        let _ = s.tick
        content
            .padding(8)
            .background(selected ? theme.accent.opacity(0.15) : (hovering ? Color.white.opacity(0.04) : .clear))
            .overlay(Rectangle().stroke(selected ? theme.accent : Color.white.opacity(0.06), lineWidth: selected ? 2 : 1))
            .shadow(color: selected ? theme.accent.opacity(0.65) : .clear, radius: 10)
            .overlay(alignment: .topTrailing) { badge }
            .scaleEffect(selected ? 1.025 : 1)
            .animation(s.mouseMoved ? nil : .easeOut(duration: 0.07), value: selected)
            .contentShape(Rectangle())
            .onHover { h in guard s.visible else { return }; hovering = h; if h && prefs.hoverSelects && s.mouseMoved && s.selected != index { s.select(index) } }
            .onTapGesture { s.select(index); s.commit() }
    }

    @ViewBuilder var content: some View {
        switch s.style {
        case .thumbs:
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(Color.black.opacity(0.6))
                    if let img = Thumbnails.shared.cache[win.id] {
                        Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(nsImage: icon).resizable().frame(width: width * 0.32, height: width * 0.32).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(win.minimized || win.hidden || win.windowless ? 0.55 : 1)
                    }
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28).offset(x: -4, y: 6)
                }
                .frame(width: width, height: width * 0.62).clipped()
                caption
            }.frame(width: width)
        case .icons:
            VStack(spacing: 6) {
                Image(nsImage: icon).resizable().frame(width: width * 0.62, height: width * 0.62).opacity(win.minimized || win.hidden ? 0.6 : 1)
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.bone).lineLimit(1)
            }.frame(width: width)
        case .titles:
            HStack(spacing: 10) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                caption
                Spacer()
            }.frame(width: width)
        }
    }

    var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.bone).lineLimit(1)
            Text(status + win.appName.uppercased()).font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? theme.accent : Palette.ash).lineLimit(1)
        }
    }

    var status: String {
        guard prefs.badges else { return "" }
        var parts: [String] = []
        if win.minimized { parts.append("MIN") }
        if win.hidden { parts.append("HIDDEN") }
        if win.fullscreen { parts.append("FULL") }
        if win.windowless { parts.append("NO WINDOW") }
        if !win.onCurrentSpace, let n = win.spaceNumber { parts.append("SPACE \(n)") }
        return parts.isEmpty ? "" : parts.joined(separator: " · ") + " · "
    }

    @ViewBuilder var badge: some View {
        if prefs.numberKeys && index < 9 {
            Text("\(index + 1)").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(selected ? Color.black : Palette.ash)
                .frame(width: 17, height: 17).background(selected ? theme.accent : Color.black.opacity(0.65))
                .offset(x: -5, y: 5)
        }
    }
}

struct VisualBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; v.appearance = NSAppearance(named: .darkAqua); return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct AppGroup: Identifiable {
    let id: String
    let name: String
    let pid: pid_t
    let items: [(Int, Win)]

    static func make(_ wins: [Win]) -> [AppGroup] {
        var out: [AppGroup] = []
        var current: [(Int, Win)] = []
        var key = ""
        for (i, w) in wins.enumerated() {
            let k = w.bundleID ?? w.appName
            if k != key, let first = current.first { out.append(AppGroup(id: key + "#\(out.count)", name: first.1.appName, pid: first.1.pid, items: current)); current = [] }
            key = k
            current.append((i, w))
        }
        if let first = current.first { out.append(AppGroup(id: key + "#\(out.count)", name: first.1.appName, pid: first.1.pid, items: current)) }
        return out
    }
}

struct GroupCard: View {
    let group: AppGroup
    let width: CGFloat
    @EnvironmentObject var s: Switcher
    @EnvironmentObject var prefs: SwitcherPrefs
    @ObservedObject var theme = Theme.shared
    @Namespace private var ns

    var active: Bool { group.items.contains { $0.0 == s.selected } }
    var icon: NSImage { NSRunningApplication(processIdentifier: group.pid)?.icon ?? NSWorkspace.shared.icon(for: .application) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                Text(group.name.uppercased()).font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(active ? theme.accent : Palette.bone).lineLimit(1)
                if group.items.count > 1 {
                    Text("\(group.items.count)").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(active ? Color.black : Palette.ash)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(active ? theme.accent : Color.white.opacity(0.08))
                }
            }
            if active && group.items.count > 1 {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.items, id: \.1.id) { i, w in
                        Tile(win: w, index: i, selected: i == s.selected, width: width)
                            .matchedGeometryEffect(id: w.id, in: ns)
                            .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
                    }
                }
            } else {
                stack
            }
        }
        .padding(10)
        .background(active ? theme.accent.opacity(0.07) : Color.clear)
        .overlay(Rectangle().stroke(active ? theme.accent.opacity(0.55) : Color.white.opacity(0.05), lineWidth: 1))
        .opacity(active || s.selected < 0 ? 1 : 0.8)
    }

    @ViewBuilder var stack: some View {
        let top = group.items[0]
        ZStack(alignment: .topLeading) {
            ForEach(Array(group.items.dropFirst().prefix(2).enumerated().reversed()), id: \.offset) { n, _ in
                Rectangle().fill(Color(white: 0.09))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.08)))
                    .frame(width: width + 16, height: width * 0.62 + 46)
                    .offset(x: CGFloat(n + 1) * 7, y: CGFloat(n + 1) * -6)
            }
            Tile(win: top.1, index: top.0, selected: top.0 == s.selected, width: width)
                .background(Color(red: 0.03, green: 0.012, blue: 0.012))
                .matchedGeometryEffect(id: top.1.id, in: ns)
        }
        .padding(.top, group.items.count > 1 ? CGFloat(min(group.items.count - 1, 2)) * 6 : 0)
        .padding(.trailing, group.items.count > 1 ? CGFloat(min(group.items.count - 1, 2)) * 7 : 0)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews)
        let w = rows.map { $0.width }.max() ?? 0
        let h = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: [Int] = [], w: CGFloat = 0, h: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !cur.isEmpty && w + spacing + size.width > maxWidth {
                rows.append((cur, w, h)); cur = []; w = 0; h = 0
            }
            w += (cur.isEmpty ? 0 : spacing) + size.width
            h = max(h, size.height)
            cur.append(i)
        }
        if !cur.isEmpty { rows.append((cur, w, h)) }
        return rows
    }
}
