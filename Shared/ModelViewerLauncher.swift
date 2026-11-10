import AppKit
import SwiftUI

// the Model Viewer runs as its own app (ModelViewerApp/), like Task Manager; Taru Tweaks only opens it
enum ModelViewerLauncher {
    static let url = URL(fileURLWithPath: "/Applications/Model Viewer.app")

    static func open(_ files: [URL] = []) {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        if files.isEmpty { NSWorkspace.shared.openApplication(at: url, configuration: cfg) }
        else { NSWorkspace.shared.open(files, withApplicationAt: url, configuration: cfg) }
    }
}

struct ModelViewerRow: View {
    var body: some View {
        HStack {
            Text("Model Viewer").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
            Spacer()
            Text("usdz · glb · obj").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
        }
        .contentShape(Rectangle())
        .onTapGesture { ModelViewerLauncher.open() }
    }
}
