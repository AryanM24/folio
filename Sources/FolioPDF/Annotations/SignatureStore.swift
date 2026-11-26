import AppKit
import FolioKit

/// The user's saved signature: drawn once, reused in every PDF.
///
/// Stored as a transparent PNG in `~/Library/Application Support/Folio/Signature.png`.
/// It never leaves the Mac, and *Clear Signature* deletes it.
enum SignatureStore {
    private static let log = Log.make("PDF")

    /// `directory` is injectable so tests don't touch the real signature.
    static func url(in directory: URL? = nil) -> URL {
        let base = directory ?? URL.applicationSupportDirectory.appending(path: "Folio", directoryHint: .isDirectory)
        return base.appending(path: "Signature.png")
    }

    static func load(from directory: URL? = nil) -> CGImage? {
        PageFactory.image(at: url(in: directory))
    }

    static func save(_ image: CGImage, in directory: URL? = nil) throws {
        let url = url(in: directory)
        guard let data = Rasterizer.encode(image, as: .png) else {
            throw FolioError("Folio couldn't save the signature.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        log.info("Saved signature")
    }

    static func clear(in directory: URL? = nil) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}
