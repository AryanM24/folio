import FolioKit
import SwiftUI
import UniformTypeIdentifiers

/// One file as a card: a Quick Look thumbnail in a soft well, the name, and a quiet
/// line of kind, date and size. Selected cards get an accent ring; favorites a star.
///
/// The thumbnail loads in `.task` when the card first appears (the grid is lazy), from
/// the shared cache when possible; until then the kind's symbol stands in.
struct FileCard: View {
    let model: WorkspaceModel
    let item: FileItem
    let selected: Bool
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    static let previewHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                if model.renaming == item.url {
                    RenameField(model: model, item: item)
                } else {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Hero.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    KindIcon(item: item, size: 11)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Hero.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
        .padding(8)
        .background(Hero.surface, in: .rect(cornerRadius: Hero.Radius.xxxl))
        .overlay {
            RoundedRectangle(cornerRadius: Hero.Radius.xxxl)
                .strokeBorder(
                    selected ? Hero.accent : (scheme == .dark ? Hero.border : .clear),
                    lineWidth: selected ? 2 : 1)
        }
        .heroSurfaceShadow()
        .contentShape(.rect(cornerRadius: Hero.Radius.xxxl))
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
        .animation(Hero.animation, value: selected)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            FileMenu(model: model, items: model.selection.contains(item.url) ? model.selectedItems : [item])
        }
        .task(id: item.modified) {
            thumbnail = ThumbnailCache.shared.cached(item)
            if thumbnail == nil {
                thumbnail = await ThumbnailCache.shared.load(item, size: CGSize(width: 320, height: Self.previewHeight * 1.4))
            }
        }
        .help(item.url.path(percentEncoded: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.kindTitle), \(subtitle)\(item.isFavorite ? ", favorite" : "")")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.open([item]) }
    }

    /// Images and videos fill the preview well; documents sit in it like a page.
    private var fillsWell: Bool {
        item.kind == .image || (item.kind == .media && UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .movie) == true)
    }

    private var subtitle: String {
        let date = RelativeDate.string(for: item.activityDate)
        guard let size = item.size else { return date }
        return "\(date) · \(formattedSize(size))"
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Hero.Radius.xxl)
                .fill(Hero.surfaceSecondary)
            if let thumbnail, fillsWell {
                // Photos and video frames fill the well, like Photos' square grid. The
                // overlay keeps the image's size from widening the card.
                Color.clear
                    .overlay { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    .clipShape(.rect(cornerRadius: Hero.Radius.xxl))
            } else if let thumbnail, item.kind == .media {
                // Audio gets a document-style icon; show it at icon size.
                Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 64, height: 64)
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 3))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 3, y: 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .offset(y: hovering ? -2 : 0)
            } else {
                Image(systemName: item.isFolder ? "folder.fill" : item.kind?.symbol ?? "doc")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Hero.muted.opacity(0.7))
            }
        }
        .frame(height: Self.previewHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Hero.warning)
                    .frame(width: 22, height: 22)
                    .background(Hero.overlay, in: .circle)
                    .heroSurfaceShadow()
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The bar that floats in when two or more files are selected.
struct BulkActionBar: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let items = model.selectedItems
        HeroToolbar {
            Text("\(items.count) selected")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Hero.foreground)
                .padding(.horizontal, 12)
            HeroToolbarDivider()
            Button("Open", systemImage: "arrow.up.forward.app") { model.openSelection() }
                .help("Open all ⌘↓")
            Button(items.allSatisfy(\.isFavorite) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                model.toggleFavorite()
            }
            .help("Favorite ⌘L")
            MoveMenu(model: model)
            ShareLink(items: items.map(\.url)) { Label("Share", systemImage: "square.and.arrow.up") }
                .help("Share")
            Button("Move to Trash", systemImage: "trash") { model.trashSelection() }
                .help("Move to Trash ⌘⌫")
            HeroToolbarDivider()
            Button("Clear Selection", systemImage: "xmark") { model.selection = [] }
                .help("Clear selection (Esc)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
    }
}

/// Move to › the library or any added location.
struct MoveMenu: View {
    let model: WorkspaceModel

    var body: some View {
        Menu {
            ForEach([model.libraryURL] + model.locations, id: \.self) { folder in
                Button(model.displayName(folder)) { model.moveSelection(to: folder) }
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .fixedSize()
        .help("Move to…")
    }
}
