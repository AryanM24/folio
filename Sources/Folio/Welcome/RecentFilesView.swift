import SwiftUI
import QuickLookThumbnailing
import FolioKit

/// Recent documents from the system list (File > Open Recent), with Quick Look thumbnails.
struct RecentFilesView: View {
    let open: (URL) -> Void
    @State private var urls: [URL] = []
    @State private var query = ""

    private var shown: [URL] {
        query.isEmpty ? urls : urls.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search recent files", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            if shown.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No recent files" : "No matches",
                    systemImage: "clock",
                    description: Text(query.isEmpty ? "Files you open appear here." : "Try a different name.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 18) {
                        ForEach(shown, id: \.self) { url in
                            RecentFileTile(url: url) { open(url) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear { urls = NSDocumentController.shared.recentDocumentURLs }
    }
}

private struct RecentFileTile: View {
    let url: URL
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit().padding(8)
                    } else {
                        Image(systemName: FileKind.kind(for: url)?.symbol ?? "doc")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: hovering ? 2 : 1)
                }
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path(percentEncoded: false))
        .contextMenu {
            Button("Open") { action() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task(id: url) { thumbnail = await Self.thumbnail(for: url) }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 200),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
