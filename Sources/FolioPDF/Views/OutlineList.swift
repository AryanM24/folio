import FolioKit
import PDFKit
import SwiftUI

/// The PDF's table of contents (its outline), as a native disclosure list.
struct OutlineList: View {
    let model: PDFEditorModel

    var body: some View {
        let nodes = OutlineNode.children(of: model.pdf.outlineRoot)
        if nodes.isEmpty {
            ContentUnavailableView(
                "No Table of Contents", systemImage: "list.bullet.indent",
                description: Text("This PDF doesn't include one.")
            )
        } else {
            List(nodes, children: \.children) { node in
                Button(node.label) { model.open(node.outline) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Hero.foreground)
                    .lineLimit(2)
                    .help(node.label)
            }
            .listStyle(.sidebar)
        }
    }
}

/// An outline entry wrapped for `List`, which needs identity and an optional
/// children key path.
struct OutlineNode: Identifiable {
    let outline: PDFOutline
    let children: [OutlineNode]?

    var id: ObjectIdentifier { ObjectIdentifier(outline) }
    var label: String { outline.label ?? "Untitled" }

    static func children(of outline: PDFOutline?) -> [OutlineNode] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let grandchildren = children(of: child)
            return OutlineNode(outline: child, children: grandchildren.isEmpty ? nil : grandchildren)
        }
    }
}

extension PDFEditorModel {
    /// Follows an outline entry, whether it stores a destination or a go-to action.
    func open(_ outline: PDFOutline) {
        if let destination = outline.destination {
            pdfView?.go(to: destination)
        } else if let action = outline.action {
            pdfView?.perform(action)
        }
        viewDidScroll()
    }
}
