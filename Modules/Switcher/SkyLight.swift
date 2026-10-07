import Foundation
import CoreGraphics

enum SkyLight {
    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static func fn<T>(_ name: String, _ type: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: type) } }

    typealias ConnFn = @convention(c) () -> Int32
    typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SetHotKeyFn = @convention(c) (Int32, UInt16, UInt16, UInt32) -> CGError
    typealias EnableHotKeyFn = @convention(c) (Int32, Bool) -> CGError

    static let connection: Int32 = fn("SLSMainConnectionID", ConnFn.self)?() ?? 0
    static let spacesForWindows = fn("SLSCopySpacesForWindows", SpacesForWindowsFn.self)
    static let displaySpaces = fn("SLSCopyManagedDisplaySpaces", DisplaySpacesFn.self)
    static let setHotKey = fn("CGSSetSymbolicHotKeyValue", SetHotKeyFn.self)
    static let enableHotKey = fn("CGSSetSymbolicHotKeyEnabled", EnableHotKeyFn.self)

    static func spaces(of window: CGWindowID) -> [UInt64] {
        guard let f = spacesForWindows, let r = f(connection, 7, [window] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return r.map(\.uint64Value)
    }

    static func spaceIndex() -> (current: Set<UInt64>, index: [UInt64: Int]) {
        guard let f = displaySpaces, let displays = f(connection)?.takeRetainedValue() as? [[String: Any]] else { return ([], [:]) }
        var current = Set<UInt64>(), index: [UInt64: Int] = [:], n = 1
        for d in displays {
            if let c = d["Current Space"] as? [String: Any], let id = (c["id64"] as? NSNumber)?.uint64Value { current.insert(id) }
            for s in d["Spaces"] as? [[String: Any]] ?? [] {
                if let id = (s["id64"] as? NSNumber)?.uint64Value { index[id] = n; n += 1 }
            }
        }
        return (current, index)
    }

    typealias FrontFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError
    typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    static let setFront = fn("_SLPSSetFrontProcessWithOptions", FrontFn.self)
    static let postEvent = fn("SLPSPostEventRecordTo", PostFn.self)
    static let psnFor: PSNFn? = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY), "GetProcessForPID").map { unsafeBitCast($0, to: PSNFn.self) }

    @discardableResult
    static func bringToFront(pid: pid_t, window: CGWindowID) -> Bool {
        guard let setFront, let psnFor else { return false }
        var psn = ProcessSerialNumber()
        guard psnFor(pid, &psn) == noErr else { return false }
        guard setFront(&psn, window, 0x200) == .success else { return false }
        if let postEvent {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x3a] = 0x10
            var wid = window
            withUnsafeBytes(of: &wid) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
            for i in 0x20..<0x30 { bytes[i] = 0xff }
            bytes[0x08] = 0x01; _ = postEvent(&psn, bytes)
            bytes[0x08] = 0x02; _ = postEvent(&psn, bytes)
        }
        return true
    }

    static let cmd: UInt32 = 0x100000, opt: UInt32 = 0x80000, shift: UInt32 = 0x20000
    static func moveNativeSwitcherToOption() {
        _ = setHotKey?(1, 0xFFFF, 48, opt); _ = enableHotKey?(1, true)
        _ = setHotKey?(2, 0xFFFF, 48, opt | shift); _ = enableHotKey?(2, true)
        _ = enableHotKey?(27, false)
    }
    static func restoreNativeSwitcher() {
        _ = setHotKey?(1, 0xFFFF, 48, cmd); _ = enableHotKey?(1, true)
        _ = setHotKey?(2, 0xFFFF, 48, cmd | shift); _ = enableHotKey?(2, true)
        _ = enableHotKey?(27, true)
    }
}
