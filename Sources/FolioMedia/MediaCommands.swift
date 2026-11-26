public import SwiftUI

/// The Media menu. Mount once on the app: `.commands { MediaCommands() }`.
///
/// Commands act on the key media window (via `focusedSceneValue`) and are disabled
/// otherwise. Space, J/K/L, ←/→ and I/O are handled by the player itself rather than
/// given as menu key equivalents, so they never steal those keys from other editors;
/// the titles show them so the menu bar still documents every shortcut.
public struct MediaCommands: Commands {
    @FocusedValue(\.mediaController) private var controller

    public init() {}

    public var body: some Commands {
        CommandMenu("Media") {
            Group { items }
                // No media window in front: every item is inert.
                .disabled(controller == nil)
        }
    }

    @ViewBuilder private var items: some View {
        Button("Play/Pause (Space)") { controller?.togglePlay() }
        Button("Next Frame (→)") { controller?.step(by: 1) }
        Button("Previous Frame (←)") { controller?.step(by: -1) }
        Divider()
        Button("Trim…") { controller?.beginTrim() }
            .keyboardShortcut("t")
        Button("Set In Point (I)") { controller?.markIn() }
        Button("Set Out Point (O)") { controller?.markOut() }
        Button("Clear Selection") { controller?.clearSelection() }
            .disabled(controller?.selection == nil)
        Divider()
        Button("Rotate Left") { controller?.edits.rotate(clockwise: false) }
        Button("Rotate Right") { controller?.edits.rotate(clockwise: true) }
        Toggle("Flip Horizontal", isOn: edit(\.flipHorizontal))
        Toggle("Flip Vertical", isOn: edit(\.flipVertical))
        Toggle("Remove Audio", isOn: edit(\.removeAudio))
        Picker("Speed", selection: edit(\.speed)) {
            ForEach(MediaEdits.speeds, id: \.self) { Text(InfoFormat.speed($0)).tag($0) }
        }
        Divider()
        Button("Export…") { controller?.export() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        Button("Save Current Frame…") { controller?.saveFrame() }
            .disabled(controller?.hasVideo != true)
        Button("Make GIF…") { controller?.makeGIF() }
            .disabled(controller?.hasVideo != true)
    }

    private func edit<Value>(_ keyPath: WritableKeyPath<MediaEdits, Value>) -> Binding<Value> {
        Binding(
            get: { controller?.edits[keyPath: keyPath] ?? MediaEdits()[keyPath: keyPath] },
            set: { controller?.edits[keyPath: keyPath] = $0 }
        )
    }
}
