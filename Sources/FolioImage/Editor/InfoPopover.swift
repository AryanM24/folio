import FolioKit
import ImageIO
import SwiftUI

/// Dimensions, file size, color profile and camera details, plus the switch that
/// removes location and metadata on save.
struct InfoPopover: View {
    let model: ImageEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Image info").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(ImageInfo.rows(for: model.source, output: model.geometry.outputSize), id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(Hero.muted)
                        Text(row.value).foregroundStyle(Hero.foreground).textSelection(.enabled)
                    }
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()

            Rectangle().fill(Hero.separator).frame(height: 1)
            Toggle(isOn: Binding(get: { model.recipe.stripMetadata }, set: { _ in model.toggleStripMetadata() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove location and metadata")
                    Text("Applies when the file is saved.")
                        .font(.system(size: 12)).foregroundStyle(Hero.muted)
                }
            }
            .toggleStyle(.hero)
        }
        .padding(16)
        .frame(width: 320)
        .background(Hero.overlay)
    }
}

/// Human-readable facts about an image, from ImageIO properties.
nonisolated enum ImageInfo {
    struct Row: Sendable { let label: String; let value: String }

    static func rows(for source: SourceImage, output: CGSize) -> [Row] {
        let p = source.properties
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var rows: [Row] = []
        let w = Int(source.pixelSize.width), h = Int(source.pixelSize.height)
        rows.append(Row(label: "Dimensions", value: "\(w) × \(h) px (\(megapixels(source.pixelSize)))"))
        if Int(output.width) != w || Int(output.height) != h {
            rows.append(Row(label: "After edits", value: "\(Int(output.width)) × \(Int(output.height)) px"))
        }
        rows.append(Row(label: "File size", value: ByteCountFormatter.string(fromByteCount: Int64(source.data.count), countStyle: .file)))
        rows.append(Row(label: "Format", value: source.type.localizedDescription ?? source.type.identifier))
        rows.append(
            Row(
                label: "Color profile",
                value: (p[kCGImagePropertyProfileName as String] as? String) ?? (source.colorSpace.name as String?)?.replacingOccurrences(
                    of: "kCGColorSpace", with: "") ?? "Unknown"))
        rows.append(
            Row(label: "Bit depth", value: "\(source.bitsPerComponent) bits per channel\(source.hasAlpha ? ", with transparency" : "")"))
        if source.frameCount > 1 { rows.append(Row(label: "Frames", value: "\(source.frameCount) (edits use the first)")) }
        let camera = [tiff[kCGImagePropertyTIFFMake as String] as? String, tiff[kCGImagePropertyTIFFModel as String] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        if !camera.isEmpty { rows.append(Row(label: "Camera", value: camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String { rows.append(Row(label: "Lens", value: lens)) }
        var exposure: [String] = []
        if let f = exif[kCGImagePropertyExifFocalLength as String] as? Double { exposure.append("\(Int(f.rounded())) mm") }
        if let a = exif[kCGImagePropertyExifFNumber as String] as? Double { exposure.append(String(format: "ƒ/%.1f", a)) }
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double { exposure.append(shutter(t)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { rows.append(Row(label: "Exposure", value: exposure.joined(separator: " · "))) }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String { rows.append(Row(label: "Taken", value: date)) }
        rows.append(Row(label: "Location", value: p[kCGImagePropertyGPSDictionary as String] == nil ? "None" : "Included"))
        return rows
    }

    static func megapixels(_ size: CGSize) -> String {
        String(format: "%.1f MP", size.width * size.height / 1_000_000)
    }

    static func shutter(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.1f s", seconds) : "1/\(Int((1 / seconds).rounded())) s"
    }
}
