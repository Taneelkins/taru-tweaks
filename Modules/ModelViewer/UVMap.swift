import SwiftUI
import AppKit
import SceneKit
import CoreImage

// UV map: every part's texture layout, flat, over its texture. Opens beside the 3D view (V) so a click on either
// side picks the same part; the checker (K) puts a numbered grid on the model to show stretching and seams.

// one part's UV triangles, three corners each, in SceneKit's texture space (0,0 = top-left of the image)
struct UVPart {
    let index: Int
    let corners: [SIMD2<Float>]
    let path: CGPath
}

enum UVReader {
    static func parts(_ model: LoadedModel) -> [UVPart] {
        model.parts.enumerated().compactMap { i, part in
            guard let g = part.node.geometry else { return nil }
            let corners = triangles(g)
            guard !corners.isEmpty else { return nil }
            let path = CGMutablePath()
            var k = 0
            while k + 2 < corners.count {
                let a = corners[k], b = corners[k + 1], c = corners[k + 2]
                path.move(to: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
                path.addLine(to: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
                path.addLine(to: CGPoint(x: CGFloat(c.x), y: CGFloat(c.y)))
                path.closeSubpath()
                k += 3
            }
            return UVPart(index: i, corners: corners, path: path)
        }
    }

    static func triangles(_ g: SCNGeometry) -> [SIMD2<Float>] {
        guard let src = g.sources(for: .texcoord).first, src.vectorCount > 0, src.componentsPerVector >= 2 else { return [] }
        let data = src.data, step = src.dataStride, offset = src.dataOffset, size = src.bytesPerComponent, count = src.vectorCount
        guard data.count >= offset + (count - 1) * step + 2 * size else { return [] }
        var uv = [SIMD2<Float>](repeating: .zero, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let at = offset + i * step
                switch (src.usesFloatComponents, size) {
                case (true, 4): uv[i] = SIMD2(raw.loadUnaligned(fromByteOffset: at, as: Float.self), raw.loadUnaligned(fromByteOffset: at + 4, as: Float.self))
                case (true, 8): uv[i] = SIMD2(Float(raw.loadUnaligned(fromByteOffset: at, as: Double.self)), Float(raw.loadUnaligned(fromByteOffset: at + 8, as: Double.self)))
                case (true, 2): uv[i] = SIMD2(Float(raw.loadUnaligned(fromByteOffset: at, as: Float16.self)), Float(raw.loadUnaligned(fromByteOffset: at + 2, as: Float16.self)))
                case (false, 2): uv[i] = SIMD2(Float(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)) / 65535, Float(raw.loadUnaligned(fromByteOffset: at + 2, as: UInt16.self)) / 65535)
                case (false, 1): uv[i] = SIMD2(Float(raw[at]) / 255, Float(raw[at + 1]) / 255)
                default: break
                }
            }
        }
        var out: [SIMD2<Float>] = []
        // USD files keep separate index lists per source (position, normal, UV…) side by side in one element
        let slot = g.sources.firstIndex { $0 === src } ?? 0
        for e in g.elements {
            var idx = indices(e)
            let channels = max(e.indicesChannelCount, 1)
            if channels > 1 {
                let head = e.primitiveType == .polygon ? min(e.primitiveCount, idx.count) : 0
                let body = Array(idx[head...])
                func pick(_ c: Int) -> [Int] { stride(from: c, to: body.count, by: channels).map { body[$0] } }
                // the UV channel sits where the UV source sits among the sources; fall back to the one that fits the UV count
                var chosen = pick(min(slot, channels - 1))
                if chosen.max() ?? 0 >= count, let fit = (0..<channels).map(pick).first(where: { ($0.max() ?? 0) == count - 1 }) { chosen = fit }
                idx = Array(idx[..<head]) + chosen
            }
            func put(_ a: Int, _ b: Int, _ c: Int) {
                guard a < count, b < count, c < count else { return }
                out.append(uv[a]); out.append(uv[b]); out.append(uv[c])
            }
            switch e.primitiveType {
            case .triangles:
                var k = 0
                while k + 2 < idx.count { put(idx[k], idx[k + 1], idx[k + 2]); k += 3 }
            case .triangleStrip:
                if idx.count >= 3 { for k in 0..<(idx.count - 2) { k % 2 == 0 ? put(idx[k], idx[k + 1], idx[k + 2]) : put(idx[k + 1], idx[k], idx[k + 2]) } }
            case .polygon:
                // first come the corner counts, one per face, then the corners themselves
                let faces = e.primitiveCount
                guard idx.count >= faces else { break }
                var at = faces
                for f in 0..<faces {
                    let n = idx[f]
                    guard at + n <= idx.count else { break }
                    if n >= 3 { for k in 1..<(n - 1) { put(idx[at], idx[at + k], idx[at + k + 1]) } }
                    at += n
                }
            default: break
            }
        }
        return out
    }

    static func indices(_ e: SCNGeometryElement) -> [Int] {
        let size = e.bytesPerIndex, total = e.data.count / max(size, 1)
        return e.data.withUnsafeBytes { raw in
            (0..<total).map { i in
                switch size {
                case 1: return Int(raw[i])
                case 2: return Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                default: return Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
            }
        }
    }

    // the base-colour picture of a material, at up to 2048 px, whatever form SceneKit holds it in
    static func texture(_ material: SCNMaterial?, file: URL) -> CGImage? {
        guard let contents = material?.diffuse.contents else { return nil }
        if let texture = contents as? MTLTexture, let ci = CIImage(mtlTexture: texture, options: nil) {
            // Metal textures read bottom-up
            let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
            return CIContext().createCGImage(flipped, from: flipped.extent)
        }
        return ModelLoader.image(contents, usdz: file, maxSide: 2048)
    }

    // a numbered grid in eight colours, so stretched, squashed or flipped spots show at a glance
    static let checker: NSImage = {
        let side = 1024, cells = 8, cell = CGFloat(side / cells)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let hues: [CGFloat] = [0.0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.88]
        for row in 0..<cells { for col in 0..<cells {
            let dark = (row + col) % 2 == 0
            NSColor(hue: hues[col], saturation: dark ? 0.55 : 0.35, brightness: dark ? 0.55 : 0.85, alpha: 1).setFill()
            // row 0 at the top of the image, like the texture
            let rect = NSRect(x: CGFloat(col) * cell, y: CGFloat(cells - 1 - row) * cell, width: cell, height: cell)
            rect.fill()
            let label = "\(Character(UnicodeScalar(65 + row)!))\(col + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: cell * 0.32, weight: .bold), .foregroundColor: NSColor(white: dark ? 1 : 0.1, alpha: 0.85)]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            // a small corner mark shows which way is up
            NSColor(white: dark ? 1 : 0, alpha: 0.6).setFill()
            NSRect(x: rect.minX + 6, y: rect.maxY - 14, width: 8, height: 8).fill()
        } }
        image.unlockFocus()
        return image
    }()
}

// the flat view, drawn by the graphics card like the 3D view so panning and zooming stay smooth on big layouts:
// scroll or pinch zooms toward the pointer, drag (or a two-finger swipe) pans, click picks a part, double-click fits
final class UVCanvas: SCNView {
    var parts: [UVPart] = [] { didSet { rebuildLines() } }
    var hiddenParts: Set<Int> = [] { didSet { if hiddenParts != oldValue { rebuildLines() } } }
    var selected: Int? { didSet { if selected != oldValue { rebuildLines() } } }
    var image: CGImage? { didSet { if image !== oldValue { rebuildBackdrop() } } }
    var accent = NSColor.systemRed { didSet { rebuildLines() } }
    var onPick: ((Int?) -> Void)?
    private(set) var zoom: CGFloat = 1
    private(set) var pan = CGPoint.zero        // in texture units
    private var dragged = false
    private let camera = SCNNode()
    private let backdrop = SCNNode()
    private let lines = SCNNode()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400), options: [SCNView.Option.preferredRenderingAPI.rawValue: NSNumber(value: SCNRenderingAPI.metal.rawValue)])
        let scene = SCNScene()
        self.scene = scene
        backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        antialiasingMode = .multisampling4X
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 100
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(backdrop)
        scene.rootNode.addChildNode(lines)
        pointOfView = camera
        rebuildBackdrop()
        place()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }

    func fit() { zoom = 1; pan = .zero; place() }

    // texture space: u to the right, v down; the 0…1 square fills 88% of the shorter side at zoom 1
    private func place() {
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let half = 0.5 / 0.88 / zoom
        camera.camera?.orthographicScale = Double(w < h ? half * h / w : half)
        camera.position = SCNVector3(0.5 + pan.x, -0.5 - pan.y, 10)
    }

    // texture units per screen point
    private var unit: CGFloat { (camera.camera.map { CGFloat($0.orthographicScale) } ?? 1) * 2 / max(bounds.height, 1) }

    func uv(at p: CGPoint) -> SIMD2<Float> {
        // p is in view points with y up (AppKit)
        let u = 0.5 + pan.x + (p.x - bounds.midX) * unit
        let v = 0.5 + pan.y - (p.y - bounds.midY) * unit
        return SIMD2(Float(u), Float(v))
    }

    private static func flat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.isDoubleSided = true
        m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
        m.blendMode = .alpha
        return m
    }

    private static func lineGeometry(_ points: [SCNVector3], color: NSColor) -> SCNGeometry {
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .line)])
        g.materials = [flat(color)]
        return g
    }

    private func rebuildBackdrop() {
        backdrop.childNodes.forEach { $0.removeFromParentNode() }
        let plane = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        plane.position = SCNVector3(0.5, -0.5, -1)
        if let image {
            let m = Self.flat(.white)
            m.diffuse.contents = image
            m.diffuse.minificationFilter = .linear; m.diffuse.magnificationFilter = .linear; m.diffuse.mipFilter = .linear
            // dimmed a little so the lines read on bright textures
            m.multiply.contents = NSColor(white: 0.8, alpha: 1)
            plane.geometry?.materials = [m]
        } else {
            plane.geometry?.materials = [Self.flat(NSColor(white: 0.13, alpha: 1))]
            var grid: [SCNVector3] = []
            for k in 1..<8 { let t = CGFloat(k) / 8
                grid += [SCNVector3(t, 0, -0.9), SCNVector3(t, -1, -0.9), SCNVector3(0, -t, -0.9), SCNVector3(1, -t, -0.9)] }
            backdrop.addChildNode(SCNNode(geometry: Self.lineGeometry(grid, color: NSColor(white: 1, alpha: 0.06))))
        }
        backdrop.addChildNode(plane)
        // the 0…1 square, plus faint neighbours for UVs that spill outside it
        var frame: [SCNVector3] = []
        for dx in -2...2 { for dy in -2...2 {
            let x = CGFloat(dx), y = -CGFloat(dy)
            frame += [SCNVector3(x, y, -0.5), SCNVector3(x + 1, y, -0.5), SCNVector3(x + 1, y, -0.5), SCNVector3(x + 1, y - 1, -0.5),
                      SCNVector3(x + 1, y - 1, -0.5), SCNVector3(x, y - 1, -0.5), SCNVector3(x, y - 1, -0.5), SCNVector3(x, y, -0.5)]
        } }
        backdrop.addChildNode(SCNNode(geometry: Self.lineGeometry(frame, color: NSColor(white: 1, alpha: 0.07))))
        let main = [SCNVector3(0, 0, -0.4), SCNVector3(1, 0, -0.4), SCNVector3(1, 0, -0.4), SCNVector3(1, -1, -0.4), SCNVector3(1, -1, -0.4), SCNVector3(0, -1, -0.4), SCNVector3(0, -1, -0.4), SCNVector3(0, 0, -0.4)]
        backdrop.addChildNode(SCNNode(geometry: Self.lineGeometry(main, color: NSColor(white: 1, alpha: 0.35))))
    }

    private func rebuildLines() {
        lines.childNodes.forEach { $0.removeFromParentNode() }
        let shown = parts.filter { !hiddenParts.contains($0.index) }
        func layer(_ list: [UVPart], fill: NSColor, edge: NSColor, z: CGFloat) {
            var tri: [SCNVector3] = [], seg: [SCNVector3] = []
            for part in list {
                var k = 0
                while k + 2 < part.corners.count {
                    let a = SCNVector3(CGFloat(part.corners[k].x), -CGFloat(part.corners[k].y), z)
                    let b = SCNVector3(CGFloat(part.corners[k + 1].x), -CGFloat(part.corners[k + 1].y), z)
                    let c = SCNVector3(CGFloat(part.corners[k + 2].x), -CGFloat(part.corners[k + 2].y), z)
                    tri += [a, b, c]; seg += [a, b, b, c, c, a]
                    k += 3
                }
            }
            guard !tri.isEmpty else { return }
            let filled = SCNGeometry(sources: [SCNGeometrySource(vertices: tri)], elements: [SCNGeometryElement(indices: (0..<Int32(tri.count)).map { $0 }, primitiveType: .triangles)])
            filled.materials = [Self.flat(fill)]
            let node = SCNNode(geometry: filled); node.renderingOrder = Int(z * 10)
            lines.addChildNode(node)
            let edges = SCNNode(geometry: Self.lineGeometry(seg, color: edge)); edges.renderingOrder = Int(z * 10) + 1
            lines.addChildNode(edges)
        }
        layer(shown.filter { $0.index != selected }, fill: NSColor(white: 1, alpha: selected == nil ? 0.05 : 0.02),
              edge: NSColor(white: 1, alpha: selected == nil ? 0.7 : 0.2), z: 0)
        if let selected { layer(shown.filter { $0.index == selected }, fill: accent.withAlphaComponent(0.2), edge: accent, z: 1) }
    }

    // the part whose triangle is under the point; the selected one first, so clicking it again keeps it
    func part(at p: CGPoint) -> Int? {
        let q = uv(at: p)
        func inside(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            func side(_ p1: SIMD2<Float>, _ p2: SIMD2<Float>) -> Float { (q.x - p2.x) * (p1.y - p2.y) - (p1.x - p2.x) * (q.y - p2.y) }
            let d1 = side(a, b), d2 = side(b, c), d3 = side(c, a)
            return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
        }
        let order = parts.filter { $0.index == selected } + parts.filter { $0.index != selected }
        for part in order where !hiddenParts.contains(part.index) {
            var k = 0
            while k + 2 < part.corners.count {
                if inside(part.corners[k], part.corners[k + 1], part.corners[k + 2]) { return part.index }
                k += 3
            }
        }
        return nil
    }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && (e.phase != [] || e.momentumPhase != []) {
            // two-finger swipe on a trackpad pans; a mouse wheel zooms
            pan.x -= e.scrollingDeltaX * unit; pan.y -= e.scrollingDeltaY * unit
            place()
        } else {
            zoom(by: e.scrollingDeltaY > 0 ? 1.12 : 1 / 1.12, at: convert(e.locationInWindow, from: nil))
        }
    }
    override func magnify(with e: NSEvent) { zoom(by: 1 + e.magnification, at: convert(e.locationInWindow, from: nil)) }

    func zoom(by factor: CGFloat, at p: CGPoint) {
        let before = uv(at: p)
        zoom = min(max(zoom * factor, 0.2), 80)
        place()
        // keep the spot under the pointer where it is
        let after = uv(at: p)
        pan.x += CGFloat(before.x - after.x); pan.y += CGFloat(before.y - after.y)
        place()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        dragged = false
        if e.clickCount == 2 { fit() }
    }
    override func mouseDragged(with e: NSEvent) {
        dragged = true
        pan.x -= e.deltaX * unit; pan.y -= e.deltaY * unit
        place()
        NSCursor.closedHand.set()
    }
    override func mouseUp(with e: NSEvent) {
        NSCursor.arrow.set()
        if !dragged, e.clickCount == 1 { onPick?(part(at: convert(e.locationInWindow, from: nil))) }
    }
}

struct UVHost: NSViewRepresentable {
    let canvas: UVCanvas
    func makeNSView(context: Context) -> UVCanvas { canvas }
    func updateNSView(_ view: UVCanvas, context: Context) {}
}

// the pane beside the 3D view
struct UVPane: View {
    @ObservedObject var doc: ModelDoc
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("UV MAP").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.bone)
                Text(doc.uvTitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                ViewerChip(title: "Texture", key: "", on: doc.uvTexture) { doc.uvTexture.toggle() }
                ViewerChip(title: "Checker", key: "K", on: doc.checker) { doc.checker.toggle() }
                ViewerChip(title: "Fit", key: "", on: false) { doc.uvCanvas.fit() }
                Button { doc.uvOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ash).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Close the UV map (V)")
            }
            .padding(.horizontal, 10).padding(.top, 30).padding(.bottom, 8)
            Rectangle().fill(Palette.rule).frame(height: 1)
            ZStack {
                UVHost(canvas: doc.uvCanvas)
                if doc.uvParts.isEmpty {
                    Text(doc.uvReading ? "READING UVS" : "NO UVS IN THIS MODEL").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash).allowsHitTesting(false)
                }
            }
            Rectangle().fill(Palette.rule).frame(height: 1)
            Text(doc.uvNote).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ash).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.035, green: 0.035, blue: 0.04))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.rule).frame(width: 1) }
    }
}
