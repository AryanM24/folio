import AppKit
import FolioKit
import SwiftUI

/// The inspector's settings: applied to new annotations of a tool, and to the selected
/// annotation when it changes.
struct AnnotationStyle: Equatable, Sendable {
    /// One of `ColorSwatches.ink`, so the swatch row can show the checkmark.
    var color: Color
    /// Stroke width in points (ink, shapes, lines).
    var lineWidth: Double
    /// 0.1…1. Stored as the annotation color's alpha, which every PDF reader honours.
    var opacity: Double
    /// Text boxes, in points.
    var fontSize: Double

    /// Sensible starting styles: yellow highlights, black pen, a translucent
    /// highlighter, red shapes.
    static func defaults(for tool: AnnotationTool) -> AnnotationStyle {
        switch tool {
        case .highlight: AnnotationStyle(color: .yellow, lineWidth: 1, opacity: 1, fontSize: 14)
        case .underline, .strikeOut: AnnotationStyle(color: .red, lineWidth: 1, opacity: 1, fontSize: 14)
        case .highlighter: AnnotationStyle(color: .yellow, lineWidth: 14, opacity: 0.4, fontSize: 14)
        case .pen: AnnotationStyle(color: .black, lineWidth: 2, opacity: 1, fontSize: 14)
        case .note: AnnotationStyle(color: .yellow, lineWidth: 1, opacity: 1, fontSize: 14)
        case .textBox, .select, .redact: AnnotationStyle(color: .black, lineWidth: 1, opacity: 1, fontSize: 14)
        case .rectangle, .ellipse, .line, .arrow: AnnotationStyle(color: .red, lineWidth: 2, opacity: 1, fontSize: 14)
        }
    }

    /// The color to write into the PDF, with opacity as alpha.
    var pdfColor: NSColor { PDFColor.resolve(color, alpha: opacity) }
}

/// Converting between SwiftUI's adaptive colors and the fixed colors a PDF stores.
enum PDFColor {
    /// Resolves `color` in light appearance: paper is white whatever the window's
    /// appearance, so the dark-mode variant of `.yellow` would be wrong on the page.
    static func resolve(_ color: Color, alpha: Double = 1) -> NSColor {
        var resolved = NSColor.black
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved.withAlphaComponent(alpha)
    }

    /// The palette entry closest to a color read from a PDF, so the inspector can show
    /// which swatch an existing annotation uses.
    static func nearestSwatch(to color: NSColor) -> Color {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .black }
        func distance(_ swatch: Color) -> CGFloat {
            let s = resolve(swatch)
            return pow(s.redComponent - rgb.redComponent, 2) + pow(s.greenComponent - rgb.greenComponent, 2)
                + pow(s.blueComponent - rgb.blueComponent, 2)
        }
        return ColorSwatches.ink.min { distance($0) < distance($1) } ?? .black
    }
}
