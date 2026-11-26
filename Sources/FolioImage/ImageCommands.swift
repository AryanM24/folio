public import SwiftUI

/// The Image menu. Mount once in the app: `.commands { ImageCommands() }`.
///
/// Items act on the image editor in the key window and are disabled otherwise.
/// Shortcuts follow Preview where it has one (⌘L/⌘R rotate, ⇧⌘K remove background,
/// ⌘0 actual size, ⌘9 fit).
public struct ImageCommands: Commands {
    @FocusedValue(\.imageEditor) private var editor

    public init() {}

    public var body: some Commands {
        CommandMenu("Image") {
            items.disabled(editor == nil)
        }
    }

    @ViewBuilder private var items: some View {
        Button("Zoom In") { editor?.zoomIn() }.keyboardShortcut("+")
        Button("Zoom Out") { editor?.zoomOut() }.keyboardShortcut("-")
        Button("Actual Size") { editor?.actualSize() }.keyboardShortcut("0")
        Button("Zoom to Fit") { editor?.zoomToFit() }.keyboardShortcut("9")
        Divider()
        Button("Rotate Left") { editor?.rotateLeft() }.keyboardShortcut("l")
        Button("Rotate Right") { editor?.rotateRight() }.keyboardShortcut("r")
        Button("Flip Horizontal") { editor?.flipHorizontal() }
        Button("Flip Vertical") { editor?.flipVertical() }
        Divider()
        ForEach(Array(InspectorTab.allCases.enumerated()), id: \.element) { index, tab in
            Button("Show \(tab.title)") { editor?.tab = tab }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
        }
        Divider()
        Button("Auto-Enhance") { editor?.toggleAutoEnhance() }.keyboardShortcut("e", modifiers: [.command, .option])
        Button("Remove Background") { editor?.toggleRemoveBackground() }.keyboardShortcut("k", modifiers: [.command, .shift])
        Button("Live Text") { editor?.liveTextEnabled.toggle() }.keyboardShortcut("t", modifiers: [.command, .option])
        Button("Pick Color…") { editor?.pickColor() }.keyboardShortcut("c", modifiers: [.command, .option])
        Button(editor?.comparing == true ? "Show Edited" : "Show Original (hold M)") { editor?.comparing.toggle() }
        Divider()
        Button("Copy Image") { editor?.copyImage() }.keyboardShortcut("c", modifiers: [.command, .shift])
        Button("Export…") { editor?.requestedPopover = .export }.keyboardShortcut("e", modifiers: [.command, .shift])
        Button("Info") { editor?.requestedPopover = .info }.keyboardShortcut("i")
        Toggle("Remove Location and Metadata on Save", isOn: Binding(
            get: { editor?.recipe.stripMetadata ?? false },
            set: { _ in editor?.toggleStripMetadata() }
        ))
        Divider()
        Button("Reset All Edits") { editor?.resetAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
    }
}
