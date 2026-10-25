// Audio engine of the Volume Mixer, ported closely from Vorssaint (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint):
// Services/Audio/AppVolumeMixer.swift (TapGainEngine, MixerTapConfiguration, LevelCompensationWatch),
// MixerRender.swift, BoostLimiter.swift and the tap-level parts of MixerRoutingSupport.swift.
import Accelerate
import AppKit
import CoreAudio

// MARK: HAL reads

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    @discardableResult
    static func read<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, UnsafeMutableRawPointer($0)) == noErr }
    }

    // only what the HAL actually returned, never a zero id
    static func list(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).filter { $0 != 0 }
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var ref: CFString = "" as CFString
        guard read(obj, sel, &ref) else { return nil }
        let s = ref as String
        return s.isEmpty ? nil : s
    }

    static var processObjects: [AudioObjectID] { list(system, kAudioHardwarePropertyProcessObjectList) }

    static func defaultOutput() -> AudioObjectID? {
        var dev = AudioObjectID(0)
        return read(system, kAudioHardwarePropertyDefaultOutputDevice, &dev) && dev != 0 ? dev : nil
    }

    static func uid(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }

    static func outputStreams(_ dev: AudioObjectID) -> [AudioStreamID] { list(dev, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) }

    // how many channels each output stream carries, in order
    static func outputStreamChannels(_ dev: AudioObjectID) -> [Int] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, storage) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    // every live, visible device that can play sound
    static func outputUIDs() -> [String] {
        list(system, kAudioHardwarePropertyDevices).compactMap { dev in
            guard !outputStreams(dev).isEmpty else { return nil }
            var alive: UInt32 = 1, hidden: UInt32 = 0
            if read(dev, kAudioDevicePropertyDeviceIsAlive, &alive), alive == 0 { return nil }
            if read(dev, kAudioDevicePropertyIsHidden, &hidden), hidden != 0 { return nil }
            return uid(dev)
        }
    }

    static func subDeviceUIDs(_ dev: AudioObjectID) -> [String] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &list) == noErr, size == UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), let list else { return [] }
        return (list.takeRetainedValue() as? [String]) ?? []
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var q = uid as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafePointer(to: &q) { AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &dev) }
        return st == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    // an output as an app's own outputs list it: the devices inside an aggregate, the device itself otherwise
    static func flattened(_ out: AudioObjectID, depth: Int = 0) -> Set<AudioObjectID> {
        let inside = subDeviceUIDs(out).compactMap(device(forUID:))
        guard !inside.isEmpty, depth < 4 else { return [out] }
        return inside.reduce(into: Set()) { $0.formUnion(flattened($1, depth: depth + 1)) }
    }

    static func processDevices(_ obj: AudioObjectID) -> [AudioObjectID] { list(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) }
}

// MARK: Tap level

enum TapLevel {
    // the stereo mixdown tap divides what it hears by the output's channel pairs (FB13479345):
    // on an 8-channel output an app reached the mixer at a quarter of its level. Never more than 4x.
    static let maxCompensation: Double = 4
    static func compensation(streamChannels: [Int?]) -> Double {
        guard let fewest = streamChannels.map({ $0 ?? 2 }).filter({ $0 > 0 }).min() else { return 1 }
        return min(max(Double(fewest) / 2, 1), maxCompensation)
    }

    // before reading a new output: no correction (the level that's never too loud); a silent app keeps
    // its correction while the default output is still one of its last outputs
    static func beforeReading(devices: Set<AudioObjectID>, last: Set<AudioObjectID>, defaults: Set<AudioObjectID>) -> Double? {
        if devices.isEmpty { return !defaults.isEmpty && defaults.isSubset(of: last) ? nil : 1 }
        return devices == last ? nil : 1
    }

    static func readIsDue(immediately: Bool, since: Double) -> Bool { immediately || since >= 1 }

    // the stream a stereo app plays into: the one holding the output's preferred stereo pair
    static func stereoStreamChannels(_ streams: [Int], preferredLeft: Int) -> Int? {
        var first = 1
        for ch in streams where ch > 0 {
            if preferredLeft >= first, preferredLeft < first + ch { return ch }
            first += ch
        }
        return streams.first { $0 > 0 }
    }

    // eases the correction: fast on the way down (5 ms), gentle on the way up (30 ms), timed by the host clock
    static func rampStep(applied: Float?, target: Float, seconds: Double) -> Float {
        guard let applied, applied > 0 else { return target }
        let duration = target < applied ? 0.005 : 0.03
        let limit = Float(pow(maxCompensation, min(max(seconds, 0) / duration, 1)))
        return min(max(target, applied / limit), applied * limit)
    }
}

// touched only by one IO proc
final class TapLevelRamp {
    private var applied: Float?
    private var lastHostTime: UInt64?
    func next(toward target: Float, hostTime: UInt64) -> Float {
        let elapsed = lastHostTime.map { hostTime > $0 ? hostTime - $0 : 0 } ?? 0
        lastHostTime = hostTime
        let v = TapLevel.rampStep(applied: applied, target: target, seconds: Double(AudioConvertHostTimeToNanos(elapsed)) / 1e9)
        applied = v
        return v
    }
}

// a float the audio thread reads while another thread replaces it, whole and lock-free
final class AtomicFloatBox {
    private var bits: Int32
    init(_ v: Float) { bits = Int32(bitPattern: v.bitPattern) }
    var value: Float {
        get { Float(bitPattern: UInt32(bitPattern: OSAtomicAdd32Barrier(0, &bits))) }
        set {
            let r = Int32(bitPattern: newValue.bitPattern)
            while true { let c = OSAtomicAdd32Barrier(0, &bits); if OSAtomicCompareAndSwap32Barrier(c, r, &bits) { return } }
        }
    }
}

final class AtomicCycleBox {
    private var bits: Int64 = 0
    var value: UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, &bits)) }
    func increment() { _ = OSAtomicIncrement64Barrier(&bits) }
}

/// Keeps a tap's level right for the outputs its processes play to. The app can move to another output
/// while the engine runs (headphones take over from a TV); each move is announced on its process objects,
/// so the correction is read again at once, off the audio thread.
final class LevelCompensationWatch {
    private let objects: [AudioObjectID]
    private let store: (Float) -> Void
    private let listenLock = NSLock()
    private var listened: [AudioObjectID] = []
    private var client: UnsafeMutableRawPointer?
    private let pendingLock = NSLock()
    private var refreshPending = false
    private var immediatePending = false
    private let queue = DispatchQueue(label: "com.taru.tweaks.mixer.level", qos: .userInitiated)
    private var lastDevices = Set<AudioObjectID>()
    private var lastReadAt: CFAbsoluteTime = 0
    private let firstRead = DispatchSemaphore(value: 0)

    private init(objects: [AudioObjectID], store: @escaping (Float) -> Void) { self.objects = objects; self.store = store }

    // listens first and reads after, so a move made while the engine was built is already in the first value
    static func started(objects: [AudioObjectID], store: @escaping (Float) -> Void) -> LevelCompensationWatch {
        let w = LevelCompensationWatch(objects: objects, store: store)
        let client = Unmanaged.passRetained(w).toOpaque()
        for o in objects {
            var a = address
            if AudioObjectAddPropertyListener(o, &a, listener, client) == noErr { w.listened.append(o) }
        }
        if w.listened.isEmpty { Unmanaged<LevelCompensationWatch>.fromOpaque(client).release() } else { w.client = client }
        w.queue.async { w.read(); w.firstRead.signal() }
        return w
    }

    func waitForFirstRead() { _ = firstRead.wait(timeout: .now() + .milliseconds(50)) }

    func refresh(immediately: Bool) {
        let queued = pendingLock.withLock {
            immediatePending = immediatePending || immediately
            guard !refreshPending else { return false }
            refreshPending = true
            return true
        }
        guard queued else { return }
        queue.async { [self] in
            let now = pendingLock.withLock { defer { refreshPending = false; immediatePending = false }; return immediatePending }
            guard TapLevel.readIsDue(immediately: now, since: CFAbsoluteTimeGetCurrent() - lastReadAt) else { return }
            read()
        }
    }

    // removed on the teardown queue, since a wedged HAL can park the removal
    func stop() {
        guard #available(macOS 14.4, *) else { return }
        TapGainEngine.teardownQueue.addOperation { [weak self] in self?.stopListening() }
    }

    // a removal the HAL refuses keeps this small object alive: a late callback is safer than freed memory
    private func stopListening() {
        let (client, objs) = listenLock.withLock { defer { self.client = nil; listened.removeAll() }; return (self.client, listened) }
        guard let client else { return }
        var all = true
        for o in objs {
            var a = Self.address
            let st = AudioObjectRemovePropertyListener(o, &a, Self.listener, client)
            if st != noErr && st != kAudioHardwareBadObjectError { all = false }
        }
        if all { Unmanaged<LevelCompensationWatch>.fromOpaque(client).release() }
    }

    private func read() {
        lastReadAt = CFAbsoluteTimeGetCurrent()
        var devices = Set<AudioObjectID>()
        for o in objects { devices.formUnion(HAL.processDevices(o)) }
        let defaults = devices.isEmpty ? (HAL.defaultOutput().map { HAL.flattened($0) } ?? []) : []
        if let first = TapLevel.beforeReading(devices: devices, last: lastDevices, defaults: defaults) { store(Float(first)) }
        guard !devices.isEmpty else { return }
        lastDevices = devices
        store(Float(TapLevel.compensation(streamChannels: devices.map(Self.stereoStreamChannels))))
    }

    private static func stereoStreamChannels(_ dev: AudioObjectID) -> Int? {
        let streams = HAL.outputStreamChannels(dev)
        guard !streams.isEmpty else { return nil }
        var pair: (UInt32, UInt32) = (1, 2)
        HAL.read(dev, kAudioDevicePropertyPreferredChannelsForStereo, &pair, scope: kAudioObjectPropertyScopeOutput)
        return TapLevel.stereoStreamChannels(streams, preferredLeft: Int(pair.0))
    }

    // the device list announces changes only on the output scope
    private static let address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static let listener: AudioObjectPropertyListenerProc = { _, _, _, client in
        guard let client else { return noErr }
        Unmanaged<LevelCompensationWatch>.fromOpaque(client).takeUnretainedValue().refresh(immediately: true)
        return noErr
    }
}

// MARK: Rendering (realtime thread: no allocation, no locks, one pass)

/// The sample shape the mixer renders without conversion. A tap tied to a device stream inherits that
/// stream's format, which isn't always the interleaved Float32 of a stereo mixdown.
struct MixerTapFormat: Equatable {
    let sampleRate: Double
    let channels: Int
    let flags: AudioFormatFlags

    init?(_ f: AudioStreamBasicDescription, allowNonInterleaved: Bool = false) {
        let ch = Int(f.mChannelsPerFrame)
        let planar = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0, f.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              allowNonInterleaved || !planar, f.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              f.mBitsPerChannel == 32, ch > 0, UInt64(f.mBytesPerFrame) == UInt64(planar ? 1 : ch) * 4,
              f.mFramesPerPacket == 1, f.mBytesPerPacket == f.mBytesPerFrame, f.mSampleRate.isFinite, f.mSampleRate > 0 else { return nil }
        sampleRate = f.mSampleRate; channels = ch; flags = f.mFormatFlags
    }

    // a wide output (HDMI TV, audio interface) gets a tap on its own stream instead of the stereo mixdown,
    // which loses level there; only for one complete stream on the app's own output
    static func usesDeviceStream(processDevices: [[AudioObjectID]], output: AudioObjectID, streamCount: Int, startingChannel: UInt32, format: MixerTapFormat?) -> Bool {
        guard output != 0, streamCount == 1, startingChannel == 1, let format, format.channels > 2 else { return false }
        return Set(processDevices.flatMap { $0 }) == [output]
    }
}

enum MixerRender {
    static func frames(bytes: UInt32, channels: UInt32) -> Int { channels > 0 ? Int(bytes) / (4 * Int(channels)) : 0 }

    // an aggregate puts what its device records first and the tap after it, so on an output with a mic the
    // tap isn't buffer zero: it's the last buffer with the tap's shape. A lone buffer can only be the tap.
    static func tapBufferIndex(in buffers: UnsafeMutableAudioBufferListPointer, tapChannels: Int) -> Int? {
        var lone: Int?
        for i in stride(from: buffers.count - 1, through: 0, by: -1) where buffers[i].mNumberChannels > 0 {
            if Int(buffers[i].mNumberChannels) == tapChannels { return buffers[i].mData == nil ? nil : i }
            if buffers.count == 1, buffers[i].mData != nil { lone = i }
        }
        return lone
    }

    static func sourceChannel(for out: Int, sourceChannels: Int) -> Int? {
        if out < sourceChannels { return out }
        if sourceChannels == 1, out == 1 { return 0 }  // mono belongs in both front channels
        return nil
    }

    // output buffers come dirty; anything not filled would replay old audio
    static func silence(_ output: UnsafeMutableAudioBufferListPointer, from frame: Int = 0) {
        for b in output {
            if frame == 0 { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }; continue }
            let ch = Int(b.mNumberChannels)
            guard ch > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let rest = frames(bytes: b.mDataByteSize, channels: b.mNumberChannels) - frame
            guard rest > 0 else { continue }
            vDSP_vclr(d + frame * ch, 1, vDSP_Length(rest * ch))
        }
    }

    // renders one interleaved source onto whatever shape the output wants (a 1-channel headset in a call,
    // an 8-channel interface), scaled by gain; silences what it doesn't write
    @discardableResult
    static func render(source: AudioBuffer, into output: UnsafeMutableAudioBufferListPointer, gain: Float) -> Int {
        var written = 0
        defer { silence(output, from: written) }
        let sch = Int(source.mNumberChannels)
        guard sch > 0, let samples = source.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
        var n = frames(bytes: source.mDataByteSize, channels: source.mNumberChannels)
        var och = 0, writable = false
        for b in output where b.mNumberChannels > 0 {
            och += Int(b.mNumberChannels)
            guard b.mData != nil else { continue }
            writable = true
            n = min(n, frames(bytes: b.mDataByteSize, channels: b.mNumberChannels))
        }
        guard n > 0, och > 0, writable else { return 0 }
        var g = gain
        if output.count == 1, Int(output[0].mNumberChannels) == sch, let d = output[0].mData?.assumingMemoryBound(to: Float.self) {
            vDSP_vsmul(samples, 1, &g, d, 1, vDSP_Length(n * sch))
            written = n
            return written
        }
        if och == 1, sch > 1 {
            guard let b = output.first(where: { $0.mNumberChannels == 1 && $0.mData != nil }), let d = b.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            var scale = gain / Float(sch)
            vDSP_vsmul(samples, vDSP_Stride(sch), &scale, d, 1, vDSP_Length(n))
            for c in 1..<sch { vDSP_vsma(samples + c, vDSP_Stride(sch), &scale, d, 1, d, 1, vDSP_Length(n)) }
            written = n
            return written
        }
        var firstOut = 0, wrote = false
        for b in output {
            let ch = Int(b.mNumberChannels)
            guard ch > 0 else { continue }
            defer { firstOut += ch }
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for c in 0..<ch {
                guard let s = sourceChannel(for: firstOut + c, sourceChannels: sch) else { vDSP_vclr(d + c, vDSP_Stride(ch), vDSP_Length(n)); continue }
                wrote = true
                vDSP_vsmul(samples + s, vDSP_Stride(sch), &g, d + c, vDSP_Stride(ch), vDSP_Length(n))
            }
        }
        written = wrote ? n : 0
        return written
    }
}

/// Keeps boosted audio under full scale without chopping the tops off: quiet parts get the full boost,
/// and when a peak wouldn't fit the whole signal dips for just that moment. 256-frame lookahead, one linked
/// gain for every channel so the stereo image stays put. Untouched below the ceiling.
enum BoostLimiter {
    static let ceiling: Float = 0.944  // about half a dB under full scale
    static let lookahead = 256
    static func release(sampleRate: Double) -> Float {
        let rate = sampleRate.isFinite && sampleRate >= 8000 ? sampleRate : 48000
        return Float(exp(-1000.0 / (rate * 160)))  // 160 ms recovery
    }
}

final class BoostLookaheadLimiter {
    private let capacity: Int
    private var delay: ContiguousArray<Float>
    private var position = 0, filled = 0, active = 0
    private var gain: Float = 1, target: Float = 1, attackStep: Float = 0
    private var attackFrames = 0, holdFrames = 0

    init(channelCapacity: Int) {
        capacity = max(1, channelCapacity)
        delay = ContiguousArray(repeating: 0, count: BoostLimiter.lookahead * capacity)
    }

    // the next valid buffer clears the delay without allocating
    func reset() { active = 0 }

    @discardableResult
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, release: Float) -> Bool {
        let channels = buffers.reduce(0) { $0 + ($1.mData == nil ? 0 : Int($1.mNumberChannels)) }
        guard frames > 0, channels > 0, channels <= capacity else { return false }
        let L = BoostLimiter.lookahead, ceiling = BoostLimiter.ceiling
        if channels != active {
            delay.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: $0.count) }
            position = 0; filled = 0; gain = 1; target = 1; attackFrames = 0; attackStep = 0; holdFrames = 0; active = channels
        }
        for f in 0..<frames {
            var peak: Float = 0
            for b in buffers {
                let n = Int(b.mNumberChannels)
                guard n > 0, let s = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for c in 0..<n { peak = max(peak, abs(s[f * n + c])) }
            }
            let need = peak > ceiling ? ceiling / peak : 1
            let over = need < 1
            if need < target {
                target = need
                let step = (target - gain) / Float(L)
                attackStep = attackFrames > 0 ? min(attackStep, step) : step
                attackFrames = L
            }
            if over { holdFrames = L }
            if attackFrames > 0 {
                gain += attackStep; attackFrames -= 1
                if gain <= target { gain = target; attackFrames = 0 }
            } else if !over, holdFrames > 0 { holdFrames -= 1 }
            else if !over { gain = 1 + (gain - 1) * release; target = gain }
            let base = position * capacity
            var i = 0
            for b in buffers {
                let n = Int(b.mNumberChannels)
                guard n > 0, let s = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for c in 0..<n {
                    let delayed = filled >= L ? delay[base + i] : 0
                    delay[base + i] = s[f * n + c]
                    s[f * n + c] = delayed * gain
                    i += 1
                }
            }
            position += 1
            if position == L { position = 0 }
            if filled < L { filled += 1 }
        }
        return true
    }
}

// zero-lookahead fallback for an output shape the lookahead can't hold
struct BoostBufferListLimiter {
    private var envelope: Float = 0
    mutating func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, release: Float) {
        for f in 0..<max(frames, 0) {
            var peak: Float = 0
            for b in buffers {
                let n = Int(b.mNumberChannels)
                guard n > 0, let s = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for c in 0..<n { peak = max(peak, abs(s[f * n + c])) }
            }
            envelope = peak > envelope ? peak : peak + (envelope - peak) * release
            guard envelope > BoostLimiter.ceiling else { continue }
            let g = BoostLimiter.ceiling / envelope
            for b in buffers {
                let n = Int(b.mNumberChannels)
                guard n > 0, let s = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for c in 0..<n { s[f * n + c] *= g }
            }
        }
    }
}

// MARK: Configuration watch

/// Watches the format, rate and stream layout one IO proc was built for. A change notification silences
/// rendering at once; the HAL is re-read on a separate queue, and a real change leaves the old proc silent
/// until the mixer replaces the engine (so a new format is never read as the old Float32 layout).
@available(macOS 14.4, *)
final class MixerTapConfiguration {
    struct Source { let device: AudioObjectID; let stream: AudioObjectID; let format: MixerTapFormat }

    private let tap: AudioObjectID, aggregate: AudioObjectID
    private let objects: [AudioObjectID]
    private let source: Source?
    private let format: MixerTapFormat
    private let sampleRate: Double
    private let outputChannels: [Int]
    private let outputFormats: [AudioObjectID: MixerTapFormat]
    private let onInvalidated: () -> Void
    private let rendering = AtomicFloatBox(1)
    private let invalidated = AtomicFloatBox(0)
    var canRender: Bool { rendering.value != 0 }
    var requiresRebuild: Bool { invalidated.value != 0 }
    private let queue = DispatchQueue(label: "com.taru.tweaks.mixer.format", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = false, immediatePending = false, stopped = false
    private var lastReadAt: CFAbsoluteTime = 0
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var client: UnsafeMutableRawPointer?

    init(tap: AudioObjectID, aggregate: AudioObjectID, objects: [AudioObjectID], source: Source?, format: MixerTapFormat, sampleRate: Double,
         outputChannels: [Int], outputFormats: [AudioObjectID: MixerTapFormat], onInvalidated: @escaping () -> Void) {
        self.tap = tap; self.aggregate = aggregate; self.objects = objects; self.source = source; self.format = format
        self.sampleRate = sampleRate; self.outputChannels = outputChannels; self.outputFormats = outputFormats; self.onInvalidated = onInvalidated
    }

    @discardableResult
    func start() -> Bool {
        let client = Unmanaged.passRetained(self).toOpaque()
        self.client = client
        let g = kAudioObjectPropertyScopeGlobal, o = kAudioObjectPropertyScopeOutput
        var props: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (tap, kAudioTapPropertyFormat, g), (aggregate, kAudioDevicePropertyNominalSampleRate, g),
            (aggregate, kAudioDevicePropertyStreamConfiguration, o), (aggregate, kAudioDevicePropertyStreams, o),
        ]
        props += outputFormats.keys.map { ($0, kAudioStreamPropertyVirtualFormat, g) }
        if let source {
            if outputFormats[source.stream] == nil { props.append((source.stream, kAudioStreamPropertyVirtualFormat, g)) }
            props += objects.map { ($0, kAudioProcessPropertyDevices, o) }
        }
        for (obj, sel, scope) in props {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListener(obj, &a, Self.listener, client) == noErr { registrations.append((obj, a)) }
        }
        if registrations.isEmpty { self.client = nil; Unmanaged<MixerTapConfiguration>.fromOpaque(client).release() }
        guard registrations.count == props.count else { stop(); return false }
        // close the gap between the first reads and registering
        refresh(immediately: true, suspend: true)
        return true
    }

    func refresh(immediately: Bool, suspend: Bool = false) {
        let enqueue = lock.withLock {
            guard !stopped, !requiresRebuild else { return false }
            if suspend { rendering.value = 0 }
            immediatePending = immediatePending || immediately
            guard !pending else { return false }
            pending = true
            return true
        }
        guard enqueue else { return }
        queue.async { [self] in
            let due = lock.withLock {
                let now = immediatePending
                pending = false; immediatePending = false
                return !stopped && TapLevel.readIsDue(immediately: now, since: CFAbsoluteTimeGetCurrent() - lastReadAt)
            }
            guard due else { return }
            lastReadAt = CFAbsoluteTimeGetCurrent()
            let same = isCurrent()
            let notify = lock.withLock {
                let n = !stopped && !requiresRebuild && !same
                if !same { rendering.value = 0; invalidated.value = 1 }
                else if !stopped, !pending, !requiresRebuild { rendering.value = 1 }
                return n
            }
            if notify { onInvalidated() }
        }
    }

    private func isCurrent() -> Bool {
        var f = AudioStreamBasicDescription()
        var rate: Float64 = 0
        guard HAL.read(tap, kAudioTapPropertyFormat, &f), MixerTapFormat(f) == format,
              HAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, &rate), rate == sampleRate,
              HAL.outputStreamChannels(aggregate) == outputChannels, Set(HAL.outputStreams(aggregate)) == Set(outputFormats.keys) else { return false }
        for (stream, expected) in outputFormats {
            guard HAL.read(stream, kAudioStreamPropertyVirtualFormat, &f), MixerTapFormat(f, allowNonInterleaved: true) == expected else { return false }
        }
        if let source {
            guard HAL.read(source.stream, kAudioStreamPropertyVirtualFormat, &f), MixerTapFormat(f) == source.format else { return false }
            let devices = Set(objects.flatMap(HAL.processDevices))
            // silence alone doesn't move the app; resuming on another output needs a new capture
            guard devices.isEmpty || devices == [source.device] else { return false }
        }
        return true
    }

    func stop() {
        let client = lock.withLock { stopped = true; rendering.value = 0; defer { self.client = nil }; return self.client }
        guard let client else { return }
        let regs = registrations
        TapGainEngine.teardownQueue.addOperation {
            var all = true
            for (obj, stored) in regs {
                var a = stored
                let st = AudioObjectRemovePropertyListener(obj, &a, Self.listener, client)
                if st != noErr && st != kAudioHardwareBadObjectError { all = false }
            }
            if all { Unmanaged<MixerTapConfiguration>.fromOpaque(client).release() }
        }
    }

    private static let listener: AudioObjectPropertyListenerProc = { _, _, _, client in
        guard let client else { return noErr }
        Unmanaged<MixerTapConfiguration>.fromOpaque(client).takeUnretainedValue().refresh(immediately: true, suspend: true)
        return noErr
    }
}

// MARK: Tap engine

/// One adjusted app: a muted process tap feeding a private aggregate on the current output, whose IO proc
/// replays the samples scaled by gain (times the tap's level correction) through the boost limiter.
@available(macOS 14.4, *)
final class TapGainEngine {
    let tappedObjects: [AudioObjectID]
    let outputUID: String
    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = min(max(newValue, 0), Float(Mixer.maxVolume)) }
    }
    var renderCycles: UInt64 { cycleBox.value }
    var requiresRebuild: Bool { configuration?.requiresRebuild ?? false }
    var compensation: Float { compensationBox.value }
    let deviceStream: Bool

    // one linked limiter for every output channel, allocated before the callback starts
    private final class LimiterBox {
        let lookahead: BoostLookaheadLimiter
        var fallback = BoostBufferListLimiter()
        init(channels: Int) { lookahead = BoostLookaheadLimiter(channelCapacity: channels) }
        func reset() { lookahead.reset(); fallback = BoostBufferListLimiter() }
        func process(_ out: UnsafeMutableAudioBufferListPointer, release: Float) {
            var n = Int.max
            for b in out where b.mData != nil && b.mNumberChannels > 0 { n = min(n, MixerRender.frames(bytes: b.mDataByteSize, channels: b.mNumberChannels)) }
            guard n > 0, n < Int.max else { return }
            if !lookahead.process(out, frames: n, release: release) { fallback.process(out, frames: n, release: release) }
        }
    }

    private let gainBox = AtomicFloatBox(1)
    private let compensationBox = AtomicFloatBox(1)
    private let cycleBox = AtomicCycleBox()
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private var configuration: MixerTapConfiguration?
    private var levelWatch: LevelCompensationWatch?

    init?(objects: [AudioObjectID], gain: Float, outputUID: String) {
        tappedObjects = objects
        self.outputUID = outputUID
        gainBox.value = min(max(gain, 0), Float(Mixer.maxVolume))
        guard let capture = Self.createTap(objects: objects, outputUID: outputUID) else { deviceStream = false; return nil }
        deviceStream = capture.source != nil
        tapID = capture.id
        // the device-stream tap loses nothing; the mixdown tap gets its correction watched from here on
        let comp = compensationBox
        if capture.source == nil { levelWatch = .started(objects: objects) { comp.value = $0 } }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Taru Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: capture.description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID) == noErr, aggregateID != 0 else { aggregateID = 0; stop(); return nil }
        var rate: Float64 = 0
        guard HAL.read(aggregateID, kAudioDevicePropertyNominalSampleRate, &rate), rate.isFinite, rate > 0 else { stop(); return nil }
        let outChannels = HAL.outputStreamChannels(aggregateID)
        guard !outChannels.isEmpty, capture.source == nil || outChannels.reduce(0, +) == capture.format.channels,
              let outFormats = Self.outputFormats(aggregateID) else { stop(); return nil }
        let config = MixerTapConfiguration(tap: tapID, aggregate: aggregateID, objects: objects, source: capture.source, format: capture.format,
                                           sampleRate: rate, outputChannels: outChannels, outputFormats: outFormats) {
            DispatchQueue.main.async { Mixer.shared.reconcileConfigurationChanges() }
        }
        configuration = config
        let ramp = TapLevelRamp()
        let limiter = LimiterBox(channels: max(2, outChannels.reduce(0, +)))
        let release = BoostLimiter.release(sampleRate: rate)
        let box = gainBox, cycles = cycleBox, tapChannels = capture.format.channels
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil, { now, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            // never drain the old format's lookahead into a new clock
            guard config.canRender else { MixerRender.silence(outs); limiter.reset(); return }
            // the output clock keeps moving through a missing tap buffer, so the delay advances over silence too
            defer { limiter.process(outs, release: release) }
            guard let i = MixerRender.tapBufferIndex(in: ins, tapChannels: tapChannels) else { MixerRender.silence(outs); return }
            let g = box.value * ramp.next(toward: comp.value, hostTime: now.pointee.mHostTime)
            guard MixerRender.render(source: ins[i], into: outs, gain: g) > 0 else { return }
            cycles.increment()
        }) == noErr else { ioProc = nil; stop(); return nil }
        guard config.start() else { stop(); return nil }
        levelWatch?.waitForFirstRead()
        guard AudioDeviceStart(aggregateID, ioProc) == noErr else { stop(); return nil }
    }

    func refreshLevelCompensation(immediately: Bool) {
        levelWatch?.refresh(immediately: immediately)
        configuration?.refresh(immediately: immediately)
    }

    // a wedged HAL can park inside teardown (DestroyProcessTap on a dead tap): overlap them, bounded,
    // so one stuck call can't keep every later aggregate and tap alive
    static let teardownQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.taru.tweaks.mixer.teardown"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 4
        return q
    }()

    private struct Capture { let id: AudioObjectID; let description: CATapDescription; let format: MixerTapFormat; let source: MixerTapConfiguration.Source? }

    private static func createTap(objects: [AudioObjectID], outputUID: String) -> Capture? {
        if let src = deviceStreamSource(objects: objects, outputUID: outputUID),
           let c = createTap(CATapDescription(processes: objects, deviceUID: outputUID, stream: 0), source: src) { return c }
        return createTap(CATapDescription(stereoMixdownOfProcesses: objects), source: nil)
    }

    private static func createTap(_ d: CATapDescription, source: MixerTapConfiguration.Source?) -> Capture? {
        d.muteBehavior = .mutedWhenTapped
        d.isPrivate = true
        var tap = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(d, &tap) == noErr, tap != 0 else { return nil }
        var f = AudioStreamBasicDescription()
        guard HAL.read(tap, kAudioTapPropertyFormat, &f), let format = MixerTapFormat(f), source == nil || format == source?.format else {
            AudioHardwareDestroyProcessTap(tap); return nil
        }
        return Capture(id: tap, description: d, format: format, source: source)
    }

    private static func deviceStreamSource(objects: [AudioObjectID], outputUID: String) -> MixerTapConfiguration.Source? {
        guard let dev = HAL.device(forUID: outputUID) else { return nil }
        let streams = HAL.outputStreams(dev)
        guard streams.count == 1, let stream = streams.first else { return nil }
        var f = AudioStreamBasicDescription()
        var start: UInt32 = 0
        guard HAL.read(stream, kAudioStreamPropertyVirtualFormat, &f), HAL.read(stream, kAudioStreamPropertyStartingChannel, &start), let format = MixerTapFormat(f) else { return nil }
        guard MixerTapFormat.usesDeviceStream(processDevices: objects.map(HAL.processDevices), output: dev, streamCount: streams.count, startingChannel: start, format: format) else { return nil }
        return .init(device: dev, stream: stream, format: format)
    }

    private static func outputFormats(_ dev: AudioObjectID) -> [AudioObjectID: MixerTapFormat]? {
        let streams = HAL.outputStreams(dev)
        guard !streams.isEmpty else { return nil }
        var out: [AudioObjectID: MixerTapFormat] = [:]
        for s in streams {
            var f = AudioStreamBasicDescription()
            guard HAL.read(s, kAudioStreamPropertyVirtualFormat, &f), let format = MixerTapFormat(f, allowNonInterleaved: true) else { return nil }
            out[s] = format
        }
        return out
    }

    func stop() {
        let tap = tapID, agg = aggregateID, proc = ioProc
        guard tap != 0 || agg != 0 || proc != nil else { return }
        tapID = 0; aggregateID = 0; ioProc = nil
        configuration?.stop(); configuration = nil
        levelWatch?.stop(); levelWatch = nil
        // mutedWhenTapped only mutes while the tap is read: stop reading first so the app's sound comes back now;
        // the destroys may wait on a broken HAL and run off the main thread
        if let proc, agg != 0 { AudioDeviceStop(agg, proc) }
        Self.teardownQueue.addOperation {
            if let proc, agg != 0 { AudioDeviceDestroyIOProcID(agg, proc) }
            if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
            if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        }
    }

    deinit { stop() }
}
