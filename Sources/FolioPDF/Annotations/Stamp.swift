import AppKit

/// The stamps in the stamp picker. Each renders to a bitmap that becomes an
/// ``ImageAnnotation``, so it looks the same in every PDF reader (PDFKit's built-in
/// named stamps look different everywhere, and not at all in some browsers).
enum Stamp: String, CaseIterable, Identifiable {
    case approved, rejected, draft, confidential, final, forComment, check, cross, date

    var id: String { rawValue }

    /// The words printed on the stamp, or the picker label for symbol stamps.
    var title: String {
        switch self {
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .draft: "Draft"
        case .confidential: "Confidential"
        case .final: "Final"
        case .forComment: "For Comment"
        case .check: "Check"
        case .cross: "Cross"
        case .date: "Today's Date"
        }
    }

    /// Stamp ink: green for yes, red for no and secrets, blue for process.
    var ink: NSColor {
        switch self {
        case .approved, .final, .check: NSColor(srgbRed: 0.09, green: 0.55, blue: 0.27, alpha: 1)
        case .rejected, .confidential, .cross: NSColor(srgbRed: 0.80, green: 0.13, blue: 0.15, alpha: 1)
        case .draft, .forComment, .date: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.75, alpha: 1)
        }
    }

    /// SF Symbol for the stamps that are a mark rather than a word.
    var symbol: String? {
        switch self {
        case .check: "checkmark"
        case .cross: "xmark"
        default: nil
        }
    }

    /// The text printed on word stamps. The date stamp uses today's date.
    func label(on date: Date = .now) -> String {
        self == .date ? date.formatted(date: .abbreviated, time: .omitted) : title.uppercased()
    }

    /// Renders the stamp at 3 pixels per point. Returns the image and its size in points.
    func render(on date: Date = .now) -> (image: CGImage, size: CGSize)? {
        let scale: CGFloat = 3
        if let symbol {
            let side: CGFloat = 40
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.8, weight: .bold)
                .applying(.init(paletteColors: [ink]))
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config) else {
                return nil
            }
            return draw(size: CGSize(width: side, height: side), scale: scale) { rect in
                glyph.draw(in: Geometry.aspectFit(glyph.size, in: rect.insetBy(dx: 2, dy: 2)))
            }
        }
        let text = label(on: date)
        let font = NSFont.systemFont(ofSize: 18, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: 1.2]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = CGSize(width: ceil(textSize.width) + 28, height: 40)
        return draw(size: size, scale: scale) { rect in
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            frame.lineWidth = 3
            ink.setStroke()
            frame.stroke()
            (text as NSString).draw(
                at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func draw(size: CGSize, scale: CGFloat, _ body: (CGRect) -> Void) -> (image: CGImage, size: CGSize)? {
        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Paper is white in both appearances; draw symbols with light-mode colors.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            body(CGRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        return (image, size)
    }
}
