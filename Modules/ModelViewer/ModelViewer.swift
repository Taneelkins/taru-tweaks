import SwiftUI
import AppKit
import SceneKit
import UniformTypeIdentifiers

// 3D model viewer: .usdz/.usd/.obj through SceneKit, .glb/.gltf through GLTFKit2. One window per file,
// opened from Finder's Open With, a drop on a viewer window, or the flame menu. Nothing runs while no window is open.
final class ModelViewer {
    static let shared = ModelViewer()
    private(set) var docs: [ModelDoc] = []

    var anyVisible: Bool { docs.contains { $0.window.isVisible } }

    func start() {
        // object: "dump" | "open <path>" (no focus steal, lands on the extra display if there is one) | "new" (empty window, same way) | "close"
        //         | "snap <png path>" | "bench" | "wire" | "frame" | "turn <dx> <dy>" | "pan <dx> <dy>" | "zoom <factor> [x y]"  → /tmp/tarutweaks-model.json
        DistributedNotificationCenter.default().addObserver(forName: .init("com.taru.tweaks.model"), object: nil, queue: .main) { [weak self] n in self?.debug(n.object as? String ?? "dump") }
    }

    func open(_ urls: [URL]) {
        let models = urls.filter { ModelLoader.types.contains($0.pathExtension.lowercased()) }
        for url in models { open(url) }
    }

    @discardableResult
    func open(_ url: URL?, quiet: Bool = false) -> ModelDoc {
        let doc: ModelDoc
        if let url, let same = docs.first(where: { $0.url == url }) {
            doc = same
        } else if let url, let empty = docs.first(where: { $0.url == nil }) {
            doc = empty; doc.load(url)
        } else if url == nil, let empty = docs.first(where: { $0.url == nil }) {
            doc = empty
        } else {
            doc = ModelDoc(offset: docs.count)
            docs.append(doc)
            doc.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: doc.window, queue: .main) { [weak self, weak doc] _ in
                if let token = doc?.closing { NotificationCenter.default.removeObserver(token) }
                doc?.canvas.clear()
                self?.docs.removeAll { $0 === doc }
                DispatchQueue.main.async { AppDelegate.shared.updateDockIcon() }
            }
            if let url { doc.load(url) }
        }
        if quiet {
            if let other = NSScreen.screens.first(where: { $0.localizedName == ExtraDisplay.shared.name }) {
                let size = NSSize(width: 1100, height: 760)
                doc.window.setFrame(NSRect(x: other.visibleFrame.midX - size.width / 2, y: other.visibleFrame.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
            doc.window.orderFrontRegardless()
            AppDelegate.shared.updateDockIcon()
        } else {
            AppDelegate.shared.present(doc.window)
        }
        return doc
    }

    func pick(into doc: ModelDoc? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ModelLoader.types.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = doc == nil
        guard panel.runModal() == .OK else { return }
        if let doc, let url = panel.url { doc.load(url) } else { open(panel.urls) }
    }

    private func debug(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let doc = docs.last
        func write(_ extra: [String: Any] = [:]) {
            var out: [String: Any] = ["windows": docs.map { $0.dump() }]
            extra.forEach { out[$0.key] = $0.value }
            if let j = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? j.write(to: URL(fileURLWithPath: "/tmp/tarutweaks-model.json")) }
        }
        switch parts.first {
        case "open" where parts.count == 2: open(URL(fileURLWithPath: parts[1]), quiet: true)
        case "new": open(nil, quiet: true)
        case "pan" where parts.count == 2:
            let v = parts[1].split(separator: " ").compactMap { Float($0) }
            if v.count == 2 { doc?.canvas.pan(dx: v[0], dy: v[1]) }
        case "close": docs.forEach { $0.window.close() }
        case "wire": doc?.wireframe.toggle()
        case "frame": doc?.canvas.reframe(animated: false)
        case "turn" where parts.count == 2:
            let v = parts[1].split(separator: " ").compactMap { Float($0) }
            if v.count == 2 { doc?.canvas.turn(dx: v[0], dy: v[1]) }
        case "zoom" where parts.count == 2:
            // "zoom 0.5" toward the middle, "zoom 0.5 0.3 0.4" toward a spot (fractions of the view from its top-left)
            let v = parts[1].split(separator: " ").compactMap { Float($0) }
            guard let doc, let f = v.first else { break }
            let size = doc.canvas.bounds.size
            doc.canvas.zoom(by: f, at: v.count == 3 ? CGPoint(x: CGFloat(v[1]) * size.width, y: CGFloat(1 - v[2]) * size.height) : nil)
        case "snap" where parts.count == 2:
            if let doc, let tiff = doc.canvas.snapshot().tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: parts[1])) }
        case "bench":
            guard let doc else { break }
            doc.canvas.benchmark(seconds: 4) { result in write(["bench": result]) }
            return
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { write() }
    }
}

final class ModelDoc: ObservableObject {
    @Published var url: URL?
    @Published var loading = false
    @Published var problem: String?
    @Published var triangles = 0
    @Published var parts = 0
    @Published var bytes: Int64 = 0
    @Published var wireframe = false { didSet { canvas.wireframe = wireframe } }
    private(set) var cutouts = 0
    private(set) var loadSeconds = 0.0

    let canvas = ModelCanvas()
    let window: NSWindow
    var closing: NSObjectProtocol?
    private var ticket = 0

    init(offset: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
        window.title = "Model Viewer"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        window.minSize = NSSize(width: 420, height: 320)
        window.contentView = NSHostingView(rootView: ModelViewerView(doc: self))
        window.center()
        if !window.setFrameUsingName("ModelViewer") { window.center() }
        window.setFrameAutosaveName(offset == 0 ? "ModelViewer" : "")
        if offset > 0 { window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(offset % 8) * 28, y: window.frame.minY - CGFloat(offset % 8) * 28)) }
        canvas.onDoubleClick = { [weak self] in self?.canvas.reframe() }
        canvas.onKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "f": self.canvas.reframe()
            case "w": self.wireframe.toggle()
            case "open": ModelViewer.shared.pick(into: self)
            default: return false
            }
            return true
        }
    }

    func load(_ url: URL) {
        ticket += 1
        let mine = ticket, started = Date()
        self.url = url; loading = true; problem = nil
        window.title = url.lastPathComponent
        window.representedURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ModelLoader.load(url) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            DispatchQueue.main.async {
                guard mine == self.ticket else { return }
                self.loading = false
                switch result {
                case .success(let model):
                    self.triangles = model.triangles; self.parts = model.parts; self.bytes = size; self.cutouts = model.cutouts
                    self.loadSeconds = Date().timeIntervalSince(started)
                    self.canvas.show(model)
                    self.canvas.wireframe = self.wireframe
                    self.window.makeFirstResponder(self.canvas)
                case .failure(let error):
                    self.canvas.clear()
                    self.triangles = 0; self.parts = 0; self.bytes = size
                    self.problem = error.localizedDescription
                }
            }
        }
    }

    func dump() -> [String: Any] {
        ["file": url?.path ?? "", "loading": loading, "problem": problem ?? "", "triangles": triangles, "parts": parts, "cutoutMaterials": cutouts, "loadSeconds": loadSeconds,
         "metal": canvas.renderingAPI == .metal, "device": canvas.device?.name ?? "", "wireframe": wireframe, "windowNumber": window.windowNumber, "visible": window.isVisible,
         "frame": NSStringFromRect(window.frame), "screen": window.screen?.localizedName ?? "", "distance": canvas.distance, "yaw": canvas.yaw, "pitch": canvas.pitch]
    }
}

struct ModelViewerView: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var theme = Theme.shared
    @State private var dropping = false

    var body: some View {
        ZStack {
            CanvasHost(canvas: doc.canvas)
            if doc.url == nil || doc.problem != nil { empty }
            if doc.loading { Text("LOADING").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(Palette.ash).allowsHitTesting(false) }
            VStack { Spacer(); HStack(alignment: .bottom) { info; Spacer(); hints } }.padding(14).allowsHitTesting(false)
            if dropping { Rectangle().stroke(theme.accent, lineWidth: 3).allowsHitTesting(false) }
        }
        .frame(minWidth: 420, minHeight: 320)
        .ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ModelLoader.types.contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async { doc.load(url) }
            }
            return true
        }
    }

    var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Palette.ash)
            Text(doc.problem == nil ? "Drop a model here" : "Couldn't open \(doc.url?.lastPathComponent ?? "that file")").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.bone)
            Text(doc.problem ?? ".usdz  .usd  .obj  .glb  .gltf").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).multilineTextAlignment(.center).frame(maxWidth: 420)
            TweakButton(title: "Open") { ModelViewer.shared.pick(into: doc) }.padding(.top, 4)
        }
    }

    @ViewBuilder var info: some View {
        if let url = doc.url, doc.problem == nil, !doc.loading {
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.bone).lineLimit(1).truncationMode(.middle)
                Text("\(doc.triangles.formatted()) triangles · \(doc.parts) \(doc.parts == 1 ? "part" : "parts") · \(ByteCountFormatter.string(fromByteCount: doc.bytes, countStyle: .file))\(doc.wireframe ? " · wireframe" : "")")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.black.opacity(0.45))
        }
    }

    @ViewBuilder var hints: some View {
        if doc.url != nil, doc.problem == nil {
            Text("drag turn · scroll or pinch zoom · ⇧ drag pan · double-click fit · W wireframe · ⌘O open")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash.opacity(0.75)).lineLimit(1)
        }
    }
}

struct CanvasHost: NSViewRepresentable {
    let canvas: ModelCanvas
    func makeNSView(context: Context) -> ModelCanvas { canvas }
    func updateNSView(_ view: ModelCanvas, context: Context) {}
}

struct ModelViewerRow: View {
    var body: some View {
        HStack {
            Text("Model Viewer").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.bone)
            Spacer()
            Text("usdz · glb · obj").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
        }
        .contentShape(Rectangle())
        .onTapGesture { ModelViewer.shared.open(nil) }
    }
}
