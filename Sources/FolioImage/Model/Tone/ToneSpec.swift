import CoreGraphics
import Foundation

/// Curves, levels, HSL, color balance, channel mixer, white balance and a LUT, as data.
///
/// The base image's tone lives in `EditRecipe.tone` (after the Adjust sliders, before
/// the filter); adjustment layers carry their own (`AdjustmentSpec.tone`). Rendered by
/// `ToneRenderer`, in this order: white balance → levels → curves → color balance →
/// HSL → channel mixer → LUT. Exposure, vibrance and the other sliders stay in
/// ``Adjustments``.
///
/// The default value changes nothing, and ``normalize()`` makes every spelling of
/// "nothing" equal to it, so `isIdentity` means "same pixels".
/// Contract type for 0.3: frozen after Phase 0.
nonisolated struct ToneSpec: Codable, Equatable, Sendable {
    /// Curve points (x = input, y = output, both 0…1), sorted by x; empty = straight line.
    /// The pipeline interpolates with a monotone cubic, so points never overshoot.
    var curves = ChannelSet<[CGPoint]>([])
    var levels = ChannelSet(LevelsChannel())
    /// Shifts per hue band; neutral bands are absent.
    var hsl: [HueBand: HSLShift] = [:]
    var colorBalance = ColorBalance()
    /// `nil` = off.
    var channelMixer: ChannelMixer?
    /// `nil` = as shot.
    var whiteBalance: WhiteBalance?
    var lut: LUTRef?

    var isIdentity: Bool { self == ToneSpec() }

    /// Drop settings that change nothing, so equal-looking specs compare equal.
    mutating func normalize() {
        for channel in ToneChannel.allCases {
            var points = curves[channel].sorted { $0.x < $1.x }
            if points.allSatisfy({ abs($0.x - $0.y) < 0.0001 }) { points = [] }
            curves[channel] = points
        }
        hsl = hsl.filter { !$0.value.isNeutral }
        if channelMixer == ChannelMixer() { channelMixer = nil }
        if whiteBalance == WhiteBalance() { whiteBalance = nil }
        if let strength = lut?.strength, strength <= 0 { lut = nil }
    }
}

/// The composite RGB channel and the three color channels.
nonisolated enum ToneChannel: String, Codable, Sendable, CaseIterable, Identifiable {
    case rgb, red, green, blue
    var id: String { rawValue }
}

/// One value per ``ToneChannel``.
nonisolated struct ChannelSet<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var rgb: Value
    var red: Value
    var green: Value
    var blue: Value

    /// The same value for every channel.
    init(_ value: Value) { (rgb, red, green, blue) = (value, value, value, value) }

    init(rgb: Value, red: Value, green: Value, blue: Value) { (self.rgb, self.red, self.green, self.blue) = (rgb, red, green, blue) }

    subscript(_ channel: ToneChannel) -> Value {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }
}

/// Levels for one channel, all 0…1 except gamma (0.1…10, 1 = linear).
nonisolated struct LevelsChannel: Codable, Equatable, Sendable {
    var inputBlack = 0.0
    var inputWhite = 1.0
    var gamma = 1.0
    var outputBlack = 0.0
    var outputWhite = 1.0
}

/// The eight bands of Photoshop's and Lightroom's HSL panel.
nonisolated enum HueBand: String, Codable, Sendable, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: String { rawValue }
}

/// −100…100 each.
nonisolated struct HSLShift: Codable, Equatable, Sendable {
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0
    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

nonisolated struct ColorBalance: Codable, Equatable, Sendable {
    var shadows = ColorShift()
    var midtones = ColorShift()
    var highlights = ColorShift()
    var preserveLuminosity = true
}

/// −100…100 each: negative toward the first color of the pair.
nonisolated struct ColorShift: Codable, Equatable, Sendable {
    var cyanRed = 0.0
    var magentaGreen = 0.0
    var yellowBlue = 0.0
}

/// Each output channel as a mix of the inputs (1 = 100 %), plus a constant offset.
nonisolated struct ChannelMixer: Codable, Equatable, Sendable {
    nonisolated struct Row: Codable, Equatable, Sendable {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var constant = 0.0
    }

    var red = Row(red: 1)
    var green = Row(green: 1)
    var blue = Row(blue: 1)
    /// Use the red row as a gray mix for all three channels (black and white).
    var monochrome = false
}

/// The scene's white point: an eyedropper result is stored as these numbers, not the
/// sampled point, so it survives crops.
nonisolated struct WhiteBalance: Codable, Equatable, Sendable {
    /// Kelvin.
    var temperature = 6500.0
    /// Green (−) to magenta (+), −150…150.
    var tint = 0.0
}

/// A `.cube` file in the asset store, mixed in at `strength` (0…1).
nonisolated struct LUTRef: Codable, Equatable, Sendable {
    var asset: AssetID
    var name: String
    var strength = 1.0
}
