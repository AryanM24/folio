import FolioKit
import SwiftUI

/// The tools in the left rail. Single-key shortcuts as in Photoshop and Pixelmator.
enum ImageTool: String, CaseIterable, Identifiable {
    case move, select, crop, brush, eraser, retouch, text, shape, gradient, eyedropper, hand, zoom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .move: "Move"
        case .select: "Select"
        case .crop: "Crop"
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .retouch: "Retouch"
        case .text: "Text"
        case .shape: "Shape"
        case .gradient: "Gradient"
        case .eyedropper: "Eyedropper"
        case .hand: "Hand"
        case .zoom: "Zoom"
        }
    }
    var symbol: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .select: "rectangle.dashed"
        case .crop: "crop"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .retouch: "bandage"
        case .text: "textformat"
        case .shape: "square.on.circle"
        case .gradient: "circle.lefthalf.filled"
        case .eyedropper: "eyedropper"
        case .hand: "hand.raised"
        case .zoom: "magnifyingglass"
        }
    }
    var shortcut: Character {
        switch self {
        case .move: "v"
        case .select: "m"
        case .crop: "c"
        case .brush: "b"
        case .eraser: "e"
        case .retouch: "j"
        case .text: "t"
        case .shape: "u"
        case .gradient: "g"
        case .eyedropper: "i"
        case .hand: "h"
        case .zoom: "z"
        }
    }
}

/// The vertical tool pill at the canvas's left edge. Click a tool or press its key;
/// pressing the key again cycles its variants (selection shapes, retouch tools, shapes).
struct ToolRail: View {
    let model: ImageEditorModel

    /// Tools in rail order, grouped by dividers.
    static let groups: [[ImageTool]] = [[.move, .select, .crop], [.retouch, .brush, .eraser], [.text, .shape, .gradient], [.eyedropper, .hand, .zoom]]

    var body: some View {
        HeroToolbar(.vertical) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { HeroToolbarDivider(.vertical) }
                ForEach(group) { tool in button(tool) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    private func button(_ tool: ImageTool) -> some View {
        let selected = model.tool == tool
        return Button {
            model.tool = tool
        } label: {
            Label(tool.title, systemImage: symbol(tool))
        }
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: selected))
        .help("\(variantTitle(tool) ?? tool.title) (\(tool.shortcut.uppercased()))")
        .accessibilityLabel(variantTitle(tool).map { "\(tool.title), \($0)" } ?? tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { variants(tool) }
    }

    /// The rail shows the active variant's symbol, as Photoshop's flyouts do.
    private func symbol(_ tool: ImageTool) -> String {
        switch tool {
        case .select: model.selectionState.tool.symbol
        case .retouch: model.retouchState.tool.symbol
        case .shape: model.options.shape.symbol
        default: tool.symbol
        }
    }

    private func variantTitle(_ tool: ImageTool) -> String? {
        switch tool {
        case .select: model.selectionState.tool.title
        case .retouch: model.retouchState.tool.title
        case .shape: model.options.shape.title
        default: nil
        }
    }

    @ViewBuilder private func variants(_ tool: ImageTool) -> some View {
        switch tool {
        case .select:
            ForEach(SelectionTool.allCases) { v in
                Button(v.title, systemImage: v.symbol) { model.selectionState.tool = v; model.tool = .select }
            }
        case .retouch:
            ForEach(RetouchStroke.Tool.allCases) { v in
                Button(v.title, systemImage: v.symbol) { model.retouchState.tool = v; model.tool = .retouch }
            }
        case .shape:
            ForEach(ShapeKind.allCases) { v in
                Button(v.title, systemImage: v.symbol) { model.options.shape = v; model.tool = .shape }
            }
        default: EmptyView()
        }
    }
}
