public import Foundation
public import UniformTypeIdentifiers

/// A one-step file operation: "Combine PDFs", "Convert images to PDF", "Extract audio".
///
/// Tools are declared by the editor modules that own the format (PDF tools live in
/// `FolioPDF`, image tools in `FolioImage`) and surfaced in three places:
///
/// 1. The workspace's Tools view (click a card, or drop files on it), and each
///    file's Tools › context menu.
/// 2. Finder > Quick Actions and the Services menu, via `NSServices` in Info.plist.
///    The service's `NSUserData` is the tool's ``id``.
/// 3. `File > Tools` in the menu bar.
///
/// A tool never modifies its inputs. It writes new files next to the first input
/// (or wherever ``Output`` says) and returns their URLs so Folio can reveal or open them.
public nonisolated struct FolioTool: Identifiable, Sendable {
    /// Stable identifier, also used as the Services `NSUserData`. Format: `"<module>.<verb>"`.
    public let id: String
    public let title: String
    public let subtitle: String
    /// SF Symbol name.
    public let symbol: String
    /// Inputs must conform to one of these.
    public let inputTypes: [UTType]
    /// Minimum number of input files (e.g. 2 for "Combine PDFs").
    public let minimumInputs: Int
    /// Optional options UI shown before running. `nil` runs immediately.
    public let options: [Option]
    public let run: @Sendable (_ inputs: [URL], _ options: [String: String]) async throws -> [URL]

    public init(
        id: String,
        title: String,
        subtitle: String,
        symbol: String,
        inputTypes: [UTType],
        minimumInputs: Int = 1,
        options: [Option] = [],
        run: @escaping @Sendable (_ inputs: [URL], _ options: [String: String]) async throws -> [URL]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.inputTypes = inputTypes
        self.minimumInputs = minimumInputs
        self.options = options
        self.run = run
    }

    /// A choice the user makes before the tool runs, e.g. output format or quality.
    public struct Option: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let choices: [(value: String, label: String)]
        public let defaultValue: String
        public init(id: String, label: String, choices: [(value: String, label: String)], defaultValue: String) {
            self.id = id
            self.label = label
            self.choices = choices
            self.defaultValue = defaultValue
        }
    }

    public func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return inputTypes.contains { type.conforms(to: $0) }
    }
}

public nonisolated extension FolioTool {
    /// Where tools write results: next to the first input, never overwriting.
    ///
    /// `unique(in:name:ext:)` appends " 2", " 3"… like Finder does.
    nonisolated static func outputURL(nextTo input: URL, name: String, ext: String) -> URL {
        unique(in: input.deletingLastPathComponent(), name: name, ext: ext)
    }

    /// An empty `ext` gives a name with no extension (folders).
    nonisolated static func unique(in folder: URL, name: String, ext: String) -> URL {
        let fm = FileManager.default
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = folder.appending(path: "\(name)\(suffix)")
        var n = 2
        while fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(name) \(n)\(suffix)")
            n += 1
        }
        return candidate
    }
}
