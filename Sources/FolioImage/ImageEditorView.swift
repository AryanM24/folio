import FolioKit
public import SwiftUI

/// The image editor window: tool rail, canvas with the floating context bar, the
/// inspector and the Layers panel on the right, and a status bar.
public struct ImageEditorView: View {
    @ObservedObject private var document: ImageDocument
    @State private var model: ImageEditorModel
    @State private var layersHeight: CGFloat = 240
    @Environment(\.undoManager) private var undoManager
    @Environment(\.documentConfiguration) private var configuration
    @Environment(\.displayScale) private var displayScale

    public init(document: ImageDocument) {
        self.document = document
        _model = State(initialValue: ImageEditorModel(document: document))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ToolRail(model: model)
                    .padding([.leading, .top], 12)
                ZStack(alignment: .top) {
                    ImageCanvas(model: model)
                    ContextBar(model: model)
                        .padding(.top, model.showRulers ? 12 + CanvasRulers.thickness : 12)
                        .padding(.horizontal, 12)
                    overlays
                }
                inspector
                    .frame(width: 304)
                    .padding([.vertical, .trailing], 12)
            }
            .background(Hero.backgroundSecondary)
            ImageStatusBar(model: model)
        }
        .frame(minWidth: 900, minHeight: 560)
        .focusable()
        .focusEffectDisabled()
        .focusedSceneValue(\.imageEditor, model)
        .onKeyPress(phases: [.down, .up]) { press in handleKey(press) }
        .onDeleteCommand {
            if model.tab == .markup { model.deleteSelectedMarkup() } else { model.deleteSelectedLayer() }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
        .onExitCommand {
            if model.selectionState.spec != nil { model.deselect() } else if model.tool == .crop { model.tool = .move }
        }
        .onAppear {
            model.undoManager = undoManager
            model.fileURL = configuration?.fileURL
            model.backingScale = displayScale
            #if DEBUG
                model.applyDemoStateIfRequested()
            #endif
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onChange(of: displayScale) { model.backingScale = displayScale }
        .task {
            // After first paint: decode full resolution so saves and zooms don't wait.
            model.warmUp()
        }
    }

    /// The inspector over the Layers panel, split by a handle you can drag.
    private var inspector: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                InspectorPanel(model: model)
                Capsule().fill(Hero.border)
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity, minHeight: 12)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: .top))
                    .gesture(
                        DragGesture().onChanged { value in
                            layersHeight = min(max(180, layersHeight - value.translation.height), geo.size.height - 240)
                        }
                    )
                    .accessibilityLabel("Resize the Layers panel")
                    .accessibilityAdjustableAction { direction in
                        layersHeight = min(max(180, layersHeight + (direction == .increment ? 40 : -40)), geo.size.height - 240)
                    }
                LayersPanel(model: model)
                    .frame(height: min(layersHeight, max(180, geo.size.height - 240)))
            }
        }
    }

    /// Single-key tools, space to pan, [ and ] for brush size, arrows to nudge, \\ to compare.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isEditingText else { return .ignored }
        let modifiers = press.modifiers.subtracting(.capsLock)
        if press.key == .space {
            model.spacePanning = press.phase == .down
            return .handled
        }
        if press.characters == "\\", modifiers.isEmpty {
            // Hold \ to compare with the original, as in Lightroom (M picks the select tool).
            model.comparing = press.phase == .down
            return .handled
        }
        guard press.phase == .down else { return .ignored }
        if let nudge = Self.nudges[press.key], model.tool == .move, let layer = model.selectedLayer {
            let step = modifiers.contains(.shift) ? 10.0 : 1
            model.transformLayer(layer.id, by: CGAffineTransform(translationX: nudge.width * step, y: nudge.height * step))
            return .handled
        }
        guard modifiers.isEmpty || modifiers == .shift, let ch = press.characters.lowercased().first else { return .ignored }
        switch ch {
        case "[", "]":
            model.stepBrushSize(ch == "]" ? 1 : -1)
            return .handled
        default:
            guard modifiers.isEmpty, let tool = ImageTool.allCases.first(where: { $0.shortcut == ch }) else { return .ignored }
            model.chooseTool(tool)
            return .handled
        }
    }

    private static let nudges: [KeyEquivalent: CGSize] = [
        .leftArrow: CGSize(width: -1, height: 0), .rightArrow: CGSize(width: 1, height: 0),
        .upArrow: CGSize(width: 0, height: -1), .downArrow: CGSize(width: 0, height: 1),
    ]

    @ViewBuilder private var overlays: some View {
        VStack(spacing: 8) {
            Spacer()
            if !model.canSaveInPlace && model.isEdited {
                ReadOnlyBanner(model: model)
            }
            if let message = model.busyMessage {
                BusyOverlay(LocalizedStringKey(message))
            } else if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.foreground)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .heroOverlay(cornerRadius: Hero.Radius.track)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 16)
        .animation(Hero.animation, value: model.toast)
        .allowsHitTesting(model.busyMessage == nil)
    }
}

/// Shown when the file's format can't be written (WebP), with the way out.
private struct ReadOnlyBanner: View {
    let model: ImageEditorModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").foregroundStyle(Hero.muted)
            Text(
                "macOS can't save \(model.source.type.preferredFilenameExtension?.uppercased() ?? "this format") files. Export a copy to keep your edits."
            )
            .font(.system(size: 13))
            .foregroundStyle(Hero.foreground)
            Button("Export as PNG") { model.export(.png, quality: 1) }
                .buttonStyle(.hero(.primary, size: .sm))
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 44)
        .heroOverlay(cornerRadius: Hero.Radius.xxxl)
    }
}

/// The image editor in the key window, for ``ImageCommands``.
/// (Spelled out because the `@Entry` macro needs Xcode's macro plugins.)
struct ImageEditorFocusKey: FocusedValueKey {
    typealias Value = ImageEditorModel
}

extension FocusedValues {
    var imageEditor: ImageEditorModel? {
        get { self[ImageEditorFocusKey.self] }
        set { self[ImageEditorFocusKey.self] = newValue }
    }
}
