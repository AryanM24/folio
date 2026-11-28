import CoreMedia

// The only file in the timeline model that touches AVFoundation's types: everything
// else is plain Swift so it can be reasoned about, tested and encoded on its own.

/// An exact rational time: `value / timescale` seconds, like `CMTime` but Codable.
///
/// Edits never use `Double`. A cut at frame 1,001 of a 23.976 fps clip is exactly
/// `1001 × 1001 / 24000` s, and stays exact through any number of splits and trims.
/// Arithmetic keeps the timescale when both sides share it, so a project's times stay
/// readable in the JSON ("1001/24000"), and falls back to flicks only when a result
/// can't be stored exactly in `Int64 / Int32`.
nonisolated struct Time: Sendable {
    var value: Int64
    /// Units per second. Always positive.
    var timescale: Int32

    init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "A time needs a positive timescale")
        self.value = value
        self.timescale = timescale
    }

    /// 705,600,000 per second: every common frame duration (including the x/1001 NTSC
    /// rates) and sample rate is a whole number of flicks, so rounding to it keeps frame
    /// boundaries exact.
    static let flicks: Int32 = 705_600_000

    static let zero = Time(value: 0, timescale: 1)

    /// For UI input and tests. Rounded to flicks.
    init(seconds: Double) {
        self.init(value: Int64((seconds * Double(Self.flicks)).rounded()), timescale: Self.flicks)
    }

    var seconds: Double { Double(value) / Double(timescale) }

    /// The closest storable time to `value / timescale`, exact whenever it fits.
    static func exact(_ value: Int128, _ timescale: Int128) -> Time {
        precondition(timescale > 0)
        var v = value, ts = timescale
        if ts > Int128(Int32.max) || Int64(exactly: v) == nil {
            let g = gcd(v, ts)
            if g > 1 { (v, ts) = (v / g, ts / g) }
        }
        if ts <= Int128(Int32.max), let small = Int64(exactly: v) {
            return Time(value: small, timescale: Int32(ts))
        }
        return Time(value: Int64(clamping: roundedDivision(v * Int128(flicks), ts)), timescale: flicks)
    }
}

nonisolated extension Time: Comparable, Hashable, CustomStringConvertible {
    static func == (a: Time, b: Time) -> Bool {
        Int128(a.value) * Int128(b.timescale) == Int128(b.value) * Int128(a.timescale)
    }

    static func < (a: Time, b: Time) -> Bool {
        Int128(a.value) * Int128(b.timescale) < Int128(b.value) * Int128(a.timescale)
    }

    // Equal times with different timescales must hash alike, so hash the reduced fraction.
    func hash(into hasher: inout Hasher) {
        let g = gcd(Int128(value), Int128(timescale))
        hasher.combine(Int128(value) / g)
        hasher.combine(Int128(timescale) / g)
    }

    var description: String { "\(value)/\(timescale)" }

    static func + (a: Time, b: Time) -> Time {
        if a.timescale == b.timescale, case let (sum, false) = a.value.addingReportingOverflow(b.value) {
            return Time(value: sum, timescale: a.timescale)
        }
        let l = lcm(Int128(a.timescale), Int128(b.timescale))
        return exact(Int128(a.value) * (l / Int128(a.timescale)) + Int128(b.value) * (l / Int128(b.timescale)), l)
    }

    static prefix func - (a: Time) -> Time { Time(value: -a.value, timescale: a.timescale) }
    static func - (a: Time, b: Time) -> Time { a + -b }
    static func += (a: inout Time, b: Time) { a = a + b }
    static func -= (a: inout Time, b: Time) { a = a - b }

    static func * (a: Time, n: Int64) -> Time { exact(Int128(a.value) * Int128(n), Int128(a.timescale)) }

    /// Source time consumed by `a` of timeline time at `speed`.
    static func * (a: Time, speed: Rational) -> Time {
        exact(Int128(a.value) * Int128(speed.numerator), Int128(a.timescale) * Int128(speed.denominator))
    }

    /// Timeline time needed to play `a` of source time at `speed`. `speed` must be positive.
    static func / (a: Time, speed: Rational) -> Time {
        precondition(speed.numerator > 0, "Divide by a positive speed")
        return exact(Int128(a.value) * Int128(speed.denominator), Int128(a.timescale) * Int128(speed.numerator))
    }
}

nonisolated extension Time: Codable {
    // "value/timescale": exact, compact, and readable in a diff.
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let (v, ts) = parseFraction(text), let value = Int64(exactly: v), let scale = Int32(exactly: ts), scale > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a time: \(text)"))
        }
        self.init(value: value, timescale: scale)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A half-open span `[start, start + duration)`.
nonisolated struct TimeRange: Codable, Hashable, Sendable, CustomStringConvertible {
    var start: Time
    var duration: Time

    init(start: Time, duration: Time) {
        self.start = start
        self.duration = duration
    }

    init(start: Time, end: Time) {
        self.init(start: start, duration: end - start)
    }

    var end: Time { start + duration }
    var isEmpty: Bool { duration <= .zero }
    var description: String { "[\(start), \(end))" }

    func contains(_ time: Time) -> Bool { start <= time && time < end }
    func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    /// The shared part, or `nil` when they don't overlap.
    func intersection(_ other: TimeRange) -> TimeRange? {
        let lo = max(start, other.start), hi = min(end, other.end)
        return hi > lo ? TimeRange(start: lo, end: hi) : nil
    }

    func shifted(by delta: Time) -> TimeRange { TimeRange(start: start + delta, duration: duration) }
}

/// An exact ratio, reduced, with a positive denominator. Used for playback speed.
nonisolated struct Rational: Hashable, Comparable, Sendable, CustomStringConvertible {
    let numerator: Int64
    let denominator: Int64

    init(_ numerator: Int64, _ denominator: Int64 = 1) {
        precondition(denominator != 0, "A ratio needs a non-zero denominator")
        let sign: Int64 = denominator < 0 ? -1 : 1
        let g = Int64(gcd(Int128(numerator), Int128(denominator)))
        self.numerator = sign * numerator / max(g, 1)
        self.denominator = sign * denominator / max(g, 1)
    }

    /// From a slider value, to a thousandth (1.37× → 137/100).
    init(approximating value: Double) {
        self.init(Int64((value * 1000).rounded()), 1000)
    }

    static let one = Rational(1)
    static let zero = Rational(0)

    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var description: String { "\(numerator)/\(denominator)" }

    static func < (a: Rational, b: Rational) -> Bool {
        Int128(a.numerator) * Int128(b.denominator) < Int128(b.numerator) * Int128(a.denominator)
    }
}

nonisolated extension Rational: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let (n, d) = parseFraction(text), let num = Int64(exactly: n), let den = Int64(exactly: d), den != 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a ratio: \(text)"))
        }
        self.init(num, den)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Frames per second as an exact ratio: 23.976 is 24000 frames per 1001 seconds.
nonisolated struct FrameRate: Hashable, Sendable, CustomStringConvertible {
    /// Frames in `seconds`.
    var frames: Int32
    var seconds: Int32

    init(_ frames: Int32, per seconds: Int32 = 1) {
        precondition(frames > 0 && seconds > 0, "A frame rate must be positive")
        self.frames = frames
        self.seconds = seconds
    }

    static let fps23_976 = FrameRate(24000, per: 1001)
    static let fps24 = FrameRate(24)
    static let fps25 = FrameRate(25)
    static let fps29_97 = FrameRate(30000, per: 1001)
    static let fps30 = FrameRate(30)
    static let fps50 = FrameRate(50)
    static let fps59_94 = FrameRate(60000, per: 1001)
    static let fps60 = FrameRate(60)
    static let presets: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]

    var perSecond: Double { Double(frames) / Double(seconds) }
    var frameDuration: Time { Time(value: Int64(seconds), timescale: frames) }
    /// "23.976", "29.97", "25".
    var description: String {
        seconds == 1 ? "\(frames)" : "\((perSecond * 1000).rounded() / 1000)"
    }

    /// The start time of frame `n` (frame 0 starts at zero).
    func time(ofFrame n: Int64) -> Time { Time(value: n * Int64(seconds), timescale: frames) }

    /// The frame showing at `time` (rounded down).
    func frame(at time: Time) -> Int64 {
        Int64(clamping: flooredDivision(Int128(time.value) * Int128(frames), Int128(time.timescale) * Int128(seconds)))
    }

    /// The nearest frame boundary. Every edit snaps its times through this.
    func snap(_ time: Time) -> Time {
        let n = roundedDivision(Int128(time.value) * Int128(frames), Int128(time.timescale) * Int128(seconds))
        return self.time(ofFrame: Int64(clamping: n))
    }

    func floor(_ time: Time) -> Time { self.time(ofFrame: frame(at: time)) }
    func ceil(_ time: Time) -> Time { -floor(-time) }
    func isOnFrame(_ time: Time) -> Bool { snap(time) == time }
}

nonisolated extension FrameRate: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let (f, s) = parseFraction(text), let frames = Int32(exactly: f), let seconds = Int32(exactly: s), frames > 0, seconds > 0
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a frame rate: \(text)"))
        }
        self.init(frames, per: seconds)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("\(frames)/\(seconds)")
    }
}

// MARK: - CMTime bridging

nonisolated extension Time {
    /// `nil` for invalid, indefinite or infinite times.
    init?(_ time: CMTime) {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        self.init(value: time.value, timescale: time.timescale)
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

nonisolated extension TimeRange {
    init?(_ range: CMTimeRange) {
        guard let start = Time(range.start), let duration = Time(range.duration) else { return nil }
        self.init(start: start, duration: duration)
    }

    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}

nonisolated extension FrameRate {
    var cmFrameDuration: CMTime { frameDuration.cmTime }
}

// MARK: - Integer helpers

nonisolated func gcd(_ a: Int128, _ b: Int128) -> Int128 {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return max(a, 1)
}

nonisolated func lcm(_ a: Int128, _ b: Int128) -> Int128 { a / gcd(a, b) * b }

/// ⌊a / b⌋ for b > 0 (Swift's `/` truncates toward zero).
nonisolated func flooredDivision(_ a: Int128, _ b: Int128) -> Int128 {
    let q = a / b
    return (a % b != 0 && a < 0) ? q - 1 : q
}

/// a / b rounded half up, for b > 0.
nonisolated func roundedDivision(_ a: Int128, _ b: Int128) -> Int128 { flooredDivision(2 * a + b, 2 * b) }

nonisolated private func parseFraction(_ text: String) -> (Int128, Int128)? {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let a = Int128(parts[0]), let b = Int128(parts[1]) else { return nil }
    return (a, b)
}
