import AppKit
import FolioKit
import UniformTypeIdentifiers

/// Getting the edited image out: Export As, batch export, animation frames, Copy, Share,
/// and the color sampler.
extension ImageEditorModel {
    /// File name without extension, for exports.
    var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Image"
    }

    /// The source has more than one frame (GIF, APNG, animated WebP, HEICS).
    var isAnimated: Bool { source.frameCount > 1 }

    func export(_ format: ExportFormat, quality: Double) {
        export(ExportOptions(format: format, quality: quality))
    }

    /// Ask where to save, then write the edited image with `options`.
    func export(_ options: ExportOptions) {
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        Task {
            await Exporter.save(suggestedName: baseName, type: options.format.type) {
                try await offCooperativePool { try ImageSaver.export(source, recipe: recipe, assets: assets, options: options) }
            }
        }
    }

    /// Apply this image’s look (sliders, tone, filter; never geometry, which belongs to the
    /// photo) and `options` to images the user picks, writing each next to its original.
    func batchExport(_ options: ExportOptions) {
        let preset: ImagePreset
        do {
            preset = try ImagePreset(name: baseName, recipe: document.recipe, store: document.assets)
        } catch {
            show(error, title: "Couldn’t read this image’s look")
            return
        }
        Task {
            let urls = await Exporter.pick(types: FileKind.image.readableTypes)
            guard !urls.isEmpty else { return }
            runBusy("Exporting \(urls.count) images…") {
                do {
                    let written = try await ImageToolOps.applyPreset(preset, options: options, to: urls)
                    self.showToast("Exported \(written.count) \(written.count == 1 ? "image" : "images")")
                } catch {
                    self.show(error, title: "Couldn’t export the images")
                }
            }
        }
    }

    /// Write every frame of an animation, edits applied, as numbered PNGs in a folder the user picks.
    func exportFrames() {
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        let name = baseName
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export Frames"
            let response = await withCheckedContinuation { c in panel.begin { c.resume(returning: $0) } }
            guard response == .OK, let folder = panel.url else { return }
            runBusy("Exporting frames…") {
                do {
                    let count = try await offCooperativePool {
                        let animation = try AnimatedImage(data: ImageSaver.data(for: source, recipe: recipe, assets: assets, as: .png))
                        let files = try animation.frameFiles()
                        for (index, data) in files.enumerated() {
                            let url = folder.appending(path: "\(name) frame \(String(format: "%03d", index + 1)).png")
                            try data.write(to: url, options: .atomic)
                        }
                        return files.count
                    }
                    self.showToast("Exported \(count) frames")
                } catch {
                    self.show(error, title: "Couldn’t export the frames")
                }
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
