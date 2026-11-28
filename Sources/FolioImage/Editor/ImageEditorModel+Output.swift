import AppKit
import FolioKit
import UniformTypeIdentifiers

/// Formats offered by Export As.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic, tiff
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
    var isLossy: Bool { ImageCodec.isLossy(type) }
}

/// Getting the edited image out: Export As, Copy, Share, and the color sampler.
extension ImageEditorModel {
    /// File name without extension, for exports.
    var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Image"
    }

    func export(_ format: ExportFormat, quality: Double) {
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        let type = format.type
        Task {
            await Exporter.save(suggestedName: baseName, type: type) {
                try await Task.detached(priority: .userInitiated) {
                    try ImageSaver.data(for: source, recipe: recipe, assets: assets, as: type, quality: format.isLossy ? quality : nil)
                }.value
            }
        }
    }

    /// Put the edited image on the clipboard as PNG (keeps transparency) and TIFF.
    func copyImage() {
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        runBusy("Copying…") {
            do {
                let png = try await Task.detached(priority: .userInitiated) {
                    try ImageSaver.data(for: source, recipe: recipe, assets: assets, as: .png)
                }.value
                let board = NSPasteboard.general
                board.clearContents()
                board.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
                self.showToast("Image copied")
            } catch {
                self.show(error, title: "Couldn't copy the image")
            }
        }
    }

    /// Show the system share sheet for the edited image, anchored to `view`.
    func share(from view: NSView) {
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        let type = ImageCodec.canWrite(source.type) ? source.type : .png
        let name = baseName
        runBusy("Preparing…") {
            do {
                let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    let data = try ImageSaver.data(for: source, recipe: recipe, assets: assets, as: type)
                    let folder = URL.temporaryDirectory.appending(path: "Folio Share \(UUID().uuidString)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appending(path: "\(name).\(type.preferredFilenameExtension ?? "png")")
                    try data.write(to: url, options: .atomic)
                    return url
                }.value
                let picker = NSSharingServicePicker(items: [url])
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch {
                self.show(error, title: "Couldn't share the image")
            }
        }
    }

    /// The system magnifier: pick any pixel on screen, copy its hex value, and use it
    /// as the markup color.
    func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let rgb = color?.usingColorSpace(.sRGB) else { return }
            let picked = RGBA(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            Task { @MainActor in self?.usePickedColor(picked) }
        }
    }

    private func usePickedColor(_ picked: RGBA) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(picked.hex, forType: .string)
        setMarkupColor(picked)
        showToast("Copied \(picked.hex)")
    }
}
