import Carbon.HIToolbox
import AppKit

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private var ready = false
    private var pending: [() -> Void] = []

    func start() {
        ready = true
        install()
        let p = pending; pending = []
        p.forEach { $0() }
    }

    func set(_ id: UInt32, mask: UInt64, key: Int64, enabled: Bool = true, action: @escaping () -> Void) {
        guard ready else { pending.append { [weak self] in self?.set(id, mask: mask, key: key, enabled: enabled, action: action) }; return }
        install()
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        actions[id] = action
        guard enabled else { return }
        var mods: UInt32 = 0
        if mask & 0x100000 != 0 { mods |= UInt32(cmdKey) }
        if mask & 0x80000 != 0 { mods |= UInt32(optionKey) }
        if mask & 0x40000 != 0 { mods |= UInt32(controlKey) }
        if mask & 0x20000 != 0 { mods |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x54415255), id: id), GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
    }
}
