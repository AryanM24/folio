import FolioKit
import SwiftUI

/// Size, format and zoom along the bottom of the window.
struct ImageStatusBar: View {
    let model: ImageEditorModel

    var body: some View {
        StatusBar {
            let source = model.source
            let output = model.geometry.outputSize
            Text("\(Int(source.pixelSize.width)) × \(Int(source.pixelSize.height)) px")
            if output != source.pixelSize {
                Text("→ \(Int(output.width)) × \(Int(output.height)) px")
            }
            Text(ByteCountFormatter.string(fromByteCount: Int64(source.data.count), countStyle: .file))
            Text(source.type.preferredFilenameExtension?.uppercased() ?? "Image")
            if model.recipe.stripMetadata {
                Text("Metadata removed on save")
            }
            Spacer()
            if model.comparing {
                HeroChip("Original", tone: .accent)
            } else if model.isEdited {
                HeroChip("Edited")
            }
            Text("\(Int((model.zoomScale * 100).rounded()))%")
        }
    }
}
