import AppKit
import FolioKit
import SwiftUI

/// Export As (format and quality), Copy and Share in one place.
struct ExportPopover: View {
    let model: ImageEditorModel
    @State private var format: ExportFormat = .png
    @State private var quality = 90.0
    @State private var shareAnchor: NSView?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
            HeroTabs(ExportFormat.allCases.map { ($0, $0.title, nil) }, selection: $format)
            if format.isLossy {
                HeroSlider("Quality", value: $quality, in: 40...100, format: { "\(Int($0))%" })
            } else {
                Text(format == .png ? "Lossless, keeps transparency." : "Lossless, large files, best for print.")
                    .font(.system(size: 12)).foregroundStyle(Hero.muted)
                    .frame(height: 46, alignment: .topLeading)
            }
            Button("Export…") {
                dismiss()
                model.export(format, quality: quality / 100)
            }
            .buttonStyle(.hero(.primary, fullWidth: true))
            .keyboardShortcut(.defaultAction)

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
            if let match = ExportFormat.allCases.first(where: { model.source.type.conforms(to: $0.type) }) { format = match }
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
