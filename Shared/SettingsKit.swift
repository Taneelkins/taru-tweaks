import SwiftUI
import AppKit

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
}

struct SidebarGroup: Identifiable {
    let id: String
    let items: [SidebarItem]
}

struct TweaksShell<Content: View>: View {
    let groups: [SidebarGroup]
    @Binding var current: String
    @ViewBuilder var content: (String) -> Content
    @ObservedObject var theme = Theme.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TARU").font(.system(size: 24, weight: .heavy, design: .monospaced)).tracking(4)
                    Text("TWEAKS").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(6).opacity(0.8)
                }
                .foregroundStyle(theme.accent).shadow(color: theme.accent.opacity(0.55), radius: 10)
                .padding(.top, 38).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { g in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.id.uppercased()).font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.rule.opacity(1.6)).padding(.bottom, 4)
                                ForEach(g.items) { item in
                                    Button { current = item.id } label: {
                                        HStack(spacing: 9) {
                                            Rectangle().fill(current == item.id ? theme.accent : .clear).frame(width: 2, height: 16)
                                            Image(systemName: item.icon).frame(width: 16).foregroundStyle(current == item.id ? theme.accent : Palette.ash)
                                            Text(item.title).font(.system(size: 12.5, weight: current == item.id ? .semibold : .regular))
                                                .foregroundStyle(current == item.id ? Palette.bone : Palette.ash)
                                            Spacer()
                                        }
                                        .padding(.vertical, 5).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                Text("BLOOD IS FUEL").font(.system(size: 9, design: .monospaced)).tracking(2).foregroundStyle(Palette.rule).padding(.vertical, 12)
            }
            .padding(.horizontal, 18).frame(width: 210).background(Color.black)
            Rectangle().fill(Palette.rule).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(current)
                }
                .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.pit)
        }
        .frame(minWidth: 760, minHeight: 540)
        .preferredColorScheme(.dark)
        .tint(theme.accent)
        .id(theme.accentHex)
    }
}

struct PageTitle: View {
    let title: String
    var subtitle: String = ""
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 22, weight: .heavy, design: .monospaced)).tracking(2).foregroundStyle(theme.accent)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.ash).fixedSize(horizontal: false, vertical: true) }
        }.padding(.bottom, 16)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 22).padding(.bottom, 4)
    }
}

struct Seg<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var value: T
    var body: some View {
        Picker("", selection: $value) { ForEach(options, id: \.1) { Text($0.0).tag($0.1) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

struct Switch: View {
    @Binding var on: Bool
    var body: some View { Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden() }
}

func modifierString(_ mask: UInt64) -> String {
    var s = ""
    if mask & 0x40000 != 0 { s += "⌃" }
    if mask & 0x80000 != 0 { s += "⌥" }
    if mask & 0x20000 != 0 { s += "⇧" }
    if mask & 0x100000 != 0 { s += "⌘" }
    return s
}

func keyString(_ key: Int64) -> String {
    let names: [Int64: String] = [48: "⇥", 50: "`", 49: "Space", 36: "↩", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑", 24: "=", 27: "-", 33: "[", 30: "]", 43: ",", 47: ".", 44: "/"]
    if let n = names[key] { return n }
    let letters: [Int64: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
    return letters[key] ?? "key \(key)"
}

struct KeyRecorder: View {
    @Binding var mask: UInt64
    @Binding var key: Int64
    @State var recording = false
    @State var monitor: Any?
    @ObservedObject var theme = Theme.shared

    var body: some View {
        Button {
            recording.toggle()
            if recording {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    let m = UInt64(e.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
                    if m != 0 { mask = m; key = Int64(e.keyCode) }
                    recording = false
                    if let mon = monitor { NSEvent.removeMonitor(mon) }
                    return nil
                }
            } else if let mon = monitor { NSEvent.removeMonitor(mon) }
        } label: {
            Text(recording ? "PRESS KEYS…" : "\(modifierString(mask)) \(keyString(key))")
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .frame(minWidth: 100).padding(.vertical, 5).padding(.horizontal, 10)
                .foregroundStyle(recording ? Color.black : Palette.bone)
                .background(recording ? theme.accent : Color.black)
                .overlay(Rectangle().stroke(theme.accent.opacity(0.7)))
        }.buttonStyle(.plain)
    }
}

struct TweakButton: View {
    let title: String
    let action: () -> Void
    @ObservedObject var theme = Theme.shared
    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.5)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .foregroundStyle(theme.accent).overlay(Rectangle().stroke(theme.accent))
        }.buttonStyle(.plain)
    }
}
