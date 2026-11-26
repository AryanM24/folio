import FolioKit
import PDFKit
import SwiftUI

/// The sidebar: page thumbnails or the document outline, switched with Hero tabs.
struct PDFSidebar: View {
    @Bindable var model: PDFEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HeroTabs(
                [(PDFEditorModel.SidebarTab.pages, "Pages", nil), (.outline, "Contents", nil)],
                selection: $model.sidebarTab
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Group {
                switch model.sidebarTab {
                case .pages: ThumbnailList(model: model)
                case .outline: OutlineList(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Lazily rendered page thumbnails with multi-select, drag to reorder, and page
/// commands in the context menu.
struct ThumbnailList: View {
    let model: PDFEditorModel
    /// Where a range selection (⇧-click) starts.
    @State private var anchor = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        ThumbnailRow(model: model, index: index, isSelected: isSelected(index))
                            .id(index)
                            .onTapGesture { click(index) }
                    }
                    // Drop target after the last page.
                    Color.clear.frame(height: 24)
                        .dropDestination(for: String.self) { items, _ in model.dropPages(items, before: model.pageCount) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { model.deleteSelectedPages() }
            .onMoveCommand { direction in
                switch direction {
                case .up: model.selectedPages = []; model.previousPage()
                case .down: model.selectedPages = []; model.nextPage()
                default: break
                }
            }
            .onChange(of: model.currentPageIndex) { _, index in
                withAnimation(Hero.animation) { proxy.scrollTo(index, anchor: .center) }
            }
            .accessibilityLabel("Page thumbnails")
        }
    }

    private func isSelected(_ index: Int) -> Bool {
        model.selectedPages.isEmpty ? index == model.currentPageIndex : model.selectedPages.contains(index)
    }

    /// Click goes to the page; ⌘-click toggles it in the selection; ⇧-click selects a range.
    private func click(_ index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var pages = model.selectedPages.isEmpty ? [model.currentPageIndex] : model.selectedPages
            if pages.contains(index) { pages.remove(index) } else { pages.insert(index) }
            model.selectedPages = pages
            anchor = index
        } else if flags.contains(.shift) {
            model.selectedPages = Set(min(anchor, index)...max(anchor, index))
        } else {
            model.selectedPages = []
            anchor = index
            model.go(toPage: index)
        }
    }
}

/// One thumbnail: the page on white paper, its number, a selection ring, and a drop
/// indicator above it while pages are dragged over.
struct ThumbnailRow: View {
    let model: PDFEditorModel
    let index: Int
    let isSelected: Bool
    @State private var image: NSImage?
    @State private var targeted = false

    private var page: PDFPage? { model.pdf.page(at: index) }

    var body: some View {
        VStack(spacing: 6) {
            paper
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: Hero.Radius.lg)
                        .strokeBorder(isSelected ? Hero.accent : .clear, lineWidth: 2)
                }
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Hero.accentSoftForeground : Hero.muted)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(isSelected ? Hero.accentSoft : .clear, in: .capsule)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .overlay(alignment: .top) {
            if targeted { Capsule().fill(Hero.accent).frame(height: 3).offset(y: -3) }
        }
        .draggable(String(index)) { paper.frame(width: 80) }
        .dropDestination(for: String.self) { items, _ in
            model.dropPages(items, before: index)
        } isTargeted: {
            targeted = $0
        }
        .contextMenu { PageContextMenu(model: model, index: index) }
        .task(id: taskKey) { await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.go(toPage: index) }
    }

    private var paper: some View {
        let size = page.map { Geometry.displaySize(crop: $0.bounds(for: .cropBox), rotation: $0.rotation) } ?? CGSize(width: 3, height: 4)
        return ZStack {
            Color.white
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
        }
        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
        .frame(maxWidth: 140, maxHeight: 180)
        .clipShape(.rect(cornerRadius: 2))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }

    /// Page identity plus revision: reloads after edits, cache hits make it free otherwise.
    private var taskKey: String {
        "\(page.map { ObjectIdentifier($0).hashValue } ?? 0)-\(model.revision)"
    }

    private func load() async {
        guard let page else { return }
        if let cached = model.thumbnails.cached(page) {
            image = cached
            return
        }
        image = await model.thumbnails.load(page, access: model.document.access, side: 180)
    }
}

/// Page commands for a thumbnail's context menu. Acts on the selection when the
/// clicked page is part of it, otherwise on the clicked page.
struct PageContextMenu: View {
    let model: PDFEditorModel
    let index: Int

    var body: some View {
        Group {
            Button("Rotate Left", systemImage: "rotate.left") { target { model.rotateLeft() } }
            Button("Rotate Right", systemImage: "rotate.right") { target { model.rotateRight() } }
            Divider()
            Button("Insert Blank Page After", systemImage: "doc.badge.plus") { target { model.insertBlankPage() } }
            Button("Duplicate", systemImage: "plus.square.on.square") { target { model.duplicateSelectedPages() } }
            Button("Extract to New PDF…", systemImage: "square.and.arrow.up") { target { Task { await model.extractSelectedPages() } } }
            Button("Recognize Text", systemImage: "text.viewfinder") { target { Task { await model.recognizeTextOnSelectedPages() } } }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { target { model.deleteSelectedPages() } }
        }
    }

    private func target(_ action: () -> Void) {
        if !model.selectedPages.contains(index) {
            model.selectedPages = []
            model.go(toPage: index)
        }
        action()
    }
}
