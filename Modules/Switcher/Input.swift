import AppKit
import ApplicationServices

final class Input {
    static let shared = Input()
    private var tap: CFMachPort?
    private let relevantMods: UInt64 = 0x40000 | 0x80000 | 0x100000 | 0x20000
    private let hyper: UInt64 = 0x40000 | 0x80000 | 0x100000 | 0x20000

    var trusted: Bool { AXIsProcessTrusted() }
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .rightMouseDown, .leftMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { Input.shared.recover() }
                return Unmanaged.passUnretained(event)
            }
            return Input.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    var onLost: (() -> Void)?

    func recover() {
        guard let t = tap else { return }
        if AXIsProcessTrusted() {
            CGEvent.tapEnable(tap: t, enable: true)
        } else {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
            tap = nil
            Switcher.shared.hide()
            SkyLight.restoreNativeSwitcher()
            onLost?()
        }
    }

    private func frontIgnored() -> Bool {
        SwitcherPrefs.shared.exception(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.ignoreShortcuts ?? false
    }

    private func overDock(_ p: CGPoint) -> Bool {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, let el else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let s = Switcher.shared
        let prefs = SwitcherPrefs.shared
        let flags = e.flags.rawValue & relevantMods

        if type == .rightMouseDown || (type == .leftMouseDown && flags == 0x40000) {
            if prefs.dockForceQuit && !s.visible && overDock(e.location) {
                e.flags.insert(.maskAlternate)
            }
            return false
        }

        if type == .flagsChanged {
            QuitGuard.shared.modifiers(flags)
            if s.visible, let active = s.shortcut, flags & active.holdMask != active.holdMask {
                DispatchQueue.main.async { s.released() }
            }
            return false
        }

        let key = e.getIntegerValueField(.keyboardEventKeycode)
        let down = type == .keyDown

        if !s.visible {
            if QuitGuard.shared.key(key, down: down, repeating: e.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: flags, synthetic: e.getIntegerValueField(.eventSourceUserData) == QuitGuard.marker, ignored: frontIgnored()) { return true }
            guard down else { return false }
            if key == prefs.desktopKey && flags & 0x100000 != 0 { DispatchQueue.main.async { WindowEngine.shared.noteDesktopKey(flags: flags, want: prefs.desktopMask, on: prefs.showDesktop, front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") } }
            if prefs.showDesktop && key == prefs.desktopKey && flags == prefs.desktopMask && !frontIgnored() {
                DispatchQueue.main.async { WindowEngine.shared.toggleShowDesktop() }
                return true
            }
            if frontIgnored() || !prefs.enabled { return false }
            for (i, sc) in prefs.shortcuts.enumerated() where sc.enabled && key == sc.key {
                let base = flags & ~UInt64(0x20000)
                if base == sc.holdMask & ~UInt64(0x20000) && flags & sc.holdMask == sc.holdMask {
                    let back = flags & 0x20000 != 0 && sc.holdMask & 0x20000 == 0
                    DispatchQueue.main.async { s.open(shortcut: i, backwards: back) }
                    return true
                }
            }
            return false
        }

        guard down else { return true }
        let shift = flags & 0x20000 != 0
        DispatchQueue.main.async { s.key(key, shift: shift, chars: e.characters) }
        return true
    }
}

extension CGEvent {
    var characters: String {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        return String(utf16CodeUnits: buf, count: len)
    }
}

final class Gestures {
    static let shared = Gestures()
    typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer, @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    var started = false
    var startX: Float = 0
    var lastStep: Float = 0
    var tracking = false

    func start() {
        guard !started, let lib, let listF = dlsym(lib, "MTDeviceCreateList"), let regF = dlsym(lib, "MTRegisterContactFrameCallback"), let startF = dlsym(lib, "MTDeviceStart") else { return }
        started = true
        let list = unsafeBitCast(listF, to: DeviceList.self)
        let reg = unsafeBitCast(regF, to: Register.self)
        let st = unsafeBitCast(startF, to: Start.self)
        guard let devices = list()?.takeRetainedValue() as? [AnyObject] else { return }
        for d in devices {
            let ptr = Unmanaged.passUnretained(d).toOpaque()
            reg(ptr) { _, data, count, _, _ in
                Gestures.shared.frame(data, Int(count))
                return 0
            }
            st(ptr, 0)
        }
    }

    func frame(_ data: UnsafeMutableRawPointer?, _ count: Int) {
        let want = SwitcherPrefs.shared.gesture
        guard want > 0 else { return }
        if count == want, let data {
            var sum: Float = 0
            for i in 0..<count { sum += data.load(fromByteOffset: i * 96 + 32, as: Float.self) }
            let x = sum / Float(count)
            if !tracking { tracking = true; startX = x; lastStep = x; return }
            let d = x - lastStep
            if abs(x - startX) > 0.06 && !Switcher.shared.visible {
                lastStep = x
                DispatchQueue.main.async { Switcher.shared.open(shortcut: 0, backwards: d < 0, gesture: true) }
            } else if Switcher.shared.visible && abs(d) > 0.05 {
                lastStep = x
                DispatchQueue.main.async { Switcher.shared.step(d > 0 ? 1 : -1) }
            }
        } else if tracking && count == 0 {
            tracking = false
            if Switcher.shared.visible { DispatchQueue.main.async { Switcher.shared.commit() } }
        } else if count != want && count != 0 {
            tracking = false
        }
    }
}
