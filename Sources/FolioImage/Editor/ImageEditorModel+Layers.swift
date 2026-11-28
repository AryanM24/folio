import Foundation
import Observation

/// Which layer the Layers panel, the Layer inspector and the transform handles act on.
@Observable
final class LayerEditingState {
    var selectedID: UUID?
}

// Phase 0 stub: the signature is the contract; WP1 fills in the body.
// Each command is one undo step through `commit(_:_:)`.
extension ImageEditorModel {
    var selectedLayer: Layer? { nil }

    /// Insert above the selected layer (or on top) and select it.
    func addLayer(_ layer: Layer) {}

    func deleteSelectedLayer() {}

    /// Reorder top-level layers (`List.onMove` offsets, bottom → top order).
    func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {}

    func duplicateSelectedLayer() {}

    func groupSelectedLayer() {}

    func mergeDown() {}

    /// Change the layer with `id`; `live` turns a drag into one step (see `live(_:)`).
    func updateLayer(_ id: UUID, _ actionName: String, live: Bool = false, _ change: (inout Layer) -> Void) {}
}
