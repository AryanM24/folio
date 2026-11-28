import FolioKit
import SwiftUI

/// Size, format, the pixel under the pointer, the tool's hint and zoom along the bottom.
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
            Text(source.type.preferredFilenameExtension?.uppercased() ?? "Image")
            if model.recipe.stripMetadata {
                Text("Metadata removed on save")
            }
            CursorReadout(model: model)
            Spacer()
            Text(model.toolHint).lineLimit(1)
            if model.comparing {
                HeroChip("Original", tone: .accent)
            } else if model.isEdited {
                HeroChip("Edited")
            }
            Text("\(Int((model.zoomScale * 100).rounded()))%")
                .frame(minWidth: 36, alignment: .trailing)
        }
    }
}

/// The pointer's pixel and its color. Its own view, so pointer moves redraw only this.
private struct CursorReadout: View {
    let model: ImageEditorModel

    var body: some View {
        if let cursor = model.cursor {
            HStack(spacing: 6) {
                Text("x \(Int(cursor.point.x))  y \(Int(cursor.point.y))")
                if let color = cursor.color {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(cgColor: color.cgColor))
                        .frame(width: 10, height: 10)
                        .imageOutline(cornerRadius: 2)
                    Text(color.hex)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pointer at \(Int(cursor.point.x)), \(Int(cursor.point.y))\(cursor.color.map { ", color \($0.hex)" } ?? "")")
        }
    }
}
