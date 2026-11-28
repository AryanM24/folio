import AppKit
import FolioKit
import SwiftUI

/// Export (format, quality, size, metadata), batch export with the same settings,
/// animation frames, Copy and Share in one place.
///
/// Entry points on the model: `export(_:)` with `ExportOptions`, `batchExport(_:)` and
/// `exportFrames()`.
struct ExportPopover: View {
    let model: ImageEditorModel
    @State private var format: ExportFormat = .png
    @State private var quality = 90.0
    @State private var sizeMode: SizeMode = .original
    @State private var longEdge = 2048
    @State private var percent = 50
    @State private var megabytes = 2.0
    @State private var stripMetadata = false
    @State private var shareAnchor: NSView?
    @Environment(\.dismiss) private var dismiss

    enum SizeMode: String, CaseIterable, Identifiable {
        case original, longEdge, percent, fileSize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: "Original size"
            case .longEdge: "Long edge"
            case .percent: "Percentage"
            case .fileSize: "File size"
            }
        }
    }

    /// The choices as export settings.
    var options: ExportOptions {
        let size: ExportOptions.Size =
            switch sizeMode {
            case .original: .original
            case .longEdge: .longEdge(max(1, longEdge))
            case .percent: .percent(Double(max(1, percent)))
            case .fileSize: .maxBytes(max(10_000, Int(megabytes * 1_000_000)))
            }
        return ExportOptions(format: format, quality: quality / 100, size: size, stripMetadata: stripMetadata)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
            Picker("Format", selection: $format) {
                ForEach(ExportFormat.available) { Text($0.title).tag($0) }
            }
            if format.isLossy {
                HeroSlider("Quality", value: $quality, in: 40...100, format: { "\(Int($0))%" })
            } else {
                Text(note).font(.system(size: 12)).foregroundStyle(Hero.muted).fixedSize(horizontal: false, vertical: true)
            }
            if format != .psd {
                Picker("Size", selection: $sizeMode) {
                    ForEach(SizeMode.allCases) { Text($0.title).tag($0) }
                }
                sizeField
            }
            Toggle("Remove location and metadata", isOn: $stripMetadata).toggleStyle(.hero)
            Button("Export…") {
                dismiss()
                model.export(options)
            }
            .buttonStyle(.hero(.primary, fullWidth: true))
            .keyboardShortcut(.defaultAction)

            Button("Apply Look to Other Images…") {
                dismiss()
                model.batchExport(options)
            }
            .buttonStyle(.hero(.secondary, size: .sm, fullWidth: true))
            .help("Applies this image’s adjustments, tone and filter, then exports with these settings")
            if model.isAnimated {
                Button("Export Frames…") {
                    dismiss()
                    model.exportFrames()
                }
                .buttonStyle(.hero(.secondary, size: .sm, fullWidth: true))
            }

            HStack(spacing: 8) {
                Button("Copy Image", systemImage: "doc.on.doc") {
                    dismiss()
                    model.copyImage()
                }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                Button("Share…", systemImage: "square.and.arrow.up") {
                    if let shareAnchor { model.share(from: shareAnchor) }
                }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                .background(ViewAnchor(view: $shareAnchor))
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Hero.overlay)
        .onAppear {
            if let match = ExportFormat.available.first(where: { model.source.type.conforms(to: $0.type) }) { format = match }
            stripMetadata = model.recipe.stripMetadata
        }
    }

    private var note: String {
        switch format {
        case .png: "Lossless, keeps transparency."
        case .psd: "Layers keep their names, blend modes and opacity. Adjustment and retouch layers are merged."
        case .gif: model.isAnimated ? "Every frame, with its timing." : "256 colors."
        case .exr: "Lossless, for compositing."
        default: "Lossless, large files, best for print."
        }
    }

    @ViewBuilder private var sizeField: some View {
        switch sizeMode {
        case .original: EmptyView()
        case .longEdge:
            LabeledContent("Pixels") { TextField("Pixels", value: $longEdge, format: .number).textFieldStyle(.hero) }
        case .percent:
            LabeledContent("Percent") { TextField("Percent", value: $percent, format: .number).textFieldStyle(.hero) }
        case .fileSize:
            LabeledContent("At most (MB)") {
                TextField("MB", value: $megabytes, format: .number.precision(.fractionLength(0...1))).textFieldStyle(.hero)
            }
        }
    }
}

/// Exposes the AppKit view behind a SwiftUI view, to anchor AppKit popovers
/// such as the share picker.
struct ViewAnchor: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
