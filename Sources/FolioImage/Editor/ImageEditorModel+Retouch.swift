import CoreGraphics
import Observation

extension RetouchStroke.Tool: Identifiable {
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clone: "Clone"
        case .heal: "Heal"
        case .spotHeal: "Spot Heal"
        case .remove: "Remove"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .redact: "Redact"
        case .redEye: "Red-Eye"
        }
    }
    var symbol: String {
        switch self {
        case .clone: "seal"
        case .heal: "bandage"
        case .spotHeal: "circle.dotted"
        case .remove: "eraser.line.dashed"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .redact: "rectangle.fill"
        case .redEye: "eye"
        }
    }
}

/// The Retouch tool's options.
@Observable
final class RetouchState {
    var tool: RetouchStroke.Tool = .spotHeal
    /// Brush radius in screen points.
    var radius = 24.0
    var hardness = 0.5
    var opacity = 1.0
    var sampleAllLayers = true
    /// Clone and heal: the ⌥-clicked source, in source pixels.
    var sourcePoint: CGPoint?
}

// Phase 0 stub: the signature is the contract; WP4 fills in the body.
extension ImageEditorModel {
    /// Add `stroke` to the retouch layer (creating it if needed), one undo step.
    func addRetouchStroke(_ stroke: RetouchStroke) {}

    /// Upscale the base image by `factor`, stored as a pixel asset.
    func upscale(by factor: Double) {}

    /// Redact every face, text block and/or barcode Vision finds.
    func autoRedact(faces: Bool, text: Bool, barcodes: Bool) {}
}
