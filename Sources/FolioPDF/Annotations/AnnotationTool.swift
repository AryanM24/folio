import SwiftUI

/// The modes of the floating annotation toolbar. Exactly one is active.
///
/// One-shot insertions (stamps, signature, image) aren't tools: they drop a selected
/// annotation in the middle of the visible page, ready to move.
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    /// Select text, fill forms, and select, move, resize or delete annotations.
    case select
    case highlight, underline, strikeOut
    case pen, highlighter
    case textBox, note
    case rectangle, ellipse, line, arrow
    case redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .textBox: "Text Box"
        case .note: "Note"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .redact: "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .pen: "pencil.tip"
        case .highlighter: "paintbrush.pointed"
        case .textBox: "character.textbox"
        case .note: "note.text"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .redact: "rectangle.inset.filled"
        }
    }

    /// Menu shortcut, always with ⌃⌘ (Preview's convention), so single keys stay free
    /// for typing into text boxes and form fields.
    var key: KeyEquivalent {
        switch self {
        case .select: "1"
        case .highlight: "h"
        case .underline: "u"
        case .strikeOut: "k"
        case .pen: "p"
        case .highlighter: "m"
        case .textBox: "t"
        case .note: "n"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .redact: "x"
        }
    }

    /// "⌃⌘H", for tooltips.
    var shortcutLabel: String { "⌃⌘\(String(key.character).uppercased())" }

    /// Text markup: applies to the selected text rather than drawing.
    var isMarkup: Bool { [.highlight, .underline, .strikeOut].contains(self) }

    /// Takes over the mouse: drags draw instead of selecting text.
    var draws: Bool { !isMarkup && self != .select }

    /// What the inspector shows for this tool's style.
    var hasStroke: Bool { [.pen, .highlighter, .rectangle, .ellipse, .line, .arrow].contains(self) }
    var hasFont: Bool { self == .textBox }
    var hasColor: Bool { self != .select && self != .redact }

    /// What the user should do next, for the status bar.
    var hint: String {
        switch self {
        case .select: "Select text or click an annotation"
        case .highlight, .underline, .strikeOut: "Select text to \(title.lowercased()) it"
        case .pen, .highlighter: "Drag to draw"
        case .textBox: "Click or drag to add a text box"
        case .note: "Click to add a note"
        case .rectangle, .ellipse, .line, .arrow: "Drag to draw a \(title.lowercased())"
        case .redact: "Drag over content to remove it permanently"
        }
    }
}
