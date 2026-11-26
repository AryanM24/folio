import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import FolioImage

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 0.001) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

private func close(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 0.0001) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

@Suite struct RecipeTests {
    @Test func defaultRecipeIsIdentity() {
        #expect(EditRecipe().isIdentity)
        var r = EditRecipe()
        r.adjustments[.exposure] = 10
        #expect(!r.isIdentity)
        r.adjustments[.exposure] = 0
        #expect(r.isIdentity, "Setting a slider back to zero means unchanged")
    }

    @Test func stripMetadataAloneDoesNotChangePixels() {
        var r = EditRecipe()
        r.stripMetadata = true
        #expect(!r.isIdentity)
        #expect(!r.changesPixels)
    }

    @Test func recipeRoundTripsThroughJSON() throws {
        var r = EditRecipe()
        r.crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        r.quarterTurns = 3
        r.straighten = -7.5
        r.flipHorizontal = true
        r.resize = PixelSize(width: 800, height: 600)
        r.adjustments[.warmth] = 40
        r.filter = .noir
        r.filterStrength = 0.6
        r.autoEnhance = [FilterSpec(name: "CIVibrance", numbers: ["inputAmount": 0.3])]
        r.markup = [MarkupItem(kind: .arrow, points: [.zero, CGPoint(x: 10, y: 10)], color: .red, lineWidth: 4)]
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(r))
        #expect(decoded == r)
    }

    @Test func slidersClampToTheirRange() {
        var a = Adjustments()
        a[.sharpness] = -50
        #expect(a[.sharpness] == 0)
        a[.contrast] = 400
        #expect(a[.contrast] == 100)
    }

    @Test func normalizeClampsValues() {
        var r = EditRecipe()
        r.quarterTurns = -1
        r.straighten = 90
        r.crop = CGRect(x: -0.5, y: 0.5, width: 1, height: 1)
        r.normalize()
        #expect(r.quarterTurns == 3)
        #expect(r.straighten == 45)
        #expect(close(r.crop, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)))
    }

    @Test func fourTurnsAndTwoFlipsAreNoOps() {
        var r = EditRecipe()
        r.crop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        r.straighten = 5
        let start = r
        for _ in 0..<4 { r.rotateClockwise() }
        #expect(r.quarterTurns == start.quarterTurns)
        #expect(close(r.crop, start.crop))
        r.flipHorizontallyOnScreen(); r.flipHorizontallyOnScreen()
        r.flipVerticallyOnScreen(); r.flipVerticallyOnScreen()
        #expect(r.flipHorizontal == start.flipHorizontal && r.flipVertical == start.flipVertical)
        #expect(r.straighten == start.straighten)
        #expect(close(r.crop, start.crop))
    }

    @Test func rotatingSwapsResize() {
        var r = EditRecipe()
        r.resize = PixelSize(width: 300, height: 200)
        r.rotateClockwise()
        #expect(r.resize == PixelSize(width: 200, height: 300))
    }

    @Test func pixelSizeFitting() {
        #expect(PixelSize(width: 6000, height: 4000).fitting(maxEdge: 2048) == PixelSize(width: 2048, height: 1365))
        #expect(PixelSize(width: 100, height: 50).fitting(maxEdge: 2048) == PixelSize(width: 100, height: 50), "Never enlarges")
        #expect(PixelSize(width: 400, height: 300).scaled(percent: 50) == PixelSize(width: 200, height: 150))
    }
}

@Suite struct GeometryTests {
    let size = CGSize(width: 400, height: 300)

    @Test func identityMapsPointsToThemselves() {
        let g = ImageGeometry(sourceSize: size, recipe: EditRecipe())
        #expect(g.canvasTransform.isIdentity)
        #expect(g.outputSize == size)
    }

    @Test func quarterTurnSwapsAndMapsCorners() {
        var r = EditRecipe()
        r.quarterTurns = 1
        let g = ImageGeometry(sourceSize: size, recipe: r)
        #expect(g.canvasSize == CGSize(width: 300, height: 400))
        // Clockwise: the top-left corner goes to the top-right.
        #expect(close(CGPoint.zero.applying(g.canvasTransform), CGPoint(x: 300, y: 0)))
        #expect(close(CGPoint(x: 400, y: 300).applying(g.canvasTransform), CGPoint(x: 0, y: 400)))
    }

    @Test func horizontalFlipMirrorsX() {
        var r = EditRecipe()
        r.flipHorizontal = true
        let g = ImageGeometry(sourceSize: size, recipe: r)
        #expect(close(CGPoint(x: 0, y: 10).applying(g.canvasTransform), CGPoint(x: 400, y: 10)))
    }

    @Test func screenFlipAfterTurnMirrorsWhatYouSee() {
        var r = EditRecipe()
        r.rotateClockwise()
        r.flipHorizontallyOnScreen()
        let g = ImageGeometry(sourceSize: size, recipe: r)
        // Turned: (0,0)→(300,0); mirrored on screen: x → 300 − x.
        #expect(close(CGPoint.zero.applying(g.canvasTransform), .zero))
        #expect(close(CGPoint(x: 400, y: 0).applying(g.canvasTransform), CGPoint(x: 0, y: 400)))
    }

    @Test func coverScale() {
        #expect(ImageGeometry.coverScale(size: size, radians: 0) == 1)
        let square = ImageGeometry.coverScale(size: CGSize(width: 100, height: 100), radians: .pi / 4)
        #expect(abs(square - 2.0.squareRoot()) < 0.0001)
    }

    @Test func straightenNeverShowsEmptyCorners() {
        for angle in [-45.0, -12, -3, 5, 20, 45] {
            var r = EditRecipe()
            r.straighten = angle
            let g = ImageGeometry(sourceSize: size, recipe: r)
            let inverse = g.canvasTransform.inverted()
            for corner in [CGPoint.zero, CGPoint(x: 400, y: 0), CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)] {
                let p = corner.applying(inverse)
                #expect(p.x >= -0.01 && p.x <= 400.01 && p.y >= -0.01 && p.y <= 300.01, "corner \(corner) at \(angle)° samples \(p)")
            }
        }
    }

    @Test func cropAndResize() {
        var r = EditRecipe()
        r.crop = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)
        r.resize = PixelSize(width: 100, height: 75)
        let g = ImageGeometry(sourceSize: size, recipe: r)
        #expect(g.cropRect == CGRect(x: 100, y: 150, width: 200, height: 150))
        #expect(g.outputSize == CGSize(width: 100, height: 75))
        #expect(close(CGPoint(x: 100, y: 150).applying(g.outputTransform), .zero))
        #expect(close(CGPoint(x: 300, y: 300).applying(g.outputTransform), CGPoint(x: 100, y: 75)))
    }

    @Test func ciTransformFlipsToBottomLeft() {
        let g = ImageGeometry(sourceSize: size, recipe: EditRecipe())
        // Identity in y-down space is identity in y-up space too.
        let t = g.ciTransform(scale: 0.5, cropped: true)
        #expect(close(CGPoint(x: 10, y: 20).applying(t), CGPoint(x: 10, y: 20)))
    }
}

@Suite struct CropMathTests {
    let canvas = CGSize(width: 4000, height: 3000)
    let full = EditRecipe.fullCrop

    @Test func fitSquareInLandscape() {
        let r = CropMath.fit(ratio: 1, canvas: canvas, around: full)
        #expect(close(r, CGRect(x: 0.125, y: 0, width: 0.75, height: 1)))
    }

    @Test func fitKeepsPixelRatio() {
        for aspect in CropAspect.allCases {
            guard let ratio = aspect.ratio(original: canvas) else { continue }
            let r = CropMath.fit(ratio: ratio, canvas: canvas, around: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))
            #expect(abs(r.width * canvas.width / (r.height * canvas.height) - ratio) < 0.001, "\(aspect)")
            #expect(r.minX >= 0 && r.maxX <= 1.0001 && r.minY >= 0 && r.maxY <= 1.0001)
        }
    }

    @Test func freeCornerDragMovesOnlyThatCorner() {
        let r = CropMath.drag(.topLeft, from: full, by: CGSize(width: 0.1, height: 0.2), ratio: nil, canvas: canvas)
        #expect(close(r, CGRect(x: 0.1, y: 0.2, width: 0.9, height: 0.8)))
    }

    @Test func dragStaysInsideAndAboveMinimum() {
        let out = CropMath.drag(.bottomRight, from: full, by: CGSize(width: 0.5, height: 0.5), ratio: nil, canvas: canvas)
        #expect(close(out, full))
        let tiny = CropMath.drag(.left, from: full, by: CGSize(width: 5, height: 0), ratio: nil, canvas: canvas)
        #expect(tiny.width >= CropMath.minimumSide - 0.0001)
    }

    @Test func aspectDragKeepsRatio() {
        let start = CropMath.fit(ratio: 1, canvas: canvas, around: full)
        for handle in CropMath.Handle.allCases where handle != .move {
            let r = CropMath.drag(handle, from: start, by: CGSize(width: -0.1, height: 0.05), ratio: 1, canvas: canvas)
            #expect(abs(r.width * canvas.width - r.height * canvas.height) < 0.5, "\(handle)")
            #expect(r.minX >= -0.0001 && r.maxX <= 1.0001 && r.minY >= -0.0001 && r.maxY <= 1.0001, "\(handle) \(r)")
        }
    }

    @Test func moveClampsToCanvas() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let r = CropMath.drag(.move, from: start, by: CGSize(width: 1, height: -1), ratio: nil, canvas: canvas)
        #expect(close(r, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
    }
}

@Suite struct MarkupTests {
    @Test func hitTestingStrokes() {
        let line = MarkupItem(kind: .pen, points: [.zero, CGPoint(x: 100, y: 0)], color: .red, lineWidth: 4)
        #expect(line.contains(CGPoint(x: 50, y: 3), tolerance: 2))
        #expect(!line.contains(CGPoint(x: 50, y: 20), tolerance: 2))
    }

    @Test func offsetMovesEveryPoint() {
        let box = MarkupItem(kind: .rectangle, points: [.zero, CGPoint(x: 10, y: 10)], color: .red, lineWidth: 2)
        #expect(box.offset(by: CGSize(width: 5, height: -5)).rect == CGRect(x: 5, y: -5, width: 10, height: 10))
    }

    @Test func textHasMeasuredBounds() {
        let text = MarkupItem(kind: .text, points: [CGPoint(x: 10, y: 10)], color: .red, lineWidth: 0, text: "Hello\nworld", fontSize: 20)
        #expect(text.bounds.width > 20)
        #expect(abs(text.bounds.height - 48) < 0.01)
    }

    @Test func hexColor() {
        #expect(RGBA(red: 1, green: 0.5, blue: 0).hex == "#FF8000")
    }
}
