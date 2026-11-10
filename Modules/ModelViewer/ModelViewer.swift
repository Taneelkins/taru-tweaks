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
        //         | "snap <png path>" | "bench" | "wire" | "frame" | "turn <dx> <dy>" | "pan <dx> <dy>" | "zoom <factor> [x y]"
        //         | "explode" (next step) | "draw" | "spin" | "play" | "seek <seconds>" | "clip" (next one) | "clay" | "panel"
        //         | "select <n>" | "hide <n>" | "solo <n>" | "showall" | "copy" | "reload" | "view front|side|top" | "flat"
        //         | "light <degrees>" | "backdrop" (next one) | "recent <n>" (open the nth recent file)
        //         | "clip <n>" | "speed <x>" | "loop" (loop ↔ play once) | "stop" | "step <frames>" | "tab parts|anims"  → /tmp/tarutweaks-model.json
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
            doc = empty; doc.load(url, remember: !quiet)
        } else if url == nil, let empty = docs.first(where: { $0.url == nil }) {
            doc = empty
        } else {
            doc = ModelDoc(offset: docs.count)
            docs.append(doc)
            doc.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: doc.window, queue: .main) { [weak self, weak doc] _ in
                if let token = doc?.closing { NotificationCenter.default.removeObserver(token) }
                doc?.shutDown()
                self?.docs.removeAll { $0 === doc }
                DispatchQueue.main.async { AppDelegate.shared.updateDockIcon() }
            }
            if let url { doc.load(url, remember: !quiet) }
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

    // MARK: recent files (newest first; only files opened by hand, not the debug hook's)

    var recent: [String] { UserDefaults.standard.stringArray(forKey: "model.recent") ?? [] }

    func remember(_ url: URL) { UserDefaults.standard.set(Array(([url.path] + recent.filter { $0 != url.path }).prefix(12)), forKey: "model.recent") }
    func forget(_ url: URL) { UserDefaults.standard.set(recent.filter { $0 != url.path }, forKey: "model.recent") }
    func clearRecent() { UserDefaults.standard.removeObject(forKey: "model.recent") }

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
            var out: [String: Any] = ["windows": docs.map { $0.dump() }, "recent": recent]
            extra.forEach { out[$0.key] = $0.value }
            if let j = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? j.write(to: URL(fileURLWithPath: "/tmp/tarutweaks-model.json")) }
        }
        switch parts.first {
        case "open" where parts.count == 2: open(URL(fileURLWithPath: parts[1]), quiet: true)
        case "view" where parts.count == 2: doc?.look(parts[1])
        case "flat": doc?.flat.toggle()
        case "light" where parts.count == 2: if let degrees = Float(parts[1]) { doc?.canvas.turnLight(by: degrees * .pi / 180) }
        case "backdrop": doc?.nextBackdrop()
        case "recent" where parts.count == 2: if let i = Int(parts[1]), recent.indices.contains(i) { doc?.load(URL(fileURLWithPath: recent[i])) }
        case "new": open(nil, quiet: true)
        case "pan" where parts.count == 2:
            let v = parts[1].split(separator: " ").compactMap { Float($0) }
            if v.count == 2 { doc?.canvas.pan(dx: v[0], dy: v[1]) }
        case "close": docs.forEach { $0.window.close() }
        case "wire": doc?.wireframe.toggle()
        case "explode": doc?.explode()
        case "clay": doc?.clay.toggle()
        case "panel": doc?.panel.toggle()
        case "showall": doc?.showAll()
        case "copy": doc?.copyPicture()
        case "reload": doc?.reload()
        case "select" where parts.count == 2: if let i = Int(parts[1]) { doc?.select(i, focus: true) }
        case "hide" where parts.count == 2: if let i = Int(parts[1]) { doc?.toggleHidden(i) }
        case "solo" where parts.count == 2: if let i = Int(parts[1]) { doc?.solo(i) }
        case "draw": doc?.toggleDrawn()
        case "spin": doc?.spinning.toggle()
        case "play": doc?.playing.toggle()
        case "clip" where parts.count == 2: if let i = Int(parts[1]) { doc?.choose(i) }
        case "clip": doc?.nextClip()
        case "speed" where parts.count == 2: if let v = ModelDoc.parseSpeed(parts[1]) { doc?.setSpeed(v) }
        case "loop": doc?.looping.toggle()
        case "stop": doc?.stopClip()
        case "step" where parts.count == 2: if let n = Int(parts[1]) { doc?.step(n) }
        case "tab" where parts.count == 2: if let t = SideTab(rawValue: parts[1]) { doc?.tab = t; doc?.panel = true }
        case "seek" where parts.count == 2: if let t = Double(parts[1]) { doc?.seek(t) }
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

struct PartRow: Identifiable {
    let id: Int
    let name: String
    let triangles: Int
    let materials: Int
    let group: String
    var hidden = false
}

final class ModelDoc: ObservableObject {
    @Published var url: URL?
    @Published var loading = false
    @Published var problem: String?
    @Published var triangles = 0
    @Published var bytes: Int64 = 0
    @Published private(set) var rows: [PartRow] = []
    @Published private(set) var facts: [String] = []
    @Published private(set) var selected: Int?
    @Published var hovered: Int? { didSet { if hovered != oldValue { mark() } } }
    @Published var panel = UserDefaults.standard.object(forKey: "model.panel") as? Bool ?? true { didSet { UserDefaults.standard.set(panel, forKey: "model.panel") } }
    @Published var byTriangles = false
    @Published var wireframe = false { didSet { canvas.wireframe = wireframe } }
    @Published var clay = false { didSet { if clay != oldValue { applyClay() } } }
    @Published var spinning = false { didSet { canvas.spinning = spinning } }
    @Published private(set) var pose = ModelPoser.Pose.together
    @Published private(set) var canExplode = false
    @Published private(set) var canDraw = false
    @Published private(set) var clips: [ModelClip] = []
    @Published private(set) var clip = 0
    @Published var playing = false { didSet { if playing != oldValue { play(playing) } } }
    // play speed (minus = backwards) and loop vs play once: kept for every clip and every file until changed
    @Published private(set) var speed = ModelDoc.savedSpeed { didSet { UserDefaults.standard.set(speed, forKey: "model.animSpeed") } }
    @Published var looping = UserDefaults.standard.object(forKey: "model.animLoop") as? Bool ?? true { didSet { UserDefaults.standard.set(looping, forKey: "model.animLoop") } }
    @Published var tab = SideTab(rawValue: UserDefaults.standard.string(forKey: "model.tab") ?? "") ?? .parts { didSet { UserDefaults.standard.set(tab.rawValue, forKey: "model.tab") } }
    // where the clip is, in its own object so only the scrub bars redraw while it plays
    let playhead = Playhead()
    @Published private(set) var toast: String?
    @Published private(set) var view: String?
    @Published var flat = false { didSet { if flat != oldValue { canvas.setFlat(flat) } } }
    @Published private(set) var backdrop = Backdrop(rawValue: UserDefaults.standard.string(forKey: "model.backdrop") ?? "") ?? .dark
    private(set) var cutouts = 0
    private(set) var loadSeconds = 0.0
    private(set) var reloads = 0
    private var model: LoadedModel?
    private var poser: ModelPoser?
    private var clock = 0.0
    private static var savedSpeed: Double { let v = UserDefaults.standard.double(forKey: "model.animSpeed"); return v == 0 ? 1 : v }
    private var marks: [SCNNode] = []
    private var dressed: [(SCNGeometry, [SCNMaterial])] = []
    private var watch: DispatchSourceFileSystemObject?
    private var settle: DispatchWorkItem?

    let canvas = ModelCanvas()
    let window: NSWindow
    var closing: NSObjectProtocol?
    private var ticket = 0

    init(offset: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
        window.title = "Model Viewer"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = NSHostingView(rootView: ModelViewerView(doc: self))
        window.center()
        if !window.setFrameUsingName("ModelViewer") { window.center() }
        window.setFrameAutosaveName(offset == 0 ? "ModelViewer" : "")
        if offset > 0 { window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(offset % 8) * 28, y: window.frame.minY - CGFloat(offset % 8) * 28)) }
        canvas.setBackdrop(backdrop)
        canvas.onView = { [weak self] name in self?.view = name }
        canvas.onClick = { [weak self] point in self?.select(self?.part(at: point)?.index, focus: false) }
        // double-click a spot to zoom in on it, double-click empty space to see everything again
        canvas.onDoubleClick = { [weak self] point in
            guard let self else { return }
            if let hit = self.part(at: point) { self.select(hit.index, focus: false); self.canvas.focus(on: hit.spot) } else { self.canvas.reframe() }
        }
        canvas.onKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "f": self.canvas.reframe()
            case "w": self.wireframe.toggle()
            case "c": self.clay.toggle()
            case "s": self.spinning.toggle()
            case "p": self.showTab(.parts)
            case "a": self.showTab(.anims)
            case "o": if self.clips.isEmpty { return false }; self.looping.toggle()
            case "[": if self.clips.isEmpty { return false }; self.setSpeed(self.speed / 2)
            case "]": if self.clips.isEmpty { return false }; self.setSpeed(self.speed * 2)
            case "\u{F702}": if self.clips.isEmpty { return false }; self.step(-1)
            case "\u{F703}": if self.clips.isEmpty { return false }; self.step(1)
            case "e": self.explode()
            case "u": self.toggleDrawn()
            case "1": self.look("front")
            case "2": self.look("side")
            case "3": self.look("top")
            case "4": self.flat.toggle()
            case "l": self.turnLight()
            case "b": self.nextBackdrop()
            case "r": self.showRecent()
            case "h": if let i = self.selected { self.toggleHidden(i) } else { return false }
            case "i": if let i = self.selected { self.solo(i) } else { return false }
            case "\u{1b}": if self.selected != nil { self.select(nil, focus: false) } else { self.showAll() }
            case " ": if self.clips.isEmpty { return false }; self.playing.toggle()
            case "open": ModelViewer.shared.pick(into: self)
            case "copy": self.copyPicture()
            case "save": self.savePicture()
            default: return false
            }
            return true
        }
    }

    // the window is closing: let go of the model, the file watch and the view (the view holds this object, so nothing frees itself)
    func shutDown() {
        ticket += 1
        watch?.cancel(); watch = nil; settle?.cancel()
        canvas.clear()
        model = nil; poser = nil; marks = []; dressed = []; clips = []; rows = []
        DispatchQueue.main.async { [window] in window.contentView = nil }
    }

    func load(_ url: URL, again: Bool = false, remember: Bool = true) {
        ticket += 1
        let mine = ticket, started = Date()
        if !again { self.url = url; loading = true; problem = nil }
        window.title = url.lastPathComponent
        window.representedURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ModelLoader.load(url) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            // watch the file from here: this thread has just read it, so macOS has nothing left to ask
            let descriptor = (try? result.get()) == nil ? -1 : open(url.path, O_EVTONLY)
            let gone = descriptor < 0 && !FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async {
                guard mine == self.ticket else { if descriptor >= 0 { close(descriptor) }; return }
                // a re-export caught half-written: keep showing the old one and try once more
                if again, case .failure = result {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if mine == self.ticket { self.load(url, remember: false) } }
                    return
                }
                self.loading = false
                // a re-export keeps the clip you were on and whether it was playing
                let keepClip = again && self.clips.indices.contains(self.clip) ? self.clips[self.clip].name : nil, wasPlaying = self.playing
                self.playing = false; self.spinning = false
                self.marks = []; self.dressed = []
                self.clips = []; self.clip = 0; self.clock = 0; self.playhead.time = 0; self.pose = .together
                self.selected = nil; self.hovered = nil
                switch result {
                case .success(let model):
                    self.model = model
                    self.triangles = model.triangles; self.bytes = size; self.cutouts = model.cutouts
                    self.loadSeconds = Date().timeIntervalSince(started)
                    let poser = ModelPoser(model.parts, setup: model.setup)
                    self.poser = poser; self.canExplode = poser.canExplode; self.canDraw = poser.canDraw
                    self.rows = model.parts.enumerated().map { PartRow(id: $0, name: $1.name, triangles: $1.triangles, materials: $1.materials, group: $1.path.first ?? "") }
                    let box = model.high - model.low
                    self.facts = ["\(model.materials) \(model.materials == 1 ? "material" : "materials") · \(model.textures) \(model.textures == 1 ? "texture" : "textures")" + (model.largestTexture > 0 ? " (largest \(model.largestTexture) px)" : ""),
                                  "size " + [box.x, box.y, box.z].map { String(format: "%.2f", $0) }.joined(separator: " × "),
                                  poser.hasGroups ? "\(poser.groupCount) groups" + (model.setup?.explode != nil ? " (from this model's setup)" : "") : ""].filter { !$0.isEmpty }
                    self.clips = model.clips
                    if let keepClip, let i = model.clips.firstIndex(where: { $0.name == keepClip }) { self.clip = i }
                    if self.clips.indices.contains(self.clip) { self.clips[self.clip].attach() }
                    self.canvas.show(model, intro: !again, keepView: again)
                    self.canvas.wireframe = self.wireframe
                    if self.clay { self.applyClay() }
                    self.window.makeFirstResponder(self.canvas)
                    // a file with animation starts moving, like it would in the game
                    if !self.clips.isEmpty { self.playing = again ? wasPlaying : true }
                    self.watchFile(descriptor, url)
                    if again { self.reloads += 1; self.flash("Reloaded") } else if remember { ModelViewer.shared.remember(url) }
                case .failure(let error):
                    self.canvas.clear()
                    self.model = nil; self.poser = nil; self.canExplode = false; self.canDraw = false
                    self.triangles = 0; self.rows = []; self.facts = []; self.bytes = size
                    self.problem = gone ? "That file isn't there any more." : error.localizedDescription
                    if gone { ModelViewer.shared.forget(url) }
                }
            }
        }
    }

    // MARK: re-exports

    // Blender saving over the file (or swapping a new one into its place) reloads it, keeping the view
    private func watchFile(_ descriptor: Int32, _ url: URL) {
        watch?.cancel(); watch = nil
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload() }
            self.settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watch = source
    }

    func reload() { if let url, problem == nil { load(url, again: true) } }

    // MARK: parts

    func part(at point: CGPoint) -> (index: Int, spot: SIMD3<Float>)? {
        guard let model, let hit = canvas.pick(point) else { return nil }
        var node: SCNNode? = hit.node
        while let n = node {
            if let index = model.parts.firstIndex(where: { $0.node === n }) { return (index, hit.spot) }
            node = n.parent
        }
        return nil
    }

    func select(_ index: Int?, focus: Bool) {
        selected = index.flatMap { rows.indices.contains($0) ? $0 : nil }
        mark()
        if focus, let i = selected, let poser, !rows[i].hidden { let box = poser.box(of: i); canvas.focus(low: box.low, high: box.high) }
    }

    // selected part gets a see-through outline of its triangles in the accent colour, the hovered one a faint one
    private func mark() {
        marks.forEach { $0.removeFromParentNode() }
        marks = []
        guard let model else { canvas.needsDisplay = true; return }
        for (index, color) in [(hovered, NSColor(white: 1, alpha: 0.35)), (selected, NSColor(Theme.shared.accent))] {
            guard let index, model.parts.indices.contains(index), let geometry = model.parts[index].node.geometry, model.parts[index].node.skinner == nil else { continue }
            let lines = SCNMaterial()
            lines.lightingModel = .constant
            lines.diffuse.contents = color
            lines.fillMode = .lines
            lines.isDoubleSided = true
            lines.readsFromDepthBuffer = false; lines.writesToDepthBuffer = false
            let copy = geometry.copy() as! SCNGeometry
            copy.materials = [lines]
            let node = SCNNode(geometry: copy)
            node.renderingOrder = 1000
            model.parts[index].node.addChildNode(node)
            marks.append(node)
        }
        canvas.needsDisplay = true
    }

    func toggleHidden(_ index: Int) {
        guard let model, rows.indices.contains(index) else { return }
        rows[index].hidden.toggle()
        model.parts[index].node.isHidden = rows[index].hidden
    }

    // only this part (again = everything back)
    func solo(_ index: Int) {
        guard let model, rows.indices.contains(index) else { return }
        let alone = rows.allSatisfy { $0.hidden == ($0.id != index) }
        for i in rows.indices { rows[i].hidden = alone ? false : i != index; model.parts[i].node.isHidden = rows[i].hidden }
    }

    func showAll() {
        guard let model else { return }
        for i in rows.indices { rows[i].hidden = false; model.parts[i].node.isHidden = false }
    }

    var hiddenCount: Int { rows.filter(\.hidden).count }

    // plain grey instead of textures, to judge the shape on its own
    private func applyClay() {
        guard let model else { return }
        if clay {
            let grey = SCNMaterial()
            grey.lightingModel = .physicallyBased
            grey.diffuse.contents = NSColor(white: 0.62, alpha: 1)
            grey.roughness.contents = 0.6; grey.metalness.contents = 0.0
            grey.isDoubleSided = true
            for part in model.parts { if let g = part.node.geometry { dressed.append((g, g.materials)); g.materials = [grey] } }
        } else {
            for (geometry, materials) in dressed { geometry.materials = materials }
            dressed = []
        }
        canvas.needsDisplay = true
    }

    // MARK: straight-on views, lights, backdrop, recent files

    // "front", "side" or "top": looks straight from there; asked again while there, goes round to the far side
    func look(_ side: String) {
        let pairs = ["front": ("front", "back"), "side": ("right", "left"), "top": ("top", "bottom")]
        guard model != nil, let (near, far) = pairs[side] else { return }
        spinning = false
        canvas.look(view == near ? far : near)
    }

    func viewLabel(_ side: String) -> String {
        switch (side, view) {
        case ("front", "back"): return "Back"
        case ("side", "right"): return "Right"
        case ("side", "left"): return "Left"
        case ("top", "bottom"): return "Bottom"
        default: return side.capitalized
        }
    }

    func viewOn(_ side: String) -> Bool { ["front": ["front", "back"], "side": ["right", "left"], "top": ["top", "bottom"]][side]?.contains(view ?? "") == true }

    // one press = an eighth of a turn; ⌥-drag turns them freely
    func turnLight() {
        guard model != nil else { return }
        canvas.turnLight(by: .pi / 4)
        var degrees = Int((canvas.lightTurn * 180 / .pi).rounded()) % 360
        if degrees < 0 { degrees += 360 }
        flash(degrees == 0 ? "Lights back to start" : "Lights turned \(degrees)°")
    }

    func nextBackdrop() {
        let all = Backdrop.allCases
        backdrop = all[((all.firstIndex(of: backdrop) ?? 0) + 1) % all.count]
        UserDefaults.standard.set(backdrop.rawValue, forKey: "model.backdrop")
        canvas.setBackdrop(backdrop)
        if model != nil { flash("Backdrop: \(backdrop.rawValue)") }
    }

    func showRecent() {
        let menu = NSMenu()
        let others = ModelViewer.shared.recent.filter { $0 != url?.path }
        for path in others {
            let file = URL(fileURLWithPath: path)
            let item = ClosureItem(file.lastPathComponent) { [weak self] in self?.load(file) }
            if #available(macOS 14.4, *) { item.subtitle = (file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
            menu.addItem(item)
        }
        if others.isEmpty {
            let none = NSMenuItem(title: "No other recent models", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Open…") { [weak self] in ModelViewer.shared.pick(into: self) })
        if !ModelViewer.shared.recent.isEmpty { menu.addItem(ClosureItem("Clear this list") { [weak self] in ModelViewer.shared.clearRecent(); self?.objectWillChange.send() }) }
        guard let window = canvas.window else { return }
        menu.popUp(positioning: nil, at: canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: canvas)
    }

    // MARK: poses

    // one press spaces the groups out, the next every single part, the next puts it back
    func explode() {
        guard let poser, poser.canExplode else { return }
        poser.go(poser.next, on: canvas)
        pose = poser.pose
    }

    func toggleDrawn() {
        guard let poser, poser.canDraw else { return }
        poser.go(poser.pose == .drawn ? .together : .drawn, on: canvas)
        pose = poser.pose
    }

    var explodeLabel: String {
        switch pose {
        case .groups: return "Explode all"
        case .apart: return "Assemble"
        default: return "Explode"
        }
    }

    // MARK: animation

    var duration: Double { clips.indices.contains(clip) ? clips[clip].duration : 0 }
    var time: Double { clock }

    // play once has run out: the next play starts it over
    private var atEnd: Bool { speed > 0 ? clock >= duration - 0.001 : clock <= 0.001 }

    private func play(_ on: Bool) {
        guard on, duration > 0 else { canvas.stop("play"); return }
        if !looping, atEnd { show(speed > 0 ? 0 : duration) }
        canvas.loop("play") { [weak self] passed in self?.advance(passed * (self?.speed ?? 1)) }
    }

    private func advance(_ by: Double) {
        let t = clock + by
        if looping || (t > 0 && t < duration) { show(t); return }
        // play once: stop on the last (or, backwards, the first) frame
        show(t >= duration ? duration : 0)
        playing = false
    }

    private func show(_ seconds: Double, wrap: Bool? = nil) {
        guard duration > 0 else { return }
        if wrap ?? looping {
            clock = seconds.truncatingRemainder(dividingBy: duration)
            if clock < 0 { clock += duration }
        } else {
            clock = min(max(seconds, 0), duration)
        }
        // the clip's own clock wraps at its length, so the very end is drawn a hair before it
        canvas.sceneTime = min(clock, duration - 0.0001)
        canvas.needsDisplay = true
        // the bar doesn't need to redraw more than 30 times a second
        if abs(clock - playhead.time) > 1.0 / 30 || clock == 0 || clock == duration { playhead.time = clock }
    }

    func seek(_ seconds: Double) { show(min(max(seconds, 0), duration), wrap: false); playhead.time = clock }

    // back to the first frame and wait there
    func stopClip() { playing = false; seek(speed > 0 ? 0 : duration) }

    // one frame at 30 a second
    func step(_ frames: Int) {
        guard duration > 0 else { return }
        playing = false
        let t = clock + Double(frames) / 30
        seek(looping ? (t < 0 ? t + duration : (t > duration ? t - duration : t)) : t)
    }

    func choose(_ index: Int) {
        guard clips.indices.contains(index) else { return }
        if index != clip {
            let was = playing
            playing = false
            clips[clip].detach()
            clip = index
            clips[clip].attach()
            seek(speed > 0 ? 0 : duration)
            playing = was
        } else if !playing {
            // clicking the clip you're on plays it from the top
            seek(speed > 0 ? 0 : duration)
            playing = true
        }
    }

    func nextClip() { if clips.count > 1 { choose((clip + 1) % clips.count) } }

    // keeps it between ±0.01 and ±20 times; 0 or nonsense keeps what was there
    func setSpeed(_ value: Double) {
        guard value.isFinite, value != 0 else { return }
        speed = (value < 0 ? -1 : 1) * min(max(abs(value), 0.01), 20)
    }

    // what was typed in the speed box: "0.5", ".25", "2x", "50%", "-1" (backwards)
    static func parseSpeed(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        var scale = 1.0
        if t.hasSuffix("%") { t.removeLast(); scale = 0.01 }
        if t.hasSuffix("x") || t.hasSuffix("×") { t.removeLast() }
        if t.hasPrefix("x") || t.hasPrefix("×") { t.removeFirst() }
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), v != 0 else { return nil }
        return v * scale
    }

    // P and A: open the side panel on that page, or close it if it's already showing it
    func showTab(_ which: SideTab) {
        if panel, tab == which { panel = false } else { tab = which; panel = true }
    }

    // MARK: pictures

    private func png() -> Data? { canvas.picture().tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } }

    func copyPicture() {
        guard model != nil, let data = png() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        flash("Picture copied")
    }

    func savePicture() {
        guard model != nil, let url, let data = png() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try data.write(to: target); flash("Picture saved") } catch { flash("Couldn't save there") }
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in if self?.toast == text { self?.toast = nil } }
    }

    func dump() -> [String: Any] {
        ["file": url?.path ?? "", "loading": loading, "problem": problem ?? "", "triangles": triangles, "parts": rows.count, "cutoutMaterials": cutouts, "loadSeconds": loadSeconds,
         "metal": canvas.renderingAPI == .metal, "device": canvas.device?.name ?? "", "wireframe": wireframe, "windowNumber": window.windowNumber, "visible": window.isVisible,
         "frame": NSStringFromRect(window.frame), "screen": window.screen?.localizedName ?? "", "distance": canvas.distance, "yaw": canvas.yaw, "pitch": canvas.pitch,
         "pose": pose.rawValue, "canExplode": canExplode, "canDraw": canDraw, "spinning": spinning, "clips": clips.map { "\($0.name) \(String(format: "%.2f", $0.duration))s" },
         "clip": clip, "playing": playing, "time": clock, "speed": speed, "looping": looping, "tab": tab.rawValue, "facts": facts, "selected": selected ?? -1, "hidden": hiddenCount, "clay": clay, "panel": panel,
         "watching": watch != nil, "reloads": reloads, "toast": toast ?? "", "rows": rows.prefix(8).map { "\($0.name) \($0.triangles)" },
         "view": view ?? "", "flat": flat, "light": Int((canvas.lightTurn * 180 / .pi).rounded()), "backdrop": backdrop.rawValue]
    }
}

struct ModelViewerView: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var theme = Theme.shared
    @State private var dropping = false

    private var showing: Bool { doc.url != nil && doc.problem == nil && !doc.loading }
    // the dark plates behind the corner text get heavier when the backdrop is bright
    private var plate: Double { doc.backdrop.bright ? 0.74 : 0.45 }

    var body: some View {
        // the parts panel sits beside the 3D view, never over the model
        HStack(spacing: 0) {
            ZStack {
                CanvasHost(canvas: doc.canvas)
                if doc.url == nil || doc.problem != nil { empty }
                if doc.loading { Text("LOADING").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(Palette.ash).allowsHitTesting(false) }
                if showing {
                    VStack(alignment: .trailing, spacing: 10) {
                        Text("drag turn · scroll or pinch zoom · ⇧ drag pan · ⌥ drag lights · click select · double-click zoom in")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(doc.backdrop.bright ? Palette.bone : Palette.ash.opacity(0.7)).lineLimit(1)
                            .padding(.horizontal, doc.backdrop.bright ? 8 : 0).padding(.vertical, doc.backdrop.bright ? 4 : 0)
                            .background(Color.black.opacity(doc.backdrop.bright ? plate : 0)).allowsHitTesting(false)
                        if let toast = doc.toast {
                            Text(toast.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(Palette.pit)
                                .padding(.horizontal, 10).padding(.vertical, 5).background(theme.accent).allowsHitTesting(false)
                        }
                        Spacer(minLength: 0)
                        if !doc.clips.isEmpty, !(doc.panel && doc.tab == .anims) { player }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .bottom, spacing: 12) { info.allowsHitTesting(false); Spacer(minLength: 0); chips }
                            VStack(alignment: .trailing, spacing: 8) { chips; HStack { info.allowsHitTesting(false); Spacer(minLength: 0) } }
                            VStack(alignment: .leading, spacing: 8) { ScrollView(.horizontal, showsIndicators: false) { chips }; info.allowsHitTesting(false) }
                        }
                    }
                    .padding(14)
                }
                if dropping { Rectangle().stroke(theme.accent, lineWidth: 3).allowsHitTesting(false) }
            }
            if showing, doc.panel { SidePanel(doc: doc) }
        }
        .frame(minWidth: 640, minHeight: 420)
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
            let recent = ModelViewer.shared.recent.filter { $0 != doc.url?.path }.prefix(6)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash).padding(.leading, 8).padding(.bottom, 4)
                    ForEach(Array(recent), id: \.self) { path in RecentLine(path: path) { doc.load(URL(fileURLWithPath: path)) } }
                }
                .frame(width: 380, alignment: .leading).padding(.top, 14)
            }
        }
    }

    var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(doc.url?.lastPathComponent ?? "").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.bone).lineLimit(1).truncationMode(.middle)
            Text("\(doc.triangles.formatted()) triangles · \(doc.rows.count) \(doc.rows.count == 1 ? "part" : "parts") · \(ByteCountFormatter.string(fromByteCount: doc.bytes, countStyle: .file))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.black.opacity(plate))
    }

    // two rows: how you look at it (views, lights, backdrop, recent files) over what you do to it
    var chips: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                ViewerChip(title: doc.viewLabel("front"), key: "1", on: doc.viewOn("front"), plate: plate) { doc.look("front") }
                ViewerChip(title: doc.viewLabel("side"), key: "2", on: doc.viewOn("side"), plate: plate) { doc.look("side") }
                ViewerChip(title: doc.viewLabel("top"), key: "3", on: doc.viewOn("top"), plate: plate) { doc.look("top") }
                ViewerChip(title: "Flat", key: "4", on: doc.flat, plate: plate) { doc.flat.toggle() }
                ViewerChip(title: "Lights", key: "L", on: false, plate: plate) { doc.turnLight() }
                ViewerChip(title: "Backdrop", key: "B", on: false, plate: plate) { doc.nextBackdrop() }
                ViewerChip(title: "Recent", key: "R", on: false, plate: plate) { doc.showRecent() }
            }
            HStack(spacing: 6) {
                if doc.canDraw { ViewerChip(title: doc.pose == .drawn ? "Sheathe" : "Unsheath", key: "U", on: doc.pose == .drawn, plate: plate) { doc.toggleDrawn() } }
                if doc.canExplode { ViewerChip(title: doc.explodeLabel, key: "E", on: doc.pose == .groups || doc.pose == .apart, plate: plate) { doc.explode() } }
                ViewerChip(title: "Spin", key: "S", on: doc.spinning, plate: plate) { doc.spinning.toggle() }
                ViewerChip(title: "Clay", key: "C", on: doc.clay, plate: plate) { doc.clay.toggle() }
                ViewerChip(title: "Wire", key: "W", on: doc.wireframe, plate: plate) { doc.wireframe.toggle() }
                ViewerChip(title: "Fit", key: "F", on: false, plate: plate) { doc.canvas.reframe() }
                if !doc.clips.isEmpty { ViewerChip(title: "Anims", key: "A", on: doc.panel && doc.tab == .anims, plate: plate) { doc.showTab(.anims) } }
                ViewerChip(title: "Parts", key: "P", on: doc.panel && doc.tab == .parts, plate: plate) { doc.showTab(.parts) }
            }
        }
    }

    // the small bar under the model; the Animations tab has the full player
    var player: some View {
        HStack(spacing: 10) {
            Button { doc.playing.toggle() } label: {
                Image(systemName: doc.playing ? "pause.fill" : "play.fill").font(.system(size: 12)).foregroundStyle(theme.accent).frame(width: 26, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ScrubBar(doc: doc, playhead: doc.playhead, compact: true)
            if doc.clips.indices.contains(doc.clip) {
                ViewerChip(title: doc.clips[doc.clip].name, key: doc.clips.count > 1 ? "\(doc.clip + 1)/\(doc.clips.count)" : "", on: false) { doc.nextClip() }
            }
            ViewerChip(title: "\(SpeedBox.label(doc.speed))× · \(doc.looping ? "loop" : "once")", key: "A", on: false) { doc.showTab(.anims) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.black.opacity(plate))
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }
}

enum SideTab: String { case parts, anims }

final class Playhead: ObservableObject { @Published var time = 0.0 }

// the side panel: the model's parts on one page, its animations on the other
struct SidePanel: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                tab("Parts", .parts, count: doc.rows.count)
                tab("Animations", .anims, count: doc.clips.count)
            }
            .padding(.top, 30)
            Rectangle().fill(Palette.rule).frame(height: 1)
            if doc.tab == .parts { PartsPanel(doc: doc) } else { AnimationsPane(doc: doc) }
        }
        .frame(width: 264)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.035, green: 0.035, blue: 0.04))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.rule).frame(width: 1) }
    }

    func tab(_ title: String, _ which: SideTab, count: Int) -> some View {
        let on = doc.tab == which
        return Button { doc.tab = which } label: {
            HStack(spacing: 5) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(on ? Palette.bone : Palette.ash)
                Text("\(count)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(on ? theme.accent : Palette.ash.opacity(0.7))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(on ? theme.accent : .clear).frame(height: 2) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// the full player: every clip in the file, transport, loop or once, a scrub bar and a speed you can type
struct AnimationsPane: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var theme = Theme.shared

    var body: some View {
        if doc.clips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                label("No animations")
                Text("This file has no animation in it.").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.bone)
                Text("Blender's .usdz export often leaves animation out; a .glb export keeps it.").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if doc.clips.indices.contains(doc.clip) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(doc.clips[doc.clip].name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(theme.accent).lineLimit(1).truncationMode(.middle)
                            Text("clip \(doc.clip + 1) of \(doc.clips.count) · \(String(format: "%.2f", doc.duration)) s · \(Int((doc.duration * 30).rounded())) frames").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash)
                        }
                    }
                    ScrubBar(doc: doc, playhead: doc.playhead, compact: false)
                    HStack(spacing: 4) {
                        icon("backward.end.fill", "Back to the start") { doc.stopClip() }
                        icon("backward.frame.fill", "One frame back (←)") { doc.step(-1) }
                        icon(doc.playing ? "pause.fill" : "play.fill", "Play / pause (Space)", big: true) { doc.playing.toggle() }
                        icon("forward.frame.fill", "One frame on (→)") { doc.step(1) }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        label("Repeat")
                        Spacer()
                        ViewerChip(title: "Loop", key: "", on: doc.looping) { doc.looping = true }.help("Play round and round (O switches)")
                        ViewerChip(title: "Once", key: "O", on: !doc.looping) { doc.looping = false }.help("Play to the end and stop (O switches)")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            label("Speed")
                            Spacer()
                            SpeedBox(doc: doc)
                        }
                        HStack(spacing: 4) {
                            ForEach([0.1, 0.25, 0.5, 1, 2], id: \.self) { v in
                                ViewerChip(title: SpeedBox.label(v) + "×", key: "", on: doc.speed == v) { doc.setSpeed(v) }
                            }
                        }
                        Text("type any speed · minus plays backwards · [ ] halve / double").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ash.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                Rectangle().fill(Palette.rule).frame(height: 1)
                HStack { label("Clips"); Spacer() }.padding(.horizontal, 12).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(spacing: 1) { ForEach(doc.clips.indices, id: \.self) { i in ClipLine(doc: doc, playhead: doc.playhead, index: i) } }.padding(.bottom, 8)
                }
            }
        }
    }

    func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash)
    }

    func icon(_ name: String, _ tip: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: big ? 14 : 11)).foregroundStyle(big ? Palette.pit : Palette.bone)
                .frame(width: big ? 36 : 28, height: 26)
                .background(big ? theme.accent : Color.black.opacity(0.45))
                .overlay(Rectangle().stroke(big ? theme.accent : Palette.ash.opacity(0.5)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(tip).accessibilityLabel(tip)
    }
}

// one clip in the list: its name and length; the one playing shows how far along it is
struct ClipLine: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var playhead: Playhead
    @ObservedObject var theme = Theme.shared
    let index: Int
    @State private var over = false

    // the list can empty under a row while the window closes or the file reloads
    var body: some View {
        if doc.clips.indices.contains(index) { row(doc.clips[index]) }
    }

    func row(_ clip: ModelClip) -> some View {
        let on = doc.clip == index
        return HStack(spacing: 8) {
            Image(systemName: on && doc.playing ? "speaker.wave.2.fill" : "film").font(.system(size: 9)).foregroundStyle(on ? theme.accent : Palette.ash).frame(width: 14)
            Text(clip.name).font(.system(size: 11, design: .monospaced)).fontWeight(on ? .bold : .regular).foregroundStyle(Palette.bone).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(String(format: "%.2f s", clip.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(on ? Palette.bone : Palette.ash)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .leading) { if on { Rectangle().fill(theme.accent).frame(width: 3) } }
        .background(alignment: .leading) {
            GeometryReader { box in
                Rectangle().fill(on ? theme.accent.opacity(0.28) : Color.white.opacity(over ? 0.07 : 0))
                    .frame(width: on && doc.duration > 0 ? box.size.width * CGFloat(playhead.time / doc.duration) : box.size.width)
            }
        }
        .contentShape(Rectangle())
        .onHover { over = $0 }
        .onTapGesture { doc.choose(index) }
        .help(on ? "Play this clip from the start" : "Switch to this clip")
    }
}

// drag to scrub; it pauses while you drag and carries on after if it was playing
struct ScrubBar: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var playhead: Playhead
    @ObservedObject var theme = Theme.shared
    let compact: Bool
    @State private var resume = false

    var body: some View {
        let slider = Slider(value: Binding(get: { playhead.time }, set: { doc.seek($0) }), in: 0...max(doc.duration, 0.01)) { editing in
            if editing { resume = doc.playing; doc.playing = false } else if resume { resume = false; doc.playing = true }
        }
        .controlSize(.small).tint(theme.accent).focusable(false)
        let readout = Text("\(String(format: "%.2f", playhead.time)) / \(String(format: "%.2f", doc.duration)) s").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
            .frame(width: 112, height: 14, alignment: .trailing)
        // fixed sizes, so a changing number never makes the window lay itself out again
        if compact {
            HStack(spacing: 10) { slider.frame(height: 18); readout }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                slider.frame(height: 18)
                HStack(spacing: 0) {
                    Text("frame \(Int((playhead.time * 30).rounded()))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash.opacity(0.8)).lineLimit(1)
                        .frame(width: 100, height: 14, alignment: .leading)
                    Spacer(minLength: 0)
                    readout
                }
            }
        }
    }
}

// the speed you type: Return or clicking away keeps it, Esc puts back what was there
struct SpeedBox: View {
    @ObservedObject var doc: ModelDoc
    @State private var text = ""
    @State private var bad = false
    @FocusState private var typing: Bool

    static func label(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        HStack(spacing: 3) {
            TextField("1", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(bad ? Color.red : Palette.bone)
                .multilineTextAlignment(.trailing).frame(width: 58)
                .focused($typing)
                .onSubmit { commit(); doc.window.makeFirstResponder(doc.canvas) }
                .onExitCommand { text = Self.label(doc.speed); bad = false; doc.window.makeFirstResponder(doc.canvas) }
            Text("×").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ash)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.black.opacity(0.5))
        .overlay(Rectangle().stroke(typing ? Palette.accent : Palette.ash.opacity(0.5)))
        .help("Type a speed: 0.5, 2, 50%, -1 plays backwards")
        .onAppear { text = Self.label(doc.speed) }
        .onChange(of: doc.speed) { _, v in if !typing { text = Self.label(v) } }
        .onChange(of: typing) { _, now in if !now { commit() } }
    }

    private func commit() {
        if let v = ModelDoc.parseSpeed(text) { doc.setSpeed(v); bad = false; text = Self.label(doc.speed) }
        else { bad = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { bad = false; text = Self.label(doc.speed) } }
    }
}

// every part with its triangle count: hover to outline it, click to zoom in on it, eye to hide it
struct PartsPanel: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var theme = Theme.shared

    private var rows: [PartRow] { doc.byTriangles ? doc.rows.sorted { $0.triangles > $1.triangles } : doc.rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var heaviest: Int { max(doc.rows.map(\.triangles).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                label("Model")
                Text("\(doc.triangles.formatted()) triangles · \(doc.rows.count) \(doc.rows.count == 1 ? "part" : "parts")").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.bone)
                ForEach(doc.facts, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            Rectangle().fill(Palette.rule).frame(height: 1)
            HStack(spacing: 6) {
                label("Parts")
                Spacer()
                if doc.hiddenCount > 0 { ViewerChip(title: "Show all", key: "", on: false) { doc.showAll() } }
                ViewerChip(title: doc.byTriangles ? "Heaviest" : "A–Z", key: "", on: false) { doc.byTriangles.toggle() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 1) { ForEach(rows) { row in line(row) } }.padding(.bottom, 8)
            }
            if let i = doc.selected, doc.rows.indices.contains(i) {
                Rectangle().fill(Palette.rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.rows[i].name).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(theme.accent).lineLimit(1).truncationMode(.middle)
                    Text("\(doc.rows[i].triangles.formatted()) triangles · \(Int((Double(doc.rows[i].triangles) / Double(max(doc.triangles, 1)) * 100).rounded()))% of the model").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.bone)
                    Text("\(doc.rows[i].materials) \(doc.rows[i].materials == 1 ? "material" : "materials")\(doc.rows[i].group.isEmpty ? "" : " · in \(doc.rows[i].group)")").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1)
                    HStack(spacing: 6) {
                        ViewerChip(title: doc.rows[i].hidden ? "Show" : "Hide", key: "H", on: doc.rows[i].hidden) { doc.toggleHidden(i) }
                        ViewerChip(title: "Only this", key: "I", on: false) { doc.solo(i) }
                    }.padding(.top, 3)
                }
                .padding(12)
            }
        }
        .onHover { if !$0 { doc.hovered = nil } }
    }

    func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash)
    }

    func line(_ row: PartRow) -> some View {
        let picked = doc.selected == row.id
        return HStack(spacing: 8) {
            Button { doc.toggleHidden(row.id) } label: {
                Image(systemName: row.hidden ? "eye.slash" : "eye").font(.system(size: 10)).foregroundStyle(row.hidden ? Palette.ash.opacity(0.6) : Palette.ash).frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(row.name).font(.system(size: 11, design: .monospaced)).fontWeight(picked ? .bold : .regular).foregroundStyle(row.hidden ? Palette.ash.opacity(0.6) : Palette.bone).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(row.triangles.formatted()).font(.system(size: 11, design: .monospaced)).foregroundStyle(picked ? Palette.bone : Palette.ash)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(alignment: .leading) { if picked { Rectangle().fill(theme.accent).frame(width: 3) } }
        // the bar behind a row is its share of the heaviest part, so the expensive ones stand out
        .background(alignment: .leading) {
            GeometryReader { box in Rectangle().fill((picked ? theme.accent : Palette.bone).opacity(picked ? 0.3 : 0.07)).frame(width: box.size.width * CGFloat(row.triangles) / CGFloat(heaviest)) }
        }
        .contentShape(Rectangle())
        .onHover { doc.hovered = $0 ? row.id : (doc.hovered == row.id ? nil : doc.hovered) }
        .onTapGesture { doc.select(picked ? nil : row.id, focus: !picked) }
    }
}

// small toggle in the viewer's corner; the dim letter is its key
struct ViewerChip: View {
    let title: String
    let key: String
    let on: Bool
    var plate = 0.45
    let action: () -> Void
    @ObservedObject var theme = Theme.shared
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(on ? Palette.pit : Palette.bone).lineLimit(1)
                if !key.isEmpty { Text(key).font(.system(size: 9, design: .monospaced)).foregroundStyle(on ? Palette.pit.opacity(0.7) : Palette.ash) }
            }
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(on ? theme.accent : Color.black.opacity(plate))
            .overlay(Rectangle().stroke(on ? theme.accent : Palette.ash.opacity(0.5)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// one recent file in the empty window: its name, then the folder it's in
struct RecentLine: View {
    let path: String
    let action: () -> Void
    @State private var over = false
    var body: some View {
        HStack(spacing: 10) {
            Text((path as NSString).lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.bone).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Text((((path as NSString).deletingLastPathComponent) as NSString).abbreviatingWithTildeInPath).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(over ? 0.07 : 0))
        .contentShape(Rectangle())
        .onHover { over = $0 }
        .onTapGesture(perform: action)
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
