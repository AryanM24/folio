import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FolioImage

@Suite struct PipelineTests {
    let source = try! SourceImage(data: TestImages.data(.png))

    private func render(_ change: (inout EditRecipe) -> Void, final: Bool = true) throws -> CGImage {
        var r = EditRecipe()
        change(&r)
        return try RenderPipeline.render(source, recipe: r, final: final)
    }

    @Test func identityRenderKeepsSizeAndContent() throws {
        let out = try render { _ in }
        #expect(out.width == 400 && out.height == 300)
        let white = TestImages.pixel(out, x: 20, y: 20)
        #expect(white.r > 240 && white.g > 240 && white.b > 240, "white square stays top-left")
        let right = TestImages.pixel(out, x: 390, y: 290)
        #expect(right.b > 200 && right.r < 40, "blue on the right")
    }

    @Test func rotateRightPutsTopLeftAtTopRight() throws {
        let out = try render { $0.rotateClockwise() }
        #expect(out.width == 300 && out.height == 400)
        #expect(TestImages.pixel(out, x: 280, y: 20).g > 240, "white square turned to the top-right")
        #expect(TestImages.pixel(out, x: 20, y: 20).g < 40)
    }

    @Test func flipMirrors() throws {
        let out = try render { $0.flipHorizontallyOnScreen() }
        #expect(TestImages.pixel(out, x: 380, y: 20).g > 240)
        #expect(TestImages.pixel(out, x: 10, y: 290).b > 200, "blue now on the left")
    }

    @Test func cropSelectsRegion() throws {
        let out = try render { $0.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5) }
        #expect(out.width == 200 && out.height == 150)
        #expect(TestImages.pixel(out, x: 100, y: 75).g > 240, "only the white square remains")
    }

    @Test func resizeUsesTargetSize() throws {
        let out = try render { $0.resize = PixelSize(width: 100, height: 75) }
        #expect(out.width == 100 && out.height == 75)
    }

    @Test func straightenFillsCorners() throws {
        let out = try render { $0.straighten = 15 }
        #expect(out.width == 400 && out.height == 300)
        #expect(TestImages.pixel(out, x: 0, y: 299).a == 255, "no transparent corners")
    }

    @Test func previewScaleShrinksOutput() throws {
        var r = EditRecipe()
        r.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let out = try RenderPipeline.render(source, recipe: r, scale: 0.5)
        #expect(out.width == 100 && out.height == 150)
    }

    @Test func exposureBrightens() throws {
        let base = TestImages.mean(try render { _ in })
        let bright = TestImages.mean(try render { $0.adjustments[.exposure] = 60 })
        #expect(bright.r + bright.g + bright.b > base.r + base.g + base.b + 30)
    }

    @Test func warmthWarms() throws {
        let gray = try SourceImage(data: TestImages.data(.png))
        var warm = EditRecipe(); warm.adjustments[.warmth] = 80
        var cool = EditRecipe(); cool.adjustments[.warmth] = -80
        let w = TestImages.mean(try RenderPipeline.render(gray, recipe: warm))
        let c = TestImages.mean(try RenderPipeline.render(gray, recipe: cool))
        #expect(w.r - w.b > c.r - c.b + 10, "warm has more red relative to blue than cool")
    }

    @Test func monoIsGray() throws {
        let out = try render { $0.filter = .mono }
        let p = TestImages.pixel(out, x: 380, y: 280)
        #expect(abs(p.r - p.b) < 4 && abs(p.r - p.g) < 4)
    }

    @Test func zeroStrengthIsUnfiltered() throws {
        let plain = TestImages.pixel(try render { _ in }, x: 380, y: 280)
        let faint = TestImages.pixel(
            try render {
                $0.filter = .noir; $0.filterStrength = 0
            }, x: 380, y: 280)
        #expect(abs(plain.b - faint.b) < 3 && abs(plain.r - faint.r) < 3)
    }

    @Test func everyPresetAndSliderRenders() throws {
        for preset in FilterPreset.allCases {
            _ = try render {
                $0.filter = preset; $0.filterStrength = 0.5
            }
        }
        for adjustment in Adjustment.allCases {
            _ = try render { $0.adjustments[adjustment] = adjustment.range.upperBound }
            _ = try render { $0.adjustments[adjustment] = adjustment.range.lowerBound }
        }
    }

    @Test func autoEnhanceIsStoredAsData() throws {
        let specs = RenderPipeline.autoEnhance(for: source.proxyImage)
        let out = try render { $0.autoEnhance = specs }
        #expect(out.width == 400)
    }

    @Test func markupIsBakedIntoSavesOnly() throws {
        let item = MarkupItem(
            kind: .rectangle, points: [CGPoint(x: 250, y: 200), CGPoint(x: 350, y: 280)],
            color: RGBA(red: 0, green: 1, blue: 0), lineWidth: 10)
        let saved = try render({ $0.markup = [item] })
        let edge = TestImages.pixel(saved, x: 300, y: 200)
        #expect(edge.g > 200 && edge.r < 80, "green stroke at the top edge")
        let preview = try render({ $0.markup = [item] }, final: false)
        #expect(TestImages.pixel(preview, x: 300, y: 200).g < 100, "the live overlay draws markup instead")
    }

    @Test func markupFollowsRotation() throws {
        // A dot near the source's top-left lands top-right after a clockwise turn.
        let dot = MarkupItem(kind: .pen, points: [CGPoint(x: 30, y: 30)], color: RGBA(red: 0, green: 1, blue: 0), lineWidth: 20)
        let out = try render {
            $0.markup = [dot]; $0.rotateClockwise()
        }
        let p = TestImages.pixel(out, x: 300 - 30, y: 30)
        #expect(p.g > 200 && p.r < 80)
    }

    @Test func orientationIsApplied() throws {
        // EXIF 6 = rotate 90° clockwise to display.
        let rotated = try SourceImage(data: TestImages.data(.jpeg, orientation: 6))
        #expect(rotated.pixelSize == CGSize(width: 300, height: 400))
        let out = try RenderPipeline.render(rotated, recipe: EditRecipe(), final: true)
        #expect(out.width == 300 && out.height == 400)
        #expect(TestImages.pixel(out, x: 280, y: 20).g > 230)
    }
}
