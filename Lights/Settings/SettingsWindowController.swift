import AppKit
import SwiftUI

/// Standard preferences window with toolbar tabs, each hosting a SwiftUI form.
final class SettingsWindowController: NSWindowController {
    init(store: LightStore, shortcuts: ShortcutCenter, adaptive: AdaptiveLighting) {
        func tab(_ title: String, symbol: String, _ content: some View) -> NSTabViewItem {
            let controller = NSHostingController(rootView: content.environment(store).environment(shortcuts).environment(adaptive))
            controller.sizingOptions = .preferredContentSize
            controller.title = title // shown as the window title while the tab is selected
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(tab("Adaptive", symbol: "sun.horizon", AdaptiveSettingsView()))
        tabs.addTabViewItem(tab("Shortcuts", symbol: "command", ShortcutsSettingsView()))
        tabs.addTabViewItem(tab("Lights", symbol: "lightbulb", LightsSettingsView()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative; make sure the window is in front even if it was declined.
        window.orderFrontRegardless()
    }
}
