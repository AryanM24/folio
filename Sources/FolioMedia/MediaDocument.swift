public import SwiftUI
public import UniformTypeIdentifiers
public import FolioKit

/// Placeholder document for the media editor. Holds the file's bytes unchanged.
///
/// Replaced by the real implementation; kept minimal so the app target links.
public final class MediaDocument: ReferenceFileDocument {
    public typealias Snapshot = Data

    public nonisolated static var readableContentTypes: [UTType] { FileKind.media.readableTypes }

    @Published var data: Data

    public nonisolated init() { data = Data() }

    public nonisolated init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = bytes
    }

    public func snapshot(contentType: UTType) throws -> Data { data }

    public nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}

/// Placeholder editor view.
public struct MediaEditorView: View {
    @ObservedObject private var document: MediaDocument
    public init(document: MediaDocument) { self.document = document }

    public var body: some View {
        ContentUnavailableView("media editor", systemImage: FileKind.media.symbol, description: Text("\(document.data.count) bytes"))
    }
}
