import AppKit
import SwiftUI

// the BetterDisplay virtual screen background Studio/Blender live on; this just plugs it in and out
final class ExtraDisplay: ObservableObject {
    static let shared = ExtraDisplay()

    @AppStorage("display.extra.name") var name = "UC Test Display"
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var note = ""

    private let cli = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    var installed: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    // NSScreen already knows, no need to ask BetterDisplay every time
    func refresh() { connected = NSScreen.screens.contains { $0.localizedName == name } }

    var on: Binding<Bool> { Binding(get: { self.connected }, set: { self.set($0) }) }

    func toggle() { set(!connected) }

    func set(_ want: Bool) {
        guard !busy, want != connected else { return }
        guard installed else { note = "BetterDisplay isn't installed"; return }
        busy = true; note = ""
        let name = name
        DispatchQueue.global(qos: .userInitiated).async {
            // BetterDisplay plugs it back in at a different size, so remember the old one and put it back
            if !want, case let (true, size) = self.run("get", "-name=\(name)", "-resolution"), size.contains("x") { UserDefaults.standard.set(size, forKey: "display.extra.size") }
            let (ok, out) = self.run("set", "-name=\(name)", "-connected=\(want ? "on" : "off")")
            if ok, want, let size = UserDefaults.standard.string(forKey: "display.extra.size") {
                Thread.sleep(forTimeInterval: 1)
                _ = self.run("set", "-name=\(name)", "-resolution=\(size)")
            }
            // the screen list takes a beat to catch up after BetterDisplay flips it
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.busy = false
                self.refresh()
                if !ok { self.note = out.isEmpty ? "BetterDisplay didn't answer" : out }
            }
        }
    }

    private func run(_ args: String...) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return (false, "") }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, out)
    }
}

struct ExtraDisplayRow: View {
    @ObservedObject var display = ExtraDisplay.shared
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Extra display").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
                Text(display.busy ? "switching…" : !display.note.isEmpty ? display.note : "\(display.name) · \(display.connected ? "on" : "off")")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: display.on).toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(display.busy)
        }
        .onAppear { display.refresh() }
    }
}
