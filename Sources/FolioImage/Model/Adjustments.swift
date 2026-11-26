import Foundation

/// One tone or color slider. Values are in the slider's own units (−100…100 or 0…100)
/// and mapped to Core Image parameters in ``RenderPipeline``, so the stored recipe
/// reads the way the user sees it.
nonisolated enum Adjustment: String, CaseIterable, Codable, Sendable, Identifiable {
    case exposure, brightness, contrast, highlights, shadows
    case saturation, vibrance, warmth, tint
    case sharpness, noiseReduction, vignette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .saturation: "Saturation"
        case .vibrance: "Vibrance"
        case .warmth: "Warmth"
        case .tint: "Tint"
        case .sharpness: "Sharpness"
        case .noiseReduction: "Noise reduction"
        case .vignette: "Vignette"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .sharpness, .noiseReduction: 0...100
        default: -100...100
        }
    }

    enum Section: String, CaseIterable, Sendable {
        case light = "Light", color = "Color", detail = "Detail"
    }

    var section: Section {
        switch self {
        case .exposure, .brightness, .contrast, .highlights, .shadows: .light
        case .saturation, .vibrance, .warmth, .tint: .color
        case .sharpness, .noiseReduction, .vignette: .detail
        }
    }
}

/// Slider values keyed by ``Adjustment``. Zero is stored as "absent" so two recipes
/// that look the same compare equal.
nonisolated struct Adjustments: Codable, Equatable, Sendable {
    private var values: [Adjustment: Double] = [:]

    subscript(_ adjustment: Adjustment) -> Double {
        get { values[adjustment] ?? 0 }
        set {
            let clamped = min(adjustment.range.upperBound, max(adjustment.range.lowerBound, newValue))
            values[adjustment] = abs(clamped) < 0.0001 ? nil : clamped
        }
    }

    var isNeutral: Bool { values.isEmpty }
}

/// The preset looks in the Filters tab.
nonisolated enum FilterPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case vivid, warm, cool, chrome, fade, instant, process, transfer, tonal, mono, noir, silvertone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .instant: "Instant"
        case .process: "Process"
        case .transfer: "Transfer"
        case .tonal: "Tonal"
        case .mono: "Mono"
        case .noir: "Noir"
        case .silvertone: "Silvertone"
        }
    }
}
