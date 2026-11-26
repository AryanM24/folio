import CoreGraphics
import Foundation

/// Aspect ratio choices in the Crop tab.
nonisolated enum CropAspect: String, CaseIterable, Sendable, Identifiable {
    case free, original, square, portrait4x5, landscape4x3, landscape3x2, landscape16x9, portrait9x16

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square"
        case .portrait4x5: "4:5"
        case .landscape4x3: "4:3"
        case .landscape3x2: "3:2"
        case .landscape16x9: "16:9"
        case .portrait9x16: "9:16"
        }
    }

    /// Width ÷ height in pixels, or `nil` for free.
    func ratio(original: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: original.height > 0 ? original.width / original.height : nil
        case .square: 1
        case .portrait4x5: 4.0 / 5
        case .landscape4x3: 4.0 / 3
        case .landscape3x2: 3.0 / 2
        case .landscape16x9: 16.0 / 9
        case .portrait9x16: 9.0 / 16
        }
    }
}

/// Pure crop-box math, in unit coordinates of the canvas (top-left origin). Aspect
/// ratios are in *pixels*, so the canvas size is needed to convert.
nonisolated enum CropMath {
    /// Which part of the crop box is being dragged.
    enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    }

    /// Smallest crop side, in unit coordinates.
    static let minimumSide = 0.02

    /// The largest rectangle with `ratio` (pixels) that fits the canvas, centered on
    /// `current`'s center and shifted inside if needed.
    static func fit(ratio: Double, canvas: CGSize, around current: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, ratio > 0 else { return current }
        // Unit-space ratio: width_u / height_u = ratio * H / W.
        let unitRatio = ratio * canvas.height / canvas.width
        var w = 1.0, h = 1.0
        if unitRatio > 1 { h = 1 / unitRatio } else { w = unitRatio }
        let cx = current.midX, cy = current.midY
        let x = min(max(0, cx - w / 2), 1 - w)
        let y = min(max(0, cy - h / 2), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The crop after dragging `handle` by `delta` (unit coordinates) from `start`.
    /// Keeps `ratio` when given, stays inside the canvas and above the minimum size.
    static func drag(_ handle: Handle, from start: CGRect, by delta: CGSize, ratio: Double?, canvas: CGSize) -> CGRect {
        if handle == .move {
            let x = min(max(0, start.minX + delta.width), 1 - start.width)
            let y = min(max(0, start.minY + delta.height), 1 - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = min(max(0, minX + delta.width), maxX - minimumSide) }
        if handle.movesRight { maxX = max(min(1, maxX + delta.width), minX + minimumSide) }
        if handle.movesTop { minY = min(max(0, minY + delta.height), maxY - minimumSide) }
        if handle.movesBottom { maxY = max(min(1, maxY + delta.height), minY + minimumSide) }
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio, canvas.width > 0, canvas.height > 0 else { return rect }

        // Keep the ratio: the dragged dimension drives, the other follows. The edge
        // opposite the handle stays put; edge handles grow symmetrically across.
        let unitRatio = ratio * canvas.height / canvas.width
        let horizontalDrives: Bool = switch handle {
        case .left, .right: true
        case .top, .bottom: false
        default: abs(delta.width) * unitRatio >= abs(delta.height) // dominant motion
        }
        var w = rect.width, h = rect.height
        if horizontalDrives { h = w / unitRatio } else { w = h * unitRatio }

        // Room available from the fixed anchor, so the box never leaves the canvas.
        let anchorX: Double = handle.movesLeft ? start.maxX : handle.movesRight ? start.minX : start.midX
        let anchorY: Double = handle.movesTop ? start.maxY : handle.movesBottom ? start.minY : start.midY
        let roomW: Double = handle.movesLeft ? anchorX : handle.movesRight ? 1 - anchorX : 2 * min(anchorX, 1 - anchorX)
        let roomH: Double = handle.movesTop ? anchorY : handle.movesBottom ? 1 - anchorY : 2 * min(anchorY, 1 - anchorY)
        let shrink = min(1, roomW / w, roomH / h)
        w *= shrink
        h *= shrink
        let minSide = minimumSide
        if w < minSide || h < minSide {
            let grow = max(minSide / w, minSide / h)
            w *= grow
            h *= grow
        }

        let x: Double = handle.movesLeft ? anchorX - w : handle.movesRight ? anchorX : anchorX - w / 2
        let y: Double = handle.movesTop ? anchorY - h : handle.movesBottom ? anchorY : anchorY - h / 2
        rect = CGRect(x: x, y: y, width: w, height: h)
        return rect
    }

    /// Unit crop expressed after one clockwise quarter turn, so a crop survives rotating.
    static func rotatedClockwise(_ r: CGRect) -> CGRect {
        // (x, y) → (1 − y, x) for points; rectangles swap axes.
        CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
    }

    static func flippedHorizontally(_ r: CGRect) -> CGRect {
        CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    static func flippedVertically(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}
