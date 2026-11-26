import CoreGraphics
import Testing

@testable import FolioPDF

@Suite struct GeometryTests {
    let crop = CGRect(x: 0, y: 0, width: 600, height: 800)

    @Test(arguments: [
        (0, CGPoint(x: 300, y: 20)),  // bottom centre stays bottom centre
        (90, CGPoint(x: 580, y: 400)),  // turned clockwise: the right edge is the visual bottom
        (180, CGPoint(x: 300, y: 780)),
        (270, CGPoint(x: 20, y: 400)),
    ])
    func displayBottomCentreMapsToPageSpace(rotation: Int, expected: CGPoint) {
        let size = Geometry.displaySize(crop: crop, rotation: rotation)
        let point = CGPoint(x: size.width / 2, y: 20).applying(Geometry.displayToPage(crop: crop, rotation: rotation))
        #expect(abs(point.x - expected.x) < 0.001 && abs(point.y - expected.y) < 0.001)
    }

    @Test func displaySizeSwapsForQuarterTurns() {
        #expect(Geometry.displaySize(crop: crop, rotation: 90) == CGSize(width: 800, height: 600))
        #expect(Geometry.displaySize(crop: crop, rotation: -180) == crop.size)
    }

    @Test func aspectFitCentres() {
        let fitted = Geometry.aspectFit(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(fitted == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func resizeNeverInverts() {
        let rect = CGRect(x: 100, y: 100, width: 50, height: 50)
        let shrunk = Handle.topRight.resize(rect, by: CGSize(width: -500, height: -500), keepAspect: false)
        #expect(shrunk.width == 8 && shrunk.height == 8)
        #expect(shrunk.origin == rect.origin)
    }

    @Test func cornerResizeKeepsAspectFromOppositeCorner() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let grown = Handle.bottomLeft.resize(rect, by: CGSize(width: -100, height: 0), keepAspect: true)
        #expect(grown.size == CGSize(width: 200, height: 100))
        #expect(grown.maxX == 100 && grown.maxY == 50)
    }

    @Test func dragRectWorksInAnyDirection() {
        #expect(Geometry.rect(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 0, y: 20)) == CGRect(x: 0, y: 20, width: 10, height: 30))
    }
}
