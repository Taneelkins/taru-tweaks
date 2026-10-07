import SwiftUI
import AppKit

struct SwitcherView: View {
    @EnvironmentObject var s: Switcher
    @EnvironmentObject var prefs: SwitcherPrefs
    @ObservedObject var theme = Theme.shared

    static func tileWidth(_ prefs: SwitcherPrefs, count: Int, screen: CGFloat) -> CGFloat {
        switch prefs.style {
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

    static func columns(count: Int, prefs: SwitcherPrefs, screen: CGFloat) -> Int {
        if prefs.style == .titles { return 1 }
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
                Text("SWITCH").font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(3).foregroundStyle(theme.accent)
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
        switch prefs.style {
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
