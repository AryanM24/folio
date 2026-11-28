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

// Phase 0 stub: the signature is the contract; WP5 fills in the body.
struct ToolRail: View {
    let model: ImageEditorModel

    var body: some View { EmptyView() }
}
