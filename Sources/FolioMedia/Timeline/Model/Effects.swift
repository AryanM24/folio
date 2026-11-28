import Foundation

// What a clip looks like, as data. Nothing here renders: `Timeline/Render` maps each case
// to a Core Image chain, in the order the list holds them.

/// One entry in a clip's effect stack. The stack applies top to bottom.
nonisolated struct Effect: Codable, Equatable, Sendable, Identifiable {
    var id = EffectID()
    var isEnabled = true
    var kind: EffectKind

    init(_ kind: EffectKind) { self.kind = kind }
}

nonisolated enum EffectKind: Codable, Equatable, Sendable {
    /// Exposure, contrast, saturation, white balance… Auto-enhance stores its result here,
    /// computed once per clip, because computing it per frame flickers.
    case color(ColorAdjustments)
    case look(Look, intensity: Double = 1)
    /// A `.cube` file, referenced like media (path + bookmark), never copied in.
    case lut(LUTReference)
    case vignette(intensity: Double = 1, radius: Double = 1)
    case sharpen(amount: Double = 0.4)
    /// Gaussian blur radius as a fraction of the frame height.
    case blur(radius: Double = 0.01)
    case grain(amount: Double = 0.3)
    case chromaKey(ChromaKey)
    /// Cut out people or any subject (Vision masks, cached per source by the analysis pass).
    case removeBackground(BackgroundSubject)
    /// Blur, pixelate or cover regions; each can follow a tracked face.
    case redact([RedactRegion])
    /// 0…1. The analysis pass caches the smoothed camera path; this is how strongly to use it.
    case stabilize(strength: Double = 0.7)
    case denoise(strength: Double = 0.5)
}

/// Neutral values leave the picture untouched. The render order is fixed:
/// exposure, white balance, highlights/shadows, contrast/saturation, vibrance.
nonisolated struct ColorAdjustments: Codable, Equatable, Sendable {
    /// EV stops.
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var vibrance = 0.0
    /// Kelvin of the light the footage was shot under; 6500 is neutral.
    var temperature = 6500.0
    var tint = 0.0
    /// 1 leaves highlights alone, lower recovers them.
    var highlights = 1.0
    /// 0 leaves shadows alone, higher lifts them.
    var shadows = 0.0

    var isNeutral: Bool { self == ColorAdjustments() }
}

/// Built-in looks (Core Image photo effects and sepia).
nonisolated enum Look: String, Codable, Sendable, CaseIterable {
    case mono, noir, tonal, chrome, fade, instant, process, transfer, sepia
}

nonisolated struct LUTReference: Codable, Equatable, Sendable {
    var name: String
    var path: String
    var bookmark: Data?
    /// Mix with the original, 0…1.
    var intensity = 1.0
}

nonisolated struct ChromaKey: Codable, Equatable, Sendable {
    var color = RGBA.green
    /// How far from `color` still counts as background, 0…1.
    var tolerance = 0.2
    var softness = 0.1
    var spillSuppression = 0.5
}

nonisolated enum BackgroundSubject: String, Codable, Sendable {
    /// Person segmentation. It also fires on animals, so the subject mode exists.
    case people
    /// Any foreground subject.
    case subject
}

nonisolated struct RedactRegion: Codable, Equatable, Sendable, Identifiable {
    enum Style: String, Codable, Sendable { case blur, pixelate, fill }

    var id = UUID()
    /// Where the region is, per frame (clip offsets).
    var rect: Keyframed<Rect>
    var style = Style.blur
    var amount = 0.5
    var fill = RGBA.black
    /// Keyframes came from the face tracker; editing one by hand clears it.
    var isTracked = false
}

// MARK: - Titles

nonisolated struct Title: Codable, Equatable, Sendable {
    var text: String
    var style = TextStyle()
    var animationIn = TitleAnimation.none
    var animationOut = TitleAnimation.none
    /// Length of each animation.
    var animationDuration = Time(value: 1, timescale: 2)
}

nonisolated enum TitleAnimation: String, Codable, Sendable, CaseIterable {
    case none, fade, slideUp, slideDown, scale, typewriter
}

/// Text styling shared by titles and captions. Sizes are fractions of the canvas height,
/// so a title looks the same on a 720p preview and a 4K export.
nonisolated struct TextStyle: Codable, Equatable, Sendable {
    enum Weight: String, Codable, Sendable, CaseIterable { case regular, medium, semibold, bold, heavy }
    enum Alignment: String, Codable, Sendable { case leading, center, trailing }

    /// PostScript or family name; `nil` is the system font.
    var fontName: String?
    var weight = Weight.bold
    var size = 0.07
    var color = RGBA.white
    var alignment = Alignment.center
    var lineSpacing = 0.0
    var letterSpacing = 0.0
    var stroke: TextStroke?
    var shadow: TextShadow?
    var box: TextBox?
}

nonisolated struct TextStroke: Codable, Equatable, Sendable {
    var color = RGBA.black
    /// Fraction of the font size.
    var width = 0.06
}

nonisolated struct TextShadow: Codable, Equatable, Sendable {
    var color = RGBA(red: 0, green: 0, blue: 0, alpha: 0.6)
    /// Fractions of the font size.
    var radius = 0.1
    var offset = Vec2(x: 0, y: 0.05)
}

/// A filled box behind the text.
nonisolated struct TextBox: Codable, Equatable, Sendable {
    var color = RGBA(red: 0, green: 0, blue: 0, alpha: 0.6)
    /// Fractions of the font size.
    var padding = 0.3
    var cornerRadius = 0.2
}

// MARK: - Transitions

/// A transition centred on a cut. It uses media beyond each clip's edges (handles), so it
/// never changes the timeline's length. Between two butted clips it lives on the right
/// clip's `transitionIn`; with nothing butted, `transitionIn`/`transitionOut` fade the clip
/// from or to the layers below (black on the primary track).
nonisolated struct ClipTransition: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case dissolve
        case fadeThroughBlack, fadeThroughWhite
        case wipe, slide, push, zoom
        case bars, copyMachine, pageCurl, ripple, flash, accordion, mod
    }
    enum Direction: String, Codable, Sendable, CaseIterable { case left, right, up, down }

    var kind = Kind.dissolve
    var duration: Time
    /// For wipes, slides, pushes and bars.
    var direction = Direction.left
}
