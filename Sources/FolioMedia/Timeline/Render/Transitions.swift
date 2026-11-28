import CoreImage
import CoreImage.CIFilterBuiltins

/// The built-in transitions. Both sides arrive as full-canvas images (clear where the
/// clip doesn't cover), so "from nothing" and "to nothing" are just clear images and the
/// result composites over the layers below.
///
/// Core Image blends in linear light: a 50 % dissolve of red into blue reads about
/// 0.73/0.74 in sRGB, not 0.5. That's the intended look (Final Cut does the same).
nonisolated enum Transitions {
    /// `direction` is where the motion goes: `.left` wipes, slides and pushes towards the left.
    static func apply(_ transition: ClipTransition, progress: Double, from: CIImage, to: CIImage, canvas: CGRect) -> CIImage {
        let p = min(1, max(0, progress))
        let eased = Interpolation.easeInOut.curve(p)
        let (w, h) = (canvas.width, canvas.height)
        let angle: Double =
            switch transition.direction {
            case .left: .pi
            case .right: 0
            case .up: .pi / 2
            case .down: -.pi / 2
            }
        // Unit vector of the motion, Core Image y-up.
        let (dx, dy): (Double, Double) =
            switch transition.direction {
            case .left: (-1, 0)
            case .right: (1, 0)
            case .up: (0, 1)
            case .down: (0, -1)
            }
        func moved(_ image: CIImage, _ amount: Double) -> CIImage {
            image.transformed(by: CGAffineTransform(translationX: dx * w * amount, y: dy * h * amount))
        }
        func scaled(_ image: CIImage, _ s: Double) -> CIImage {
            image.transformed(
                by: CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY).concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY)))
        }
        func builtIn(_ name: String, _ extra: [String: Any]) -> CIImage {
            var parameters = extra
            parameters[kCIInputTargetImageKey] = to
            parameters[kCIInputTimeKey] = p
            return from.applyingFilter(name, parameters: parameters)
        }
        let center = CIVector(x: canvas.midX, y: canvas.midY)
        let extent = CIVector(cgRect: canvas)
        let result: CIImage
        switch transition.kind {
        case .dissolve: result = dissolve(from, to, p)
        case .fadeThroughBlack, .fadeThroughWhite:
            let color = CIImage(color: transition.kind == .fadeThroughBlack ? .black : .white).cropped(to: canvas)
            result = p < 0.5 ? dissolve(from, color, p * 2) : dissolve(color, to, p * 2 - 1)
        case .wipe:
            // The edge travels with the motion; `to` is revealed behind it.
            let reveal: CGRect =
                switch transition.direction {
                case .left: CGRect(x: canvas.maxX - w * p, y: canvas.minY, width: w * p, height: h)
                case .right: CGRect(x: canvas.minX, y: canvas.minY, width: w * p, height: h)
                case .up: CGRect(x: canvas.minX, y: canvas.minY, width: w, height: h * p)
                case .down: CGRect(x: canvas.minX, y: canvas.maxY - h * p, width: w, height: h * p)
                }
            result = to.cropped(to: reveal).composited(over: from)
        case .slide: result = moved(to, eased - 1).composited(over: from)
        case .push: result = moved(to, eased - 1).composited(over: moved(from, eased))
        case .zoom: result = dissolve(scaled(from, 1 + eased), scaled(to, 0.6 + 0.4 * eased), p)
        case .bars:
            result = builtIn("CIBarsSwipeTransition", [kCIInputAngleKey: angle, kCIInputWidthKey: w / 24, "inputBarOffset": w / 64])
        case .copyMachine: result = builtIn("CICopyMachineTransition", [kCIInputExtentKey: extent, kCIInputAngleKey: angle])
        case .pageCurl:
            result = builtIn(
                "CIPageCurlTransition",
                [
                    kCIInputExtentKey: extent, kCIInputAngleKey: angle, kCIInputRadiusKey: min(w, h) / 6, "inputBacksideImage": from,
                    kCIInputShadingImageKey: shading(canvas),
                ])
        case .ripple:
            result = builtIn(
                "CIRippleTransition", [kCIInputCenterKey: center, kCIInputExtentKey: extent, kCIInputShadingImageKey: shading(canvas)])
        case .flash: result = builtIn("CIFlashTransition", [kCIInputCenterKey: center, kCIInputExtentKey: extent])
        case .accordion: result = builtIn("CIAccordionFoldTransition", ["inputNumberOfFolds": 4])
        case .mod: result = builtIn("CIModTransition", [kCIInputCenterKey: center, kCIInputAngleKey: angle])
        }
        return result.cropped(to: canvas)
    }

    private static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: t])
    }

    /// A soft highlight for the page curl's and ripple's shading input.
    private static func shading(_ canvas: CGRect) -> CIImage {
        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: canvas.midX, y: canvas.midY)
        g.radius0 = 0
        g.radius1 = Float(max(canvas.width, canvas.height))
        g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.6)
        g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        return g.outputImage?.cropped(to: canvas) ?? CIImage.empty()
    }
}
