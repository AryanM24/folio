import SwiftUI
import QuickLookThumbnailing
import FolioKit

/// Recent documents from the system list (File › Open Recent), with Quick Look thumbnails.
///
/// Reading the list is instant; thumbnails load lazily per tile, so this never slows
/// down launch.
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
                .textFieldStyle(.hero)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            if shown.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No recent files" : "No matches",
                    systemImage: query.isEmpty ? "clock" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Files you open appear here." : "Try a different name.")
                )
                .foregroundStyle(Hero.muted)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 16)], spacing: 20) {
                        ForEach(shown, id: \.self) { url in
                            RecentFileTile(url: url) { open(url) }
                        }
                    }
                    .padding(24)
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
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: FileKind.kind(for: url)?.symbol ?? "doc")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Hero.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .background(Hero.surface, in: .rect(cornerRadius: Hero.Radius.xxl))
                .overlay {
                    RoundedRectangle(cornerRadius: Hero.Radius.xxl)
                        .strokeBorder(hovering ? Hero.accent : Hero.border, lineWidth: hovering ? 2 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Hero.foreground)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(Hero.muted)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
            }
            .scaleEffect(hovering ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
        .help(url.path(percentEncoded: false))
        .accessibilityLabel("Open \(url.lastPathComponent)")
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
