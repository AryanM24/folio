import AVKit
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

/// State and actions for one media window. The view, the menu bar (`MediaCommands`)
/// and the keyboard handler in `FolioPlayerView` all drive this one object.
@Observable
final class MediaController {
    /// A long-running export, shown in the progress HUD.
    struct Job {
        var title: String
        var fraction: Double = 0
        var task: Task<Void, Never>?
    }

    let url: URL
    let player: AVPlayer
    /// Known from the file's type before any loading, so the first frame has the right layout.
    let isAudioOnly: Bool
    private(set) var info: MediaInfo?
    /// The part of the file that Export, GIF and Trim use. `nil` means the whole file.
    var selection: CMTimeRange? { didSet { applySelectionToPlayer() } }
    var edits = MediaEdits() { didSet { previewEdits() } }
    var format: ExportFormat = .original
    private(set) var job: Job?
    private(set) var lastSaved: URL?
    private(set) var peaks: [Float]?
    private(set) var waveformMessage: String?
    private(set) var thumbnails: [CGImage?] = []
    /// Playhead in seconds. Updated only for audio files, where the waveform draws it.
    private(set) var currentTime: Double = 0
    private(set) var isTrimming = false
    weak var playerView: AVPlayerView?

    private let log = Log.make("Media")

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        let type = UTType(filenameExtension: url.pathExtension)
        isAudioOnly = type.map { $0.conforms(to: .audio) && !$0.conforms(to: .movie) } ?? false
        if isAudioOnly {
            player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.currentTime = time.seconds }
            }
        }
    }

    var duration: CMTime { info?.duration ?? player.currentItem?.duration ?? .zero }
    var hasVideo: Bool { info.map { $0.video != nil } ?? !isAudioOnly }

    // MARK: Loading (after first paint)

    /// Headers, then the waveform or filmstrip. Each step is independent: a failure in one
    /// leaves the others working.
    func load() async {
        do {
            info = try await MediaInfo.load(url)
        } catch {
            log.error("Couldn't read media info: \(error.localizedDescription, privacy: .public)")
        }
        if !ExportFormat.available(hasVideo: hasVideo).contains(format) { format = .original }
        if isAudioOnly || info?.video == nil {
            do {
                peaks = try await Waveform.peaks(for: url)
            } catch {
                waveformMessage = error.localizedDescription
            }
        } else {
            thumbnails = Array(repeating: nil, count: 12)
            await Frames.filmstrip(url, count: 12, height: 56) { [weak self] index, image in
                self?.thumbnails[index] = image
            }
        }
    }

    // MARK: Transport

    func togglePlay() {
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    /// J/K/L shuttle, as in QuickTime and Final Cut.
    func shuttle(_ key: Shuttle.Key) {
        let canReverse = player.currentItem?.canPlayReverse ?? false
        let rate = Shuttle.rate(after: key, current: player.rate, canReverse: canReverse)
        if key == .reverse, !canReverse { step(by: -1); return }
        player.rate = rate
    }

    /// Exactly one frame, using the decoder's own frame step (so variable frame rates work).
    func step(by frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    func seek(toFraction fraction: Double) {
        let seconds = max(0, min(1, fraction)) * duration.seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: Selection

    func markIn() { selection = MediaMath.settingPoint(player.currentTime(), isIn: true, current: selection, duration: duration) }
    func markOut() { selection = MediaMath.settingPoint(player.currentTime(), isIn: false, current: selection, duration: duration) }
    func clearSelection() { selection = nil }

    var canTrim: Bool { playerView?.canBeginTrimming ?? false }

    /// AVPlayerView's own trim bar. On OK, its handles become the selection.
    func beginTrim() {
        guard let view = playerView, view.canBeginTrimming else { NSSound.beep(); return }
        isTrimming = true
        view.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTrimming = false
                guard result == .okButton, let item = self.player.currentItem else { return }
                let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : self.duration
                self.selection = MediaMath.clamp(from: start, to: end, within: self.duration)
            }
        }
    }

    /// Playback stays inside the selection, so what you hear is what you'll export.
    private func applySelectionToPlayer() {
        guard let item = player.currentItem else { return }
        item.reversePlaybackEndTime = selection?.start ?? .invalid
        item.forwardPlaybackEndTime = selection?.end ?? .invalid
    }

    /// Speed and mute are cheap to preview; rotation and flips apply on export.
    private func previewEdits() {
        player.defaultRate = Float(edits.speed)
        if player.rate != 0 { player.rate = Float(edits.speed) }
        player.isMuted = edits.removeAudio
    }

    // MARK: Export

    var baseName: String { url.deletingPathExtension().lastPathComponent }

    func export() {
        let request = ExportRequest(source: url, format: format, range: selection, edits: edits)
        Task {
            let fileType = await MediaExport.fileType(for: request)
            let type = UTType(fileType.rawValue) ?? .movie
            let suffix = selection == nil && edits.isIdentity && format == .original ? "copy" : "edited"
            guard let destination = await askDestination(name: "\(baseName) \(suffix)", type: type) else { return }
            run("Exporting “\(destination.lastPathComponent)”", destination: destination) { progress in
                try await MediaExport.run(request, to: destination, progress: progress)
            }
        }
    }

    func saveFrame() {
        let time = player.currentTime()
        player.pause()
        Task {
            guard
                let destination = await askDestination(
                    name: "\(baseName) \(MediaMath.timecode(time).replacingOccurrences(of: ":", with: "."))", type: .png)
            else { return }
            run("Saving frame", destination: destination) { [url] _ in
                let image = try await Frames.still(url, at: time)
                try await MediaExport.writeAtomically(to: destination) { try Frames.writePNG(image, to: $0) }
            }
        }
    }

    func makeGIF() {
        let range = selection
        Task {
            guard let destination = await askDestination(name: baseName, type: .gif) else { return }
            run("Making “\(destination.lastPathComponent)”", destination: destination) { [url] progress in
                try await GIFMaker.make(from: url, range: range, fps: 15, width: 480, to: destination, progress: progress)
            }
        }
    }

    func cancelJob() { job?.task?.cancel() }

    private func run(
        _ title: String, destination: URL, work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        job = Job(title: title)
        job?.task = Task {
            do {
                try await work { fraction in
                    Task { @MainActor [weak self] in self?.job?.fraction = fraction }
                }
                lastSaved = destination
            } catch is CancellationError {
                log.info("Export cancelled")
            } catch {
                Alert.show(error, title: "Couldn't save “\(destination.lastPathComponent)”", window: playerView?.window)
            }
            job = nil
        }
    }

    private func askDestination(name: String, type: UTType) async -> URL? {
        // One export at a time per window (the menu stays enabled while the HUD is up).
        guard job == nil else { NSSound.beep(); return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = name
        let response: NSApplication.ModalResponse
        if let window = playerView?.window ?? NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let chosen = panel.url else { return nil }
        guard chosen.standardizedFileURL != url.standardizedFileURL else {
            Alert.show(
                FolioError("Choose a different name. Folio never replaces the original file."), title: "Can't overwrite the original",
                window: playerView?.window)
            return nil
        }
        return chosen
    }
}

/// J/K/L shuttle rates. Pure so the progression is testable.
nonisolated enum Shuttle {
    enum Key: Sendable { case reverse, pause, forward }

    /// L: play, then 2×, 4×, 8×. J: the same backwards. K: stop.
    /// Pressing the opposite direction first stops at 1× that way, like QuickTime.
    static func rate(after key: Key, current: Float, canReverse: Bool) -> Float {
        switch key {
        case .pause: return 0
        case .forward: return current <= 0 ? 1 : min(current * 2, 8)
        case .reverse:
            guard canReverse else { return 0 }
            return current >= 0 ? -1 : max(current * 2, -8)
        }
    }
}
