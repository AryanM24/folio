public import SwiftUI

/// The Image, Layer, Select and Filter menus. Mount once in the app:
/// `.commands { ImageCommands() }`.
///
/// Items act on the image editor in the key window and are disabled otherwise.
/// Shortcuts follow Preview where it has one (⌘L/⌘R rotate, ⇧⌘K remove background,
/// ⌘0 actual size, ⌘9 fit) and Photoshop for layers and selections (⌘J, ⌘G, ⌘E, ⌘D,
/// ⇧⌘I). Tools take single keys in the canvas (V, M, C…) and ⌃⌘ + that key here.
public struct ImageCommands: Commands {
    @FocusedValue(\.imageEditor) private var editor

    public init() {}

    public var body: some Commands {
        CommandMenu("Image") { imageItems.disabled(editor == nil) }
        CommandMenu("Layer") { layerItems.disabled(editor == nil) }
        CommandMenu("Select") { selectItems.disabled(editor == nil) }
        CommandMenu("Filter") { filterItems.disabled(editor == nil) }
    }

    // MARK: Image

    @ViewBuilder private var imageItems: some View {
        Menu("Tools") {
            ForEach(ImageTool.allCases) { tool in
                Button(tool.title) { editor?.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [.control, .command])
            }
        }
        Divider()
        Button("Zoom In") { editor?.zoomIn() }.keyboardShortcut("+")
        Button("Zoom Out") { editor?.zoomOut() }.keyboardShortcut("-")
        Button("Actual Size") { editor?.actualSize() }.keyboardShortcut("0")
        Button("Zoom to Fit") { editor?.zoomToFit() }.keyboardShortcut("9")
        Button("Zoom to Selection") { editor?.zoomToSelection() }.keyboardShortcut("0", modifiers: [.command, .option])
        Divider()
        toggle("Rulers", \.showRulers).keyboardShortcut("r", modifiers: [.command, .option])
        toggle("Guides", \.showGuides).keyboardShortcut(";")
        toggle("Snap to Guides", \.snapToGuides).keyboardShortcut(";", modifiers: [.command, .shift])
        toggle("Pixel Grid", \.showPixelGrid).keyboardShortcut("'")
        Button("Clear Guides") { editor?.clearGuides() }.disabled(editor?.recipe.guides.isEmpty ?? true)
        Divider()
        Button("Image Size…") { editor?.tool = .crop }.keyboardShortcut("i", modifiers: [.command, .option])
        Button("Trim Transparent Edges") { editor?.trimTransparentEdges() }
        Button("Rotate Left") { editor?.rotateLeft() }.keyboardShortcut("l")
        Button("Rotate Right") { editor?.rotateRight() }.keyboardShortcut("r")
        Button("Flip Horizontal") { editor?.flipHorizontal() }
        Button("Flip Vertical") { editor?.flipVertical() }
        Menu("Upscale") {
            Button("1.5×") { editor?.upscale(by: 1.5) }
            Button("2×") { editor?.upscale(by: 2) }
        }
        Divider()
        ForEach(Array(InspectorTab.allCases.enumerated()), id: \.element) { index, tab in
            Button("Show \(tab.title)") { editor?.tab = tab }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
        }
        Divider()
        Button("Live Text") { editor?.liveTextEnabled.toggle() }.keyboardShortcut("t", modifiers: [.command, .option])
        Button("Pick Color…") { editor?.pickColor() }.keyboardShortcut("c", modifiers: [.command, .option])
        Button(editor?.comparing == true ? "Show Edited" : "Show Original (hold \\)") { editor?.comparing.toggle() }
        Divider()
        Button("Copy Image") { editor?.copyImage() }.keyboardShortcut("c", modifiers: [.command, .shift])
        Button("Export…") { editor?.requestedPopover = .export }.keyboardShortcut("e", modifiers: [.command, .shift])
        Button("Info") { editor?.requestedPopover = .info }.keyboardShortcut("i")
        Toggle(
            "Remove Location and Metadata on Save",
            isOn: Binding(get: { editor?.recipe.stripMetadata ?? false }, set: { _ in editor?.toggleStripMetadata() }))
        Divider()
        Button("Reset All Edits") { editor?.resetAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
    }

    private func toggle(_ title: String, _ keyPath: ReferenceWritableKeyPath<ImageEditorModel, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { editor?[keyPath: keyPath] ?? false }, set: { editor?[keyPath: keyPath] = $0 }))
    }

    // MARK: Layer

    @ViewBuilder private var layerItems: some View {
        let layer = editor?.selectedLayer
        Menu("New Layer") {
            if let editor { AddLayerItems(model: editor) }
        }
        Button("New Paint Layer") { editor?.addPaintLayer() }.keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Duplicate Layer") { editor?.duplicateSelectedLayer() }.keyboardShortcut("j").disabled(layer == nil)
        Button("Delete Layer") { editor?.deleteSelectedLayer() }.disabled(layer == nil || layer?.isLocked == true)
        Divider()
        Button("Group Layer") { editor?.groupSelectedLayer() }.keyboardShortcut("g").disabled(layer == nil)
        Button("Ungroup") { editor?.ungroupSelectedLayer() }.keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!(layer.map { if case .group = $0.content { true } else { false } } ?? false))
        Button("Merge Down") { editor?.mergeDown() }.keyboardShortcut("e").disabled(layer == nil)
        Button("Rasterize Layer") { editor?.rasterizeSelectedLayer() }.disabled(layer == nil)
        Button("Flatten Image") { editor?.flattenImage() }.disabled(editor?.recipe.layers.isEmpty ?? true)
        Divider()
        Button("Bring Forward") { editor?.moveSelectedLayer(by: 1) }.keyboardShortcut("]").disabled(layer == nil)
        Button("Send Backward") { editor?.moveSelectedLayer(by: -1) }.keyboardShortcut("[").disabled(layer == nil)
        Divider()
        Button(layer?.isVisible == false ? "Show Layer" : "Hide Layer") {
            if let layer { editor?.setLayerVisible(layer.id, !layer.isVisible) }
        }
        .keyboardShortcut(",").disabled(layer == nil)
        Button(layer?.isLocked == true ? "Unlock Layer" : "Lock Layer") {
            if let layer { editor?.setLayerLocked(layer.id, !layer.isLocked) }
        }
        .keyboardShortcut("/").disabled(layer == nil)
        Menu("Blend Mode") {
            if let editor, let layer { BlendModeItems(model: editor, layer: layer) }
        }
        .disabled(layer == nil)
        Button("Add Mask from Selection") { editor?.addMaskFromSelection() }
            .disabled(layer == nil || editor?.selectionState.spec == nil)
        Button("Layer Properties") { editor?.tab = .layer }.disabled(layer == nil)
    }

    // MARK: Select

    @ViewBuilder private var selectItems: some View {
        let hasSelection = editor?.selectionState.spec != nil
        Button("All") { editor?.selectAll() }
        Button("Deselect") { editor?.deselect() }.keyboardShortcut("d").disabled(!hasSelection)
        Button("Inverse") { editor?.invertSelection() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!hasSelection)
        Divider()
        Button("Subject") { editor?.selectSubject(at: nil) }.keyboardShortcut("s", modifiers: [.command, .option])
        Button("Sky") { editor?.selectSky() }
        Button("Color Range") {
            editor?.selectionState.tool = .colorRange
            editor?.tool = .select
        }
        Divider()
        Menu("Modify") {
            Section("Expand") { ForEach([2.0, 5, 10, 25], id: \.self) { px in Button("Expand by \(Int(px)) px") { editor?.growSelection(by: px) } } }
            Section("Contract") { ForEach([2.0, 5, 10, 25], id: \.self) { px in Button("Contract by \(Int(px)) px") { editor?.growSelection(by: -px) } } }
            Section("Feather") { ForEach([2.0, 5, 10, 25], id: \.self) { px in Button("Feather \(Int(px)) px") { editor?.featherSelection(px) } } }
            Section("Smooth") { ForEach([2.0, 5, 10], id: \.self) { px in Button("Smooth \(Int(px)) px") { editor?.smoothSelection(px) } } }
        }
        .disabled(!hasSelection)
        Menu("Refine Edge") {
            ForEach([2.0, 5, 10, 20], id: \.self) { px in Button("\(Int(px)) px") { editor?.refineSelectionEdge(px) } }
        }
        .disabled(!hasSelection)
        Divider()
        Button("Save Selection") { editor?.saveSelection() }.disabled(!hasSelection)
        Menu("Load Selection") {
            ForEach(editor?.selectionState.saved ?? []) { saved in Button(saved.name) { editor?.loadSelection(saved) } }
        }
        .disabled(editor?.selectionState.saved.isEmpty ?? true)
        Button("Zoom to Selection") { editor?.zoomToSelection() }.disabled(!hasSelection)
    }

    // MARK: Filter

    @ViewBuilder private var filterItems: some View {
        Button("Auto-Enhance") { editor?.toggleAutoEnhance() }.keyboardShortcut("e", modifiers: [.command, .option])
        Button("Remove Background") { editor?.toggleRemoveBackground() }.keyboardShortcut("k", modifiers: [.command, .shift])
        Divider()
        Menu("Look") {
            Button("None") { editor?.commit("Remove Filter") { $0.filter = nil } }
            Divider()
            ForEach(FilterPreset.allCases) { preset in
                Button(preset.title) { editor?.commit("Filter") { $0.filter = preset; $0.filterStrength = 1 } }
            }
        }
        Menu("As Adjustment Layer") {
            Button("Blur") { editor?.addAdjustmentLayer(.blur(radius: 12)) }
            Button("Pixelate") { editor?.addAdjustmentLayer(.pixelate(size: 16)) }
            Divider()
            ForEach(FilterPreset.allCases) { preset in
                Button(preset.title) { editor?.addAdjustmentLayer(.filter(preset, strength: 1)) }
            }
        }
        Divider()
        Button("Fix Red-Eye") { editor?.fixRedEye() }
        Menu("Auto-Redact") {
            Button("Faces") { editor?.autoRedact(faces: true, text: false, barcodes: false) }
            Button("Text") { editor?.autoRedact(faces: false, text: true, barcodes: false) }
            Button("Barcodes") { editor?.autoRedact(faces: false, text: false, barcodes: true) }
        }
    }
}
