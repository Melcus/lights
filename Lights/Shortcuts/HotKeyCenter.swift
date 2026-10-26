import Carbon.HIToolbox

/// Thin wrapper over Carbon global hot keys, which work without Accessibility permission.
/// Cocoa apps receive them on the event dispatcher target, not the application target.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: () -> Void)] = [:]
    private var nextID: UInt32 = 1
    private var isHandlerInstalled = false
    private static let signature: OSType = 0x4C47_4854 // "LGHT"

    private init() {}

    /// Returns nil when the combination is taken by another app or the system.
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }
        hotKeys[id] = (ref, handler)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let hotKey = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(hotKey.ref)
    }

    /// Whether the combination is free: not a macOS shortcut (Spotlight, Mission Control, …) and
    /// registrable. Carbon hot keys aren't exclusive, so system shortcuts must be checked explicitly.
    func isAvailable(_ shortcut: Shortcut) -> Bool {
        guard !Self.isSystemShortcut(shortcut), let id = register(shortcut, handler: {}) else { return false }
        unregister(id)
        return true
    }

    private static func isSystemShortcut(_ shortcut: Shortcut) -> Bool {
        var symbolicHotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&symbolicHotKeys) == noErr,
              let entries = symbolicHotKeys?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevantModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int).map(UInt32.init) == shortcut.keyCode
                && (entry[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32($0) & relevantModifiers }
                    == shortcut.carbonModifiers & relevantModifiers
        }
    }

    private func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    private func fire(_ id: UInt32) {
        hotKeys[id]?.handler()
    }
}
