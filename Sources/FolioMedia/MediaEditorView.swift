public import SwiftUI
import FolioKit

/// The media window: player (or waveform for audio), filmstrip, status bar and inspector.
///
/// Plays the file straight from disk: the URL comes from the document configuration,
/// never from the document's (nonexistent) bytes.
public struct MediaEditorView: View {
    private let document: MediaDocument
    @Environment(\.documentConfiguration) private var configuration

    public init(document: MediaDocument) { self.document = document }

    public var body: some View {
        if let url = configuration?.fileURL {
            MediaScreen(url: url, openedAt: document.openedAt).id(url)
        } else {
            ContentUnavailableView("Open a movie or sound file", systemImage: FileKind.media.symbol,
                                   description: Text("Choose File › Open… to play a video or audio file."))
                .background(Hero.background)
        }
    }
}

private struct MediaScreen: View {
    let url: URL
    let openedAt: ContinuousClock.Instant
    @State private var controller: MediaController?
    private let log = Log.make("Media")

    var body: some View {
        Group {
            if let controller { content(controller) } else { Hero.background }
        }
        .frame(minWidth: 720, idealWidth: 1120, minHeight: 460, idealHeight: 680)
        .onAppear {
            guard controller == nil else { return }
            controller = MediaController(url: url)
            let ms = Int(openedAt.duration(to: .now) / .milliseconds(1))
            log.info("Media window content ready \(ms, privacy: .public) ms after the document opened")
        }
        .onDisappear { controller?.player.pause() }
    }

    private func content(_ controller: MediaController) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if controller.isAudioOnly {
                    VStack(spacing: 16) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Hero.foreground)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        WaveformView(controller: controller)
                        PlayerView(controller: controller)
                            .frame(height: 52)
                            .clipShape(.rect(cornerRadius: Hero.Radius.xl))
                    }
                    .heroCard()
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlayerView(controller: controller)
                    if !controller.thumbnails.isEmpty { FilmstripView(controller: controller) }
                }
                StatusBar {
                    Text(InfoFormat.selection(controller.selection))
                    if !controller.edits.isIdentity { Text("Edits apply on export") }
                    Spacer()
                    if let saved = controller.lastSaved {
                        Button("Saved “\(saved.lastPathComponent)” · Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([saved])
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Hero.accentSoftForeground)
                    }
                }
            }
            InfoSidebar(controller: controller)
        }
        .background(Hero.background)
        .overlay {
            if let job = controller.job {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ExportHUD(job: job) { controller.cancelJob() }
                }
                .transition(.opacity)
            }
        }
        .animation(Hero.animation, value: controller.job != nil)
        .focusedSceneValue(\.mediaController, controller)
        .task { await controller.load() }
    }
}

// Spelled out instead of `@Entry`: the Command Line Tools don't ship SwiftUI's macro plugin.
private struct MediaControllerKey: FocusedValueKey { typealias Value = MediaController }

extension FocusedValues {
    var mediaController: MediaController? {
        get { self[MediaControllerKey.self] }
        set { self[MediaControllerKey.self] = newValue }
    }
}
