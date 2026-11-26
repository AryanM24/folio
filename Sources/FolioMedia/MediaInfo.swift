import AVFoundation
import CoreMedia

/// What the info sidebar shows. Loaded once, after the window is on screen, from the
/// container's headers only (AVFoundation never decodes or scans the whole file here).
nonisolated struct MediaInfo: Sendable {
    struct Video: Sendable {
        var codec: String
        var size: CGSize
        var frameRate: Float
        var bitrate: Float
    }

    struct Audio: Sendable {
        var codec: String
        var channels: Int
        var sampleRate: Double
        var bitrate: Float
    }

    var duration: CMTime = .zero
    var fileSize: Int64?
    var video: Video?
    var audio: Audio?
    var creationDate: Date?
    var location: String?
    /// File size over duration, the number people compare between files.
    var overallBitrate: Double? {
        guard let fileSize, duration.seconds > 0 else { return nil }
        return Double(fileSize) * 8 / duration.seconds
    }

    /// Reads headers from `url`. Missing pieces stay `nil` rather than failing the whole load,
    /// so a file with odd metadata still shows its duration and codecs.
    static func load(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()
        info.duration = try await asset.load(.duration)
        info.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform, fps, rate, formats) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
            info.video = Video(
                codec: formats.first.map { codecName($0.mediaSubType.rawValue) } ?? "Unknown",
                size: MediaMath.displaySize(natural: natural, transform: transform),
                frameRate: fps,
                bitrate: rate
            )
        }
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let (rate, formats) = try await track.load(.estimatedDataRate, .formatDescriptions)
            let asbd = formats.first?.audioStreamBasicDescription
            info.audio = Audio(
                codec: formats.first.map { codecName($0.mediaSubType.rawValue) } ?? "Unknown",
                channels: Int(asbd?.mChannelsPerFrame ?? 0),
                sampleRate: asbd?.mSampleRate ?? 0,
                bitrate: rate
            )
        }

        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate).first {
            info.creationDate = try? await item.load(.dateValue)
        }
        if info.creationDate == nil { info.creationDate = try? await asset.load(.creationDate)?.load(.dateValue) }
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation).first,
            let text = try? await item.load(.stringValue)
        {
            info.location = formatLocation(iso6709: text)
        }
        return info
    }

    /// Human names for the FourCCs people actually meet.
    static func codecName(_ fourCC: FourCharCode) -> String {
        switch fourCC {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: "HEVC"
        case kCMVideoCodecType_AppleProRes422: "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes4444: "ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444 XQ"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: "Motion JPEG"
        case kCMVideoCodecType_VP9: "VP9"
        case kCMVideoCodecType_AV1: "AV1"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatLinearPCM: "Linear PCM"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAppleLossless: "Apple Lossless"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        default: fourCCString(fourCC)
        }
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return bytes.allSatisfy { (32...126).contains($0) } ? text : String(format: "0x%08X", code)
    }

    /// "+37.3318-122.0312+010.000/" (ISO 6709, as cameras and phones write it)
    /// → "37.3318° N, 122.0312° W". `nil` if it doesn't parse.
    static func formatLocation(iso6709 text: String) -> String? {
        let scanner = Scanner(string: text)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble(),
            abs(lat) <= 90, abs(lon) <= 180
        else { return nil }
        let ns = lat >= 0 ? "N" : "S", ew = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), ns, abs(lon), ew)
    }
}
