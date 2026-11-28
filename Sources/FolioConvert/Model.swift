public import Foundation

/// How hard to squeeze. One axis for every format, so nobody has to learn per-format flags.
///
/// - `lossless`: bit- or sample-exact, verified. Fails with ``ConvertError/Code/losslessUnavailable``
///   rather than quietly degrading when the target can't be lossless (HEIC, JPEG, AAC…).
/// - `balanced`: the default. Visually indistinguishable for most people, much smaller.
/// - `small`: as small as is still pleasant to use.
public nonisolated enum Quality: String, Codable, Sendable, CaseIterable {
    case lossless, balanced, small
}

/// What survives a conversion, honestly labelled on every result.
public nonisolated enum Fidelity: String, Codable, Sendable {
    /// Decodes to exactly the same pixels, samples, cells or text. Verified.
    case lossless
    /// Not bit-exact, but differences are below what people notice (HEIC q0.9, text with layout).
    case visuallyLossless = "visually_lossless"
    /// Smaller, with visible or audible loss at close inspection.
    case lossy
    /// Only the content (text, values) survives; layout and styling don't.
    case contentOnly = "content_only"
}

/// One reachable target for a source format.
public nonisolated struct Target: Codable, Sendable, Equatable {
    public var to: Format
    /// Fidelity at the default (`balanced`) quality.
    public var fidelity: Fidelity
    /// `true` when `quality: lossless` is possible for this pair.
    public var losslessAvailable: Bool
    /// What the conversion drops, in plain words ("formulas", "page layout").
    public var drops: [String]
    public var notes: String?

    public init(to: Format, fidelity: Fidelity, losslessAvailable: Bool, drops: [String] = [], notes: String? = nil) {
        self.to = to
        self.fidelity = fidelity
        self.losslessAvailable = losslessAvailable
        self.drops = drops
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case to, fidelity, drops, notes
        case losslessAvailable = "lossless_available"
    }
}

/// A conversion request: the same shape for the CLI, the MCP server, Finder and the app.
public nonisolated struct ConvertRequest: Sendable {
    public var inputs: [URL]
    /// `nil` means "same format as each input", which is how you ask to compress.
    public var target: Format?
    public var quality: Quality
    /// Per-output size budget. Picks the best quality that fits, or fails with `sizeUnreachable`.
    public var maxBytes: Int64?
    /// Images and video: longest side in pixels.
    public var maxDimension: Int?
    public var stripMetadata: Bool
    /// `nil` writes next to each input.
    public var outputDirectory: URL?
    public var onConflict: OnConflict
    /// `nil` verifies when `quality` is `lossless`.
    public var verify: Bool?
    public var dryRun: Bool

    public init(
        inputs: [URL], target: Format?, quality: Quality = .balanced, maxBytes: Int64? = nil, maxDimension: Int? = nil,
        stripMetadata: Bool = false, outputDirectory: URL? = nil, onConflict: OnConflict = .rename, verify: Bool? = nil,
        dryRun: Bool = false
    ) {
        self.inputs = inputs
        self.target = target
        self.quality = quality
        self.maxBytes = maxBytes
        self.maxDimension = maxDimension
        self.stripMetadata = stripMetadata
        self.outputDirectory = outputDirectory
        self.onConflict = onConflict
        self.verify = verify
        self.dryRun = dryRun
    }

    public enum OnConflict: String, Codable, Sendable {
        /// Finder-style "name 2.ext". Never overwrites.
        case rename
        /// Leave the existing file and report `skipped`.
        case skip
        /// Report `OUTPUT_EXISTS`.
        case fail
    }
}

/// The work handed to a family converter: one input, one target, a temporary output path.
///
/// The engine owns naming, conflicts, atomic moves and size bookkeeping. A converter only
/// writes `output` (a file, or a directory when it returns `isDirectory`), and never touches
/// `input`.
public nonisolated struct Job: Sendable {
    public let input: URL
    public let source: Format
    public let target: Format
    public let quality: Quality
    public let maxBytes: Int64?
    public let maxDimension: Int?
    public let stripMetadata: Bool
    /// Whether the converter should verify its output (always true for `lossless`).
    public let verify: Bool
    /// Temporary path in the destination folder; the engine renames it into place.
    public let output: URL
    public let progress: @Sendable (Double) -> Void
}

/// What a converter reports back about a finished job.
public nonisolated struct Outcome: Sendable {
    public var fidelity: Fidelity
    /// `remux`, `copy`, `encode`, `transcode`, `render`, `extract`…
    public var method: String
    public var details: [String: JSONValue]
    public var dropped: [String]
    public var warnings: [String]
    public var verification: Verification?
    /// `true` when the converter wrote a folder (e.g. one image per PDF page).
    public var isDirectory: Bool

    public init(
        fidelity: Fidelity, method: String, details: [String: JSONValue] = [:], dropped: [String] = [],
        warnings: [String] = [], verification: Verification? = nil, isDirectory: Bool = false
    ) {
        self.fidelity = fidelity
        self.method = method
        self.details = details
        self.dropped = dropped
        self.warnings = warnings
        self.verification = verification
        self.isDirectory = isDirectory
    }
}

public nonisolated struct Verification: Codable, Sendable, Equatable {
    public var passed: Bool
    /// What was checked, e.g. `["opens", "pixels identical", "duration±1frame"]`.
    public var checks: [String]
    /// Optional numbers: `max_delta`, `psnr`, `differing_samples`.
    public var metrics: [String: Double]

    public init(passed: Bool, checks: [String], metrics: [String: Double] = [:]) {
        self.passed = passed
        self.checks = checks
        self.metrics = metrics
    }
}

/// One line of the result: what happened to one input.
public nonisolated struct ConvertResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, skipped, failed, planned }

    public var input: String
    public var output: String?
    public var status: Status
    public var fidelity: Fidelity?
    public var method: String?
    public var bytesIn: Int64
    public var bytesOut: Int64?
    public var ratio: Double?
    public var durationMs: Int
    public var details: [String: JSONValue]
    public var verification: Verification?
    public var dropped: [String]
    public var warnings: [String]
    public var error: ConvertError?

    /// A result with nothing filled in yet; callers set the rest as they learn it.
    public init(input: String, status: Status, bytesIn: Int64, durationMs: Int = 0) {
        self.input = input
        self.status = status
        self.bytesIn = bytesIn
        self.durationMs = durationMs
        details = [:]
        dropped = []
        warnings = []
    }

    enum CodingKeys: String, CodingKey {
        case input, output, status, fidelity, method, ratio, details, verification, dropped, warnings, error
        case bytesIn = "bytes_in", bytesOut = "bytes_out", durationMs = "duration_ms"
    }
}

/// The full answer for a request, as `folio convert --json` prints it and MCP returns it.
public nonisolated struct ConvertReport: Codable, Sendable {
    public var results: [ConvertResult]
    public var summary: Summary

    public struct Summary: Codable, Sendable {
        public var ok: Int, failed: Int, skipped: Int
        public var bytesIn: Int64, bytesOut: Int64
        public var durationMs: Int
        enum CodingKeys: String, CodingKey {
            case ok, failed, skipped
            case bytesIn = "bytes_in", bytesOut = "bytes_out", durationMs = "duration_ms"
        }
    }

    public init(results: [ConvertResult], durationMs: Int) {
        self.results = results
        summary = Summary(
            ok: results.count { $0.status == .ok },
            failed: results.count { $0.status == .failed },
            skipped: results.count { $0.status == .skipped },
            bytesIn: results.reduce(0) { $0 + $1.bytesIn },
            bytesOut: results.reduce(0) { $0 + ($1.bytesOut ?? 0) },
            durationMs: durationMs)
    }
}

/// A structured, recoverable error with a stable code agents can branch on.
public nonisolated struct ConvertError: Error, Codable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case notFound = "NOT_FOUND"
        case unsupportedInput = "UNSUPPORTED_INPUT"
        case unsupportedPair = "UNSUPPORTED_PAIR"
        case losslessUnavailable = "LOSSLESS_UNAVAILABLE"
        case sizeUnreachable = "SIZE_UNREACHABLE"
        case outputExists = "OUTPUT_EXISTS"
        case pathNotAllowed = "PATH_NOT_ALLOWED"
        case encrypted = "ENCRYPTED"
        case corruptInput = "CORRUPT_INPUT"
        case tooLarge = "TOO_LARGE"
        case verificationFailed = "VERIFICATION_FAILED"
        case cancelled = "CANCELLED"
        case `internal` = "INTERNAL"
    }

    public var code: Code
    public var message: String
    public var hint: String?
    public var alternatives: [Target]?

    public init(_ code: Code, _ message: String, hint: String? = nil, alternatives: [Target]? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.alternatives = alternatives
    }

    public var errorDescription: String? { message }
}

/// A small JSON value for free-form details and metadata, so results stay `Codable`.
public nonisolated enum JSONValue: Codable, Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String), int(Int64), double(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
