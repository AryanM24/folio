import CoreGraphics
import Foundation

// The layer stack, as plain data. Rendered by `LayerCompositor` (above the developed
// original, before geometry), so every coordinate here is in *source pixels* of the
// oriented original, top-left origin, y down, like `MarkupItem`. Crop, turns and
// straighten then apply to the whole document.
//
// Contract types for 0.3: frozen after Phase 0. Add cases only at the end of an enum,
// and new stored properties only with a default, so stored sessions keep decoding.

/// One layer. Layers sit above the developed original, bottom → top.
nonisolated struct Layer: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var content: Content
    var isVisible = true
    var isLocked = false
    /// 0…1, applied after blending (`CIMix`), so effects fade with the layer.
    var opacity = 1.0
    /// 0…1, like `opacity` but spares the layer effects (Photoshop's "Fill").
    var fillOpacity = 1.0
    var blend: BlendMode = .normal
    /// Layer space → source pixels (move, scale, rotate, skew).
    var transform: CGAffineTransform = .identity
    /// Perspective: when set, the corners of the transformed layer's bounds move to
    /// these source-pixel points (`CIPerspectiveTransform`).
    var perspective: Quad?
    /// `nil` = fully visible.
    var mask: LayerMask?
    /// Clip to the alpha of the layer below (`CISourceAtopCompositing`).
    var clipsToBelow = false
    var effects: [LayerEffect] = []

    nonisolated enum Content: Codable, Equatable, Sendable {
        /// Pasted image, ML fill, baked paint, upscale: an encoded image in the asset store.
        case pixels(AssetID)
        case text(TextSpec)
        case shape(ShapeSpec)
        /// Solid color or gradient, filling the whole document.
        case fill(FillSpec)
        /// Applies to everything below it (through the mask and opacity).
        case adjustment(AdjustmentSpec)
        /// Clone, heal, blur, pixelate, redact and red-eye strokes over everything below.
        case retouch([RetouchStroke])
        case paint(PaintSpec)
        case group(GroupSpec)
    }

    /// Photoshop's 27 blend modes. `CI…BlendMode` filters cover most; the rest
    /// (dissolve, darker/lighter color, hard mix) are runtime Metal kernels.
    nonisolated enum BlendMode: String, CaseIterable, Codable, Sendable, Identifiable {
        case normal, dissolve
        case darken, multiply, colorBurn, linearBurn, darkerColor
        case lighten, screen, colorDodge, linearDodge, lighterColor
        case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
        case difference, exclusion, subtract, divide
        case hue, saturation, color, luminosity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .normal: "Normal"
            case .dissolve: "Dissolve"
            case .darken: "Darken"
            case .multiply: "Multiply"
            case .colorBurn: "Color Burn"
            case .linearBurn: "Linear Burn"
            case .darkerColor: "Darker Color"
            case .lighten: "Lighten"
            case .screen: "Screen"
            case .colorDodge: "Color Dodge"
            case .linearDodge: "Linear Dodge (Add)"
            case .lighterColor: "Lighter Color"
            case .overlay: "Overlay"
            case .softLight: "Soft Light"
            case .hardLight: "Hard Light"
            case .vividLight: "Vivid Light"
            case .linearLight: "Linear Light"
            case .pinLight: "Pin Light"
            case .hardMix: "Hard Mix"
            case .difference: "Difference"
            case .exclusion: "Exclusion"
            case .subtract: "Subtract"
            case .divide: "Divide"
            case .hue: "Hue"
            case .saturation: "Saturation"
            case .color: "Color"
            case .luminosity: "Luminosity"
            }
        }
    }
}

/// A group of layers. Pass-through groups blend their children straight into the
/// layers below; isolated groups composite their children first, then blend once.
nonisolated struct GroupSpec: Codable, Equatable, Sendable {
    var layers: [Layer] = []
    var passThrough = true
}

// MARK: - Masks

nonisolated struct LayerMask: Codable, Equatable, Sendable {
    var source: MaskSource
    /// Gaussian feather radius in source pixels.
    var feather = 0.0
    /// 0…1: how strongly the hidden parts are hidden.
    var density = 1.0
    var inverted = false
    var isEnabled = true
}

nonisolated enum MaskSource: Codable, Equatable, Sendable {
    /// Recomputed from the spec (rect, lasso, wand, subject…), never stored as pixels.
    case selection(SelectionSpec)
    /// A painted grayscale mask in the asset store (white = visible), in layer space.
    case pixels(AssetID)
    /// A vector mask, filled = visible, in layer space.
    case vector(VectorPath)
    /// A luminosity mask: visible where the pixels below are between `low` and `high` (0…1).
    case luminance(low: Double, high: Double)
}

// MARK: - Effects

nonisolated enum LayerEffect: Codable, Equatable, Sendable {
    case dropShadow(ShadowEffect)
    case stroke(StrokeEffect)
    case outerGlow(GlowEffect)
}

nonisolated struct ShadowEffect: Codable, Equatable, Sendable {
    var color = RGBA(red: 0, green: 0, blue: 0)
    var opacity = 0.5
    /// Direction the light comes from, in degrees (Photoshop: 120 = from the top left).
    var angle = 120.0
    /// Offset in source pixels.
    var distance = 10.0
    var blur = 10.0
    /// 0…1: how much of the blur is solid before it fades.
    var spread = 0.0
    var blend: Layer.BlendMode = .multiply
}

nonisolated struct StrokeEffect: Codable, Equatable, Sendable {
    nonisolated enum Position: String, Codable, Sendable, CaseIterable { case outside, inside, center }
    var color = RGBA(red: 0, green: 0, blue: 0)
    var width = 3.0
    var position: Position = .outside
    var opacity = 1.0
}

nonisolated struct GlowEffect: Codable, Equatable, Sendable {
    var color = RGBA(red: 1, green: 1, blue: 0.75)
    var opacity = 0.75
    var radius = 10.0
    var spread = 0.0
    var blend: Layer.BlendMode = .screen
}

// MARK: - Content specs

/// Text in layer space. Fonts are stored by PostScript name and fall back when missing.
nonisolated struct TextSpec: Codable, Equatable, Sendable {
    nonisolated enum Alignment: String, Codable, Sendable, CaseIterable { case left, center, right, justified }

    var runs: [TextRun]
    var alignment: Alignment = .left
    /// Line height as a multiple of the font's natural line height.
    var lineHeight = 1.0
    /// `nil`: point text that grows as you type. Otherwise area text wrapped to this width
    /// (and clipped to this height), with its top-left at the layer origin.
    var box: CGSize?
    /// Text on a path (layer space), or `nil` for straight lines.
    var path: VectorPath?
    /// Paints the glyphs with a gradient instead of each run's color.
    var fill: FillSpec?

    var string: String { runs.map(\.text).joined() }
}

nonisolated struct TextRun: Codable, Equatable, Sendable {
    var text: String
    var fontName = "Helvetica"
    /// Point size in source pixels.
    var size = 48.0
    var color = RGBA(red: 0, green: 0, blue: 0)
    /// Extra spacing between characters, in thousandths of an em (Photoshop's tracking).
    var tracking = 0.0
    var underline = false
    var strikethrough = false
}

nonisolated struct ShapeSpec: Codable, Equatable, Sendable {
    nonisolated enum Geometry: Codable, Equatable, Sendable {
        case rectangle(CGRect, cornerRadius: Double)
        case ellipse(CGRect)
        /// A line; heads make it an arrow (double-ended when both are set).
        case line(from: CGPoint, to: CGPoint, startHead: ArrowHead, endHead: ArrowHead)
        case polygon(CGRect, sides: Int)
        /// `innerRadius` is the inner points' distance as a fraction of the outer (0…1).
        case star(CGRect, points: Int, innerRadius: Double)
        case speechBubble(CGRect, tail: CGPoint)
        case path(VectorPath)
    }

    nonisolated enum ArrowHead: String, Codable, Sendable, CaseIterable { case none, open, closed, curved }

    var geometry: Geometry
    var fill: FillSpec?
    var stroke: StrokeSpec?
}

nonisolated struct StrokeSpec: Codable, Equatable, Sendable {
    nonisolated enum Cap: String, Codable, Sendable, CaseIterable { case butt, round, square }
    nonisolated enum Join: String, Codable, Sendable, CaseIterable { case miter, round, bevel }

    var color = RGBA(red: 0, green: 0, blue: 0)
    /// Width in source pixels.
    var width = 4.0
    /// Dash lengths in source pixels; empty = solid.
    var dash: [Double] = []
    var cap: Cap = .round
    var join: Join = .round
}

nonisolated enum FillSpec: Codable, Equatable, Sendable {
    case solid(RGBA)
    case gradient(GradientSpec)
}

/// A multi-stop gradient from `start` to `end` (layer space). Radial and diamond use
/// `start` as the center and the distance to `end` as the radius; angular sweeps
/// around `start` beginning at `end`.
nonisolated struct GradientSpec: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable, CaseIterable { case linear, radial, angular, diamond, reflected }

    var kind: Kind = .linear
    var stops: [ColorStop]
    var start: CGPoint
    var end: CGPoint
}

nonisolated struct ColorStop: Codable, Equatable, Sendable {
    /// 0…1 along the gradient.
    var location: Double
    var color: RGBA
}

/// What an adjustment layer does to everything below it.
nonisolated enum AdjustmentSpec: Codable, Equatable, Sendable {
    case adjustments(Adjustments)
    /// Curves, levels, HSL, color balance, channel mixer, white balance, LUT.
    case tone(ToneSpec)
    case filter(FilterPreset, strength: Double)
    /// Gaussian blur radius in source pixels.
    case blur(radius: Double)
    /// Block size in source pixels.
    case pixelate(size: Double)
}

/// A retouch operation, stored as data and re-rendered, except where the result is
/// expensive or non-deterministic (spot heal, remove): that fill is kept in `patch`.
nonisolated struct RetouchStroke: Codable, Equatable, Sendable, Identifiable {
    nonisolated enum Tool: String, Codable, Sendable, CaseIterable {
        case clone, heal, spotHeal, remove, blur, pixelate, redact, redEye
    }

    /// Where the tool applies, in source pixels.
    nonisolated enum Area: Codable, Equatable, Sendable {
        /// A brushed path; `radius` in source pixels.
        case brush(points: [CGPoint], radius: Double)
        case rect(CGRect)
        case selection(SelectionSpec)
    }

    var id = UUID()
    var tool: Tool
    var area: Area
    /// 0…1: 1 = hard edge, 0 = fully soft brush.
    var hardness = 0.5
    var opacity = 1.0
    /// Clone/heal: where the pixels are taken from, relative to the destination.
    var sourceOffset: CGSize?
    /// Sample the composite of every layer below, not only the base image.
    var sampleAllLayers = true
    /// Tool strength: blur radius, pixelate block size or red-eye desaturation (0…1).
    var amount = 0.0
    /// Redact fill color.
    var color = RGBA(red: 0, green: 0, blue: 0)
    /// The computed fill for spot heal and remove, so re-renders don't recompute it.
    var patch: PlacedAsset?
}

/// An image asset placed at `rect` (source pixels).
nonisolated struct PlacedAsset: Codable, Equatable, Sendable {
    var asset: AssetID
    var rect: CGRect
}

/// A paint layer: an optional baked raster plus the strokes painted since the bake.
/// Baking every N strokes keeps the recipe small.
nonisolated struct PaintSpec: Codable, Equatable, Sendable {
    var baked: PlacedAsset?
    var strokes: [BrushStroke] = []
}

nonisolated struct BrushStroke: Codable, Equatable, Sendable {
    nonisolated struct Point: Codable, Equatable, Sendable {
        var location: CGPoint
        /// 0…1 from a tablet (`NSEvent.pressure`); 1 for a mouse.
        var pressure = 1.0
    }

    var points: [Point]
    var color = RGBA(red: 0, green: 0, blue: 0)
    /// Diameter in source pixels.
    var size = 20.0
    var hardness = 0.8
    var opacity = 1.0
    var flow = 1.0
    /// Erases the layer's pixels (destination-out) instead of painting.
    var isEraser = false
}

// MARK: - Geometry helpers

/// Four corners in source pixels, for perspective transforms and corrections.
nonisolated struct Quad: Codable, Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

/// A Bézier path that encodes as data (selections, vector masks, shapes, text paths).
nonisolated struct VectorPath: Codable, Equatable, Sendable {
    nonisolated enum Element: Codable, Equatable, Sendable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quad(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    var elements: [Element] = []

    var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .quad(let p, let c): path.addQuadCurve(to: p, control: c)
            case .curve(let p, let c1, let c2): path.addCurve(to: p, control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
