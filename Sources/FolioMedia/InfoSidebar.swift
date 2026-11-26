import AVFoundation
import FolioKit
import SwiftUI

/// The right-hand inspector: file details, selection, edits and export.
struct InfoSidebar: View {
    @Bindable var controller: MediaController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                details
                selection
                edits
                export
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .frame(width: 280)
        .background(Hero.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Hero.separator).frame(width: 1) }
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        InspectorSection("Details") {
            if let info = controller.info {
                VStack(alignment: .leading, spacing: 6) {
                    row("Duration", MediaMath.timecode(info.duration))
                    if let size = info.fileSize { row("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let rate = info.overallBitrate { row("Bitrate", InfoFormat.bitrate(rate)) }
                    if let video = info.video {
                        row("Video", video.codec)
                        row("Resolution", "\(Int(video.size.width)) × \(Int(video.size.height))")
                        if video.frameRate > 0 { row("Frame rate", InfoFormat.frameRate(video.frameRate)) }
                    }
                    if let audio = info.audio {
                        row("Audio", audio.codec)
                        row("Channels", InfoFormat.channels(audio.channels))
                        if audio.sampleRate > 0 { row("Sample rate", InfoFormat.sampleRate(audio.sampleRate)) }
                    }
                    if let date = info.creationDate { row("Created", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let location = info.location { row("Location", location) }
                }
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Loading details")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Hero.muted).frame(width: 84, alignment: .leading)
            Text(value).foregroundStyle(Hero.foreground).textSelection(.enabled).monospacedDigit()
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: Selection

    private var selection: some View {
        InspectorSection("Selection") {
            Text(InfoFormat.selection(controller.selection))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Hero.foreground)
            HStack(spacing: 8) {
                Button("Trim", systemImage: "timeline.selection") { controller.beginTrim() }
                    .buttonStyle(.hero(.secondary, size: .sm))
                    .help("Trim with handles ⌘T")
                Button("Set in", systemImage: "arrow.right.to.line") { controller.markIn() }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Set in point I")
                Button("Set out", systemImage: "arrow.left.to.line") { controller.markOut() }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Set out point O")
                Button("Clear selection", systemImage: "xmark") { controller.clearSelection() }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Use the whole file")
                    .disabled(controller.selection == nil)
            }
        }
    }

    // MARK: Edits

    private var edits: some View {
        InspectorSection("Edits") {
            if controller.hasVideo {
                HStack(spacing: 2) {
                    Button("Rotate left", systemImage: "rotate.left") { controller.edits.rotate(clockwise: false) }
                        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                        .help("Rotate left")
                    Button("Rotate right", systemImage: "rotate.right") { controller.edits.rotate(clockwise: true) }
                        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                        .help("Rotate right")
                    HeroToolbarDivider()
                    Button("Flip horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        controller.edits.flipHorizontal.toggle()
                    }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: controller.edits.flipHorizontal))
                    .help("Flip horizontal")
                    Button("Flip vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                        controller.edits.flipVertical.toggle()
                    }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: controller.edits.flipVertical))
                    .help("Flip vertical")
                    Spacer()
                    if controller.edits.quarterTurns != 0 {
                        HeroChip("\(controller.edits.quarterTurns * 90)°", tone: .accent)
                    }
                }
                if controller.info?.audio != nil {
                    Toggle("Remove audio", isOn: $controller.edits.removeAudio).toggleStyle(.hero)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Speed").font(.system(size: 12)).foregroundStyle(Hero.muted)
                HeroTabs(MediaEdits.speeds.map { ($0, InfoFormat.speed($0), nil) }, selection: $controller.edits.speed)
            }
            Text("Rotation and flips apply when you export. The original file isn't changed.")
                .font(.system(size: 11))
                .foregroundStyle(Hero.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Export

    private var export: some View {
        InspectorSection("Export") {
            Picker("Format", selection: $controller.format) {
                ForEach(ExportFormat.available(hasVideo: controller.hasVideo)) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Export format")
            Button("Export…", systemImage: "square.and.arrow.up") { controller.export() }
                .buttonStyle(.hero(.primary, fullWidth: true))
                .help("Export ⇧⌘E")
                .disabled(controller.job != nil)
            if controller.hasVideo {
                HStack(spacing: 8) {
                    Button("Save frame", systemImage: "camera") { controller.saveFrame() }
                        .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                        .help("Save the current frame as a PNG")
                    Button("Make GIF", systemImage: "photo.stack") { controller.makeGIF() }
                        .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                        .help("Make an animated GIF of the selection")
                }
                .disabled(controller.job != nil)
            }
        }
    }
}

/// Number formatting for the inspector. Pure, so it's tested.
nonisolated enum InfoFormat {
    static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kb/s", bitsPerSecond / 1000)
    }

    static func frameRate(_ fps: Float) -> String {
        // 29.97 and 23.976 matter; 30.00 doesn't need decimals.
        abs(fps - fps.rounded()) < 0.005 ? "\(Int(fps.rounded())) fps" : String(format: "%.2f fps", fps)
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1 surround"
        case 8: "7.1 surround"
        default: "\(count) channels"
        }
    }

    static func sampleRate(_ hz: Double) -> String {
        hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000)) kHz" : String(format: "%.1f kHz", hz / 1000)
    }

    static func speed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(value)×"
    }

    static func selection(_ range: CMTimeRange?) -> String {
        guard let range else { return "Whole file" }
        return "\(MediaMath.timecode(range.start)) – \(MediaMath.timecode(range.end))  (\(MediaMath.timecode(range.duration)))"
    }
}
