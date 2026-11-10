import AppKit
import SceneKit
import GLTFKit2

struct LoadedModel {
    let scene: SCNScene
    let content: SCNNode
    let low: SIMD3<Float>
    let high: SIMD3<Float>
    let triangles: Int
    let parts: Int
    let cutouts: Int
}

enum ModelLoader {
    static let types: Set<String> = ["usdz", "usd", "usda", "usdc", "obj", "glb", "gltf"]

    struct Failure: LocalizedError { let errorDescription: String? }

    // runs off the main thread; everything here is plain data until the view takes the scene
    static func load(_ url: URL) throws -> LoadedModel {
        let ext = url.pathExtension.lowercased()
        let source: SCNScene
        if ext == "glb" || ext == "gltf" {
            // GLTFKit2 (MIT) builds the SceneKit scene; it already turns MASK materials into cutouts
            source = SCNScene(gltfAsset: try GLTFAsset(url: url, options: [:]))
        } else {
            source = try SCNScene(url: url, options: [.checkConsistency: false])
        }

        // own scene, so file lights, cameras and backgrounds never change the studio look
        let scene = SCNScene()
        let content = SCNNode()
        for child in source.rootNode.childNodes { child.removeFromParentNode(); content.addChildNode(child) }
        // Blender's USD export is Z-up and SceneKit doesn't turn it
        if let up = source.attribute(forKey: SCNScene.Attribute.upAxis.rawValue) as? SCNVector3, up.z > 0.5 { content.eulerAngles.x = -.pi / 2 }
        scene.rootNode.addChildNode(content)

        var triangles = 0, parts = 0, cutouts = 0
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var seen = Set<ObjectIdentifier>()
        content.enumerateHierarchy { node, _ in
            node.light = nil; node.camera = nil
            guard let geometry = node.geometry else { return }
            parts += 1
            for element in geometry.elements { triangles += count(element) }
            let (a, b) = geometry.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = node.simdConvertPosition(SIMD3(Float(x), Float(y), Float(z)), to: nil)
                low = simd_min(low, p); high = simd_max(high, p)
            } } }
            if ext != "glb" && ext != "gltf" {
                for material in geometry.materials where seen.insert(ObjectIdentifier(material)).inserted { if cutout(material, usdz: url) { cutouts += 1 } }
            }
        }
        guard parts > 0, low.x <= high.x else { throw Failure(errorDescription: "No meshes in this file") }
        return LoadedModel(scene: scene, content: content, low: low, high: high, triangles: triangles, parts: parts, cutouts: cutouts)
    }

    static func count(_ e: SCNGeometryElement) -> Int {
        switch e.primitiveType {
        case .triangles, .triangleStrip: return e.primitiveCount
        case .polygon:
            // polygon data starts with one corner count per face; a face of n corners draws as n - 2 triangles
            let size = e.bytesPerIndex
            guard e.data.count >= e.primitiveCount * size else { return 0 }
            return e.data.withUnsafeBytes { raw in
                (0..<e.primitiveCount).reduce(0) { total, i in
                    let n: Int
                    switch size {
                    case 1: n = Int(raw[i])
                    case 2: n = Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    default: n = Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    }
                    return total + max(n - 2, 0)
                }
            }
        default: return 0
        }
    }

    // USD/OBJ give an opacity texture but no "cutout" flag, and SceneKit then blends it: leaves sort wrong and
    // punch holes in what's behind them. A texture whose alpha is nearly all on/off is a cutout, so cut it instead.
    static func cutout(_ m: SCNMaterial, usdz: URL) -> Bool {
        let contents = m.transparent.contents
        if contents == nil || contents is NSNumber || contents is NSColor { return false }
        guard let image = image(contents, usdz: usdz), isCutout(image) else { return false }
        m.blendMode = .replace
        m.transparencyMode = .default
        m.shaderModifiers = [.fragment: "if (_output.color.a < 0.5) { discard_fragment(); }"]
        return true
    }

    static func image(_ contents: Any?, usdz: URL) -> CGImage? {
        if let image = contents as? NSImage { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if let string = contents as? String { return image(URL(fileURLWithPath: string), usdz: usdz) }
        guard let url = contents as? URL else {
            if let c = contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID { return (c as! CGImage) }
            return nil
        }
        var data: Data?
        // textures inside a .usdz come back as "<file>.usdz?offset=…&size=…"
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let offset = parts.queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
           let size = parts.queryItems?.first(where: { $0.name == "size" })?.value.flatMap(Int.init), let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: url.path)) {
            try? handle.seek(toOffset: offset); data = try? handle.read(upToCount: size); try? handle.close()
        } else {
            data = try? Data(contentsOf: url)
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
    }

    static func isCutout(_ image: CGImage) -> Bool {
        let side = 256
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return false }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var clear = 0, soft = 0
        for i in 0..<(side * side) {
            let a = px[i * 4 + 3]
            if a < 26 { clear += 1 } else if a < 230 { soft += 1 }
        }
        // some real holes, and few in-between pixels (glass and smoke are mostly in-between)
        return clear > 0 && soft * 3 < clear + soft
    }
}

// Soft studio: a dark room with a big overhead light, a key, a fill and a cool rim, so metals have something to reflect.
enum Studio {
    static let environment: CGImage? = {
        let w = 1024, h = 512
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
        // room: floor (bottom of the picture) darker than the walls, ceiling a little brighter
        let room = CGGradient(colorsSpace: space, colors: [color(0.012, 0.012, 0.014), color(0.05, 0.05, 0.055), color(0.16, 0.16, 0.17)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(room, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        // u 0…1 goes round the room, v 0 floor … 1 straight up
        func lamp(u: CGFloat, v: CGFloat, width: CGFloat, height: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            let glow = CGGradient(colorsSpace: space, colors: [color(r, g, b), color(r, g, b, 0.55), color(r, g, b, 0)] as CFArray, locations: [0, 0.45, 1])!
            for wrap in [-1, 0, 1] as [CGFloat] {
                ctx.saveGState()
                ctx.translateBy(x: (u + wrap) * CGFloat(w), y: v * CGFloat(h))
                ctx.scaleBy(x: width * CGFloat(w), y: height * CGFloat(h))
                ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 0.5, options: [])
                ctx.restoreGState()
            }
        }
        ctx.setBlendMode(.plusLighter)
        lamp(u: 0.5, v: 1.0, width: 1.6, height: 0.55, 1.6, 1.6, 1.7)      // overhead softbox
        lamp(u: 0.36, v: 0.68, width: 0.22, height: 0.30, 7.0, 6.7, 6.2)   // key, front-left and up
        lamp(u: 0.68, v: 0.56, width: 0.30, height: 0.40, 1.5, 1.6, 1.8)   // fill, front-right
        lamp(u: 0.02, v: 0.60, width: 0.10, height: 0.50, 5.0, 5.6, 6.6)   // rim strip behind
        lamp(u: 0.86, v: 0.40, width: 0.16, height: 0.22, 1.2, 1.2, 1.3)   // low kicker
        return ctx.makeImage()
    }()

    static let backdrop: CGImage? = {
        let w = 64, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1), CGColor(red: 0.075, green: 0.075, blue: 0.085, alpha: 1), CGColor(red: 0.11, green: 0.11, blue: 0.125, alpha: 1)] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return ctx.makeImage()
    }()
}
