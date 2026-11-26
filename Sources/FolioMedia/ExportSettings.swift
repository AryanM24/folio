import AVFoundation
import UniformTypeIdentifiers

/// The output formats Export offers. Pure data: the mapping to AVFoundation presets
/// and file types is unit-tested, the export itself lives in `MediaExport`.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// Same codecs, no re-encode: lossless and as fast as copying.
    case original
    case hevc4K, hevc1080p
    case h264_4K, h264_1080p, h264_720p, h264_480p
    case proRes
    case m4a
    case wav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original quality (no re-encode)"
        case .hevc4K: "HEVC 4K"
        case .hevc1080p: "HEVC 1080p"
        case .h264_4K: "H.264 4K"
        case .h264_1080p: "H.264 1080p"
        case .h264_720p: "H.264 720p"
        case .h264_480p: "H.264 480p"
        case .proRes: "ProRes 422"
        case .m4a: "Audio only (M4A, AAC)"
        case .wav: "Audio only (WAV)"
        }
    }

    var isAudioOnly: Bool { self == .m4a || self == .wav }

    /// Formats that make sense for a file with or without video.
    static func available(hasVideo: Bool) -> [ExportFormat] {
        hasVideo ? allCases : [.original, .m4a, .wav]
    }

    /// The `AVAssetExportSession` preset, or `nil` for WAV (written with a reader/writer,
    /// because no export preset produces linear PCM in a WAVE container).
    var preset: String? {
        switch self {
        case .original: AVAssetExportPresetPassthrough
        case .hevc4K: AVAssetExportPresetHEVC3840x2160
        case .hevc1080p: AVAssetExportPresetHEVC1920x1080
        case .h264_4K: AVAssetExportPreset3840x2160
        case .h264_1080p: AVAssetExportPreset1920x1080
        case .h264_720p: AVAssetExportPreset1280x720
        case .h264_480p: AVAssetExportPreset640x480
        case .proRes: AVAssetExportPresetAppleProRes422LPCM
        case .m4a: AVAssetExportPresetAppleM4A
        case .wav: nil
        }
    }

    /// Container for the output. `original` keeps the source's container when it can.
    func fileType(source: UTType?) -> AVFileType {
        switch self {
        case .original:
            if let source, source.conforms(to: .mpeg4Movie) { return .mp4 }
            if let source, source.conforms(to: .mpeg4Audio) { return .m4a }
            if let source, source.conforms(to: .audio), !source.conforms(to: .movie) { return .m4a }
            return .mov
        case .proRes: return .mov
        case .m4a: return .m4a
        case .wav: return .wav
        default: return .mp4
        }
    }
}

/// Changes applied while exporting. The original file is never touched.
nonisolated struct MediaEdits: Equatable, Sendable {
    /// Clockwise quarter turns, 0…3.
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var removeAudio = false
    /// 1 is normal speed. Offered: 0.5, 1, 1.5, 2.
    var speed: Double = 1

    static let speeds: [Double] = [0.5, 1, 1.5, 2]

    var changesGeometry: Bool { quarterTurns % 4 != 0 || flipHorizontal || flipVertical }
    var isIdentity: Bool { self == MediaEdits() }

    /// Speed changes retime audio, which passthrough can't do, so they force a re-encode.
    /// Rotation, flips and removing audio are lossless: they only change track metadata.
    var requiresReencode: Bool { speed != 1 }

    mutating func rotate(clockwise: Bool) {
        quarterTurns = ((quarterTurns + (clockwise ? 1 : -1)) % 4 + 4) % 4
    }
}

/// Geometry and timing math, separate from AVFoundation so it can be tested.
nonisolated enum MediaMath {
    /// The track transform after applying `edits` on top of the source's own
    /// `preferredTransform`, re-anchored so the picture lands at the origin
    /// (AVFoundation expects display rects in positive coordinates).
    static func transform(natural size: CGSize, preferred: CGAffineTransform, edits: MediaEdits) -> CGAffineTransform {
        // Quarter turns as exact matrices; `rotated(by: .pi/2)` leaves 1e-16 noise.
        // In AVFoundation's (y-down) display space, (0, 1, -1, 0) turns the picture clockwise.
        let turns: [CGAffineTransform] = [
            .identity,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0),
        ]
        // Rotate first, then flip, so a flip mirrors the picture as it is shown.
        let flip = CGAffineTransform(scaleX: edits.flipHorizontal ? -1 : 1, y: edits.flipVertical ? -1 : 1)
        let edit = turns[((edits.quarterTurns % 4) + 4) % 4].concatenating(flip)
        let combined = preferred.concatenating(edit)
        let box = CGRect(origin: .zero, size: size).applying(combined)
        return combined.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    /// Display size of a track: natural size through its transform.
    static func displaySize(natural size: CGSize, transform: CGAffineTransform) -> CGSize {
        let box = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(box.width).rounded(), height: abs(box.height).rounded())
    }

    /// Duration after playing `duration` at `speed`× (2× halves it).
    static func scaled(_ duration: CMTime, speed: Double) -> CMTime {
        guard speed > 0, duration.isNumeric else { return duration }
        return CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed)
    }

    /// Clamp a selection to the asset. `nil` when empty.
    static func clamp(_ range: CMTimeRange, to duration: CMTime) -> CMTimeRange? {
        clamp(from: range.start, to: range.end, within: duration)
    }

    /// The range between two times in either order (a leftward drag), clamped to the
    /// asset. Takes two times because `CMTimeRange(start:end:)` can't hold an inverted range.
    static func clamp(from first: CMTime, to second: CMTime, within duration: CMTime) -> CMTimeRange? {
        guard first.isNumeric, second.isNumeric, duration.isNumeric else { return nil }
        let a = CMTimeClampToRange(first, range: CMTimeRange(start: .zero, duration: duration))
        let b = CMTimeClampToRange(second, range: CMTimeRange(start: .zero, duration: duration))
        let lo = CMTimeMinimum(a, b), hi = CMTimeMaximum(a, b)
        guard hi > lo else { return nil }
        return CMTimeRange(start: lo, end: hi)
    }

    /// The selection after setting an in or out point at `time`. Setting an in point past
    /// the current out point (or an out before the in) starts a fresh range at that end,
    /// like Final Cut does, instead of producing an inverted range.
    static func settingPoint(_ time: CMTime, isIn: Bool, current: CMTimeRange?, duration: CMTime) -> CMTimeRange? {
        let full = CMTimeRange(start: .zero, duration: duration)
        let range = current ?? full
        let proposed =
            isIn
            ? CMTimeRange(start: time, end: time < range.end ? range.end : duration)
            : CMTimeRange(start: time > range.start ? range.start : .zero, end: time)
        return clamp(proposed, to: duration)
    }

    /// "1:02:03.25", "2:03.25" or "0:03.25": hours only when needed, hundredths always,
    /// so neighbouring frames read differently.
    static func timecode(_ time: CMTime) -> String {
        guard time.isNumeric else { return "--:--" }
        let total = max(0, time.seconds)
        let hundredths = Int((total * 100).rounded(.down))
        let h = hundredths / 360_000, m = hundredths / 6000 % 60, s = hundredths / 100 % 60, f = hundredths % 100
        let tail = String(format: "%02d.%02d", s, f)
        return h > 0 ? String(format: "%d:%02d:", h, m) + tail : "\(m):" + tail
    }
}
