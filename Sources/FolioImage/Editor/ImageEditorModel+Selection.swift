import CoreGraphics
import Foundation
import Observation

/// The selection tools (the Select flyout in the tool rail).
enum SelectionTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, lasso, polygon, wand, colorRange, subject, sky
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .lasso: "Lasso"
        case .polygon: "Polygon Lasso"
        case .wand: "Magic Wand"
        case .colorRange: "Color Range"
        case .subject: "Select Subject"
        case .sky: "Select Sky"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .lasso: "lasso"
        case .polygon: "skew"
        case .wand: "wand.and.rays"
        case .colorRange: "eyedropper.halffull"
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        }
    }
}

/// The live selection and the selection tools' options. Not part of the recipe.
@Observable
final class SelectionState {
    var tool: SelectionTool = .rectangle
    /// How the next shape combines (⇧ add, ⌥ subtract, ⇧⌥ intersect).
    var mode: SelectionSpec.Mode = .add
    var spec: SelectionSpec?
    var wandTolerance = 0.15
    var contiguous = true
    var sampleAllLayers = true
}

// Phase 0 stub: the signature is the contract; WP2 fills in the body.
extension ImageEditorModel {
    /// Combine `shape` into the live selection with `selectionState.mode`.
    func select(_ shape: SelectionSpec.Shape) {}

    func selectAll() {}

    func deselect() {}

    func invertSelection() {}

    /// The subject under `point` (source pixels), or every subject when `nil`.
    func selectSubject(at point: CGPoint?) {}

    /// Copy the live selection into the selected layer's mask (one undo step).
    func addMaskFromSelection() {}
}
