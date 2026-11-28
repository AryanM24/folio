import FolioKit
public import SwiftUI

/// The preview window. A placeholder until the 0.3 Quick Look view (with Inspect, Convert
/// and Open With) lands; `Quartz` (`QLPreviewView`) is imported there, not at launch.
public struct PreviewView: View {
    let document: PreviewDocument

    public init(document: PreviewDocument) { self.document = document }

    public var body: some View {
        ContentUnavailableView(
            "Preview", systemImage: FileKind.preview.symbol, description: Text("Previews of this kind of file are coming in Folio 0.3."))
    }
}
