import AppKit
import FolioConvert
import FolioKit
import QuickLookThumbnailing
import SwiftUI

/// State behind a result card: running, then finished with one row per file.
@Observable
final class ResultCardModel {
    enum Primary { case reveal, copy }

    var count: Int
    var fraction = 0.0
    var current = ""
    /// `nil` while running.
    var rows: [ConvertRow]?
    var thumbnail: NSImage?
    var primary: Primary
    var hovered = false

    init(count: Int, primary: Primary = .reveal, rows: [ConvertRow]? = nil, thumbnail: NSImage? = nil) {
        self.count = count
        self.primary = primary
        self.rows = rows
        self.thumbnail = thumbnail
    }

    var outputs: [URL] { rows?.compactMap(\.output) ?? [] }
    var failures: [ConvertRow] { rows?.filter(\.failed) ?? [] }
}

/// What the card's buttons do. The controller fills these in; previews leave them empty.
struct ResultCardActions {
    var copy: () -> Void = {}
    var reveal: () -> Void = {}
    var open: () -> Void = {}
    var undo: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}
}

/// The CleanShot-style card in the bottom-right corner after a conversion.
struct ResultCardView: View {
    @Bindable var model: ResultCardModel
    var actions = ResultCardActions()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let rows = model.rows {
                finished(rows)
            } else {
                running
            }
        }
        .padding(12)
        .frame(width: 344, alignment: .leading)
        .heroOverlay(cornerRadius: Hero.Radius.track)
        .onHover { model.hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversion result")
    }

    // MARK: Running

    private var running: some View {
        HStack(alignment: .top, spacing: 12) {
            tile { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 18)).foregroundStyle(Hero.muted) }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.count == 1 ? "Converting \(model.current)" : "Converting \(model.count) files")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressBar(fraction: model.fraction)
                Text("Esc to cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
            }
            Spacer(minLength: 0)
            Button("Cancel", systemImage: "xmark", action: actions.cancel)
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Cancel  esc")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(model.fraction * 100)) percent")
    }

    // MARK: Finished

    @ViewBuilder
    private func finished(_ rows: [ConvertRow]) -> some View {
        let ok = rows.filter { $0.output != nil }
        HStack(alignment: .top, spacing: 12) {
            if let first = ok.first?.output {
                thumbnail.onDrag { NSItemProvider(contentsOf: first) ?? NSItemProvider() }
                    .help("Drag to any app")
                    .accessibilityLabel("Drag \(first.lastPathComponent) to another app")
            } else {
                tile { Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Hero.dangerSoftForeground) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title(rows, ok: ok))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.foreground)
                    .lineLimit(ok.isEmpty ? 2 : 1)
                    .truncationMode(.middle)
                if let totals = ConvertSummary.totals(rows) {
                    Text(totals).font(.system(size: 12)).foregroundStyle(Hero.foreground).monospacedDigit()
                    Text(ConvertSummary.meta(rows)).font(.system(size: 12)).foregroundStyle(Hero.muted).monospacedDigit()
                } else if let failure = rows.first(where: \.failed) ?? rows.first {
                    errorText(failure)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: actions.dismiss)
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Dismiss  esc")
        }
        if rows.count > 1 { list(rows) }
        if !ok.isEmpty { actionBar }
    }

    private func title(_ rows: [ConvertRow], ok: [ConvertRow]) -> String {
        if rows.count == 1 { return ok.isEmpty ? "Couldn't convert \(rows[0].name)" : rows[0].name }
        let failed = rows.count { $0.failed }
        if ok.isEmpty { return "Couldn't convert \(rows.count) files" }
        return failed == 0 ? "\(ok.count) files converted" : "\(ok.count) of \(rows.count) files converted"
    }

    private func errorText(_ row: ConvertRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let message = row.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Hero.foreground)
            }
            if let hint = row.hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(Hero.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ rows: [ConvertRow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .foregroundStyle(Hero.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let out = row.bytesOut, row.output != nil {
                            Text(ConvertSummary.change(row.bytesIn, out)).foregroundStyle(Hero.muted).monospacedDigit()
                        } else {
                            Text(row.failed ? "Failed" : "Skipped")
                                .foregroundStyle(row.failed ? Hero.dangerSoftForeground : Hero.muted)
                        }
                    }
                    .font(.system(size: 12))
                    .frame(height: 24)
                    .help(row.message.map { [$0, row.hint].compactMap { $0 }.joined(separator: " ") } ?? "")
                    .onDrag { row.output.flatMap(NSItemProvider.init(contentsOf:)) ?? NSItemProvider() }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 24 * 5)
        .fixedSize(horizontal: false, vertical: true)
        .background(Hero.surfaceSecondary, in: .rect(cornerRadius: Hero.Radius.lg))
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            if model.primary == .copy {
                Button("Copy", systemImage: "doc.on.doc", action: actions.copy)
                    .buttonStyle(.hero(.primary, size: .sm))
                    .help("Copy  ⌘C")
                Button("Show in Finder", systemImage: "folder", action: actions.reveal)
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Show in Finder")
            } else {
                Button("Show in Finder", systemImage: "folder", action: actions.reveal)
                    .buttonStyle(.hero(.primary, size: .sm))
                Button("Copy", systemImage: "doc.on.doc", action: actions.copy)
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Copy  ⌘C")
            }
            Button("Open", systemImage: "arrow.up.forward.app", action: actions.open)
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Open")
            Spacer(minLength: 0)
            Button("Undo", systemImage: "arrow.uturn.backward", action: actions.undo)
                .buttonStyle(.hero(.ghost, size: .sm))
                .help("Move the new files to the Trash  ⌘⌫")
        }
    }

    // MARK: Pieces

    private var thumbnail: some View {
        tile {
            if let image = model.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(Hero.muted)
            }
        }
    }

    /// 56 pt tile; 8 pt corners sit concentric inside the card's 20 pt corners and 12 pt padding.
    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content() }
            .frame(width: 56, height: 56)
            .background(Hero.default)
            .clipShape(.rect(cornerRadius: Hero.Radius.lg))
            // Pure black or white, never a tinted neutral, so the edge doesn't pick up the surface.
            .overlay {
                RoundedRectangle(cornerRadius: Hero.Radius.lg).strokeBorder(
                    scheme == .dark ? .white.opacity(0.1) : .black.opacity(0.1), lineWidth: 1)
            }
    }
}

/// A determinate bar in the slider's track style.
struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Hero.default)
                Capsule().fill(Hero.accent).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Controller

/// Shows one result card at a time: a run's progress, then its outcome, with keyboard
/// shortcuts (⌘C copy, Space Quick Look, ⌘⌫ trash, Esc dismiss or cancel).
final class ResultCard {
    private(set) static var current: ResultCard?

    let model: ResultCardModel
    private let panel: FloatingPanel
    private var dismissTask: Task<Void, Never>?
    /// Cancels the conversion while it runs.
    var onCancel: (() -> Void)?

    private init(model: ResultCardModel) {
        self.model = model
        var actions = ResultCardActions()
        let box = WeakBox<ResultCard>()
        actions.copy = { box.value?.copy() }
        actions.reveal = { box.value?.reveal() }
        actions.open = { box.value?.open() }
        actions.undo = { box.value?.undo() }
        actions.cancel = { box.value?.cancel() }
        actions.dismiss = { box.value?.dismiss() }
        panel = FloatingPanel(activating: false) { ResultCardView(model: model, actions: actions) }
        box.value = self
        panel.onCancel = { box.value?.cancel() }
        panel.onKey = { box.value?.handle($0) ?? false }
        withObservationTracking({ _ = model.hovered }, onChange: { Task { @MainActor in box.value?.hoverChanged() } })
    }

    /// Replaces any card on screen with a new one in its running state.
    static func begin(count: Int, primary: ResultCardModel.Primary) -> ResultCard {
        current?.close()
        let card = ResultCard(model: ResultCardModel(count: count, primary: primary))
        current = card
        card.place()
        card.panel.fade(in: true)
        if NSApp.isActive { card.panel.makeKey() }
        return card
    }

    /// A card that opens straight on a finished state, e.g. "the clipboard has no image".
    static func show(_ rows: [ConvertRow], primary: ResultCardModel.Primary = .reveal) {
        begin(count: rows.count, primary: primary).finish(rows)
    }

    func progress(_ fraction: Double, _ name: String) {
        guard model.rows == nil else { return }
        model.fraction = max(model.fraction, fraction)
        model.current = name
    }

    func finish(_ rows: [ConvertRow]) {
        model.rows = rows
        if let first = model.outputs.first { loadThumbnail(first) }
        scheduleDismiss()
        // The finished card is taller; keep it pinned to the corner once SwiftUI has laid it out.
        Task { self.place() }
    }

    // MARK: Actions

    func copy() {
        guard !model.outputs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(model.outputs as [NSURL])
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
        dismiss()
    }

    func open() {
        model.outputs.forEach { NSWorkspace.shared.open($0) }
        dismiss()
    }

    /// Undo means the new files go to the Trash; inputs were never touched.
    func undo() {
        let outputs = model.outputs
        guard !outputs.isEmpty else { return }
        Task {
            _ = try? await NSWorkspace.shared.recycle(outputs)
            ConvertHistory.shared.remove(outputs)
            dismiss()
        }
    }

    func cancel() {
        if model.rows == nil, let onCancel { onCancel() } else { dismiss() }
    }

    func dismiss() {
        close()
        if Self.current === self { Self.current = nil }
    }

    private func close() {
        dismissTask?.cancel()
        panel.fade(in: false)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers, flags) {
        case ("c", .command): copy()
        case (" ", []):
            QuickLook.shared.toggle(model.outputs)
            if !model.outputs.isEmpty { NSApp.activate() }
        case ("\u{8}", .command), ("\u{7F}", .command): undo()
        default: return false
        }
        return true
    }

    // MARK: Placement and timing

    /// Bottom-right of the screen with the pointer, inside the Dock and menu bar.
    private func place() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? .zero
        let inset = 16 - FloatingPanel.margin
        panel.setFrame(
            NSRect(x: visible.maxX - size.width - inset, y: visible.minY + inset, width: size.width, height: size.height), display: true)
    }

    private func hoverChanged() {
        withObservationTracking({ _ = model.hovered }, onChange: { [weak self] in Task { @MainActor in self?.hoverChanged() } })
        if model.hovered {
            dismissTask?.cancel()
            panel.makeKey()  // so ⌘C and Space reach the card without clicking it first
        } else {
            scheduleDismiss()
        }
    }

    /// Successful cards leave after 8 s unless hovered; errors stay until dismissed.
    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard let rows = model.rows, !model.hovered, !rows.contains(where: \.failed) else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func loadThumbnail(_ url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 112, height: 112), scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        Task {
            let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            model.thumbnail = image ?? NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        }
    }
}

/// Lets closures handed to a panel reach their owner without a retain cycle.
final class WeakBox<T: AnyObject> {
    weak var value: T?
}
