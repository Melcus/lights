import AppKit
import Observation
import SwiftUI

/// Menu bar icon: click for the panel, Option-click to toggle every light, right-click for a menu.
final class StatusItemController: NSObject {
    private let store: LightStore
    private let adaptive: AdaptiveLighting
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: GlassPanel
    private var outsideClickMonitor: Any?

    init(store: LightStore, adaptive: AdaptiveLighting, openSettings: @escaping () -> Void) {
        self.store = store
        self.adaptive = adaptive
        self.openSettings = openSettings
        panel = GlassPanel(rootView: PanelView(openSettings: openSettings).environment(store).environment(adaptive))
        super.init()

        panel.onClose = { [weak self] in self?.panelDidClose() }
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityTitle("Lights")
        }
        observeIcon()
    }

    func togglePanel() {
        panel.isVisible ? closePanel() : showPanel()
    }

    func showPanel() {
        guard !panel.isVisible, let button = statusItem.button, let window = button.window else { return }
        store.refreshAll()
        panel.show(below: window.convertToScreen(button.convert(button.bounds, to: nil)))
        button.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    func closePanel() {
        panel.dismiss()
    }

    private func panelDidClose() {
        statusItem.button?.highlight(false)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            store.toggleAll()
        } else {
            togglePanel()
        }
    }

    // MARK: Icon

    private func observeIcon() {
        Task { [weak self, store] in
            for await state in Observations({ (anyOn: store.anyOn, hasLights: !store.lights.isEmpty) }) {
                self?.updateIcon(anyOn: state.anyOn, hasLights: state.hasLights)
            }
        }
    }

    private func updateIcon(anyOn: Bool, hasLights: Bool) {
        let name = !hasLights ? "lightbulb.slash" : anyOn ? "lightbulb.max.fill" : "lightbulb"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Lights")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Context menu

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        menu.autoenablesItems = false

        let toggleAll = NSMenuItem(title: store.anyOn ? "Turn All Lights Off" : "Turn All Lights On",
                                   action: #selector(menuToggleAll), keyEquivalent: "")
        toggleAll.target = self
        toggleAll.isEnabled = !store.reachableLights.isEmpty
        menu.addItem(toggleAll)

        if !store.lights.isEmpty { menu.addItem(.separator()) }
        for light in store.lights {
            let item = NSMenuItem(title: light.name, action: #selector(menuToggleLight(_:)), keyEquivalent: "")
            item.target = self
            item.state = light.isOn ? .on : .off
            item.isEnabled = light.isReachable
            item.representedObject = light.id
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let adaptiveItem = NSMenuItem(title: "Adaptive Lighting", action: #selector(menuToggleAdaptive), keyEquivalent: "")
        adaptiveItem.target = self
        adaptiveItem.state = adaptive.isEnabled ? .on : .off
        menu.addItem(adaptiveItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Lights", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuToggleAll() {
        store.toggleAll()
    }

    @objc private func menuToggleLight(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let light = store.light(id: id) else { return }
        store.toggle(light)
    }

    @objc private func menuToggleAdaptive() {
        adaptive.isEnabled.toggle()
    }

    @objc private func menuSettings() {
        openSettings()
    }
}
