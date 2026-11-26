public import AppKit
public import UniformTypeIdentifiers

/// Writes data the user asked to export ("Export As…", tool output) through a save panel.
///
/// Document saving is *not* done here: documents save themselves through
/// `ReferenceFileDocument` autosave. This is only for producing new files.
public enum Exporter {
    /// Ask where to save, then write the bytes atomically.
    ///
    /// - Parameters:
    ///   - suggestedName: File name without extension; the type's extension is appended.
    ///   - type: Content type of the output, used for the extension and the panel filter.
    ///   - window: Present as a sheet on this window when given.
    ///   - produce: Builds the bytes. Runs after the user picks a destination, so slow
    ///     exports don't block the panel. Throwing shows an alert.
    /// - Returns: The URL written, or `nil` if the user cancelled.
    @discardableResult
    public static func save(
        suggestedName: String,
        type: UTType,
        window: NSWindow? = NSApp.keyWindow,
        produce: @escaping @Sendable () async throws -> Data
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { c in panel.begin { c.resume(returning: $0) } }
        }
        guard response == .OK, let url = panel.url else { return nil }
        do {
            let data = try await produce()
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Alert.show(error, title: "Couldn't export “\(url.lastPathComponent)”", window: window)
            return nil
        }
    }

    /// Ask for one or more files to read (tools, "Insert Image…").
    public static func pick(types: [UTType], multiple: Bool = true, window: NSWindow? = NSApp.keyWindow) async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { c in panel.begin { c.resume(returning: $0) } }
        }
        return response == .OK ? panel.urls : []
    }
}

/// Error presentation in the native style.
public enum Alert {
    public static func show(_ error: any Error, title: String, window: NSWindow? = NSApp.keyWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// An error with a message written for people, not developers.
public nonisolated struct FolioError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
