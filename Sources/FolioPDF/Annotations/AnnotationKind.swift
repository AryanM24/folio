import AppKit
import PDFKit

/// What Folio lets you do with an annotation, decided by its PDF subtype so it works
/// the same for annotations Folio made and ones that came with the file.
struct AnnotationKind {
    let subtype: String

    init(_ annotation: PDFAnnotation) { subtype = annotation.type ?? "" }

    private func `is`(_ type: PDFAnnotationSubtype) -> Bool { subtype == type.name }

    /// Form fields, links and popups belong to PDFKit's own interaction.
    var isEditable: Bool { !(self.is(.widget) || self.is(.link) || self.is(.popup)) }
    /// Markup sticks to its text, so it can be recolored or deleted but not dragged.
    var isMovable: Bool { isEditable && !isMarkup }
    /// Shapes, text boxes and stamps have meaningful boxes. Ink and lines are paths
    /// inside their box, which PDFKit doesn't rescale, so they only move.
    var isResizable: Bool { self.is(.square) || self.is(.circle) || self.is(.freeText) || self.is(.stamp) }
    /// Images and stamps keep their aspect ratio when resized.
    var keepsAspect: Bool { self.is(.stamp) }
    var isMarkup: Bool { self.is(.highlight) || self.is(.underline) || self.is(.strikeOut) }
    var hasText: Bool { self.is(.freeText) || self.is(.text) }
    var isFreeText: Bool { self.is(.freeText) }
    var hasStroke: Bool { self.is(.ink) || self.is(.square) || self.is(.circle) || self.is(.line) }
    var hasColor: Bool { !self.is(.stamp) }

    /// The tool that makes this kind, to remember its style.
    var tool: AnnotationTool? {
        switch subtype {
        case PDFAnnotationSubtype.highlight.name: .highlight
        case PDFAnnotationSubtype.underline.name: .underline
        case PDFAnnotationSubtype.strikeOut.name: .strikeOut
        case PDFAnnotationSubtype.ink.name: .pen
        case PDFAnnotationSubtype.freeText.name: .textBox
        case PDFAnnotationSubtype.text.name: .note
        case PDFAnnotationSubtype.square.name: .rectangle
        case PDFAnnotationSubtype.circle.name: .ellipse
        case PDFAnnotationSubtype.line.name: .line
        default: nil
        }
    }

    /// Name for the inspector title and VoiceOver.
    var title: String {
        switch subtype {
        case PDFAnnotationSubtype.highlight.name: "Highlight"
        case PDFAnnotationSubtype.underline.name: "Underline"
        case PDFAnnotationSubtype.strikeOut.name: "Strikethrough"
        case PDFAnnotationSubtype.ink.name: "Drawing"
        case PDFAnnotationSubtype.freeText.name: "Text Box"
        case PDFAnnotationSubtype.text.name: "Note"
        case PDFAnnotationSubtype.square.name: "Rectangle"
        case PDFAnnotationSubtype.circle.name: "Ellipse"
        case PDFAnnotationSubtype.line.name: "Line"
        case PDFAnnotationSubtype.stamp.name: "Stamp"
        default: "Annotation"
        }
    }
}

extension PDFAnnotationSubtype {
    /// The subtype as `PDFAnnotation.type` reports it. The constants carry the PDF
    /// name's leading slash ("/Widget") but `type` doesn't ("Widget"), so comparing
    /// `rawValue` directly never matches.
    nonisolated var name: String { rawValue.hasPrefix("/") ? String(rawValue.dropFirst()) : rawValue }
}

/// The visual properties of an annotation, captured for undo and applied from the
/// inspector's ``AnnotationStyle``.
struct AnnotationAppearance {
    var color: NSColor
    var fontColor: NSColor?
    var font: NSFont?
    var lineWidth: CGFloat?

    init(_ annotation: PDFAnnotation) {
        color = annotation.color
        fontColor = annotation.fontColor
        font = annotation.font
        lineWidth = annotation.border?.lineWidth
    }

    func restore(on annotation: PDFAnnotation) {
        annotation.color = color
        if let fontColor { annotation.fontColor = fontColor }
        if let font { annotation.font = font }
        if let lineWidth { annotation.border = AnnotationFactory.border(width: lineWidth) }
    }

    /// Reads an annotation into inspector terms.
    static func style(of annotation: PDFAnnotation) -> AnnotationStyle {
        let kind = AnnotationKind(annotation)
        let ink = kind.isFreeText ? (annotation.fontColor ?? .black) : annotation.color
        return AnnotationStyle(
            color: PDFColor.nearestSwatch(to: ink),
            lineWidth: Double(annotation.border?.lineWidth ?? 1),
            opacity: Double(ink.alphaComponent),
            fontSize: Double(annotation.font?.pointSize ?? 14)
        )
    }

    /// Writes inspector settings into an annotation, touching only what its kind uses.
    static func apply(_ style: AnnotationStyle, to annotation: PDFAnnotation) {
        let kind = AnnotationKind(annotation)
        if kind.isFreeText {
            annotation.fontColor = style.pdfColor
            annotation.font = (annotation.font ?? .systemFont(ofSize: 14)).withSize(style.fontSize)
        } else if kind.hasColor {
            annotation.color = style.pdfColor
        } else {
            annotation.color = annotation.color.withAlphaComponent(style.opacity)
        }
        if kind.hasStroke { annotation.border = AnnotationFactory.border(width: style.lineWidth) }
    }
}
