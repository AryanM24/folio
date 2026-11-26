import CoreGraphics
import Foundation

/// Every change the user made to an image, as plain data.
///
/// The editor never mutates pixels. It keeps the decoded original in memory and this
/// recipe next to it, and ``RenderPipeline`` turns the pair into pixels on demand: at
/// screen size for the live preview, at full size when saving. Because each save
/// re-renders from the original, autosaving a JPEG ten times costs one generation of
/// compression, not ten.
///
/// The recipe is a value type, so undo is "put the previous recipe back".
nonisolated struct EditRecipe: Codable, Equatable, Sendable {
    /// Bumped when the encoding changes incompatibly; stored sessions with another
    /// version are ignored (the file itself is still opened as-is).
    static let version = 1

    // MARK: Geometry

    /// Crop in unit coordinates of the rotated and straightened canvas, top-left origin.
    var crop = EditRecipe.fullCrop
    /// Clockwise quarter turns, 0…3.
    var quarterTurns = 0
    /// Fine rotation in degrees, −45…45. The image is scaled up so no empty corners show.
    var straighten = 0.0
    var flipHorizontal = false
    var flipVertical = false
    /// Final pixel size after cropping, or `nil` to keep the cropped size.
    var resize: PixelSize?

    // MARK: Tone and color

    var adjustments = Adjustments()
    /// Filters suggested by `CIImage.autoAdjustmentFilters`, frozen as data so the
    /// preview, the saved file and a reopened session all agree. `nil` means off.
    var autoEnhance: [FilterSpec]?
    var filter: FilterPreset?
    /// How much of the filter to mix in, 0…1.
    var filterStrength = 1.0

    // MARK: Content

    /// Cut the subject out (Vision foreground mask); the background becomes transparent.
    var removeBackground = false
    var markup: [MarkupItem] = []

    // MARK: Saving

    /// Drop EXIF, GPS, IPTC and XMP when writing the file.
    var stripMetadata = false

    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// True when saving would produce the original file unchanged.
    var isIdentity: Bool { self == EditRecipe() }

    /// True when only geometry-free, pixel-free settings differ (nothing to render).
    var changesPixels: Bool {
        var copy = self
        copy.stripMetadata = false
        return copy != EditRecipe()
    }

    /// The recipe with tone, color, filter and cut-out kept but geometry reset.
    /// Used for the crop view, which shows the whole canvas.
    var withoutCrop: EditRecipe {
        var copy = self
        copy.crop = Self.fullCrop
        copy.resize = nil
        return copy
    }

    /// Normalizes values that have several spellings, so equality means "same output".
    mutating func normalize() {
        quarterTurns = ((quarterTurns % 4) + 4) % 4
        straighten = min(45, max(-45, straighten))
        filterStrength = min(1, max(0, filterStrength))
        crop = crop.standardized.intersection(Self.fullCrop)
        if crop.isNull || crop.width <= 0 || crop.height <= 0 { crop = Self.fullCrop }
    }
}

// MARK: - Geometry edits in screen terms

nonisolated extension EditRecipe {
    /// Turn 90° clockwise as the user sees it, carrying the crop along.
    mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        crop = CropMath.rotatedClockwise(crop)
        if let size = resize { resize = PixelSize(width: size.height, height: size.width) }
    }

    mutating func rotateCounterclockwise() {
        for _ in 0..<3 { rotateClockwise() }
    }

    /// Mirror left-right on screen. Flips are stored in source space (applied before
    /// the quarter turns), so after an odd number of turns a screen-horizontal flip is
    /// a source-vertical one. Mirroring also mirrors the straighten angle and the crop.
    mutating func flipHorizontallyOnScreen() {
        if quarterTurns % 2 == 0 { flipHorizontal.toggle() } else { flipVertical.toggle() }
        straighten = -straighten
        crop = CropMath.flippedHorizontally(crop)
    }

    mutating func flipVerticallyOnScreen() {
        if quarterTurns % 2 == 0 { flipVertical.toggle() } else { flipHorizontal.toggle() }
        straighten = -straighten
        crop = CropMath.flippedVertically(crop)
    }
}

/// A pixel size that encodes as integers.
nonisolated struct PixelSize: Codable, Equatable, Hashable, Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    init(_ size: CGSize) {
        self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    var cgSize: CGSize { CGSize(width: width, height: height) }

    /// The largest size with the same aspect ratio whose long edge is at most `maxEdge`.
    /// Never enlarges.
    func fitting(maxEdge: Int) -> PixelSize {
        let long = max(width, height)
        guard long > maxEdge, maxEdge > 0 else { return self }
        let scale = Double(maxEdge) / Double(long)
        return PixelSize(width: Int((Double(width) * scale).rounded()), height: Int((Double(height) * scale).rounded()))
    }

    /// This size scaled by `percent` (100 = unchanged).
    func scaled(percent: Double) -> PixelSize {
        PixelSize(width: Int((Double(width) * percent / 100).rounded()), height: Int((Double(height) * percent / 100).rounded()))
    }
}

/// A Core Image filter and its scalar/vector inputs, so auto-enhance can be stored.
nonisolated struct FilterSpec: Codable, Equatable, Sendable {
    var name: String
    var numbers: [String: Double] = [:]
    var vectors: [String: [Double]] = [:]
}
