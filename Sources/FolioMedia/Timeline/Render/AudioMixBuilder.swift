import AVFoundation
import MediaToolbox

/// Turns clip sound settings into an `AVMutableAudioMix`. Mix parameters belong to a
/// composition track, not a clip, so each clip becomes a run of volume ramps over the time
/// it occupies on its track: keyframed volume × track volume × fades × crossfades × ducking.
/// Ramps are linear, so curves (eases, equal-power crossfades, products of ramps) are
/// split until each piece is within 1 % of a straight line.
nonisolated enum AudioMixBuilder {
    /// One clip's sound on one composition track.
    struct Piece: Sendable {
        var trackID: CMPersistentTrackID
        /// Where it sounds, handles included.
        var window: TimeRange
        var clip: Clip
        var trackVolume: Double
        var ducking: Ducking?
        /// Equal-power fades for transitions: up across `fadeUp`, down across `fadeDown`.
        var fadeUp: TimeRange?
        var fadeDown: TimeRange?
    }

    static func mix(
        _ pieces: [Piece], tracks: [CMPersistentTrackID: AVMutableCompositionTrack], speech: [TimeRange],
        pitch: [CMPersistentTrackID: AVAudioTimePitchAlgorithm]
    ) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        let byTrack = Dictionary(grouping: pieces, by: \.trackID)
        mix.inputParameters = byTrack.keys.sorted().compactMap { id -> AVAudioMixInputParameters? in
            guard let track = tracks[id] else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTimePitchAlgorithm = pitch[id] ?? .spectral
            for piece in byTrack[id]!.sorted(by: { $0.window.start < $1.window.start }) {
                for ramp in ramps(piece, speech: speech) {
                    parameters.setVolumeRamp(
                        fromStartVolume: Float(ramp.from), toEndVolume: Float(ramp.to), timeRange: ramp.range.cmTimeRange)
                }
            }
            let panned = byTrack[id]!.filter { $0.clip.audio.pan.isAnimated || $0.clip.audio.pan.value != 0 }
            if !panned.isEmpty { parameters.audioTapProcessor = PanTap.make(panned) }
            return parameters
        }
        return mix
    }

    /// Linear gain at timeline time `t`.
    static func gain(_ piece: Piece, at t: Time, speech: [TimeRange]) -> Double {
        let clip = piece.clip
        let offset = t - clip.start
        var g = clip.audio.volume.value(at: offset) * piece.trackVolume
        let fadeIn = clip.audio.fadeIn.seconds, fadeOut = clip.audio.fadeOut.seconds
        if fadeIn > 0 { g *= unit(offset.seconds / fadeIn) }
        if fadeOut > 0 { g *= unit((clip.end - t).seconds / fadeOut) }
        if let w = piece.fadeUp { g *= sin(.pi / 2 * unit(progress(t, w))) }
        if let w = piece.fadeDown { g *= cos(.pi / 2 * unit(progress(t, w))) }
        if let ducking = piece.ducking { g *= duck(t, ducking, speech) }
        return max(0, g)
    }

    /// 1 away from speech, `amount` dB during it, ramping over `fade` either side.
    static func duck(_ t: Time, _ ducking: Ducking, _ speech: [TimeRange]) -> Double {
        let fade = max(ducking.fade.seconds, 0.001)
        let x = t.seconds
        let depth = speech.reduce(0.0) { deepest, range in
            let s = range.start.seconds, e = range.end.seconds
            let level = x < s ? unit(1 - (s - x) / fade) : x > e ? unit(1 - (x - e) / fade) : 1
            return max(deepest, level)
        }
        return 1 - depth * (1 - AudioSettings.gain(decibels: ducking.amount))
    }

    struct Ramp: Equatable {
        var range: TimeRange
        var from: Double
        var to: Double
    }

    static func ramps(_ piece: Piece, speech: [TimeRange]) -> [Ramp] {
        let clip = piece.clip, w = piece.window
        var marks: [Time] = [w.start, w.end, clip.start, clip.end, clip.start + clip.audio.fadeIn, clip.end - clip.audio.fadeOut]
        marks += clip.audio.volume.keys.map { clip.start + $0.time }
        for range in [piece.fadeUp, piece.fadeDown].compactMap({ $0 }) { marks += [range.start, range.end] }
        if let ducking = piece.ducking {
            for range in speech where range.start - ducking.fade < w.end && range.end + ducking.fade > w.start {
                marks += [range.start - ducking.fade, range.start, range.end, range.end + ducking.fade]
            }
        }
        let sorted = Set(marks.filter { $0 >= w.start && $0 <= w.end }).sorted()
        var result: [Ramp] = []
        func emit(_ a: Time, _ b: Time, _ depth: Int) {
            let ga = gain(piece, at: a, speech: speech), gb = gain(piece, at: b, speech: speech)
            let mid = (a + b) * Rational(1, 2)
            // Quarter points too: an S-curve crosses the straight line at its middle.
            let off = [Rational(1, 4), Rational(1, 2), Rational(3, 4)].contains { f in
                abs(gain(piece, at: a + (b - a) * f, speech: speech) - (ga + (gb - ga) * f.doubleValue)) > 0.01
            }
            if depth < 5, off {
                emit(a, mid, depth + 1)
                emit(mid, b, depth + 1)
            } else {
                result.append(Ramp(range: TimeRange(start: a, end: b), from: ga, to: gb))
            }
        }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a { emit(a, b, 0) }
        return result
    }

    private static func unit(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func progress(_ t: Time, _ w: TimeRange) -> Double {
        w.duration > .zero ? (t - w.start).seconds / w.duration.seconds : 1
    }
}

/// Stereo balance for a composition track, through an `MTAudioProcessingTap`. The tap runs
/// on the real-time audio thread: it only reads the immutable pan curve, never allocates.
///
/// shortcut: a mono source reaches the tap as one channel, so it can't be panned here (it
/// plays centred). Upmix such sources into stereo when pan on mono matters.
nonisolated private final class PanTap: @unchecked Sendable {
    let pieces: [(window: TimeRange, start: Time, pan: Keyframed<Double>)]
    /// Set in `prepare`, before any `process` call.
    var isFloat = false
    var isInterleaved = false
    var channels = 0

    init(_ pieces: [AudioMixBuilder.Piece]) {
        self.pieces = pieces.map { ($0.window, $0.clip.start, $0.clip.audio.pan) }
    }

    func pan(at time: CMTime) -> Double {
        guard let t = Time(time), let piece = pieces.first(where: { $0.window.contains(t) }) else { return 0 }
        return min(1, max(-1, piece.pan.value(at: t - piece.start)))
    }

    static func make(_ pieces: [AudioMixBuilder.Piece]) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(PanTap(pieces)).toOpaque()),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<PanTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let me = Unmanaged<PanTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                me.isFloat = f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
                me.isInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                me.channels = Int(f.mChannelsPerFrame)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                let me = Unmanaged<PanTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard me.isFloat, me.channels == 2 else { return }
                let p = me.pan(at: range.start)
                guard p != 0 else { return }
                let left = Float(p > 0 ? 1 - p : 1), right = Float(p < 0 ? 1 + p : 1)
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                let count = Int(framesOut.pointee)
                if me.isInterleaved, let data = list.first?.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<count {
                        data[2 * i] *= left
                        data[2 * i + 1] *= right
                    }
                } else if list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                    let r = list[1].mData?.assumingMemoryBound(to: Float.self)
                {
                    for i in 0..<count {
                        l[i] *= left
                        r[i] *= right
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr
        else { return nil }
        return tap
    }
}
