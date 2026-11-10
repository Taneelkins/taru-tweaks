import AppKit
import SceneKit

// SceneKit view (Metal) with its own turntable camera: nothing draws unless the camera or the model changes.
final class ModelCanvas: SCNView, SCNSceneRendererDelegate {
    private let rig = SCNNode()
    private let lens = SCNCamera()
    private let fov: Float = 32

    private(set) var center = SIMD3<Float>(repeating: 0)
    private(set) var radius: Float = 1
    private var corners: [SIMD3<Float>] = []
    private(set) var target = SIMD3<Float>(repeating: 0)
    private(set) var distance: Float = 3
    private(set) var yaw: Float = -0.6
    private(set) var pitch: Float = -0.3
    private var glide: Timer?

    var onDoubleClick: (() -> Void)?
    var onKey: ((String) -> Bool)?
    private(set) var frameTimes: [TimeInterval] = []
    var recording = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 620), options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        allowsCameraControl = false
        antialiasingMode = .multisampling4X
        rendersContinuously = false
        preferredFramesPerSecond = 120
        backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        delegate = self
        lens.fieldOfView = CGFloat(fov)
        lens.wantsHDR = true
        lens.minimumExposure = 0; lens.maximumExposure = 0
        lens.bloomIntensity = 0
        rig.camera = lens
        // a soft light that rides with the camera, so the side you look at is never in the dark
        let head = SCNNode()
        head.light = SCNLight()
        head.light?.type = .directional
        head.light?.intensity = 450
        head.light?.color = NSColor(white: 1, alpha: 1)
        head.eulerAngles = SCNVector3(-0.45, -0.5, 0)
        rig.addChildNode(head)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ model: LoadedModel) {
        glide?.invalidate()
        rig.removeFromParentNode()
        model.scene.rootNode.addChildNode(rig)
        model.scene.lightingEnvironment.contents = Studio.environment
        model.scene.lightingEnvironment.intensity = 1.15
        model.scene.background.contents = Studio.backdrop
        scene = model.scene
        pointOfView = rig
        center = (model.low + model.high) / 2; radius = max(simd_length(model.high - model.low) / 2, 0.0001)
        corners = [model.low.x, model.high.x].flatMap { x in [model.low.y, model.high.y].flatMap { y in [model.low.z, model.high.z].map { z in SIMD3(x, y, z) } } }
        yaw = -0.6; pitch = -0.3
        target = center; distance = fitDistance
        apply()
    }

    func clear() { glide?.invalidate(); scene = nil }

    private var turnNow: simd_quatf { simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0]) }

    // just far enough back that the model's box fits the window from the angle you're looking at
    private var fitDistance: Float {
        let up = tan(fov * .pi / 360), across = up * Float(max(bounds.width, 1) / max(bounds.height, 1))
        let back = turnNow.inverse
        var need: Float = 0
        for corner in corners {
            let p = back.act(corner - center)
            need = max(need, abs(p.x) / across + p.z, abs(p.y) / up + p.z)
        }
        return max(need, radius * 0.05) * 1.06
    }

    private func apply() {
        pitch = min(max(pitch, -1.55), 1.55)
        distance = min(max(distance, radius * 0.02), radius * 60)
        // the model can't be pushed out of reach
        let away = target - center
        if simd_length(away) > radius * 1.5 { target = center + simd_normalize(away) * radius * 1.5 }
        let turn = turnNow
        rig.simdOrientation = turn
        rig.simdPosition = target + turn.act([0, 0, distance])
        let reach = simd_length(target - center) + radius
        lens.zNear = Double(max(distance - reach, distance * 0.02, radius * 0.002))
        lens.zFar = Double(distance + reach * 2)
    }

    func turn(dx: Float, dy: Float) {
        glide?.invalidate()
        yaw -= dx * 0.008; pitch -= dy * 0.008
        apply()
    }

    func pan(dx: Float, dy: Float) {
        glide?.invalidate()
        let turn = turnNow
        target += (turn.act([1, 0, 0]) * -dx + turn.act([0, 1, 0]) * dy) * perPoint
        apply()
    }

    // how much of the model one screen point covers at the spot the camera turns around
    private var perPoint: Float { 2 * distance * tan(fov * .pi / 360) / Float(max(bounds.height, 1)) }

    // zooms toward the pointer, so what you point at stays under it (nil = toward the middle)
    func zoom(by factor: Float, at point: CGPoint? = nil) {
        glide?.invalidate()
        let wanted = min(max(distance * factor, radius * 0.02), radius * 60)
        if let point {
            let turn = turnNow
            let off = turn.act([1, 0, 0]) * Float(point.x - bounds.midX) + turn.act([0, 1, 0]) * Float(point.y - bounds.midY)
            target += off * perPoint * (1 - wanted / distance)
        }
        distance = wanted
        apply()
    }

    // glide back to the whole model, keeping the angle you were looking from
    func reframe(animated: Bool = true) {
        glide?.invalidate()
        let fromTarget = target, fromDistance = distance, toDistance = fitDistance
        guard animated, window?.occlusionState.contains(.visible) == true else { target = center; distance = toDistance; apply(); return }
        let start = CACurrentMediaTime(), length = 0.28
        glide = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Float(min((CACurrentMediaTime() - start) / length, 1)), ease = 1 - pow(1 - t, 3)
            self.target = fromTarget + (self.center - fromTarget) * ease
            self.distance = fromDistance + (toDistance - fromDistance) * ease
            self.apply()
            if t >= 1 { timer.invalidate() }
        }
    }

    var wireframe: Bool {
        get { debugOptions.contains(.renderAsWireframe) }
        set { if newValue { debugOptions.insert(.renderAsWireframe) } else { debugOptions.remove(.renderAsWireframe) } }
    }

    // MARK: trackpad and mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.clickCount == 2 { onDoubleClick?() }
    }
    override func mouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) { pan(dx: Float(e.deltaX), dy: Float(e.deltaY)) } else { turn(dx: Float(e.deltaX), dy: Float(e.deltaY)) }
    }
    override func rightMouseDown(with e: NSEvent) { window?.makeFirstResponder(self) }
    override func rightMouseDragged(with e: NSEvent) { pan(dx: Float(e.deltaX), dy: Float(e.deltaY)) }
    override func otherMouseDragged(with e: NSEvent) { pan(dx: Float(e.deltaX), dy: Float(e.deltaY)) }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) {
            pan(dx: Float(e.scrollingDeltaX), dy: Float(e.scrollingDeltaY))
            return
        }
        // fingers pushed away (or wheel rolled forward) = closer, whatever the "natural scrolling" switch says
        var push = Float(e.scrollingDeltaY) * (e.isDirectionInvertedFromDevice ? -1 : 1)
        if UserDefaults.standard.bool(forKey: "model.zoomFlip") { push = -push }
        zoom(by: exp(-push * (e.hasPreciseScrollingDeltas ? 0.006 : 0.06)), at: convert(e.locationInWindow, from: nil))
    }
    override func magnify(with e: NSEvent) { zoom(by: 1 / max(1 + Float(e.magnification), 0.2), at: convert(e.locationInWindow, from: nil)) }
    override func smartMagnify(with e: NSEvent) { onDoubleClick?() }

    override func keyDown(with e: NSEvent) {
        if let key = e.charactersIgnoringModifiers?.lowercased(), onKey?(key) == true { return }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers?.lowercased() == "o", onKey?("open") == true { return true }
        return super.performKeyEquivalent(with: e)
    }

    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); apply() }

    // MARK: frame timing for the debug hook

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        if recording { frameTimes.append(CACurrentMediaTime()) }
    }

    // turns the model through the same code a drag uses and reports how evenly the frames came
    func benchmark(seconds: Double, done: @escaping ([String: Any]) -> Void) {
        frameTimes = []; recording = true
        let start = CACurrentMediaTime()
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            self.turn(dx: 3, dy: Float(sin(Double(ticks) / 40)) * 0.6)
            if ticks % 2 == 0 { self.zoom(by: 1 + Float(sin(Double(ticks) / 25)) * 0.01) }
            guard CACurrentMediaTime() - start >= seconds else { return }
            timer.invalidate(); self.recording = false
            let times = self.frameTimes
            let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
            let span = (times.last ?? 0) - (times.first ?? 0)
            done(["frames": times.count, "fps": span > 0 ? Double(times.count - 1) / span : 0,
                  "medianMs": gaps.isEmpty ? 0 : gaps[gaps.count / 2], "p99Ms": gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, gaps.count * 99 / 100)], "worstMs": gaps.last ?? 0])
        }
    }
}
