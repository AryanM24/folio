import AppKit
import FolioKit
import SwiftUI

/// The scrolling canvas: a white sheet of paper centered on `Hero.backgroundSecondary`.
///
/// The paper is the text view itself, sized to the page width with the page margins as
/// its text inset, and at least one page tall. In "wrap to window" mode it fills the
/// window width instead. The canvas draws the soft shadow under the paper.
final class PaperCanvas: NSView {
    let textView: DocsTextView
    var page = PageSetup() { didSet { if page != oldValue { layoutPaper() } } }
    var wrapsToWindow = false { didSet { if wrapsToWindow != oldValue { layoutPaper() } } }

    /// Space above the paper, leaving room for the floating formatting toolbar.
    static let topInset: CGFloat = 72
    static let sideInset: CGFloat = 32
    static let bottomInset: CGFloat = 48
    /// Margins in wrap-to-window mode, where the page's own margins would be too wide.
    static let wrapMargin: CGFloat = 48

    private var isLayingOut = false

    init(textView: DocsTextView) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        addSubview(textView)
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged), name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used from Interface Builder") }

    override var isFlipped: Bool { true }

    /// Re-fits the canvas when the scroll view resizes.
    func observe(_ clip: NSClipView) {
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func contentChanged(_ note: Notification) { layoutPaper() }

    /// Sizes the paper (text view) and the canvas around it.
    func layoutPaper() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let visibleWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let paperWidth: CGFloat
        let inset: NSSize
        if wrapsToWindow {
            paperWidth = max(360, visibleWidth - Self.sideInset * 2)
            inset = NSSize(width: Self.wrapMargin, height: Self.wrapMargin)
        } else {
            paperWidth = page.paperSize.width
            inset = NSSize(width: page.margins.left, height: page.margins.top)
        }
        let containerWidth = wrapsToWindow ? paperWidth - inset.width * 2 : page.contentSize.width
        if textView.textContainer?.size.width != containerWidth {
            textView.textContainer?.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        let minHeight =
            wrapsToWindow
            ? max(400, (enclosingScrollView?.contentView.bounds.height ?? 600) - Self.topInset - Self.bottomInset) : page.paperSize.height
        textView.minSize = NSSize(width: paperWidth, height: minHeight)
        textView.maxSize = NSSize(width: paperWidth, height: CGFloat.greatestFiniteMagnitude)
        if textView.frame.width != paperWidth {
            textView.setFrameSize(NSSize(width: paperWidth, height: max(minHeight, textView.frame.height)))
        }
        textView.sizeToFit()

        let width = max(visibleWidth, paperWidth + Self.sideInset * 2)
        let height = textView.frame.height + Self.topInset + Self.bottomInset
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        let origin = NSPoint(x: ((width - paperWidth) / 2).rounded(), y: Self.topInset)
        if textView.frame.origin != origin { textView.setFrameOrigin(origin) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Hero.backgroundSecondary).setFill()
        dirtyRect.fill()
        // Two soft shadows, the HeroUI card recipe, so the sheet lifts off the canvas.
        let paper = textView.frame
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(effectiveAppearance.isDark ? 0.5 : 0.10)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill()
        paper.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.06).setStroke()
        NSBezierPath(rect: paper.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
