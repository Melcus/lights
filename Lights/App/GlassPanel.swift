import AppKit
import SwiftUI

/// Borderless Liquid Glass panel that drops down from the menu bar without activating the app,
/// so the frontmost app keeps focus.
final class GlassPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?

    private static let cornerRadius: CGFloat = 26
    private let hostingView: NSHostingView<AnyView>
    private var isDismissing = false
    /// Size of the SwiftUI content, kept up to date while hidden too.
    private var contentSize = CGSize.zero
    /// Where the top edge belongs while shown: just under the menu bar.
    private var topEdge: CGFloat?

    init(rootView: some View) {
        let sizeRelay = SizeRelay()
        hostingView = NSHostingView(rootView: AnyView(
            rootView
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: \.size) { sizeRelay.onChange?($0) }
                // The window catches up with a size change a moment later; keep the top still meanwhile.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        ))
        // The panel sizes itself (see contentDidResize), so AppKit gets no size of its own to apply.
        hostingView.sizingOptions = []

        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        delegate = self

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = hostingView
        glass.autoresizingMask = [.width, .height]

        // The window server traces the shadow from the window's pixels and sees the glass as a
        // full rectangle; clipping it to the same rounded shape makes the shadow follow the corners.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.addSubview(glass)
        contentView = clip

        sizeRelay.onChange = { [weak self] size in self?.contentDidResize(to: size) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes, as with menus.
    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    func show(below anchor: NSRect) {
        isDismissing = false
        hostingView.layoutSubtreeIfNeeded() // brings contentSize up to date
        let size = contentSize
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = (anchor.minY - 6).rounded(.down)
        topEdge = top
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        } completionHandler: { [weak self] in
            // The shadow is traced from what's on screen; trace it once the rounded glass is drawn.
            MainActor.assumeIsolated { self?.invalidateShadow() }
        }
    }

    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isDismissing else { return }
                self.orderOut(nil)
                self.isDismissing = false
                self.onClose?()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func contentDidResize(to size: CGSize) {
        // Whole points, so AppKit has nothing to round and frames compare exactly.
        contentSize = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        // Not from inside SwiftUI's update: after a click in the panel that runs within AppKit's
        // layout pass, and resizing the window there resizes the content view twice, leaving it
        // taller or shorter than the window (content shifted up, or a stub below the menu bar).
        DispatchQueue.main.async { [weak self] in self?.placeUnderMenuBar() }
    }

    /// Sizes the panel to its content, top edge under the menu bar.
    private func placeUnderMenuBar() {
        guard isVisible, !isDismissing, let topEdge, contentSize.width > 0, contentSize.height > 0 else { return }
        let target = NSRect(x: frame.minX, y: topEdge - contentSize.height, width: contentSize.width, height: contentSize.height)
        guard frame != target else { return }
        setFrame(target, display: true)
        invalidateShadow()
    }

    private final class SizeRelay {
        var onChange: ((CGSize) -> Void)?
    }
}
