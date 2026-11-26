import CoreGraphics

/// Small, pure geometry helpers shared by drawing tools and page stamping.
nonisolated enum Geometry {
    /// The largest rect with `size`'s aspect ratio that fits inside `bounds`, centred.
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// The rect spanned by a drag from `a` to `b`, whichever way the user dragged.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Size of a page's crop box as the reader sees it, after `/Rotate`.
    static func displaySize(crop: CGRect, rotation: Int) -> CGSize {
        normalized(rotation) % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    /// Maps "display space" (origin at the visual bottom-left of the rotated page, in
    /// points) to PDF page space. Stamping page numbers and watermarks in display space
    /// keeps them upright and at the visual bottom however the page is rotated.
    ///
    /// PDF `/Rotate` turns the page clockwise for display; this is its inverse.
    static func displayToPage(crop c: CGRect, rotation: Int) -> CGAffineTransform {
        switch normalized(rotation) {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: c.maxX, ty: c.minY)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: c.maxX, ty: c.maxY)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: c.minX, ty: c.maxY)
        default: CGAffineTransform(translationX: c.minX, y: c.minY)
        }
    }

    /// Rotation folded into 0, 90, 180 or 270.
    static func normalized(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }
}
