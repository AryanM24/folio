import AppKit
import FolioConvert
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar Drop Shelf: the Folio glyph in the status bar. Drop files on it, or into
/// its popover, to open the Convert panel; the popover also lists the last few results.
///
/// Shown by default. "Hide from menu bar" lives in the popover (Settings belongs to another
/// pane); ⌘K › "Show Drop Shelf in menu bar" brings it back.
final class ShelfController: NSObject, NSDraggingDestination {
    static let shared = ShelfController()
    static let key = "convert.showShelf"

    private var item: NSStatusItem?
    private let popover = NSPopover()

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            shared.update()
        }
    }

    /// Adds or removes the status item to match the setting.
    func update() {
        if Self.isEnabled, item == nil {
            install()
        } else if !Self.isEnabled, let item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = Self.glyph
        button.setAccessibilityLabel("Folio Drop Shelf")
        button.toolTip = "Drop files to convert"
        button.target = self
        button.action = #selector(toggle(_:))
        // The status button's window forwards drags to its delegate; the button itself can't be subclassed.
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(
            rootView: ShelfView(history: .shared) { [weak self] urls in
                self?.convert(urls)
            } hide: {
                ShelfController.isEnabled = false
            })
        self.item = item
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func convert(_ urls: [URL]) {
        popover.performClose(nil)
        ConvertFlow.present(urls)
    }

    // MARK: Drops on the status item

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        item?.button?.highlight(true)
        return fileURLs(sender).isEmpty ? [] : .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) { item?.button?.highlight(false) }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        item?.button?.highlight(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        convert(urls)
        return true
    }

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// The folded F from the brand shapes, as an 18 pt template image; the fold at half
    /// opacity keeps it readable once the menu bar tints it.
    static var glyph: NSImage {
        let mark = ZStack {
            FolioGlyphSheet().fill(.black)
            FolioGlyphFold().fill(.black.opacity(0.5))
        }
        // The glyph fills about 55 % of its 64-unit tile; a 29 pt tile makes it 16 pt tall.
        .frame(width: 29, height: 29)
        .frame(width: 18, height: 18)
        let renderer = ImageRenderer(content: mark)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
        image.isTemplate = true
        image.accessibilityDescription = "Folio"
        return image
    }
}

extension ShelfController: NSWindowDelegate {}

/// The shelf's popover: a drop zone, recent results and the hide switch.
struct ShelfView: View {
    var history: ConvertHistory
    var drop: ([URL]) -> Void = { _ in }
    var hide: () -> Void = {}
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dropZone.padding(12)
            Text("Recent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Hero.muted)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            if history.rows.isEmpty {
                Text("Converted files show up here")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.rows) { row in RecentRow(row: row) }
                }
                .padding(.horizontal, 8)
            }
            Rectangle().fill(Hero.separator).frame(height: 1).padding(.top, 8)
            HStack(spacing: 4) {
                Button("Open Folio", action: ConvertFlow.showWorkspace)
                    .buttonStyle(.hero(.ghost, size: .sm))
                Spacer()
                Button("Hide from menu bar", action: hide)
                    .buttonStyle(.hero(.ghost, size: .sm))
                    .help("Bring it back from ⌘K › Show Drop Shelf in menu bar")
            }
            .padding(8)
        }
        .frame(width: 296)
    }

    private var dropZone: some View {
        Button {
            ConvertFlow.present([])
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 18))
                    .foregroundStyle(targeted ? Hero.accentSoftForeground : Hero.muted)
                    .padding(.bottom, 4)
                Text("Drop files to convert")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(targeted ? Hero.accentSoftForeground : Hero.foreground)
                Text("or click to choose")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .background(targeted ? Hero.accentSoft : Hero.surfaceSecondary, in: .rect(cornerRadius: Hero.Radius.xl))
            .overlay {
                RoundedRectangle(cornerRadius: Hero.Radius.xl)
                    .strokeBorder(targeted ? Hero.accent : Hero.border, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6, 4]))
            }
            .contentShape(.rect(cornerRadius: Hero.Radius.xl))
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls)
            return !urls.isEmpty
        } isTargeted: {
            targeted = $0
        }
        .accessibilityLabel("Choose files to convert")
    }
}

private struct RecentRow: View {
    let row: ConvertRow
    @State private var hovered = false

    var body: some View {
        Button {
            if let output = row.output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                Text(row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Hero.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let out = row.bytesOut {
                    Text(ConvertSummary.change(row.bytesIn, out))
                        .font(.system(size: 12))
                        .foregroundStyle(Hero.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hovered ? Hero.default : .clear, in: .rect(cornerRadius: Hero.Radius.lg))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .onDrag { row.output.flatMap(NSItemProvider.init(contentsOf:)) ?? NSItemProvider() }
        .help("Show in Finder, or drag to any app")
        .accessibilityLabel("\(row.name), \(row.bytesOut.map { ConvertSummary.sizes(row.bytesIn, $0) } ?? "")")
        .accessibilityHint("Shows the file in Finder")
    }

    private var icon: NSImage {
        NSWorkspace.shared.icon(for: row.output.flatMap { UTType(filenameExtension: $0.pathExtension) } ?? .data)
    }
}
