import AppKit
import SwiftUI

/// A borderless panel that hosts a SwiftUI view drawn with Hero surfaces.
///
/// The window itself is clear and shadowless: the view draws its own rounded overlay and
/// shadow, with `FloatingPanel.margin` of transparent room so the shadow isn't clipped.
/// Transparent pixels let clicks through to whatever is underneath.
final class FloatingPanel: NSPanel {
    static let margin: CGFloat = 20

    /// Keys the panel handles itself (Esc, ⌘C, Space…). Return `true` when handled.
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    init<Content: View>(activating: Bool, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: .zero, styleMask: activating ? [.borderless] : [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        let host = NSHostingController(rootView: content().padding(Self.margin))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event) == true || super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    /// Fades in or out in 150 ms, or at once with Reduce Motion.
    func fade(in show: Bool, completion: (() -> Void)? = nil) {
        let instant = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if show {
            alphaValue = instant ? 1 : 0
            orderFrontRegardless()
        }
        guard !instant else {
            if !show { orderOut(nil) }
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = show ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if !show { self.orderOut(nil) }
                completion?()
            }
        }
    }
}
