import AppKit

/// Keeps the text view as wide as the visible area (wider when lines don't wrap) and at least
/// as tall, whenever the scroll view retiles.
///
/// SwiftUI creates the scroll view at zero size, and a document view autoresized from zero
/// never recovers its width, so this sizes it explicitly instead of relying on autoresizing.
final class CodeScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        // The line-number ruler overlaps the content area (the clip view is inset), so the
        // visible width is the content width minus the ruler.
        let ruler = rulersVisible ? (verticalRulerView?.ruleThickness ?? 0) : 0
        let size = NSSize(width: max(0, contentSize.width - ruler), height: contentSize.height)
        textView.minSize = size
        var frame = textView.frame
        if textView.isHorizontallyResizable {
            frame.size.width = max(frame.width, size.width)
        } else {
            frame.size.width = size.width
        }
        frame.size.height = max(frame.height, size.height)
        if frame.size != textView.frame.size { textView.setFrameSize(frame.size) }
    }
}
