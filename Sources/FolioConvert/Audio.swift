import AVFoundation
import CryptoKit
public import Foundation

/// Audio conversions, built on AVAudioFile and AudioToolbox.
///
/// AVAudioFile (ExtAudioFile underneath) is about twice as fast as AVAssetExportSession for
/// audio, so every encode goes through it. Lossless targets keep the sample rate and bit
/// depth and are verified sample by sample.
public nonisolated enum AudioConverter: FamilyConverter {
    public static let family: Format.Family = .audio

    static let losslessTargets: [Format] = [.alac, .flac, .wav, .aiff]

    /// Sources with targets so far; ogg, opus, caf, aac, ac3, w64, m4b and mid join in 0.3.
    static let sources: Set<Format> = [.m4a, .alac, .flac, .wav, .aiff, .mp3]

    public static func targets(from source: Format) -> [Target] {
        guard sources.contains(source) else { return [] }
        // An .m4a may hold AAC or ALAC; the codec is only known once the file is open.
        let maybeLossy = source == .m4a || source == .mp3
        let aac = Target(
            to: .m4a, fidelity: .visuallyLossless, losslessAvailable: false, drops: ["tags and artwork"],
            notes: source == .m4a ? "Re-encodes to AAC 256 kbps; AAC that's already that small is kept as is." : "AAC 256 kbps.")
        let lossless = losslessTargets.filter { $0 != source }.map { to in
            Target(
                to: to, fidelity: .lossless, losslessAvailable: true, drops: ["tags and artwork"],
                notes: maybeLossy ? "Lossless from here if the source is AAC or MP3: it can't undo earlier loss." : nil)
        }
        return [aac] + lossless
    }

    public static func convert(_ job: Job) async throws -> Outcome {
        let input = try open(job.input)
        let source = input.fileFormat.streamDescription.pointee
        let lossySource = isLossy(source.mFormatID)
        var warnings: [String] = []

        // Already-compact AAC into an .m4a: a byte copy, so the engine's never-bigger rule keeps the original.
        if job.target == .m4a, job.quality == .balanced, job.maxBytes == nil, isAAC(source.mFormatID),
            let rate = await bitrate(job.input, seconds: Double(input.length) / input.fileFormat.sampleRate), rate <= 270_000
        {
            try FileManager.default.copyItem(at: job.input, to: job.output)
            return Outcome(fidelity: .lossless, method: "copy", details: try await inspect(job.output, format: .m4a))
        }

        let plan: Plan
        if job.target == .m4a {
            plan = aacPlan(input, quality: job.quality, maxBytes: job.maxBytes)
        } else {
            plan = try losslessPlan(input, target: job.target, lossySource: lossySource)
            if lossySource { warnings.append("lossless from here: the source was already lossy") }
        }
        let written = try encode(input, to: job.output, plan: plan, progress: job.progress)

        var verification: Verification?
        if let written {
            verification = try AudioVerify.matches(job.output, as: plan.common, written)
        } else if plan.fidelity == .lossless {
            verification = try AudioVerify.compare(job.input, job.output, as: plan.common)
        } else if job.verify {
            verification = try AudioVerify.duration(job.input, job.output)
        }
        var details = try await inspect(job.output, format: job.target)
        details["source_codec"] = .string(codecName(source.mFormatID))
        return Outcome(
            fidelity: plan.fidelity, method: "encode", details: details, dropped: ["tags and artwork"], warnings: warnings,
            verification: verification)
    }

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        let file = try open(url)
        let asbd = file.fileFormat.streamDescription.pointee
        let rate = file.fileFormat.sampleRate
        var meta: [String: JSONValue] = [
            "duration_s": .double(rate > 0 ? (Double(file.length) / rate * 1000).rounded() / 1000 : 0),
            "sample_rate": .int(Int64(rate)),
            "channels": .int(Int64(asbd.mChannelsPerFrame)),
            "codec": .string(codecName(asbd.mFormatID)),
        ]
        if let depth = bitDepth(asbd) { meta["bit_depth"] = .int(Int64(depth)) }
        if let bps = await bitrate(url, seconds: rate > 0 ? Double(file.length) / rate : 0) { meta["bitrate"] = .int(Int64(bps)) }
        return meta
    }

    public static func resource(for job: Job) -> Resource { .cpu }

    // MARK: Plans

    /// How to write the output: file settings plus the sample format both sides are read in.
    struct Plan {
        var settings: [String: Any]
        /// Read the input, write the output and verify in this format, so a lossless compare is exact.
        var common: AVAudioCommonFormat
        var fidelity: Fidelity
        /// Hash what was written and verify the output against that. Decoding AAC twice isn't
        /// repeatable (noise substitution draws from a process-wide random generator), so a
        /// lossy source can't be compared by decoding it again.
        var digest = false
    }

    static func losslessPlan(_ input: AVAudioFile, target: Format, lossySource: Bool) throws -> Plan {
        let asbd = input.fileFormat.streamDescription.pointee
        let isFloat = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        // A decoded AAC/MP3 is written as 16-bit PCM, so "lossless from here" is still exactly checkable.
        let depth = lossySource ? 16 : max(16, bitDepth(asbd) ?? 16)
        if isFloat, target == .flac || target == .alac {
            throw ConvertError(
                .losslessUnavailable, "\(target.title) stores whole-number samples, and this file uses \(depth)-bit floating point.",
                hint: "Use wav or aiff to keep it exact.")
        }
        // AudioToolbox's FLAC encoder writes 16 or 24 bits only.
        if target == .flac, depth > 24 {
            throw ConvertError(
                .losslessUnavailable, "FLAC here holds at most 24 bits, and this file has \(depth).", hint: "Use alac, wav or aiff.")
        }
        let common: AVAudioCommonFormat =
            isFloat ? (depth == 64 ? .pcmFormatFloat64 : .pcmFormatFloat32) : (depth == 16 ? .pcmFormatInt16 : .pcmFormatInt32)
        var settings = base(input, sampleRate: input.fileFormat.sampleRate)
        switch target {
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC  // bit depth follows `common`: Int16 → 16, Int32 → 24
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = depth
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = depth
            settings[AVLinearPCMIsFloatKey] = isFloat
            settings[AVLinearPCMIsBigEndianKey] = target == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        return Plan(settings: settings, common: common, fidelity: .lossless, digest: lossySource)
    }

    static func aacPlan(_ input: AVAudioFile, quality: Quality, maxBytes: Int64?) -> Plan {
        let rate = input.fileFormat.sampleRate
        // AAC-LC tops out at 48 kHz; hi-res sources are resampled (it's lossy anyway).
        let outRate = rate <= 48_000 ? rate : (rate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000)
        let mono = input.fileFormat.channelCount == 1
        let lossySource = isLossy(input.fileFormat.streamDescription.pointee.mFormatID)
        var settings = base(input, sampleRate: outRate)
        var bitRate: Int
        if quality == .small, !mono {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC_HE
            bitRate = 64_000
        } else {
            // HE-AAC mono caps at 40 kbps on this encoder, so small mono is AAC-LC 48 kbps.
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Variable
            bitRate = quality == .small ? 48_000 : mono ? 128_000 : 256_000
        }
        if let maxBytes, input.length > 0 {
            let seconds = Double(input.length) / rate
            bitRate = min(bitRate, max(24_000, Int(Double(maxBytes) * 8 * 0.97 / seconds)))
        }
        settings[AVEncoderBitRateKey] = bitRate
        let fidelity: Fidelity = quality == .small || lossySource ? .lossy : .visuallyLossless
        return Plan(settings: settings, common: .pcmFormatFloat32, fidelity: fidelity)
    }

    static func base(_ input: AVAudioFile, sampleRate: Double) -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: input.fileFormat.channelCount]
        // More than two channels need a layout or AudioToolbox refuses the format.
        if input.fileFormat.channelCount > 2, let layout = input.fileFormat.channelLayout {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    // MARK: Encoding

    static let chunk: AVAudioFrameCount = 1 << 16

    /// Returns what was written (per-channel SHA-256 and frame count) when `plan.digest` asks for it.
    @discardableResult
    static func encode(_ source: AVAudioFile, to url: URL, plan: Plan, progress: @Sendable (Double) -> Void) throws -> AudioVerify.Written?
    {
        let input = try AVAudioFile(forReading: source.url, commonFormat: plan.common, interleaved: false)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: url, settings: plan.settings, commonFormat: plan.common, interleaved: false)
        } catch {
            throw ConvertError(.unsupportedPair, "AudioToolbox couldn't set up that encoder for this file: \(error.localizedDescription)")
        }
        defer { output.close() }
        let total = Double(max(input.length, 1))
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            throw ConvertError(.internal, "Couldn't allocate an audio buffer.")
        }
        if input.processingFormat.sampleRate == output.processingFormat.sampleRate {
            var hashers = plan.digest ? Array(repeating: SHA256(), count: Int(input.processingFormat.channelCount)) : []
            var frames: Int64 = 0
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: inBuffer)
                if inBuffer.frameLength == 0 { break }
                try output.write(from: inBuffer)
                if plan.digest { AudioVerify.hash(inBuffer, into: &hashers) }
                frames += Int64(inBuffer.frameLength)
                progress(Double(input.framePosition) / total)
            }
            return plan.digest ? AudioVerify.Written(frames: frames, channels: hashers.map { $0.finalize() }) : nil
        }
        // Resample through AVAudioConverter (only for hi-res sources going to AAC).
        guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: chunk)
        else { throw ConvertError(.internal, "Couldn't set up the sample-rate converter.") }
        // The block runs synchronously inside `convert`, on this thread.
        let feed = UncheckedSendable((input, inBuffer))
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                let (input, inBuffer) = feed.value
                guard (try? input.read(into: inBuffer)) != nil, inBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error { throw error ?? ConvertError(.internal, "Resampling failed.") }
            if outBuffer.frameLength > 0 { try output.write(from: outBuffer) }
            progress(Double(input.framePosition) / total)
            if status == .endOfStream { break }
        }
        return nil
    }

    // MARK: Helpers

    static func open(_ url: URL) throws -> AVAudioFile {
        do { return try AVAudioFile(forReading: url) } catch {
            throw ConvertError(.corruptInput, "Couldn't read “\(url.lastPathComponent)” as audio.", hint: error.localizedDescription)
        }
    }

    static func isAAC(_ id: AudioFormatID) -> Bool {
        [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD]
            .contains(id)
    }

    static func isLossy(_ id: AudioFormatID) -> Bool {
        ![kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC].contains(id)
    }

    static func bitDepth(_ asbd: AudioStreamBasicDescription) -> Int? {
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM: return Int(asbd.mBitsPerChannel)
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // Both encode the source depth in the flags (kAppleLosslessFormatFlag_16BitSourceData = 1 …).
            switch asbd.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return nil
            }
        default: return nil
        }
    }

    /// The codec's own rate; file size over duration overstates it for short files (headers, padding).
    static func bitrate(_ url: URL, seconds: Double) async -> Int? {
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
            let rate = try? await track.load(.estimatedDataRate), rate > 0
        {
            return Int(rate)
        }
        return seconds > 0 ? Int(Double(Engine.fileSize(url)) * 8 / seconds) : nil
    }
}

/// Short codec names for results: "aac", "alac", "hevc", "h264"…
nonisolated func codecName(_ code: FourCharCode) -> String {
    switch code {
    case kAudioFormatLinearPCM, 0x736f_7774 /* sowt */, 0x7477_6f73 /* twos */: "pcm"
    case kAudioFormatMPEG4AAC, 0x6d70_3461 /* mp4a */: "aac"
    case kAudioFormatMPEG4AAC_HE: "he-aac"
    case kAudioFormatMPEG4AAC_HE_V2: "he-aac-v2"
    case kAudioFormatAppleLossless: "alac"
    case kAudioFormatFLAC: "flac"
    case kAudioFormatMPEGLayer3: "mp3"
    case kAudioFormatOpus: "opus"
    case kCMVideoCodecType_HEVC, 0x6865_7631 /* hev1 */: "hevc"
    case kCMVideoCodecType_H264: "h264"
    case kCMVideoCodecType_AV1: "av1"
    case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
        "prores"
    default:
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
            ?? "unknown"
    }
}
