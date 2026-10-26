import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LightStore()
    private let shortcuts = ShortcutCenter()
    private lazy var adaptive = AdaptiveLighting(store: store)
    private var statusItem: StatusItemController?
    private lazy var settings = SettingsWindowController(store: store, shortcuts: shortcuts, adaptive: adaptive)

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DesignSnapshots.renderIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif

        NSApp.mainMenu = MainMenu.make()
        statusItem = StatusItemController(store: store, adaptive: adaptive, openSettings: { [weak self] in self?.showSettings(nil) })
        shortcuts.perform = { [weak self] action in self?.perform(action) }
        shortcuts.registerAll()
        store.onManualChange = { [weak self] light in self?.adaptive.userAdjusted(light) }
        store.start()
        adaptive.start()
        #if DEBUG
        DebugCommands.install(store: store, settings: settings, adaptive: adaptive) { [weak self] in self?.statusItem?.togglePanel() }
        #endif

        // Point new users at the menu bar icon; `-showPanelOnLaunch YES` does the same on demand.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunchedBefore") || defaults.bool(forKey: "showPanelOnLaunch") {
            defaults.set(true, forKey: "hasLaunchedBefore")
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                statusItem?.showPanel()
            }
        }
    }

    /// Opening the app again from Finder or Spotlight shows Settings, since there is no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }

    @objc func showSettings(_ sender: Any?) {
        statusItem?.closePanel()
        settings.show()
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleAll: store.toggleAll()
        case .allOn: store.setAll(on: true)
        case .allOff: store.setAll(on: false)
        case .brighter: store.adjustBrightness(by: 10)
        case .dimmer: store.adjustBrightness(by: -10)
        case .showPanel: statusItem?.togglePanel()
        case .toggleAdaptive: adaptive.isEnabled.toggle()
        default:
            if let id = action.lightID, let light = store.light(id: id) { store.toggle(light) }
        }
    }
}
