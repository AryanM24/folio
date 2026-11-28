import AVFoundation
import FolioKit
import Vision

/// Faces and licence-plate-like text, found and followed through a clip for auto-redact.
///
/// Detection runs on a sample of frames (10 a second by default) and detections are linked
/// into tracks by overlap. Re-detecting instead of following one box (`VNTrackObjectRequest`)
/// avoids drift; the redact effect interpolates between the samples.
nonisolated enum FaceTracker {
    enum Target: String, Codable, Sendable, CaseIterable {
        case faces
        /// Short runs of letters and digits in a plate-shaped box.
        case plates
    }

    struct Sample: Codable, Equatable, Sendable {
        /// Source time.
        var time: Time
        /// Fractions of the upright frame, origin top-left, y down, padded to cover the whole face.
        var rect: Rect
    }

    struct Track: Codable, Equatable, Sendable {
        var target: Target
        var samples: [Sample]
    }

    struct Parameters: Codable, Equatable, Sendable {
        var targets: Set<Target> = [.faces]
        var interval = Time(value: 1, timescale: 10)
        /// Boxes grow by this fraction of their size on each side.
        var padding = 0.2
        var maxDimension = 960
    }

    static func tracks(
        in url: URL, parameters: Parameters = Parameters(), cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil
    ) async throws -> [Track] {
        let compute = {
            let orientation = try await VideoFrameReader.info(url, maxDimension: parameters.maxDimension).2.orientation
            var detections: [(target: Target, time: Time, rects: [Rect])] = []
            var next = Time.zero
            var plateTurn = 0
            try await VideoFrameReader.read(url, maxDimension: parameters.maxDimension, progress: progress) { time, pixels in
                guard let t = Time(time), t >= next else { return }
                next = t + parameters.interval
                let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation)
                if parameters.targets.contains(.faces) {
                    let request = VNDetectFaceRectanglesRequest()
                    try await perform(handler, [request])
                    detections.append((.faces, t, (request.results ?? []).map { padded(rect(of: $0.boundingBox), parameters.padding) }))
                }
                // Text recognition costs more; plates move slowly, so look every third sample.
                if parameters.targets.contains(.plates) {
                    defer { plateTurn += 1 }
                    guard plateTurn % 3 == 0 else { return }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = false
                    try await perform(handler, [request])
                    let aspect = Double(CVPixelBufferGetWidth(pixels)) / Double(max(1, CVPixelBufferGetHeight(pixels)))
                    let plates = (request.results ?? []).filter { observation in
                        guard let text = observation.topCandidates(1).first?.string else { return false }
                        let box = observation.boundingBox
                        let shape = box.width * aspect / max(0.0001, box.height)
                        return looksLikePlate(text) && (1.5...7).contains(shape)
                    }
                    detections.append((.plates, t, plates.map { padded(rect(of: $0.boundingBox), parameters.padding) }))
                }
            }
            return Target.allCases.flatMap { target in
                link(detections.filter { $0.target == target }.map { ($0.time, $0.rects) }, target: target, maxGap: parameters.interval * 6)
            }
        }
        guard let cache else { return try await compute() }
        let key = try AnalysisCache.Key(
            "redact", media: url,
            parameters: [
                parameters.targets.map(\.rawValue).sorted().joined(separator: ","), "\(parameters.interval)", "\(parameters.padding)",
                "\(parameters.maxDimension)",
            ])
        return try await cache.value(key, compute: compute)
    }

    /// Joins per-sample detections into tracks: each box continues the track whose last box
    /// it overlaps most (IoU ≥ 0.3) if that track was seen within `maxGap`. Tracks seen only
    /// once are dropped as likely false positives.
    static func link(_ samples: [(time: Time, rects: [Rect])], target: Target, maxGap: Time) -> [Track] {
        var tracks: [Track] = []
        for (time, rects) in samples {
            var claimed = Set<Int>()
            for rect in rects {
                let candidates = tracks.indices.filter { i in
                    !claimed.contains(i) && time - tracks[i].samples.last!.time <= maxGap
                }
                let best = candidates.max { overlap(tracks[$0].samples.last!.rect, rect) < overlap(tracks[$1].samples.last!.rect, rect) }
                if let best, overlap(tracks[best].samples.last!.rect, rect) >= 0.3 {
                    tracks[best].samples.append(Sample(time: time, rect: rect))
                    claimed.insert(best)
                } else {
                    tracks.append(Track(target: target, samples: [Sample(time: time, rect: rect)]))
                    claimed.insert(tracks.count - 1)
                }
            }
        }
        return tracks.filter { $0.samples.count > 1 }
    }

    /// A redact region for `track` as it plays in `clip`: keyframes at clip offsets.
    /// `nil` when none of the track is in the clip.
    static func region(for track: Track, in clip: Clip, style: RedactRegion.Style = .blur) -> RedactRegion? {
        let tick = Time(value: 1, timescale: 1000)
        let keys = track.samples.compactMap { sample -> (Time, Rect)? in
            clip.timelineRange(forSource: TimeRange(start: sample.time, duration: tick)).map { ($0.start - clip.start, sample.rect) }
        }
        guard let first = keys.first else { return nil }
        var rect = Keyframed(first.1)
        for (offset, value) in keys { rect.set(value, at: offset) }
        return RedactRegion(rect: rect, style: style, isTracked: true)
    }

    /// Plate-like: 4–10 letters, digits, spaces or dashes, with at least one digit and one letter.
    static func looksLikePlate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let core = trimmed.filter { $0.isLetter || $0.isNumber }
        guard (4...10).contains(trimmed.count), core.count >= 4,
            trimmed.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == " " || $0 == "-" || $0 == "·" })
        else { return false }
        return core.contains(where: \.isNumber) && core.contains(where: \.isLetter)
    }

    /// Intersection over union.
    static func overlap(_ a: Rect, _ b: Rect) -> Double {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard w > 0, h > 0 else { return 0 }
        let shared = w * h
        return shared / (a.width * a.height + b.width * b.height - shared)
    }

    /// Vision's normalised box (origin bottom-left) as a model `Rect` (origin top-left).
    static func rect(of box: CGRect) -> Rect {
        Rect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    static func padded(_ r: Rect, _ fraction: Double) -> Rect {
        let x0 = max(0, r.x - r.width * fraction), y0 = max(0, r.y - r.height * fraction)
        let x1 = min(1, r.x + r.width * (1 + fraction)), y1 = min(1, r.y + r.height * (1 + fraction))
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
