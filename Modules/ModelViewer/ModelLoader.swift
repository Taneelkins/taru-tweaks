import AppKit
import SceneKit
import GLTFKit2

// one mesh of the model, as it sits when the file opens
struct ModelPart {
    let node: SCNNode
    let name: String
    let home: SIMD3<Float>      // world position at rest
    let low: SIMD3<Float>       // world box at rest
    let high: SIMD3<Float>
    let sheath: Bool            // named like a sheath (or sits in a group named like one)
    let path: [String]          // names of the groups it sits in, nearest first
    var branch: ObjectIdentifier // the top group it belongs to, below any wrapper every part shares
    let triangles: Int
    let materials: Int
}

// one animation in the file: everything it moves, on the view's own clock so it can be paused and scrubbed
final class ModelClip {
    let name: String
    let duration: Double
    private let players: [(node: SCNNode, key: String, player: SCNAnimationPlayer)]

    init(name: String, players: [(node: SCNNode, key: String, player: SCNAnimationPlayer)]) {
        self.name = name
        self.players = players
        duration = players.map { $0.player.animation.duration }.max() ?? 0
    }

    func attach() { for p in players { p.node.addAnimationPlayer(p.player, forKey: p.key); p.player.play() } }
    func detach() { for p in players { p.node.removeAnimation(forKey: p.key) } }

    static func player(_ animation: SCNAnimation) -> SCNAnimationPlayer {
        animation.usesSceneTimeBase = true
        animation.repeatCount = .greatestFiniteMagnitude
        animation.isRemovedOnCompletion = false
        return SCNAnimationPlayer(animation: animation)
    }
}

struct LoadedModel {
    let scene: SCNScene
    let stage: SCNNode          // holds the model and the camera; turning it turns both under the studio lights
    let content: SCNNode
    let low: SIMD3<Float>
    let high: SIMD3<Float>
    let triangles: Int
    let cutouts: Int
    let parts: [ModelPart]
    let clips: [ModelClip]
    let setup: ModelSetup?
    let materials: Int
    let textures: Int
    let largestTexture: Int     // longest side in pixels, 0 when unknown
}

enum ModelLoader {
    static let types: Set<String> = ["usdz", "usd", "usda", "usdc", "obj", "glb", "gltf", "fbx"]
    static let sheathNames = ["saya", "sheath", "scabbard", "sageo", "holster"]

    struct Failure: LocalizedError { let errorDescription: String? }

    // runs off the main thread; everything here is plain data until the view takes the scene
    static func load(_ file: URL) throws -> LoadedModel {
        // SceneKit can't read .fbx; turn it into a cached .glb first and load that
        let url = file.pathExtension.lowercased() == "fbx" ? try FBX.glb(for: file) : file
        let ext = url.pathExtension.lowercased()
        let gltf = ext == "glb" || ext == "gltf"
        let source: SCNScene
        var named: [(String, SCNAnimation)] = []
        var images: Int?
        if gltf {
            // GLTFKit2 (MIT) builds the SceneKit scene; it already turns MASK materials into cutouts
            let asset = try GLTFAsset(url: url, options: [:])
            let reader = GLTFSCNSceneSource(asset: asset)
            guard let scene = reader.defaultScene ?? reader.scenes.first else { throw Failure(errorDescription: "No scene in this file") }
            source = scene
            // SceneKit splits one glTF image into several textures, so count the file's own images
            images = asset.images.count
            named = reader.animations.map { ($0.name, $0.animationPlayer.animation) }
        } else {
            source = try SCNScene(url: url, options: [.checkConsistency: false])
        }

        // own scene, so file lights, cameras and backgrounds never change the studio look
        let scene = SCNScene()
        let content = SCNNode()
        for child in source.rootNode.childNodes { child.removeFromParentNode(); content.addChildNode(child) }
        // Blender's USD export is Z-up and SceneKit doesn't turn it
        if let up = source.attribute(forKey: SCNScene.Attribute.upAxis.rawValue) as? SCNVector3, up.z > 0.5 { content.eulerAngles.x = -.pi / 2 }
        let stage = SCNNode()
        stage.addChildNode(content)
        scene.rootNode.addChildNode(stage)

        var triangles = 0, cutouts = 0
        var parts: [ModelPart] = []
        var chains: [[SCNNode]] = []
        var materials = Set<ObjectIdentifier>(), pictures = Set<String>(), largest = 0
        var moving: [(node: SCNNode, key: String, player: SCNAnimationPlayer)] = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var seen = Set<ObjectIdentifier>()
        content.enumerateHierarchy { node, _ in
            node.light = nil; node.camera = nil
            // USD files arrive with their animation already running; take it over
            for key in node.animationKeys {
                if let player = node.animationPlayer(forKey: key) { moving.append((node, key, ModelClip.player(player.animation))) }
                node.removeAnimation(forKey: key)
            }
            guard let geometry = node.geometry else { return }
            let own = geometry.elements.reduce(0) { $0 + count($1) }
            triangles += own
            for material in geometry.materials where materials.insert(ObjectIdentifier(material)).inserted {
                for slot in [material.diffuse, material.normal, material.metalness, material.roughness, material.emission, material.ambientOcclusion] {
                    guard let (key, side) = picture(slot.contents) else { continue }
                    if pictures.insert(key).inserted { largest = max(largest, side) }
                }
            }
            let (a, b) = geometry.boundingBox
            var partLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude), partHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = node.simdConvertPosition(SIMD3(Float(x), Float(y), Float(z)), to: nil)
                partLow = simd_min(partLow, p); partHigh = simd_max(partHigh, p)
            } } }
            low = simd_min(low, partLow); high = simd_max(high, partHigh)
            var chain: [SCNNode] = [], walk: SCNNode? = node
            while let n = walk, n !== content { chain.insert(n, at: 0); walk = n.parent }
            let names = chain.map { $0.name ?? "" }
            let sheath = names.contains { name in sheathNames.contains { name.lowercased().contains($0) } }
            chains.append(chain)
            parts.append(ModelPart(node: node, name: node.name ?? "Part \(parts.count + 1)", home: node.simdWorldPosition, low: partLow, high: partHigh, sheath: sheath,
                                   path: names.dropLast().reversed(), branch: ObjectIdentifier(node), triangles: own, materials: geometry.materials.count))
            if !gltf {
                for material in geometry.materials where seen.insert(ObjectIdentifier(material)).inserted { if cutout(material, usdz: url) { cutouts += 1 } }
            }
        }
        guard !parts.isEmpty, low.x <= high.x else { throw Failure(errorDescription: "No meshes in this file") }
        // skip the wrappers every part sits in ("root", "Scene"), then the next group down is the part's branch
        var shared = 0
        while let first = chains.first, shared < first.count - 1, chains.allSatisfy({ $0.count > shared + 1 && $0[shared] === first[shared] }) { shared += 1 }
        for i in parts.indices { parts[i].branch = ObjectIdentifier(chains[i][min(shared, chains[i].count - 1)]) }
        var clips = named.enumerated().map { i, pair in ModelClip(name: pair.0.isEmpty ? "Clip \(i + 1)" : pair.0, players: [(content, "clip", ModelClip.player(pair.1))]) }
        if !moving.isEmpty { clips.append(ModelClip(name: "Animation", players: moving)) }
        return LoadedModel(scene: scene, stage: stage, content: content, low: low, high: high, triangles: triangles, cutouts: cutouts, parts: parts, clips: clips.filter { $0.duration > 0 },
                           setup: ModelSetup.load(for: file), materials: materials.count, textures: images ?? pictures.count, largestTexture: largest)
    }

    // a texture's identity and its longest side, without decoding it
    static func picture(_ contents: Any?) -> (String, Int)? {
        guard let contents, !(contents is NSNumber), !(contents is NSColor) else { return nil }
        if let texture = contents as? MTLTexture { return ("\(ObjectIdentifier(texture as AnyObject))", max(texture.width, texture.height)) }
        if let image = contents as? NSImage { return ("\(ObjectIdentifier(image))", image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0) }
        if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { let image = contents as! CGImage; return ("\(ObjectIdentifier(image))", max(image.width, image.height)) }
        let url = (contents as? URL) ?? (contents as? String).map { URL(fileURLWithPath: $0) }
        guard let url else { return ("\(ObjectIdentifier(contents as AnyObject))", 0) }
        var side = 0
        if let data = bytes(url), let source = CGImageSourceCreateWithData(data as CFData, nil), let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            side = max(info[kCGImagePropertyPixelWidth] as? Int ?? 0, info[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        return (url.absoluteString, side)
    }

    // textures inside a .usdz come back as "<file>.usdz?offset=…&size=…"
    static func bytes(_ url: URL) -> Data? {
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let offset = parts.queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
           let size = parts.queryItems?.first(where: { $0.name == "size" })?.value.flatMap(Int.init), let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: url.path)) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: size)
        }
        return try? Data(contentsOf: url)
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

    static func image(_ contents: Any?, usdz: URL, maxSide: Int = 512) -> CGImage? {
        if let image = contents as? NSImage { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if let string = contents as? String { return image(URL(fileURLWithPath: string), usdz: usdz, maxSide: maxSide) }
        guard let url = contents as? URL else {
            if let c = contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID { return (c as! CGImage) }
            return nil
        }
        let data = bytes(url)
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
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

    // a soft top-to-bottom fade behind the model: greys from the bottom, the middle and the top of the window
    static func fade(_ bottom: CGFloat, _ middle: CGFloat, _ top: CGFloat) -> CGImage? {
        let w = 64, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // a touch of blue, like the app's own dark
        let colors = [bottom, middle, top].map { CGColor(red: $0, green: $0, blue: min($0 * 1.13, 1), alpha: 1) } as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return ctx.makeImage()
    }
}

// what's behind the model; the lighting stays the studio's whichever is picked
enum Backdrop: String, CaseIterable {
    case dark, black, grey, light

    var bright: Bool { self == .grey || self == .light }

    private static let pictures: [Backdrop: CGImage] = {
        var made: [Backdrop: CGImage] = [:]
        made[.dark] = Studio.fade(0.035, 0.075, 0.11)
        made[.grey] = Studio.fade(0.2, 0.27, 0.33)
        made[.light] = Studio.fade(0.62, 0.74, 0.82)
        return made
    }()

    var picture: Any { Backdrop.pictures[self] ?? NSColor.black }
}

// .fbx → .glb with the Assimp command-line tool (BSD-3) bundled in the app (Homebrew's as a fallback).
// The .glb is cached by path, size and date, so reopening the same file is instant.
enum FBX {
    static var tool: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/assimp")
        for url in [bundled, URL(fileURLWithPath: "/opt/homebrew/bin/assimp"), URL(fileURLWithPath: "/usr/local/bin/assimp")]
        where FileManager.default.isExecutableFile(atPath: url.path) { return url }
        return nil
    }

    static func glb(for file: URL) throws -> URL {
        guard let tool else { throw ModelLoader.Failure(errorDescription: "Opening .fbx needs the Assimp converter, which is missing from Model Viewer") }
        let info = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (info?[.size] as? NSNumber)?.int64Value ?? 0
        let date = Int((info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Model Viewer/fbx", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = file.deletingPathExtension().lastPathComponent
        let out = folder.appendingPathComponent("\(name)-\(stableKey(file.path))-\(size)-\(date).glb")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        // drop older conversions of this same file
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("\(name)-\(stableKey(file.path))-") { try? FileManager.default.removeItem(at: old) }
        let temp = folder.appendingPathComponent(UUID().uuidString + ".glb")
        let run = Process()
        run.executableURL = tool
        run.arguments = ["export", file.path, temp.path, "-fglb2", "-tri"]
        let err = Pipe(); run.standardError = err; run.standardOutput = Pipe()
        try run.run(); run.waitUntilExit()
        guard run.terminationStatus == 0, FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ModelLoader.Failure(errorDescription: "Couldn't convert this .fbx" + (text.isEmpty ? "" : ": " + String(text.suffix(200))))
        }
        try FileManager.default.moveItem(at: temp, to: out)
        return out
    }

    // FNV-1a, stable across launches (Swift's Hasher is seeded per run)
    static func stableKey(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
