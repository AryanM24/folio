import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import FolioConvert
import FolioKit
import SwiftUI
import Testing

@testable import Folio

/// Renders the Convert panel, the shelf popover and result cards to PNGs, with sample data.
/// Off by default; README screenshots come from:
/// `FOLIO_CONVERT_SNAPSHOTS=build/snapshots make test` (add `FOLIO_APPEARANCE=dark` for dark).
@Suite("Convert snapshots", .enabled(if: ProcessInfo.processInfo.environment["FOLIO_CONVERT_SNAPSHOTS"] != nil))
struct ConvertSnapshotTests {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLIO_CONVERT_SNAPSHOTS"] ?? "/tmp")
    let dark = ProcessInfo.processInfo.environment["FOLIO_APPEARANCE"] == "dark"
    let downloads = URL(fileURLWithPath: "/Users/you/Downloads")

    @Test func panel() async throws {
        let inputs = ["Photo.png", "Beach.png", "Receipt.png"].map { downloads.appending(path: $0) }
        let targets = [
            Target(to: .png, fidelity: .lossless, losslessAvailable: true),
            Target(to: .heic, fidelity: .visuallyLossless, losslessAvailable: false),
            Target(to: .jpeg, fidelity: .lossy, losslessAvailable: false),
            Target(to: .avif, fidelity: .visuallyLossless, losslessAvailable: false),
            Target(to: .webp, fidelity: .visuallyLossless, losslessAvailable: false),
            Target(to: .tiff, fidelity: .lossless, losslessAvailable: true),
            Target(to: .gif, fidelity: .lossy, losslessAvailable: false, drops: ["colours beyond 256"]),
            Target(to: .jxl, fidelity: .lossless, losslessAvailable: true),
        ]
        let choice = ConvertChoice(target: .heic, quality: .balanced, maxMegabytes: 10, stripMetadata: true)
        try await write(ConvertPanel(inputs: inputs, targets: targets, choice: choice), "convert-panel")
    }

    @Test func shelf() async throws {
        let history = ConvertHistory()
        history.add([
            ConvertRow(name: "Q3 report.pdf", output: downloads.appending(path: "Q3 report.pdf"), bytesIn: 2_400_000, bytesOut: 1_900_000),
            ConvertRow(
                name: "Launch clip.mp4", output: downloads.appending(path: "Launch clip.mp4"), bytesIn: 212_000_000, bytesOut: 38_400_000),
            ConvertRow(name: "Photo.heic", output: downloads.appending(path: "Photo.heic"), bytesIn: 18_900_000, bytesOut: 4_100_000),
        ])
        try await write(ShelfView(history: history).heroOverlay(cornerRadius: Hero.Radius.xxxl), "shelf")
    }

    @Test func resultCards() async throws {
        let photo = ConvertRow(
            name: "Photo.heic", output: downloads.appending(path: "Photo.heic"), bytesIn: 18_900_000, bytesOut: 4_100_000,
            fidelity: .visuallyLossless, durationMs: 420)
        try await write(ResultCardView(model: ResultCardModel(count: 1, rows: [photo], thumbnail: sampleThumbnail())), "result-card")

        let many = [
            photo,
            ConvertRow(
                name: "Beach.heic", output: downloads.appending(path: "Beach.heic"), bytesIn: 9_800_000, bytesOut: 2_200_000,
                fidelity: .visuallyLossless, durationMs: 380),
            ConvertRow(
                name: "Receipt.png", bytesIn: 1_200_000, failed: true, message: "The file is damaged",
                hint: "Open it in Folio and save a fresh copy"),
        ]
        try await write(ResultCardView(model: ResultCardModel(count: 3, rows: many, thumbnail: sampleThumbnail())), "result-card-many")

        let running = ResultCardModel(count: 3)
        running.fraction = 0.42
        try await write(ResultCardView(model: running), "result-card-running")

        let failed = ConvertRow(
            name: "the clipboard", bytesIn: 0, failed: true, message: "The clipboard has no image", hint: "Copy an image, then try again")
        try await write(ResultCardView(model: ResultCardModel(count: 1, rows: [failed])), "result-card-error")
    }

    /// The photo from the image editor screenshot, cropped out of its window.
    private func sampleThumbnail() -> NSImage? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/image-dark.png")
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let crop = image.cropping(to: CGRect(x: 170, y: 130, width: 852, height: 852))
        else { return nil }
        return NSImage(cgImage: crop, size: CGSize(width: 112, height: 112))
    }

    /// Draws through AppKit (like WindowSnapshots), so text fields render, at 2x.
    private func write<V: View>(_ view: V, _ name: String) async throws {
        let root = view.padding(24).background(Hero.background).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name + (dark ? "-dark" : "") + ".png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
    }
}
