import Foundation

/// A value that can be animated between keyframes.
nonisolated protocol Interpolatable: Codable, Equatable, Sendable {
    /// The value a fraction `t` (0…1) of the way from `a` to `b`.
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self
}

/// The curve from one keyframe to the next. Stored on the earlier keyframe.
nonisolated enum Interpolation: String, Codable, Sendable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut
    /// Keep the earlier value until the next keyframe.
    case hold

    func curve(_ t: Double) -> Double {
        switch self {
        case .linear: t
        case .easeIn: t * t
        case .easeOut: 1 - (1 - t) * (1 - t)
        case .easeInOut: t * t * (3 - 2 * t)
        case .hold: 0
        }
    }
}

nonisolated struct Keyframe<Value: Interpolatable>: Codable, Equatable, Sendable {
    /// Offset from the start of the clip, in timeline time.
    var time: Time
    var value: Value
    var interpolation: Interpolation = .linear
}

/// A property that is either constant or animated by keyframes.
///
/// Keyframe times are offsets from the clip's start, so moving a clip moves its animation.
/// Splits and trims rebase them (`rebased(to:)`) so the picture doesn't change.
/// The renderer evaluates `value(at:)` per frame.
nonisolated struct Keyframed<Value: Interpolatable>: Equatable, Sendable {
    /// The value when there are no keyframes.
    var value: Value
    /// Sorted by time.
    private(set) var keys: [Keyframe<Value>] = []

    init(_ value: Value) { self.value = value }

    var isAnimated: Bool { !keys.isEmpty }

    func value(at time: Time) -> Value {
        guard let first = keys.first, let last = keys.last else { return value }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        let i = keys.lastIndex { $0.time <= time } ?? 0
        let a = keys[i], b = keys[i + 1]
        let span = (b.time - a.time).seconds
        let t = span > 0 ? (time - a.time).seconds / span : 1
        return Value.interpolate(a.value, b.value, a.interpolation.curve(t))
    }

    /// Adds a keyframe, or replaces the one at the same time.
    mutating func set(_ newValue: Value, at time: Time, interpolation: Interpolation = .linear) {
        keys.removeAll { $0.time == time }
        let key = Keyframe(time: time, value: newValue, interpolation: interpolation)
        keys.insert(key, at: keys.firstIndex { $0.time > time } ?? keys.endIndex)
    }

    mutating func removeKey(at time: Time) {
        keys.removeAll { $0.time == time }
    }

    /// Drops the animation and holds `newValue`.
    mutating func setConstant(_ newValue: Value) {
        value = newValue
        keys = []
    }

    /// The animation as seen by a clip cut down (or extended) to `window`, given in the old
    /// clip's offsets: boundary keyframes keep the values at the cut, and times shift so
    /// `window.start` becomes zero.
    ///
    /// shortcut: a cut inside an eased segment keeps that segment's curve name, so the
    /// shape of the rest of the ease is approximate. Exact re-parametrisation can come with
    /// a graph editor.
    func rebased(to window: TimeRange) -> Keyframed {
        guard isAnimated else { return self }
        var result = self
        var kept = keys.filter { window.start <= $0.time && $0.time <= window.end }
        if keys.contains(where: { $0.time < window.start }), !kept.contains(where: { $0.time == window.start }) {
            let before = keys.last { $0.time < window.start }
            kept.insert(
                Keyframe(time: window.start, value: value(at: window.start), interpolation: before?.interpolation ?? .linear), at: 0)
        }
        if keys.contains(where: { $0.time > window.end }), !kept.contains(where: { $0.time == window.end }) {
            kept.append(Keyframe(time: window.end, value: value(at: window.end), interpolation: .linear))
        }
        result.keys = kept.map { Keyframe(time: $0.time - window.start, value: $0.value, interpolation: $0.interpolation) }
        return result
    }
}

nonisolated extension Keyframed: Codable {
    private enum CodingKeys: String, CodingKey { case value, keys }

    // A constant is written as the bare value, so un-animated clips stay small in the file.
    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self), container.contains(.keys) {
            value = try container.decode(Value.self, forKey: .value)
            keys = try container.decode([Keyframe<Value>].self, forKey: .keys).sorted { $0.time < $1.time }
        } else {
            value = try Value(from: decoder)
        }
    }

    func encode(to encoder: any Encoder) throws {
        if keys.isEmpty {
            try value.encode(to: encoder)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
            try container.encode(keys, forKey: .keys)
        }
    }
}

// MARK: - Values

nonisolated extension Double: Interpolatable {
    static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// A 2D point or offset. Positions are fractions of the canvas, y down, origin at the centre.
nonisolated struct Vec2: Interpolatable, Hashable {
    var x: Double
    var y: Double
    static let zero = Vec2(x: 0, y: 0)

    static func interpolate(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 {
        Vec2(x: .interpolate(a.x, b.x, t), y: .interpolate(a.y, b.y, t))
    }
}

/// A rectangle in fractions of the frame (0…1), origin top-left, y down.
nonisolated struct Rect: Interpolatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    static let full = Rect(x: 0, y: 0, width: 1, height: 1)

    static func interpolate(_ a: Rect, _ b: Rect, _ t: Double) -> Rect {
        Rect(
            x: .interpolate(a.x, b.x, t), y: .interpolate(a.y, b.y, t),
            width: .interpolate(a.width, b.width, t), height: .interpolate(a.height, b.height, t))
    }
}

/// Amounts cut from each edge, as fractions of the source frame (0.1 = 10 %).
nonisolated struct Insets: Interpolatable, Hashable {
    var top: Double = 0
    var left: Double = 0
    var bottom: Double = 0
    var right: Double = 0
    static let zero = Insets()

    var isZero: Bool { self == .zero }

    static func interpolate(_ a: Insets, _ b: Insets, _ t: Double) -> Insets {
        Insets(
            top: .interpolate(a.top, b.top, t), left: .interpolate(a.left, b.left, t),
            bottom: .interpolate(a.bottom, b.bottom, t), right: .interpolate(a.right, b.right, t))
    }
}

/// Straight (non-premultiplied) sRGB, components 0…1.
nonisolated struct RGBA: Interpolatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let white = RGBA(red: 1, green: 1, blue: 1)
    static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
    static let green = RGBA(red: 0, green: 1, blue: 0)

    static func interpolate(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(
            red: .interpolate(a.red, b.red, t), green: .interpolate(a.green, b.green, t),
            blue: .interpolate(a.blue, b.blue, t), alpha: .interpolate(a.alpha, b.alpha, t))
    }
}
