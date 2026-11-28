import CoreGraphics
import Foundation

/// A saved look: any subset of the tone settings, applied to other images (and batches).
/// Geometry and content are never part of a preset, so it fits any image size.
nonisolated struct ImagePreset: Codable, Equatable, Sendable, Identifiable {
    static let version = 1

    var version = Self.version
    var id = UUID()
    var name: String
    /// `nil` fields leave the recipe's own value alone.
    var adjustments: Adjustments?
    var tone: ToneSpec?
    var filter: FilterPreset?
    var filterStrength: Double?
    /// LUT files the tone refers to, so a preset is self-contained.
    var assets: [AssetID: Data] = [:]

    /// `recipe` with this preset's settings in place of its own; LUTs go into `store`.
    /// White balance belongs to the photo, so a preset's tone keeps the recipe's.
    func applied(to recipe: EditRecipe, store: any AssetStore) throws -> EditRecipe {
        var out = recipe
        for data in assets.values { try store.put(data) }
        if let adjustments { out.adjustments = adjustments }
        if var tone {
            tone.whiteBalance = recipe.tone.whiteBalance
            out.tone = tone
        }
        if let filter { out.filter = filter }
        if let filterStrength { out.filterStrength = filterStrength }
        out.normalize()
        return out
    }
}

nonisolated extension ImagePreset {
    /// The current look of `recipe` (sliders, tone without white balance, filter), with
    /// its LUT file copied in from `store`.
    init(name: String, recipe: EditRecipe, store: any AssetStore) throws {
        var tone = recipe.tone
        tone.whiteBalance = nil
        self.init(
            name: name, adjustments: recipe.adjustments, tone: tone, filter: recipe.filter,
            filterStrength: recipe.filter == nil ? nil : recipe.filterStrength)
        if let lut = tone.lut { assets[lut.asset] = try store.data(lut.asset) }
    }

    /// Looks that ship with Folio. Tone only, so they stack on the Adjust sliders.
    static let builtIn: [ImagePreset] = {
        func look(_ index: Int, _ name: String, _ build: (inout ToneSpec) -> Void) -> ImagePreset {
            var tone = ToneSpec()
            build(&tone)
            let id = UUID(uuidString: String(format: "F0110000-0000-4000-8000-%012d", index))!
            return ImagePreset(id: id, name: name, tone: tone)
        }
        func points(_ values: (Double, Double)...) -> [CGPoint] { values.map { CGPoint(x: $0.0, y: $0.1) } }
        return [
            look(1, "Soft Contrast") { $0.curves.rgb = points((0, 0), (0.25, 0.21), (0.75, 0.80), (1, 1)) },
            look(2, "Matte") {
                $0.curves.rgb = points((0, 0.07), (0.25, 0.27), (0.75, 0.76), (1, 0.96))
                $0.hsl = [.orange: HSLShift(saturation: -10), .blue: HSLShift(saturation: -15), .green: HSLShift(saturation: -15)]
            },
            look(3, "Warm Film") {
                $0.curves.rgb = points((0, 0.04), (0.5, 0.52), (1, 0.97))
                $0.colorBalance.highlights = ColorShift(cyanRed: 8, yellowBlue: -14)
                $0.colorBalance.shadows = ColorShift(cyanRed: -4, yellowBlue: 6)
            },
            look(4, "Teal and Orange") {
                $0.curves.rgb = points((0, 0), (0.25, 0.22), (0.75, 0.78), (1, 1))
                $0.colorBalance.shadows = ColorShift(cyanRed: -16, yellowBlue: 14)
                $0.colorBalance.highlights = ColorShift(cyanRed: 12, yellowBlue: -12)
                $0.hsl = [.orange: HSLShift(saturation: 12), .aqua: HSLShift(hue: -20), .green: HSLShift(saturation: -25)]
            },
            look(5, "Cool Morning") {
                $0.curves.rgb = points((0, 0.02), (0.5, 0.54), (1, 1))
                $0.colorBalance.midtones = ColorShift(cyanRed: -6, yellowBlue: 10)
            },
            look(6, "Golden Hour") {
                $0.colorBalance.highlights = ColorShift(cyanRed: 14, yellowBlue: -18)
                $0.colorBalance.midtones = ColorShift(cyanRed: 4, yellowBlue: -6)
                $0.hsl = [.yellow: HSLShift(saturation: 15), .orange: HSLShift(saturation: 10, luminance: 8)]
            },
            look(7, "Classic B&W") {
                $0.channelMixer = ChannelMixer(red: .init(red: 0.4, green: 0.45, blue: 0.15), monochrome: true)
                $0.curves.rgb = points((0, 0), (0.25, 0.2), (0.75, 0.8), (1, 1))
            },
            look(8, "Faded B&W") {
                $0.channelMixer = ChannelMixer(red: .init(red: 0.3, green: 0.55, blue: 0.15), monochrome: true)
                $0.curves.rgb = points((0, 0.1), (0.5, 0.52), (1, 0.92))
            },
        ]
    }()
}

/// The user's presets, one JSON file each in
/// `~/Library/Application Support/Folio/Image Presets`.
nonisolated struct PresetLibrary: Sendable {
    let directory: URL

    static let shared = PresetLibrary(
        directory: URL.applicationSupportDirectory.appending(path: "Folio/Image Presets", directoryHint: .isDirectory))

    /// Every readable preset, by name. Files from a newer Folio are skipped.
    func load() -> [ImagePreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return
            files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ImagePreset.self, from: Data(contentsOf: $0)) }
            .filter { $0.version <= ImagePreset.version }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ preset: ImagePreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preset).write(to: url(preset), options: .atomic)
    }

    func delete(_ preset: ImagePreset) throws {
        try FileManager.default.removeItem(at: url(preset))
    }

    private func url(_ preset: ImagePreset) -> URL { directory.appending(path: "\(preset.id.uuidString).json") }
}
