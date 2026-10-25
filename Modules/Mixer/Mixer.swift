import AppKit
import CoreAudio
import SwiftUI

// Per-app volume. An app at 100% is never touched. Turn one down (or past 100% to boost) and it gets a
// Core Audio process tap: its sound is muted at the source, pulled through a private aggregate device,
// scaled and played on the current output. No audio driver. Idea and approach from Vorssaint's mixer.
final class Mixer: ObservableObject {
    static let shared = Mixer()
    static let maxVolume: Float = 2

    struct AppAudio: Identifiable, Equatable {
        let id: String
        let name: String
        let pid: pid_t
        var objects: [AudioObjectID]
        var playing: Bool
    }

    @Published private(set) var apps: [AppAudio] = []
    @Published var volumes: [String: Float] = (UserDefaults.standard.dictionary(forKey: "mixer.volumes") as? [String: Float]) ?? [:]
    @Published var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mixer.muted") ?? [])
    @Published var menuIcon = UserDefaults.standard.object(forKey: "mixer.menu") as? Bool ?? true { didSet { UserDefaults.standard.set(menuIcon, forKey: "mixer.menu"); item?.item.isVisible = menuIcon } }

    private var engines: [String: TapEngine] = [:]
    private var item: TaruStatusItem?
    private var pending: DispatchWorkItem?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let s = TaruStatusItem(name: "Volume Mixer", autosave: "Item-3", page: "mixer", content: AnyView(MixerMenu()))
        s.set(symbol: "slider.vertical.3")
        s.onHide = { [weak self] in self?.menuIcon = false }
        // the playing dots only matter while you're looking, so the list only refreshes while the popup is open
        s.onShow = { [weak self] in self?.watch(true) }
        s.onClose = { [weak self] in self?.watch(false) }
        s.item.isVisible = menuIcon
        item = s
        // the HAL tells us when apps start/stop having audio objects or the output switches; no polling
        for sel in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
                self?.schedule(rebuildAll: sel == kAudioHardwarePropertyDefaultOutputDevice)
            }
        }
        refresh()
    }

    private var watcher: Timer?
    private func watch(_ on: Bool) {
        watcher?.invalidate(); watcher = nil
        guard on else { return }
        refresh()
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func volume(_ id: String) -> Float { volumes[id] ?? 1 }

    func set(_ id: String, volume: Float) {
        let v = min(max(volume, 0), Self.maxVolume)
        // snap to 100% near the middle so it's easy to hand an app back untouched
        volumes[id] = abs(v - 1) < 0.03 ? nil : v
        UserDefaults.standard.set(volumes, forKey: "mixer.volumes")
        if let e = engines[id] { e.gain = gain(id) }
        apply(id)
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        UserDefaults.standard.set(Array(muted), forKey: "mixer.muted")
        if let e = engines[id] { e.gain = gain(id) }
        apply(id)
    }

    func reset() {
        volumes = [:]; muted = []
        UserDefaults.standard.removeObject(forKey: "mixer.volumes"); UserDefaults.standard.removeObject(forKey: "mixer.muted")
        engines.values.forEach { $0.stop() }; engines = [:]
    }

    private func gain(_ id: String) -> Float { muted.contains(id) ? 0 : volume(id) }
    private func needsTap(_ id: String) -> Bool { muted.contains(id) || volume(id) != 1 }

    private func schedule(rebuildAll: Bool) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if rebuildAll { self?.engines.values.forEach { $0.stop() }; self?.engines = [:] }
            self?.refresh()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func refresh() {
        apps = Self.scan()
        for a in apps { apply(a.id) }
        // apps that went away take their tap with them
        for id in engines.keys where !apps.contains(where: { $0.id == id }) { engines.removeValue(forKey: id)?.stop() }
    }

    private func apply(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        guard needsTap(id) else { engines.removeValue(forKey: id)?.stop(); return }
        if let e = engines[id], e.objects == app.objects { return }
        engines.removeValue(forKey: id)?.stop()
        guard let uid = Self.outputUID() else { return }
        engines[id] = TapEngine(objects: app.objects, gain: gain(id), outputUID: uid)
    }

    // MARK: HAL reads

    static func read<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr
    }

    static func list(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func outputUID() -> String? {
        var dev = AudioObjectID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &dev), dev != 0 else { return nil }
        var uid: Unmanaged<CFString>?
        guard read(dev, kAudioDevicePropertyDeviceUID, &uid), let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    // Discord, Chrome and friends play sound from helper processes; the kernel knows which app is responsible
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func scan() -> [AppAudio] {
        let me = getpid()
        var byApp: [String: AppAudio] = [:]
        for obj in list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            var pid: pid_t = -1
            guard read(obj, kAudioProcessPropertyPID, &pid), pid > 0, pid != me else { continue }
            var running: UInt32 = 0
            _ = read(obj, kAudioProcessPropertyIsRunningOutput, &running)
            let owner = responsible.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil } ?? pid
            guard let app = NSRunningApplication(processIdentifier: owner) ?? NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular || running != 0 else { continue }
            let id = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            guard id != Bundle.main.bundleIdentifier else { continue }
            if var a = byApp[id] {
                a.objects.append(obj); a.playing = a.playing || running != 0
                byApp[id] = a
            } else {
                byApp[id] = AppAudio(id: id, name: app.localizedName ?? id, pid: app.processIdentifier, objects: [obj], playing: running != 0)
            }
        }
        return byApp.values.map { var a = $0; a.objects.sort(); return a }.sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
    }
}

// MARK: Tap engine

// one tapped app: tap → private aggregate on the current output → IOProc that scales the samples
final class TapEngine {
    let objects: [AudioObjectID]
    private let target: UnsafeMutablePointer<Float>
    private let current: UnsafeMutablePointer<Float>
    private var tap = AudioObjectID(0)
    private var aggregate = AudioObjectID(0)
    private var proc: AudioDeviceIOProcID?

    var gain: Float {
        get { target.pointee }
        set { target.pointee = min(max(newValue, 0), Mixer.maxVolume) }
    }

    init?(objects: [AudioObjectID], gain: Float, outputUID: String) {
        self.objects = objects
        target = .allocate(capacity: 1); target.initialize(to: gain)
        current = .allocate(capacity: 1); current.initialize(to: gain)
        guard #available(macOS 14.4, *) else { return nil }
        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != 0 else { cleanup(); return nil }
        var fmt = AudioStreamBasicDescription()
        guard Mixer.read(tap, kAudioTapPropertyFormat, &fmt), fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0, fmt.mBitsPerChannel == 32 else { stop(); return nil }
        let tapChannels = Int(fmt.mChannelsPerFrame)
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Taru Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregate) == noErr, aggregate != 0 else { stop(); return nil }
        let target = self.target, current = self.current
        // realtime thread: no allocation, no locks, one pass
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            // the tap is the last input buffer with the tap's channel count (a device with a mic puts its own first)
            var src: AudioBuffer?
            for b in ins where Int(b.mNumberChannels) == tapChannels && b.mData != nil { src = b }
            let goal = target.pointee
            var g = current.pointee
            for o in outs {
                guard let od = o.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let och = max(1, Int(o.mNumberChannels))
                let frames = Int(o.mDataByteSize) / (4 * och)
                guard let s = src, let sd = s.mData?.assumingMemoryBound(to: Float.self) else {
                    od.update(repeating: 0, count: frames * och); continue
                }
                let sframes = min(frames, Int(s.mDataByteSize) / (4 * tapChannels))
                g = current.pointee
                // ramp to the new gain over one buffer so slider moves don't click
                let step = (goal - g) / Float(max(1, frames))
                for f in 0..<frames {
                    g += step
                    for c in 0..<och {
                        var x: Float = f < sframes ? sd[f * tapChannels + min(c, tapChannels - 1)] * g : 0
                        // boosted audio gets a soft ceiling instead of hard clipping crackle
                        if g > 1 { x = x * (27 + x * x) / (27 + 9 * x * x); x = min(max(x, -1), 1) }
                        od[f * och + c] = x
                    }
                }
            }
            current.pointee = goal
        }
        guard status == noErr, AudioDeviceStart(aggregate, proc) == noErr else { stop(); return nil }
    }

    func stop() {
        // stop reading first so the app's own output comes back right away
        if let proc, aggregate != 0 { AudioDeviceStop(aggregate, proc) }
        let proc = self.proc, aggregate = self.aggregate, tap = self.tap
        self.proc = nil; self.aggregate = 0; self.tap = 0
        DispatchQueue.global(qos: .utility).async {
            if let proc, aggregate != 0 { AudioDeviceDestroyIOProcID(aggregate, proc) }
            if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != 0, #available(macOS 14.4, *) { AudioHardwareDestroyProcessTap(tap) }
        }
    }

    private func cleanup() { stop() }

    deinit {
        stop()
        // the IOProc may still be finishing its last buffer on the audio thread; keep the gain alive a moment
        let t = target, c = current
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { t.deallocate(); c.deallocate() }
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
            if mixer.apps.isEmpty {
                Text("Nothing is making sound right now.").font(.system(size: 12)).foregroundStyle(Palette.ash)
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
        let muted = mixer.muted.contains(app.id)
        let v = mixer.volume(app.id)
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                if app.playing { Circle().fill(theme.accent).frame(width: 6, height: 6).shadow(color: theme.accent, radius: 3) }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).font(.system(size: 12, weight: .medium)).foregroundStyle(muted ? Palette.ash : Palette.bone).lineLimit(1)
                    Spacer()
                    Text(muted ? "MUTED" : "\(Int((v * 100).rounded()))%").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(v > 1 && !muted ? theme.accent : Palette.ash)
                }
                Slider(value: Binding(get: { Double(v) }, set: { mixer.set(app.id, volume: Float($0)) }), in: 0...Double(Mixer.maxVolume))
                    .controlSize(.mini).tint(theme.accent).disabled(muted)
            }
            Button { mixer.toggleMute(app.id) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(muted ? theme.accent : Palette.ash).frame(width: 18)
            }.buttonStyle(.plain)
        }
    }
}

struct MixerSettings: View {
    @ObservedObject var mixer = Mixer.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Volume Mixer", subtitle: "Set each app's volume on its own, boost quiet ones past 100% or mute one without touching the rest. Click the sliders icon in the menu bar.")
            SettingRow(title: "Menu bar icon") { Switch(on: $mixer.menuIcon) }
            SettingRow(title: "Apps with their own volume", detail: mixer.volumes.isEmpty && mixer.muted.isEmpty ? "None, every app is at 100%" : "\(Set(mixer.volumes.keys).union(mixer.muted).count) adjusted, remembered next time they play") {
                TweakButton(title: "Reset all") { mixer.reset() }
            }
            Text("The first time you move a slider, macOS asks to let Taru Tweaks capture audio from other apps. Allow it, or the app you turned down goes silent. Apps left at 100% are never touched and cost nothing; each adjusted app costs a little CPU while it's open.")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ash).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
        }
    }
}
