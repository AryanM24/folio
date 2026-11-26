import FolioKit
public import SwiftUI

/// The image editor window: canvas with a floating toolbar, the inspector on the
/// right, and a status bar.
public struct ImageEditorView: View {
    @ObservedObject private var document: ImageDocument
    @State private var model: ImageEditorModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.documentConfiguration) private var configuration
    @Environment(\.displayScale) private var displayScale

    public init(document: ImageDocument) {
        self.document = document
        _model = State(initialValue: ImageEditorModel(document: document))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    ImageCanvas(model: model)
                    ImageToolbar(model: model)
                        .padding(.top, 12)
                    overlays
                }
                InspectorPanel(model: model)
                    .frame(width: 304)
                    .padding([.vertical, .trailing], 12)
            }
            .background(Hero.backgroundSecondary)
            ImageStatusBar(model: model)
        }
        .frame(minWidth: 820, minHeight: 520)
        .focusable()
        .focusEffectDisabled()
        .focusedSceneValue(\.imageEditor, model)
        .onKeyPress("m", phases: [.down, .up]) { press in
            // Hold M to compare with the original, as in Photos.
            guard !model.isEditingText else { return .ignored }
            model.comparing = press.phase == .down
            return .handled
        }
        .onDeleteCommand { model.deleteSelectedMarkup() }
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
