import CoreGraphics
import Testing

@testable import FolioImage

nonisolated private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 0.0001) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

@Suite(.timeLimit(.minutes(1)))
nonisolated struct CanvasMathTests {
    private let viewport = CanvasViewport(imageSize: CGSize(width: 1000, height: 800), viewSize: CGSize(width: 500, height: 400), zoom: 1, center: CGPoint(x: 500, y: 400))

    @Test func viewAndImagePointsRoundTrip() {
        var v = viewport
        v.zoom = 2.5
        v.center = CGPoint(x: 310, y: 220)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 123.4, y: 77), CGPoint(x: 999, y: 799)] {
            #expect(close(v.toImage(v.toView(p)), p))
        }
    }

    @Test func visibleRectMapsTheViewIntoSourcePixels() {
        #expect(viewport.visibleImageRect == CGRect(x: 250, y: 200, width: 500, height: 400))
        var v = viewport
        v.zoom = 0.25  // the whole picture fits, so all of it is visible
        #expect(v.visibleImageRect == CGRect(x: 0, y: 0, width: 1000, height: 800))
        // The view's corners land on the visible rect's corners.
        #expect(close(viewport.toImage(.zero), CGPoint(x: 250, y: 200)))
        #expect(close(viewport.toImage(CGPoint(x: 500, y: 400)), CGPoint(x: 750, y: 600)))
    }

    @Test func zoomKeepsThePointUnderTheCursorFixed() {
        let anchor = CGPoint(x: 123, y: 77)
        let before = viewport.toImage(anchor)
        for zoom in [0.3, 1.7, 3.7, 16] {
            let after = viewport.zoomed(to: zoom, anchor: anchor)
            #expect(after.zoom == zoom)
            #expect(close(after.toImage(anchor), before), "zoom \(zoom)")
            #expect(close(after.toView(before), anchor), "zoom \(zoom)")
        }
        // Away from the edges, clamping keeps the invariant.
        let deep = viewport.zoomed(to: 4, anchor: CGPoint(x: 250, y: 200)).clamped()
        #expect(close(deep.toImage(CGPoint(x: 250, y: 200)), viewport.toImage(CGPoint(x: 250, y: 200))))
    }

    @Test func clampingCentersSmallPicturesAndStopsAtEdges() {
        var v = viewport
        v.zoom = 0.2
        v.center = CGPoint(x: 0, y: 9999)
        #expect(v.clamped().center == CGPoint(x: 500, y: 400))
        v.zoom = 2
        v.center = CGPoint(x: -500, y: 5000)
        let c = v.clamped()
        #expect(c.pictureFrame.minX == 0, "left edge meets the view's left edge")
        #expect(c.pictureFrame.maxY == 400, "bottom edge meets the view's bottom edge")
    }

    @Test func fitAndZoomToRect() {
        #expect(CanvasViewport.fitZoom(image: CGSize(width: 1000, height: 800), view: CGSize(width: 500, height: 400), insets: .init()) == 0.5)
        #expect(CanvasViewport.fitZoom(image: CGSize(width: 100, height: 80), view: CGSize(width: 500, height: 400), insets: .init()) == 1)
        let v = viewport.fitting(CGRect(x: 100, y: 100, width: 250, height: 100))
        #expect(v.zoom == 2)
        #expect(close(v.toView(CGPoint(x: 225, y: 150)), CGPoint(x: 250, y: 200)), "the rect's middle is the view's middle")
    }

    @Test func ciTransformPutsThePictureWhereTheViewSaysAtBackingScale() {
        var v = viewport
        v.zoom = 0.5
        v.center = CGPoint(x: 500, y: 400)  // picture fills 500 × 400 points from (0, 0)
        let extent = CGRect(x: 0, y: 0, width: 250, height: 200)  // a quarter-scale graph
        let t = v.ciTransform(extent: extent, drawableHeight: 800, backing: 2)
        // Graph top-left (CI y up: (0, 200)) → drawable top-left (0, 800).
        #expect(close(CGPoint(x: 0, y: 200).applying(t), CGPoint(x: 0, y: 800)))
        #expect(close(CGPoint(x: 250, y: 0).applying(t), CGPoint(x: 1000, y: 0)))
    }

    @Test func guidesSnapToTheNearestTargetWithinTolerance() {
        #expect(GuideSnapping.snap(103, to: [100, 200], tolerance: 5) == 100)
        #expect(GuideSnapping.snap(110, to: [100, 200], tolerance: 5) == nil)
        #expect(GuideSnapping.snap(104, to: [100, 106], tolerance: 5) == 106)
        // A box at 97…147 (middle 122) moves 3 px so its left edge sits on the guide at 100.
        #expect(GuideSnapping.offset([97, 122, 147], to: [100, 300], tolerance: 5) == 3)
        #expect(GuideSnapping.offset([97, 122, 147], to: [], tolerance: 5) == nil)
    }

    @Test func rulerTicksAreRoundNumbersFarEnoughApart() {
        #expect(GuideSnapping.tickStep(zoom: 1) == 100)
        #expect(GuideSnapping.tickStep(zoom: 0.1) == 1000)
        #expect(GuideSnapping.tickStep(zoom: 8) == 10)
    }

    @Test func listMovesBecomeStackMoves() {
        // List shows [C, B, A] for the stack [A, B, C].
        let (from, to) = LayersPanel.stackMove(from: [0], to: 3, count: 3)  // C to the bottom
        #expect(from == [2] && to == 0)
        let (from2, to2) = LayersPanel.stackMove(from: [2], to: 0, count: 3)  // A to the top
        #expect(from2 == [0] && to2 == 3)
    }
}
