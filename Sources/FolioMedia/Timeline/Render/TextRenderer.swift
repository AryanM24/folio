import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Synchronization

/// Titles and burned-in captions, drawn with `CIAttributedTextImageGenerator`.
///
/// Text is laid out once per (text, style, size) and cached, never per frame. Sizes in
/// `TextStyle` are fractions of the frame height, so passing the render height keeps 4K
/// text sharp and a half-size preview cheap.
nonisolated enum TextRenderer {
    /// A title as it looks `offset` into its clip.
    struct TitleFrame {
        var image: CIImage
        var opacity = 1.0
        /// Added to the clip's position, in canvas fractions (y down).
        var shift = Vec2.zero
        var scale = 1.0
    }

    private static let cache = Mutex<[String: UncheckedSendable<CIImage>]>([:])

    /// `text` in `style`, for a frame `height` pixels tall, with its box, at the origin.
    /// Characters from `visibleCount` on are laid out but not drawn (typewriter), and
    /// `highlight` recolours one range (the word being spoken).
    static func image(
        _ text: String, style: TextStyle, height: Double, visibleCount: Int? = nil, highlight: (range: NSRange, color: RGBA)? = nil
    ) -> CIImage {
        let key = "\(text)|\(style)|\(height)|\(visibleCount ?? -1)|\(highlight.map { "\($0.range)\($0.color)" } ?? "")"
        if let hit = cache.withLock({ $0[key] }) { return hit.value }
        let image = draw(text, style: style, height: height, visibleCount: visibleCount, highlight: highlight)
        cache.withLock {
            if $0.count > 256 { $0.removeAll() }
            $0[key] = UncheckedSendable(image)
        }
        return image
    }

    private static func draw(
        _ text: String, style: TextStyle, height: Double, visibleCount: Int?, highlight: (range: NSRange, color: RGBA)?
    ) -> CIImage {
        let size = max(1, style.size * height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment =
            switch style.alignment {
            case .leading: .left
            case .center: .center
            case .trailing: .right
            }
        paragraph.lineSpacing = style.lineSpacing * size
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(style, size: size),
            .foregroundColor: style.color.nsColor,
            .kern: style.letterSpacing * size,
            .paragraphStyle: paragraph,
        ]
        if let stroke = style.stroke {
            attributes[.strokeColor] = stroke.color.nsColor
            // Negative: stroke and fill. Percent of the font size.
            attributes[.strokeWidth] = -stroke.width * 100
        }
        if let shadow = style.shadow {
            let s = NSShadow()
            s.shadowColor = shadow.color.nsColor
            s.shadowBlurRadius = shadow.radius * size
            s.shadowOffset = NSSize(width: shadow.offset.x * size, height: -shadow.offset.y * size)
            attributes[.shadow] = s
        }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        let length = string.length
        if let highlight, NSMaxRange(highlight.range) <= length {
            string.addAttribute(.foregroundColor, value: highlight.color.nsColor, range: highlight.range)
        }
        if let visibleCount {
            let hidden = NSRange(location: min(length, (text.prefix(visibleCount) as Substring).utf16.count), length: 0)
            let range = NSRange(location: hidden.location, length: length - hidden.location)
            string.addAttributes([.foregroundColor: NSColor.clear, .strokeColor: NSColor.clear], range: range)
            string.removeAttribute(.shadow, range: range)
        }
        let generator = CIFilter.attributedTextImageGenerator()
        generator.text = string
        generator.scaleFactor = 1
        guard var image = generator.outputImage, !image.extent.isEmpty else { return CIImage.empty() }
        if let box = style.box {
            let pad = box.padding * size
            let rect = image.extent.insetBy(dx: -pad, dy: -pad)
            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = rect
            shape.radius = Float(box.cornerRadius * size)
            shape.color = box.color.ciColor
            if let fill = shape.outputImage { image = image.composited(over: fill) }
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func font(_ style: TextStyle, size: Double) -> NSFont {
        if let name = style.fontName, let named = NSFont(name: name, size: size) { return named }
        let weight: NSFont.Weight =
            switch style.weight {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    // MARK: Titles

    /// The title `offset` into a clip `duration` long, with its in and out animations.
    static func title(_ title: Title, offset: Time, duration: Time, height: Double) -> TitleFrame {
        let length = min(title.animationDuration.seconds, duration.seconds / 2)
        let t = offset.seconds, total = duration.seconds
        var frame = TitleFrame(image: CIImage.empty())
        var visible: Int?
        let count = title.text.count
        for (animation, progress) in [
            (title.animationIn, length > 0 ? t / length : 1), (title.animationOut, length > 0 ? (total - t) / length : 1),
        ] where animation != .none && progress < 1 {
            let p = Interpolation.easeOut.curve(min(1, max(0, progress)))
            switch animation {
            case .none: break
            case .fade: frame.opacity *= p
            case .slideUp:
                frame.shift.y += (1 - p) * 0.1
                frame.opacity *= p
            case .slideDown:
                frame.shift.y -= (1 - p) * 0.1
                frame.opacity *= p
            case .scale:
                frame.scale *= 0.6 + 0.4 * p
                frame.opacity *= p
            case .typewriter: visible = min(visible ?? count, Int((Double(count) * p).rounded()))
            }
        }
        frame.image = image(title.text, style: title.style, height: height, visibleCount: visible)
        return frame
    }

    // MARK: Captions

    /// Every burned-in caption showing at `time`, placed on a canvas of `size`.
    static func captions(_ scene: RenderScene, at time: Time, size: CGSize) -> CIImage? {
        var result: CIImage?
        for (style, cues) in scene.captions {
            guard let cue = cues.first(where: { $0.range.contains(time) }) else { continue }
            var highlight: (NSRange, RGBA)?
            if let color = style.highlight, let i = cue.words.firstIndex(where: { $0.range.contains(time) }) {
                highlight = wordRange(cue, index: i).map { ($0, color) }
            }
            let text = image(cue.text, style: style.text, height: size.height, highlight: highlight)
            let margin = style.margin * size.height
            let y = style.placement == .bottom ? margin : size.height - margin - text.extent.height
            let placed = text.transformed(by: CGAffineTransform(translationX: ((size.width - text.extent.width) / 2).rounded(), y: y.rounded()))
            result = result.map { placed.composited(over: $0) } ?? placed
        }
        return result
    }

    /// Where word `index` of `cue` sits in its text, found left to right.
    private static func wordRange(_ cue: ResolvedCue, index: Int) -> NSRange? {
        let text = cue.text as NSString
        var cursor = 0
        for (i, word) in cue.words.enumerated() {
            let found = text.range(of: word.text, range: NSRange(location: cursor, length: text.length - cursor))
            guard found.location != NSNotFound else { return nil }
            if i == index { return found }
            cursor = NSMaxRange(found)
        }
        return nil
    }
}

nonisolated extension RGBA {
    var ciColor: CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
