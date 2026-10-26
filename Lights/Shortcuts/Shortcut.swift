import AppKit
import Carbon.HIToolbox

/// A global key combination, stored in Carbon terms because that's what `RegisterEventHotKey` takes.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        carbonModifiers = UInt32(carbon)
    }

    var modifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// Requires ⌃ or ⌥: plain typing must never flip a light, and ⌘ or ⌘⇧ combinations would steal
    /// app shortcuts such as ⌘W or ⌘⇧T everywhere. Function keys may stand alone.
    var isValid: Bool {
        !modifiers.isDisjoint(with: [.option, .control]) || Self.functionKeys.contains(Int(keyCode))
    }

    var displayString: String { Self.symbols(for: modifiers) + Self.keyName(for: keyCode) }

    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }

    private static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeys[Int(keyCode)] { return name }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// The character the key produces in the current keyboard layout, so a German Z reads as Z.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "?⃝",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// What a shortcut does. Per-light toggles embed the light's ID, presets the preset's.
struct ShortcutAction: Hashable, RawRepresentable {
    var rawValue: String

    static let toggleAll = ShortcutAction(rawValue: "toggleAll")
    static let allOn = ShortcutAction(rawValue: "allOn")
    static let allOff = ShortcutAction(rawValue: "allOff")
    static let brighter = ShortcutAction(rawValue: "brighter")
    static let dimmer = ShortcutAction(rawValue: "dimmer")
    static let showPanel = ShortcutAction(rawValue: "showPanel")
    static let toggleAdaptive = ShortcutAction(rawValue: "toggleAdaptive")

    static func toggle(_ lightID: String) -> ShortcutAction { ShortcutAction(rawValue: "toggle:" + lightID) }

    var lightID: String? {
        rawValue.hasPrefix("toggle:") ? String(rawValue.dropFirst("toggle:".count)) : nil
    }

    static func applyPreset(_ presetID: UUID) -> ShortcutAction { ShortcutAction(rawValue: "preset:" + presetID.uuidString) }

    var presetID: UUID? {
        rawValue.hasPrefix("preset:") ? UUID(uuidString: String(rawValue.dropFirst("preset:".count))) : nil
    }
}
