public import FolioKit
import AVFoundation
import UniformTypeIdentifiers

/// Media tools for the Welcome window, File › Tools and Finder Quick Actions.
/// Each writes new files next to its input and never changes the input.
public enum MediaTools {
    public nonisolated static let all: [FolioTool] = [extractAudio, convertToMP4, compress, makeGIF]

    nonisolated static let extractAudio = FolioTool(
        id: "media.extractAudio",
        title: "Extract Audio",
        subtitle: "Save a video's sound as M4A or WAV",
        symbol: "waveform",
        inputTypes: [.audiovisualContent],
        options: [.init(id: "format", label: "Format", choices: [("m4a", "M4A (AAC)"), ("wav", "WAV (uncompressed)")], defaultValue: "m4a")]
    ) { inputs, options in
        let format: ExportFormat = options["format"] == "wav" ? .wav : .m4a
        return try await each(inputs) { url in
            try await export(url, format: format, name: url.deletingPathExtension().lastPathComponent, ext: format == .wav ? "wav" : "m4a")
        }
    }

    nonisolated static let convertToMP4 = FolioTool(
        id: "media.convertMP4",
        title: "Convert to MP4",
        subtitle: "H.264 video that plays everywhere",
        symbol: "film",
        inputTypes: [.movie]
    ) { inputs, _ in
        // The 4K preset is "up to 4K": smaller sources keep their size.
        try await each(inputs) { url in
            try await export(url, format: .h264_4K, name: url.deletingPathExtension().lastPathComponent, ext: "mp4")
        }
    }

    nonisolated static let compress = FolioTool(
        id: "media.compress",
        title: "Compress Video",
        subtitle: "Make a smaller copy for sharing",
        symbol: "arrow.down.right.and.arrow.up.left",
        inputTypes: [.movie],
        options: [.init(id: "preset", label: "Size", choices: [
            (ExportFormat.hevc1080p.rawValue, "1080p HEVC (best quality per MB)"),
            (ExportFormat.h264_720p.rawValue, "720p H.264"),
            (ExportFormat.h264_480p.rawValue, "480p H.264 (smallest)"),
        ], defaultValue: ExportFormat.hevc1080p.rawValue)]
    ) { inputs, options in
        let format = options["preset"].flatMap(ExportFormat.init(rawValue:)) ?? .hevc1080p
        return try await each(inputs) { url in
            try await export(url, format: format, name: url.deletingPathExtension().lastPathComponent + " compressed", ext: "mp4")
        }
    }

    nonisolated static let makeGIF = FolioTool(
        id: "media.makeGIF",
        title: "Make GIF",
        subtitle: "Turn the start of a video into an animated GIF",
        symbol: "photo.stack",
        inputTypes: [.movie],
        options: [
            .init(id: "width", label: "Width", choices: [("320", "320 px"), ("480", "480 px"), ("640", "640 px")], defaultValue: "480"),
            .init(id: "fps", label: "Frame rate", choices: [("10", "10 fps"), ("15", "15 fps"), ("24", "24 fps")], defaultValue: "15"),
        ]
    ) { inputs, options in
        let width = CGFloat(Double(options["width"] ?? "") ?? 480)
        let fps = Double(options["fps"] ?? "") ?? 15
        return try await each(inputs) { url in
            let output = FolioTool.outputURL(nextTo: url, name: url.deletingPathExtension().lastPathComponent, ext: "gif")
            // GIFMaker caps the frame count, so a long video becomes its first stretch.
            try await GIFMaker.make(from: url, range: GIFMaker.toolRange(fps: fps), fps: fps, width: width, to: output) { _ in }
            return output
        }
    }

    private nonisolated static func export(_ url: URL, format: ExportFormat, name: String, ext: String) async throws -> URL {
        let output = FolioTool.outputURL(nextTo: url, name: name, ext: ext)
        try await MediaExport.run(ExportRequest(source: url, format: format), to: output) { _ in }
        return output
    }

    /// One input at a time: hardware encoders are shared, so parallel exports only contend.
    private nonisolated static func each(_ inputs: [URL], _ body: (URL) async throws -> URL) async throws -> [URL] {
        var outputs: [URL] = []
        for url in inputs { outputs.append(try await body(url)) }
        return outputs
    }
}
