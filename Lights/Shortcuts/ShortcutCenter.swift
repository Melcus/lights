import AppKit
import Carbon.HIToolbox
import Observation

/// Persists the user's shortcuts, keeps them registered as global hot keys and runs the single
/// active shortcut recording.
@Observable
final class ShortcutCenter {
    struct Problem {
        let action: ShortcutAction
        let message: String
    }

    private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    /// Only one recorder is armed at a time.
    private(set) var recordingAction: ShortcutAction?
    /// Modifiers held while recording, for live feedback.
    private(set) var heldModifiers: NSEvent.ModifierFlags = []
    /// Why the last attempt for an action was refused.
    private(set) var problem: Problem?

    @ObservationIgnored var perform: ((ShortcutAction) -> Void)?
    @ObservationIgnored private var registrations: [ShortcutAction: UInt32] = [:]
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var recordingObservers: [NSObjectProtocol] = []

    private static let defaultsKey = "shortcuts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = Dictionary(uniqueKeysWithValues: stored.map { (ShortcutAction(rawValue: $0.key), $0.value) })
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts[action]
    }

    func registerAll() {
        for action in shortcuts.keys where registrations[action] == nil {
            register(action)
        }
    }

    func clear(_ action: ShortcutAction) {
        assign(nil, to: action)
    }

    // MARK: Recording

    func beginRecording(_ action: ShortcutAction) {
        endRecording()
        problem = nil
        recordingAction = action
        // Existing combinations must be captured rather than fire while recording.
        for action in Array(registrations.keys) { unregister(action) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.record(event)
            return nil
        }

        // Recording must not outlive the window it started in, or every shortcut stays suspended.
        var endTriggers: [(Notification.Name, AnyObject?)] = [(NSApplication.didResignActiveNotification, nil)]
        if let window = NSApp.keyWindow {
            endTriggers += [(NSWindow.didResignKeyNotification, window), (NSWindow.willCloseNotification, window)]
        }
        recordingObservers = endTriggers.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRecording() }
            }
        }
    }

    func endRecording() {
        guard recordingAction != nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingObservers.forEach(NotificationCenter.default.removeObserver)
        recordingObservers = []
        recordingAction = nil
        heldModifiers = []
        registerAll()
    }

    private func record(_ event: NSEvent) {
        guard let action = recordingAction else { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown else {
            heldModifiers = modifiers
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            endRecording()
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            assign(nil, to: action)
            endRecording()
        default:
            let shortcut = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
            guard shortcut.isValid else {
                problem = Problem(action: action, message: "Add ⌃ or ⌥")
                NSSound.beep()
                return
            }
            assign(shortcut, to: action)
            endRecording()
        }
    }

    // MARK: Registration

    private func assign(_ shortcut: Shortcut?, to action: ShortcutAction) {
        if let shortcut {
            if shortcuts.contains(where: { $0.key != action && $0.value == shortcut }) {
                problem = Problem(action: action, message: "Used by another action")
                return
            }
            if shortcut != shortcuts[action] {
                unregister(action)
                guard HotKeyCenter.shared.isAvailable(shortcut) else {
                    if recordingAction == nil { register(action) }
                    problem = Problem(action: action, message: "Taken by macOS or another app")
                    return
                }
            }
        }

        problem = nil
        unregister(action)
        shortcuts[action] = shortcut
        if recordingAction == nil { register(action) }
        save()
    }

    private func register(_ action: ShortcutAction) {
        guard let shortcut = shortcuts[action] else { return }
        registrations[action] = HotKeyCenter.shared.register(shortcut) { [weak self] in
            self?.perform?(action)
        }
    }

    private func unregister(_ action: ShortcutAction) {
        guard let id = registrations.removeValue(forKey: action) else { return }
        HotKeyCenter.shared.unregister(id)
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }
}
