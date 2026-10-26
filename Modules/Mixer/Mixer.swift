import AppKit
import CoreAudio
import SwiftUI

// Per-app volume. An app at 100% is never touched. Turn one down (or past 100% to boost) and it gets a
// Core Audio process tap: its sound is muted at the source, pulled through a private aggregate device,
// scaled and played on the current output. No audio driver. The engine (MixerEngine.swift) and the way
// taps are kept in step with the system below are ported from Vorssaint's mixer (GPL-3.0-or-later).
final class Mixer: ObservableObject {
    static let shared = Mixer()
    static let maxVolume: Double = 2

    struct AppAudio: Identifiable, Equatable {
        let id: String          // row: bundle id, or "process:<pid>" for a bare executable
        let key: String?        // what its volume is saved under (bundle id or name); nil = not saved
        let name: String
        let pid: pid_t
        var objects: [AudioObjectID]
        var playing: Bool
        var bypassed: Bool      // Zoom, DAWs (and Discord/Teams unless allowed): listed, never tapped
    }

    @Published private(set) var apps: [AppAudio] = []
    @Published var volumes: [String: Double] = (UserDefaults.standard.dictionary(forKey: "mixer.volumes") as? [String: Double]) ?? [:]
    @Published var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mixer.muted") ?? [])
    @Published private(set) var needsPermission = false
    @Published var enabled = UserDefaults.standard.object(forKey: "mixer.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "mixer.enabled"); enabled ? start() : stop() }
    }
    @Published var menuIcon = UserDefaults.standard.object(forKey: "mixer.menu") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuIcon, forKey: "mixer.menu"); item?.item.isVisible = menuIcon && enabled }
    }
    // replaying a call app under our process defeats its screen-share self-exclusion (viewers would hear the call)
    @Published var callApps = UserDefaults.standard.object(forKey: "mixer.callApps") as? Bool ?? true {
        didSet { UserDefaults.standard.set(callApps, forKey: "mixer.callApps"); refresh() }
    }

    private var engines: [String: GainEngine] = [:]
    private var item: TaruStatusItem?
    var statusItem: TaruStatusItem? { item }
    private var started = false
    private var open = false
    private var defaultUID: String?
    private var outputUIDs: [String] = []
    private var builds = Builds()
    private var recovery = Recovery()
    private var repairs: [String: CFAbsoluteTime] = [:]
    private var lostAt: [String: CFAbsoluteTime] = [:]
    private var renders: [String: (cycles: UInt64, at: Double)] = [:]
    private var reconcilePending = false
    private var reading = false, readAgain = false, generation = 0
    private var refreshPending = false
    private var lastRefreshAt: CFAbsoluteTime = 0
    private var running: [AudioObjectID: Set<AudioObjectPropertySelector>] = [:]
    private var processObjects: [AudioObjectID] = []
    private var wake: Any?
    // reading the HAL can block for tens of ms; building a tap too. Neither runs on main.
    private let halQueue = DispatchQueue(label: "com.taru.tweaks.mixer.hal", qos: .userInitiated)
    private let buildQueue = DispatchQueue(label: "com.taru.tweaks.mixer.build", qos: .userInitiated)

    func start() {
        guard enabled, !started else { return }
        started = true
        // a brand-new item lands at the far left, inside the section the Menu Bar ‹ hides; start it just left of the
        // battery, where the Taru Bar readouts (which draw over the icons right of it) can't cover it
        let ud = UserDefaults.standard
        if ud.object(forKey: "NSStatusItem Preferred Position Item-3") == nil { ud.set(6140.0, forKey: "NSStatusItem Preferred Position Item-3") }
        if item == nil {
            let s = TaruStatusItem(name: "Volume Mixer", autosave: "Item-3", page: "mixer", content: AnyView(MixerMenu()))
            s.set(symbol: "slider.vertical.3")
            s.onHide = { [weak self] in self?.menuIcon = false }
            s.onLog = { [weak self] in self?.log($0) }
            // the playing dots only matter while you're looking, so per-app play/stop events are only followed while open
            s.onShow = { [weak self] in self?.log("show"); self?.open = true; self?.refresh() }
            s.onClose = { [weak self] in self?.log("close"); self?.open = false; self?.refresh() }
            item = s
        }
        item?.item.isVisible = menuIcon
        // the HAL tells us when apps get/lose audio objects, devices come and go, or the output switches; no polling
        for sel in Self.globalSelectors {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListener(HAL.system, &a, Self.listener, nil)
        }
        // a wake can leave an aggregate that never renders again while its tap keeps muting the app
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            renders.removeAll(); recovery.clearAll()
            refresh(); reconcile(); scheduleReconcile(after: 2)
        }
        refresh()
    }

    func stop() {
        guard started else { return }
        started = false
        item?.close()
        item?.item.isVisible = false
        for sel in Self.globalSelectors {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(HAL.system, &a, Self.listener, nil)
        }
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
        prune(keeping: [])
        builds = Builds(); generation += 1; reading = false
        engines.values.forEach { $0.stop() }; engines = [:]
        apps = []
    }

    private static let globalSelectors = [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
    private static let runningSelectors = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyDevices]
    private static let listener: AudioObjectPropertyListenerProc = { _, _, _, _ in
        DispatchQueue.main.async { Mixer.shared.scheduleRefresh() }
        return noErr
    }

    // ~/Library/Caches/TaruTweaks/mixer.log
    func log(_ s: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/mixer.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Volume

    func volume(_ app: AppAudio) -> Double { app.bypassed ? 1 : app.key.flatMap { volumes[$0] } ?? 1 }
    func isMuted(_ app: AppAudio) -> Bool { !app.bypassed && app.key.map(muted.contains) == true }

    // Loudness is heard on a log scale, so the slider squares below 100%: 50% is -12 dB, 25% is -24 dB.
    // A straight slider kept nearly all its audible range in the bottom fifth. Boost stays linear (200% = +6 dB).
    static func gain(forVolume v: Double) -> Float { let l = max(v, 0); return Float(l < 1 ? l * l : l) }
    private func gain(_ app: AppAudio) -> Float { isMuted(app) ? 0 : Self.gain(forVolume: volume(app)) }
    private func needsEngine(_ app: AppAudio) -> Bool { !app.bypassed && !app.objects.isEmpty && defaultUID != nil && (isMuted(app) || abs(volume(app) - 1) >= 0.005) }

    func set(_ app: AppAudio, volume: Double) {
        guard let key = app.key, !app.bypassed else { return }
        let v = min(max(volume, 0), Self.maxVolume)
        // snap to 100% near the middle so it's easy to hand an app back untouched
        volumes[key] = abs(v - 1) < 0.03 ? nil : v
        UserDefaults.standard.set(volumes, forKey: "mixer.volumes")
        changed(app)
    }

    func toggleMute(_ app: AppAudio) {
        guard let key = app.key, !app.bypassed else { return }
        if muted.contains(key) { muted.remove(key) } else { muted.insert(key) }
        UserDefaults.standard.set(Array(muted), forKey: "mixer.muted")
        changed(app)
    }

    private func changed(_ app: AppAudio) {
        recovery.clear(app.id)
        if let latest = apps.first(where: { $0.id == app.id }) { apply(latest) }
        // a gain change can't revive a stalled aggregate; check the render path too
        reconcile()
    }

    func reset() {
        volumes = [:]; muted = []
        UserDefaults.standard.removeObject(forKey: "mixer.volumes"); UserDefaults.standard.removeObject(forKey: "mixer.muted")
        reconcile()
    }

    // MARK: Refresh (HAL read off main, applied on main)

    private func scheduleRefresh() {
        guard started, !refreshPending else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - lastRefreshAt
        if elapsed >= 0.2 { refresh(); return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 - elapsed) { [weak self] in
            guard let self else { return }
            refreshPending = false
            refresh()
        }
    }

    func refresh() {
        guard started else { return }
        // one pass at a time: a second one now would read against state the first hasn't published
        guard !reading else { readAgain = true; return }
        reading = true
        generation += 1
        lastRefreshAt = CFAbsoluteTimeGetCurrent()
        let gen = generation, allowCalls = callApps
        halQueue.async { [weak self] in
            let snap = Self.scan(ownPid: getpid(), allowCallApps: allowCalls)
            DispatchQueue.main.async { self?.applySnapshot(snap, generation: gen) }
        }
    }

    private struct Snapshot { let defaultUID: String?; let outputs: [String]; let apps: [AppAudio]; let objects: [AudioObjectID] }

    private func applySnapshot(_ snap: Snapshot, generation gen: Int) {
        guard gen == generation, started else { return }
        reading = false
        defer { if readAgain { readAgain = false; refresh() } }
        let envChanged = defaultUID != nil && (snap.defaultUID != defaultUID || snap.outputs != outputUIDs)
        if envChanged {
            // builds aimed at the old output can't be installed; reconcile replaces live engines one by one,
            // each new tap running before its predecessor stops
            builds = Builds()
            for (id, e) in engines where e.outputUID == snap.defaultUID { engines[id]?.refreshLevelCompensation(immediately: true) }
            log("output now \(snap.defaultUID ?? "none")")
        }
        defaultUID = snap.defaultUID
        outputUIDs = snap.outputs
        processObjects = snap.objects
        // audio starting/stopping leaves the process list as it was: follow play state on the objects that matter
        let follow = open ? Set(snap.objects) : Set(snap.apps.filter { engines[$0.id] != nil || needsEngine($0) }.flatMap(\.objects))
        prune(keeping: follow)
        follow.forEach(subscribe)
        guard envChanged || snap.apps != apps else { return }
        if snap.apps != apps { apps = snap.apps; if open { DispatchQueue.main.async { self.item?.fit() } } }
        reconcile()
        if needsPermission, !apps.contains(where: needsEngine), engines.isEmpty { needsPermission = false }
    }

    private func subscribe(_ obj: AudioObjectID) {
        for sel in Self.runningSelectors where running[obj]?.contains(sel) != true {
            var a = Self.runningAddress(sel)
            if AudioObjectAddPropertyListener(obj, &a, Self.listener, nil) == noErr { running[obj, default: []].insert(sel) }
        }
    }

    private func prune(keeping keep: Set<AudioObjectID>) {
        for obj in running.keys where !keep.contains(obj) {
            for sel in running.removeValue(forKey: obj) ?? [] {
                var a = Self.runningAddress(sel)
                AudioObjectRemovePropertyListener(obj, &a, Self.listener, nil)
            }
        }
    }

    private static func runningAddress(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: sel == kAudioProcessPropertyDevices ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scan(ownPid: pid_t, allowCallApps: Bool) -> Snapshot {
        let def = HAL.defaultOutput().flatMap(HAL.uid)
        let outputs = HAL.outputUIDs()
        let objects = HAL.processObjects
        var groups: [pid_t: (app: NSRunningApplication, objects: [AudioObjectID], playing: Bool, bundle: String?)] = [:]
        for obj in objects {
            var pid: pid_t = -1
            guard HAL.read(obj, kAudioProcessPropertyPID, &pid), pid > 0, pid != ownPid else { continue }
            // every regular app holding an audio connection, playing or not, so it's adjustable before it plays;
            // helpers (Discord, Chrome) are billed to the app responsible for them
            guard let app = ResponsibleProcess.regularAppOwner(of: pid) else { continue }
            let owner = app.processIdentifier
            var run: UInt32 = 0
            HAL.read(obj, kAudioProcessPropertyIsRunningOutput, &run)
            var g = groups[owner] ?? (app, [], false, nil)
            g.objects.append(obj)
            g.playing = g.playing || run != 0
            // the audio object knows its own bundle id, which is the app's when it plays its own sound
            if g.bundle == nil { g.bundle = app.bundleIdentifier ?? (pid == owner ? HAL.string(obj, kAudioProcessPropertyBundleID) : nil) }
            groups[owner] = g
        }
        var rows: [String: AppAudio] = [:]
        for (owner, g) in groups {
            let name = ResponsibleProcess.displayName(pid: owner, fallback: g.app.localizedName ?? "pid \(owner)")
            let bundle = g.bundle.flatMap { $0.isEmpty ? nil : $0 }
            let id = bundle ?? "process:\(owner)"
            guard id != Bundle.main.bundleIdentifier else { continue }
            if var r = rows[id] {
                r.objects = Array(Set(r.objects).union(g.objects)); r.playing = r.playing || g.playing
                rows[id] = r; continue
            }
            rows[id] = AppAudio(id: id, key: bundle ?? (name.hasPrefix("pid ") ? nil : name), name: name, pid: owner, objects: g.objects,
                                playing: g.playing, bypassed: bypassesTap(bundle: bundle, name: name, allowCallApps: allowCallApps))
        }
        let apps = rows.values.map { var a = $0; a.objects.sort(); return a }
            .sorted { ($0.playing ? 0 : 1, $0.name.lowercased(), $0.id) < ($1.playing ? 0 : 1, $1.name.lowercased(), $1.id) }
        return Snapshot(defaultUID: def, outputs: outputs, apps: apps, objects: objects)
    }

    // apps that break when tapped: pro audio hosts own their device/clock chain and go silent; Zoom fights
    // the tap; Discord/Teams lose their screen-share self-exclusion unless allowed in settings
    static func bypassesTap(bundle: String?, name: String, allowCallApps: Bool) -> Bool {
        let b = (bundle ?? "").lowercased()
        if !allowCallApps, ["com.hnc.discord", "com.microsoft.teams"].contains(where: { b.hasPrefix($0) }) { return true }
        if b.hasPrefix("us.zoom.") { return true }
        let pro = ["com.apple.logic", "com.apple.garageband", "com.apple.mainstage", "com.ableton.", "com.avid.", "com.cockos.reaper",
                   "com.steinberg.", "com.presonus.", "com.fender.studioapp", "com.bitwig.", "com.image-line.", "com.motu."]
        if pro.contains(where: { b.hasPrefix($0) }) { return true }
        return ["zoom", "zoom.us", "zoom workplace"].contains(name.lowercased().trimmingCharacters(in: .whitespaces))
    }

    // MARK: Engines

    private func reconcile() {
        guard started else { return }
        let byId = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = CFAbsoluteTimeGetCurrent()
        var next: Double?
        func later(_ d: Double) { next = min(next ?? d, d) }
        for (id, engine) in engines {
            // an app that recreates its audio unit between clips loses its object and gets a new one moments
            // later; nothing is audible in between, so keep the tap 0.2 s instead of rebuilding per notification
            guard let app = byId[id], !app.objects.isEmpty else {
                let lost = lostAt[id] ?? now
                if lostAt[id] == nil { lostAt[id] = now }
                if now - lost < 0.2 { later(0.2 - (now - lost)) } else { discard(id) }
                continue
            }
            lostAt[id] = nil
            if engine.requiresRebuild { renders[id] = nil; apply(app); continue }
            // waking from sleep can leave an aggregate whose IO proc never runs again while the tap keeps
            // muting the app: a render count that stops moving while the app plays means it goes, now
            if app.playing {
                if let prev = renders[id], prev.cycles == engine.renderCycles {
                    if now - prev.at >= 1.5 {
                        log("\(app.name): engine stalled, rebuilding")
                        engines.removeValue(forKey: id)?.stop()
                        renders[id] = nil
                        if recovery.recordFailure(id, objects: engine.tappedObjects, output: engine.outputUID) { apply(app) }
                        continue
                    }
                    later(1.5 - (now - prev.at))
                } else {
                    if let prev = renders[id], prev.cycles != engine.renderCycles { recovery.clear(id) }
                    renders[id] = (engine.renderCycles, now)
                    later(1.5)
                }
            } else { renders[id] = nil }
            // each move to another output is announced; this pass catches one that wasn't
            engine.refreshLevelCompensation(immediately: false)
            guard engine.tappedObjects != app.objects || engine.outputUID != defaultUID || !needsEngine(app) else { continue }
            guard needsEngine(app) else { discard(id); continue }
            // an engine on a device that's gone (headphones unplugged) can only mute the app: drop it now.
            // Every other rebuild keeps its tap until the replacement runs.
            if !outputUIDs.contains(engine.outputUID) { engines.removeValue(forKey: id)?.stop(); renders[id] = nil }
            apply(app)
        }
        for app in apps where needsEngine(app) && engines[app.id] == nil { apply(app) }
        for id in Array(repairs.keys) + Array(lostAt.keys) where byId[id] == nil && engines[id] == nil { repairs[id] = nil; lostAt[id] = nil; recovery.clear(id) }
        if let next { scheduleReconcile(after: next) }
    }

    func reconcileConfigurationChanges() { reconcile() }

    private func scheduleReconcile(after delay: Double) {
        guard !reconcilePending else { return }
        reconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.01)) { [weak self] in
            self?.reconcilePending = false
            self?.reconcile()
        }
    }

    private func apply(_ app: AppAudio) {
        guard started, needsEngine(app), let output = defaultUID else { discard(app.id); return }
        if let e = engines[app.id], e.tappedObjects == app.objects, e.outputUID == output, !e.requiresRebuild { e.gain = gain(app); return }
        if let until = repairs[app.id], until > CFAbsoluteTimeGetCurrent() { scheduleReconcile(after: until - CFAbsoluteTimeGetCurrent()); return }
        guard recovery.allowsBuild(app.id, objects: app.objects, output: output), #available(macOS 14.4, *), let token = builds.begin(app.id) else { return }
        let objects = app.objects, g = gain(app)
        buildQueue.async { [weak self] in
            let e = TapGainEngine(objects: objects, gain: g, outputUID: output)
            DispatchQueue.main.async {
                guard let self else { e?.stop(); return }
                self.install(e, for: app.id, name: app.name, token: token)
            }
        }
    }

    private func install(_ engine: GainEngine?, for id: String, name: String, token: Int) {
        let current = builds.isCurrent(id, token)
        builds.finish(id, token)
        // a build that started before the mixer moved on would add a second live tap and play the app twice
        guard current, started else { engine?.stop(); return }
        guard let engine else {
            log("\(name): tap could not be built")
            if retryInvalidated(id) { return }
            if let e = engines[id], !outputUIDs.contains(e.outputUID) { discard(id) }
            // a row with a tap still running plainly isn't being refused for lack of consent
            if engines[id] == nil { needsPermission = true }
            engines[id]?.refreshLevelCompensation(immediately: true)
            return
        }
        needsPermission = false
        // the slider may have moved, or the app's objects changed, while it was built: honor the latest state
        guard let latest = apps.first(where: { $0.id == id }) else { engine.stop(); return }
        guard latest.objects == engine.tappedObjects, latest.objects.count > 0, engine.outputUID == defaultUID, needsEngine(latest) else {
            engine.stop(); apply(latest); return
        }
        engine.gain = gain(latest)
        repairs[id] = nil
        let previous = engines.updateValue(engine, forKey: id)
        renders[id] = nil
        previous?.stop()
        log("\(name): tapped (\(engine.deviceStream ? "device stream" : "stereo mixdown"), gain \(engine.gain))")
        // a tap mutes at once: arm the render check now, or a dead first aggregate leaves the app silent
        reconcile()
    }

    private func discard(_ id: String) {
        engines.removeValue(forKey: id)?.stop()
        repairs[id] = nil; lostAt[id] = nil; renders[id] = nil
        recovery.clear(id)
    }

    // a format/rate change invalidated the engine and the rebuild failed: wait half a second and try once more
    private func retryInvalidated(_ id: String) -> Bool {
        guard repairs[id] != nil || engines[id]?.requiresRebuild == true else { return false }
        engines.removeValue(forKey: id)?.stop()
        renders[id] = nil
        guard let app = apps.first(where: { $0.id == id }), needsEngine(app), let output = defaultUID else { repairs[id] = nil; return true }
        if recovery.recordFailure(id, objects: app.objects, output: output) {
            repairs[id] = CFAbsoluteTimeGetCurrent() + 0.5
            scheduleReconcile(after: 0.5)
        } else { repairs[id] = nil }
        return true
    }

    // debug: /tmp/tarutweaks-mixer.json
    func dump() -> [String: Any] {
        ["enabled": enabled, "open": open, "output": defaultUID ?? "", "needsPermission": needsPermission, "followed": running.count,
         "apps": apps.map { a -> [String: Any] in
             var d: [String: Any] = ["id": a.id, "name": a.name, "objects": a.objects.count, "playing": a.playing, "bypassed": a.bypassed, "volume": volume(a), "muted": isMuted(a)]
             if let e = engines[a.id] { d["engine"] = ["gain": e.gain, "compensation": e.compensation, "cycles": e.renderCycles, "deviceStream": e.deviceStream] }
             return d
         }]
    }

    private struct Builds {
        private var tokens: [String: Int] = [:]
        private var nextToken = 1
        mutating func begin(_ id: String) -> Int? {
            guard tokens[id] == nil else { return nil }
            defer { nextToken += 1 }
            tokens[id] = nextToken
            return nextToken
        }
        func isCurrent(_ id: String, _ t: Int) -> Bool { tokens[id] == t }
        mutating func finish(_ id: String, _ t: Int) { if tokens[id] == t { tokens[id] = nil } }
    }

    // the same broken configuration gets two tries, not a rebuild loop
    private struct Recovery {
        private var failures: [String: (objects: [AudioObjectID], output: String, count: Int)] = [:]
        func allowsBuild(_ id: String, objects: [AudioObjectID], output: String) -> Bool {
            guard let f = failures[id], f.objects == objects, f.output == output else { return true }
            return f.count < 2
        }
        mutating func recordFailure(_ id: String, objects: [AudioObjectID], output: String) -> Bool {
            let same = failures[id].map { $0.objects == objects && $0.output == output } ?? false
            let count = same ? failures[id]!.count + 1 : 1
            failures[id] = (objects, output, count)
            return count < 2
        }
        mutating func clear(_ id: String) { failures[id] = nil }
        mutating func clearAll() { failures = [:] }
    }
}

// availability-erased face of TapGainEngine (taps need macOS 14.4, the app supports 14.0)
protocol GainEngine: AnyObject {
    var gain: Float { get set }
    var tappedObjects: [AudioObjectID] { get }
    var outputUID: String { get }
    var renderCycles: UInt64 { get }
    var requiresRebuild: Bool { get }
    var compensation: Float { get }
    var deviceStream: Bool { get }
    func refreshLevelCompensation(immediately: Bool)
    func stop()
}

@available(macOS 14.4, *)
extension TapGainEngine: GainEngine {}

// MARK: Which app a process belongs to

enum ResponsibleProcess {
    private static let resolve: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func owner(of pid: pid_t) -> pid_t { resolve.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil } ?? pid }

    // normally the helper's responsible process; some browsers detach helpers from that chain (each is
    // responsible for itself), so walk the parent chain to the nearest regular app, at most 6 steps
    static func regularAppOwner(of pid: pid_t) -> NSRunningApplication? {
        func regular(_ p: pid_t) -> Bool { NSRunningApplication(processIdentifier: p)?.activationPolicy == .regular }
        func walk(_ start: pid_t) -> pid_t? {
            guard start > 0 else { return nil }
            if regular(start) { return start }
            var cur = start
            for _ in 0..<6 {
                cur = parent(of: cur)
                guard cur > 1 else { return nil }
                if regular(cur) { return cur }
            }
            return nil
        }
        let r = owner(of: pid)
        return (walk(r) ?? (r != pid ? walk(pid) : nil)).flatMap(NSRunningApplication.init(processIdentifier:))
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
    }

    static func displayName(pid: pid_t, fallback: String) -> String {
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName, !n.isEmpty { return n }
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { let n = String(cString: buf); if !n.isEmpty { return n } }
        return fallback
    }
}

// MARK: UI

struct MixerMenu: View {
    @ObservedObject var mixer = Mixer.shared
    @ObservedObject var theme = Theme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VOLUME MIXER").font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.ash)
                Spacer()
                if !mixer.volumes.isEmpty || !mixer.muted.isEmpty {
                    Button("RESET ALL") { mixer.reset() }.buttonStyle(.plain).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ash)
                }
            }
            if mixer.needsPermission {
                Text("macOS blocked audio capture. Allow Taru Tweaks in System Settings › Privacy & Security › Screen & System Audio Recording, then move the slider again.")
                    .font(.system(size: 10.5)).foregroundStyle(theme.accent).fixedSize(horizontal: false, vertical: true)
            }
            if mixer.apps.isEmpty {
                Text("No app has sound open right now.").font(.system(size: 12)).foregroundStyle(Palette.ash)
            }
            ForEach(mixer.apps) { app in MixerRow(app: app) }
            Text("100% leaves an app untouched. Past 100% boosts quiet apps.").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.ash)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(Color.black.opacity(0.96))
    }
}

struct MixerRow: View {
    let app: Mixer.AppAudio
    @ObservedObject var mixer = Mixer.shared
    @ObservedObject var theme = Theme.shared

    var body: some View {
        let muted = mixer.isMuted(app)
        let v = mixer.volume(app)
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                if app.playing { Circle().fill(theme.accent).frame(width: 6, height: 6).shadow(color: theme.accent, radius: 3) }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).font(.system(size: 12, weight: .medium)).foregroundStyle(muted || app.bypassed ? Palette.ash : Palette.bone).lineLimit(1)
                    Spacer()
                    Text(app.bypassed ? "OWN AUDIO" : muted ? "MUTED" : "\(Int((v * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(v > 1 && !muted ? theme.accent : Palette.ash)
                }
                if app.bypassed {
                    Text("Left alone: tapping this app breaks its sound").font(.system(size: 9.5)).foregroundStyle(Palette.ash)
                } else {
                    Slider(value: Binding(get: { v }, set: { mixer.set(app, volume: $0) }), in: 0...Mixer.maxVolume)
                        .controlSize(.mini).tint(theme.accent).disabled(muted)
                }
            }
            Button { mixer.toggleMute(app) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(muted ? theme.accent : Palette.ash).frame(width: 18)
            }.buttonStyle(.plain).disabled(app.bypassed).opacity(app.bypassed ? 0.3 : 1)
        }
    }
}

struct MixerSettings: View {
    @ObservedObject var mixer = Mixer.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Volume Mixer", subtitle: "Set each app's volume on its own, boost quiet ones past 100% or mute one without touching the rest. Click the sliders icon in the menu bar.")
            SettingRow(title: "Volume Mixer") { Switch(on: $mixer.enabled) }
            SettingRow(title: "Menu bar icon") { Switch(on: $mixer.menuIcon) }
            SettingRow(title: "Discord & Teams volume", detail: "Off keeps them untouched, so audio you screen-share never includes the call") { Switch(on: $mixer.callApps) }
            SettingRow(title: "Apps with their own volume", detail: mixer.volumes.isEmpty && mixer.muted.isEmpty ? "None, every app is at 100%" : "\(Set(mixer.volumes.keys).union(mixer.muted).count) adjusted, remembered next time they play") {
                TweakButton(title: "Reset all") { mixer.reset() }
            }
            Text("The first time you move a slider, macOS asks to let Taru Tweaks capture audio from other apps. Allow it, or the app you turned down goes silent. Apps left at 100% are never touched and cost nothing; each adjusted app costs a little CPU while it's open.")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
        }
    }
}
