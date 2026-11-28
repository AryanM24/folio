import FolioKit
public import SwiftUI
public import UniformTypeIdentifiers

/// A `.folio-video` project: a small JSON file that references media, never contains it.
///
/// The project lives in `store` (`ProjectStore`), and every change goes through
/// `store.edit`, which registers undo and so triggers autosave and Versions. Mount it with
/// `DocumentGroup(newDocument: { VideoProjectDocument() })`.
public final class VideoProjectDocument: ReferenceFileDocument {
    /// A copy of the project for a background save. `Project` is a value, so taking it is O(1).
    public struct Snapshot: Sendable {
        let project: Project
    }

    public nonisolated static var readableContentTypes: [UTType] { [.folioVideoProject] }

    let store: ProjectStore

    /// A new, empty project: 1080p, 30 fps, one video and one audio track.
    public nonisolated init() {
        store = ProjectStore(project: Project())
    }

    /// Opens a prepared project ("Edit in Timeline").
    nonisolated init(project: Project) {
        store = ProjectStore(project: project)
    }

    public nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw FolioError("This video project couldn't be read. It may be a folder or an alias that no longer points anywhere.")
        }
        store = ProjectStore(project: try ProjectFile.decode(data))
    }

    /// Runs on AppKit's save thread with the main thread parked; see `readDuringSave`.
    public nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
        readDuringSave { Snapshot(project: store.project) }
    }

    public nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ProjectFile.encode(snapshot.project))
    }
}

/// Reading and writing the `.folio-video` JSON.
nonisolated enum ProjectFile {
    /// Sorted keys and indentation, so two versions of a project diff cleanly.
    static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project)
    }

    static func decode(_ data: Data) throws -> Project {
        struct Header: Decodable { var version: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw FolioError("This file isn't a Folio video project, or it's damaged.")
        }
        guard header.version <= Project.currentVersion else {
            throw FolioError(
                "This project was saved by a newer version of Folio (project format \(header.version)). Update Folio to open it.")
        }
        do {
            return try decoder.decode(Project.self, from: data)
        } catch {
            throw FolioError("This video project is damaged and couldn't be opened. \(describe(error))")
        }
    }

    /// Where decoding failed, in words: "Problem at tracks.0.clips.3.start."
    private static func describe(_ error: any Error) -> String {
        let context: DecodingError.Context? =
            switch error as? DecodingError {
            case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): c
            default: nil
            }
        guard let context, !context.codingPath.isEmpty else { return "" }
        return "Problem at \(context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: "."))."
    }
}
