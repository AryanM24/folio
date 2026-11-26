import AppKit
import FolioKit
import SwiftUI
import VisionKit

private let log = Log.make("Image")

/// Live Text: VisionKit's own overlay, so selecting, copying, looking up and data
/// detectors (dates, addresses, links) behave exactly as in Preview and Photos.
struct LiveTextOverlay: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let view = ImageAnalysisOverlayView()
        view.preferredInteractionTypes = .automatic
        view.selectableItemsHighlighted = true
        return view
    }

    func updateNSView(_ view: ImageAnalysisOverlayView, context: Context) {
        guard context.coordinator.analyzed !== image else { return }
        context.coordinator.analyzed = image
        context.coordinator.task?.cancel()
        let image = self.image
        context.coordinator.task = Task {
            guard ImageAnalyzer.isSupported else { return }
            do {
                let analysis = try await ImageAnalyzer().analyze(
                    image, orientation: .up, configuration: .init([.text, .machineReadableCode]))
                guard !Task.isCancelled else { return }
                view.analysis = analysis
            } catch {
                log.error("Live Text analysis failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var analyzed: CGImage?
        var task: Task<Void, Never>?
    }
}
