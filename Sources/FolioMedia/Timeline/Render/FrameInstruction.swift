import AVFoundation
import CoreImage

/// One visual clip as the compositor draws it. Keyframes are evaluated per frame from
/// `clip` (offsets from `clip.start`), so one layer covers a whole span however it animates.
nonisolated struct RenderLayer: Sendable {
    enum Content: Sendable {
        /// Frames from a composition track; `orientation` is the source's `preferredTransform`.
        case track(CMPersistentTrackID, orientation: CGAffineTransform)
        /// A still decoded at build time (`RenderScene.images`).
        case image(SourceID)
        case color(RGBA)
        case title(Title)
    }

    var content: Content
    var clip: Clip
    /// The source, for analysis hooks (masks, stabilization) keyed by it.
    var source: MediaSource?
}

/// What one model track contributes to a frame.
nonisolated enum FrameItem: Sendable {
    case layer(RenderLayer)
    /// `from` or `to` is `nil` for a transition into or out of the layers below.
    case transition(ClipTransition, window: TimeRange, from: RenderLayer?, to: RenderLayer?)

    var layers: [RenderLayer] {
        switch self {
        case .layer(let l): [l]
        case .transition(_, _, let a, let b): [a, b].compactMap { $0 }
        }
    }
}

/// Everything shared by a build's instructions: canvas, stills, LUTs, captions, analysis.
nonisolated final class RenderScene: Sendable {
    let canvas: CanvasSize
    let background: RGBA
    let colorSpace: ColorSpace
    let images: [SourceID: UncheckedSendable<CIImage>]
    /// Parsed `.cube` files by path.
    let luts: [String: CubeLUT]
    let captions: [(style: CaptionStyle, cues: [ResolvedCue])]
    /// Background-removal masks by `RenderScene.maskKey`.
    let masks: [String: any FrameMasks]
    let cameraPaths: [SourceID: any CameraPath]

    init(
        canvas: CanvasSize, background: RGBA, colorSpace: ColorSpace, images: [SourceID: UncheckedSendable<CIImage>] = [:],
        luts: [String: CubeLUT] = [:], captions: [(style: CaptionStyle, cues: [ResolvedCue])] = [],
        masks: [String: any FrameMasks] = [:], cameraPaths: [SourceID: any CameraPath] = [:]
    ) {
        self.canvas = canvas
        self.background = background
        self.colorSpace = colorSpace
        self.images = images
        self.luts = luts
        self.captions = captions
        self.masks = masks
        self.cameraPaths = cameraPaths
    }

    static func maskKey(_ source: SourceID, _ subject: BackgroundSubject) -> String { "\(source)/\(subject.rawValue)" }
}

/// The instruction for one span of the timeline where the set of layers doesn't change.
/// Immutable; AVFoundation hands it to `Compositor` on its own queues.
nonisolated final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let scene: RenderScene
    /// Bottom to top.
    let items: [FrameItem]

    init(timeRange: CMTimeRange, scene: RenderScene, items: [FrameItem]) {
        self.timeRange = timeRange
        self.scene = scene
        self.items = items
        var ids: [CMPersistentTrackID] = []
        for case .track(let id, _) in items.flatMap(\.layers).map(\.content) where !ids.contains(id) { ids.append(id) }
        requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) }
    }
}
