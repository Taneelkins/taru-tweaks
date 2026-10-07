import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .red
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

final class Theme: ObservableObject {
    static let shared = Theme()
    static let presets: [(String, String)] = [("Blood", "#E0241B"), ("Hell", "#FF6A1A"), ("Gold", "#FFC23A"), ("Void", "#8A4DFF"), ("Cyber", "#2DE2E6"), ("Bone", "#ECDCD9")]
    let store = UserDefaults(suiteName: "com.taru.ultra")!
    @Published var accentHex: String

    init() {
        accentHex = store.string(forKey: "accent") ?? "#E0241B"
        DistributedNotificationCenter.default().addObserver(forName: .init("com.taru.ultra.theme"), object: nil, queue: .main) { [weak self] n in
            if let h = n.object as? String, h != self?.accentHex { self?.accentHex = h }
        }
    }

    var accent: Color { Color(hex: accentHex) }

    func set(_ hex: String) {
        accentHex = hex
        store.set(hex, forKey: "accent")
        DistributedNotificationCenter.default().postNotificationName(.init("com.taru.ultra.theme"), object: hex, userInfo: nil, deliverImmediately: true)
    }
}

enum Palette {
    static var accent: Color { Theme.shared.accent }
    static let bone = Color(red: 0.925, green: 0.863, blue: 0.851)
    static let ash = Color(red: 0.604, green: 0.478, blue: 0.459)
    static let pit = Color(red: 0.055, green: 0.027, blue: 0.027)
    static let rule = Color(red: 0.18, green: 0.078, blue: 0.071)
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
                    if !detail.isEmpty { Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.vertical, 11)
            Rectangle().fill(Palette.rule).frame(height: 1)
        }
    }
}

struct ThemePicker: View {
    @ObservedObject var theme = Theme.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Theme.presets, id: \.1) { p in
                    Button { theme.set(p.1) } label: {
                        VStack(spacing: 5) {
                            Rectangle().fill(Color(hex: p.1)).frame(width: 44, height: 28)
                                .overlay(Rectangle().stroke(theme.accentHex == p.1 ? Palette.bone : .clear, lineWidth: 2))
                                .shadow(color: Color(hex: p.1).opacity(0.6), radius: theme.accentHex == p.1 ? 8 : 0)
                            Text(p.0.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ash)
                        }
                    }.buttonStyle(.plain)
                }
            }
            SettingRow(title: "Custom color", detail: "Shared by Fuel, Overdrive and Arsenal") {
                ColorPicker("", selection: Binding(get: { theme.accent }, set: { theme.set($0.hex) }), supportsOpacity: false).labelsHidden()
            }
        }
    }
}

func loginItem(_ name: String, enabled: Bool) {
    let script = enabled
        ? "tell application \"System Events\" to if not (exists login item \"\(name)\") then make login item at end with properties {path:\"/Applications/\(name).app\", hidden:true}"
        : "tell application \"System Events\" to delete (every login item whose name is \"\(name)\")"
    NSAppleScript(source: script)?.executeAndReturnError(nil)
}

func isLoginItem(_ name: String) -> Bool {
    var err: NSDictionary?
    let r = NSAppleScript(source: "tell application \"System Events\" to exists login item \"\(name)\"")?.executeAndReturnError(&err)
    return r?.booleanValue ?? false
}
