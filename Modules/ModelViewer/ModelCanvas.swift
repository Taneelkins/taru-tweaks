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
    private var timers: [String: Timer] = [:]
    private var fitted = false                   // still framed on the whole model, so a resized view re-frames it

    var onClick: ((CGPoint) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var onKey: ((String) -> Bool)?
    private var pressed = CGPoint.zero
    private var dragged = false
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

    // intro: the camera swings in from further round and further back. keepView: a re-export of the same file, so stay where you were looking
    func show(_ model: LoadedModel, intro: Bool, keepView: Bool = false) {
        stopAll()
        rig.removeFromParentNode()
        model.scene.rootNode.addChildNode(rig)
        model.scene.lightingEnvironment.contents = Studio.environment
        model.scene.lightingEnvironment.intensity = 1.15
        model.scene.background.contents = Studio.backdrop
        scene = model.scene
        pointOfView = rig
        sceneTime = 0
        setBounds(low: model.low, high: model.high)
        if keepView { apply(); return }
        yaw = -0.6; pitch = -0.3
        target = center; distance = fitDistance; fitted = true
        apply()
        guard intro, onScreen else { return }
        let toYaw = yaw, toPitch = pitch
        run("camera", seconds: 0.9) { [weak self] t in
            guard let self else { return }
            let ease = 1 - pow(1 - t, 4)
            self.yaw = toYaw - (1 - ease) * 1.3
            self.pitch = toPitch + (1 - ease) * 0.22
            // asked fresh each frame: the view may still be settling to its size (the parts panel sliding in)
            self.distance = self.fitDistance * (1 + (1 - ease) * 0.45)
            self.apply()
        }
    }

    func clear() { stopAll(); scene = nil }

    private var onScreen: Bool { window?.occlusionState.contains(.visible) == true }

    // MARK: timers (only alive while something is moving)

    func run(_ name: String, seconds: Double, tick: @escaping (Float) -> Void, done: (() -> Void)? = nil) {
        stop(name)
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            let t = Float(min((CACurrentMediaTime() - start) / max(seconds, 0.001), 1))
            tick(t)
            if t >= 1 { timer.invalidate(); self?.timers[name] = nil; done?() }
        }
        timers[name] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // runs until stopped; gets the seconds since its last tick, and skips ticks while the window can't be seen
    func loop(_ name: String, tick: @escaping (Double) -> Void) {
        stop(name)
        var last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            let now = CACurrentMediaTime(), passed = min(now - last, 0.1)
            last = now
            if self?.onScreen == true { tick(passed) }
        }
        timers[name] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop(_ name: String) { timers[name]?.invalidate(); timers[name] = nil }
    func stopAll() { timers.values.forEach { $0.invalidate() }; timers = [:] }
    func running(_ name: String) -> Bool { timers[name] != nil }

    // MARK: camera

    private var turnNow: simd_quatf { simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0]) }

    private func setBounds(low: SIMD3<Float>, high: SIMD3<Float>) {
        center = (low + high) / 2; radius = max(simd_length(high - low) / 2, 0.0001)
        corners = [low.x, high.x].flatMap { x in [low.y, high.y].flatMap { y in [low.z, high.z].map { z in SIMD3(x, y, z) } } }
    }

    // just far enough back that the model's box fits the window from the angle you're looking at
    private var fitDistance: Float { fit(corners, around: center) }

    private func fit(_ corners: [SIMD3<Float>], around middle: SIMD3<Float>) -> Float {
        let up = tan(fov * .pi / 360), across = up * Float(max(bounds.width, 1) / max(bounds.height, 1))
        let back = turnNow.inverse
        var need: Float = 0
        for corner in corners {
            let p = back.act(corner - middle)
            need = max(need, abs(p.x) / across + p.z, abs(p.y) / up + p.z)
        }
        return max(need, radius * 0.05) * 1.06
    }

    // glide in on one part (or one spot) without forgetting how big the whole model is
    func focus(low: SIMD3<Float>, high: SIMD3<Float>, animated: Bool = true) {
        let box = [low.x, high.x].flatMap { x in [low.y, high.y].flatMap { y in [low.z, high.z].map { z in SIMD3(x, y, z) } } }
        let middle = (low + high) / 2
        glide(to: middle, distance: fit(box, around: middle) * 1.5, animated: animated)
    }

    func focus(on point: SIMD3<Float>) { glide(to: point, distance: min(distance, max(radius * 0.7, distance * 0.55)), animated: true) }

    private func glide(to spot: SIMD3<Float>, distance wanted: Float, animated: Bool) {
        stop("camera"); fitted = false
        let fromTarget = target, fromDistance = distance
        guard animated, onScreen else { target = spot; distance = wanted; apply(); return }
        run("camera", seconds: 0.35) { [weak self] t in
            guard let self else { return }
            let ease = 1 - pow(1 - t, 3)
            self.target = fromTarget + (spot - fromTarget) * ease
            self.distance = fromDistance + (wanted - fromDistance) * ease
            self.apply()
        }
    }

    // what's under a point of the view: the mesh and the exact spot on it
    func pick(_ point: CGPoint) -> (node: SCNNode, spot: SIMD3<Float>)? {
        hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true]).first.map { ($0.node, $0.simdWorldCoordinates) }
    }

    func picture() -> NSImage { snapshot() }

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
        stop("camera")
        yaw -= dx * 0.008; pitch -= dy * 0.008
        apply()
    }

    func pan(dx: Float, dy: Float) {
        stop("camera"); fitted = false
        let turn = turnNow
        target += (turn.act([1, 0, 0]) * -dx + turn.act([0, 1, 0]) * dy) * perPoint
        apply()
    }

    // how much of the model one screen point covers at the spot the camera turns around
    private var perPoint: Float { 2 * distance * tan(fov * .pi / 360) / Float(max(bounds.height, 1)) }

    // zooms toward the pointer, so what you point at stays under it (nil = toward the middle)
    func zoom(by factor: Float, at point: CGPoint? = nil) {
        stop("camera"); fitted = false
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
    func reframe(animated: Bool = true, seconds: Double = 0.3) { refit(low: nil, high: nil, animated: animated, seconds: seconds) }

    // the model changed shape (parts spread out or came back): glide to fit the new box
    func refit(low: SIMD3<Float>?, high: SIMD3<Float>?, animated: Bool, seconds: Double) {
        stop("camera")
        let fromTarget = target, fromDistance = distance, fromCenter = center, fromRadius = radius
        if let low, let high { setBounds(low: low, high: high) }
        let toCenter = center, toRadius = radius, toDistance = fitDistance
        fitted = true
        guard animated, onScreen else { target = center; distance = toDistance; apply(); return }
        run("camera", seconds: seconds) { [weak self] t in
            guard let self else { return }
            let ease = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            // the limits glide too, so the view never snaps when the box shrinks
            self.center = fromCenter + (toCenter - fromCenter) * ease
            self.radius = fromRadius + (toRadius - fromRadius) * ease
            self.target = fromTarget + (toCenter - fromTarget) * ease
            self.distance = fromDistance + (toDistance - fromDistance) * ease
            self.apply()
        }
    }

    var spinning: Bool {
        get { running("spin") }
        set {
            guard newValue != spinning else { return }
            if newValue { loop("spin") { [weak self] passed in self?.yaw -= Float(passed) * 0.5; self?.apply() } } else { stop("spin") }
        }
    }

    var wireframe: Bool {
        get { debugOptions.contains(.showWireframe) }
        set { if newValue { debugOptions.insert(.showWireframe) } else { debugOptions.remove(.showWireframe) } }
    }

    // MARK: trackpad and mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = convert(e.locationInWindow, from: nil); dragged = false
    }
    // a press that never moved is a click: once selects what's under it, twice zooms in on it
    override func mouseUp(with e: NSEvent) {
        guard !dragged else { return }
        if e.clickCount == 2 { onDoubleClick?(pressed) } else if e.clickCount == 1 { onClick?(pressed) }
    }
    override func mouseDragged(with e: NSEvent) {
        let here = convert(e.locationInWindow, from: nil)
        if !dragged, hypot(here.x - pressed.x, here.y - pressed.y) < 3 { return }
        dragged = true
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
    override func smartMagnify(with e: NSEvent) { reframe() }

    override func keyDown(with e: NSEvent) {
        if !e.modifierFlags.contains(.command), let key = e.charactersIgnoringModifiers?.lowercased(), onKey?(key) == true { return }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let name = ["o": "open", "c": "copy", "s": "save"][e.charactersIgnoringModifiers?.lowercased() ?? ""], onKey?(name) == true { return true }
        return super.performKeyEquivalent(with: e)
    }

    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); apply() }

    // the window or the parts panel changed the view's shape: if you hadn't zoomed or panned, keep the model framed
    override func setFrameSize(_ size: NSSize) {
        let changed = size != frame.size
        super.setFrameSize(size)
        if changed, fitted, scene != nil, !running("camera") { distance = fitDistance; apply() }
    }

    // MARK: frame timing for the debug hook

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        if recording { frameTimes.append(CACurrentMediaTime()) }
    }

    // turns the model through the same code a drag uses and reports how evenly the frames came
    func benchmark(seconds: Double, done: @escaping ([String: Any]) -> Void) {
        frameTimes = []; recording = true
        var ticks = 0
        run("bench", seconds: seconds, tick: { [weak self] _ in
            guard let self else { return }
            ticks += 1
            self.turn(dx: 3, dy: Float(sin(Double(ticks) / 40)) * 0.6)
            if ticks % 2 == 0 { self.zoom(by: 1 + Float(sin(Double(ticks) / 25)) * 0.01) }
        }, done: { [weak self] in
            guard let self else { return }
            self.recording = false
            let times = self.frameTimes
            let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
            let span = (times.last ?? 0) - (times.first ?? 0)
            done(["frames": times.count, "fps": span > 0 ? Double(times.count - 1) / span : 0,
                  "medianMs": gaps.isEmpty ? 0 : gaps[gaps.count / 2], "p99Ms": gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, gaps.count * 99 / 100)], "worstMs": gaps.last ?? 0])
        })
    }
}
