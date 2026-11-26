import FolioKit
import SwiftUI

/// The floating tool pill over the canvas: zoom, rotate, smart tools, compare,
/// info and export.
struct ImageToolbar: View {
    @Bindable var model: ImageEditorModel
    @State private var showInfo = false
    @State private var showExport = false

    var body: some View {
        HeroToolbar {
            tool("Zoom Out", "minus.magnifyingglass", help: "Zoom out ⌘−") { model.zoomOut() }
            Menu {
                Button("Zoom to Fit") { model.zoomToFit() }
                Button("Actual Size") { model.actualSize() }
                Divider()
                ForEach([0.25, 0.5, 2, 4], id: \.self) { z in
                    Button("\(Int(z * 100))%") { model.setZoom(z) }
                }
            } label: {
                Text("\(Int((model.zoomScale * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Hero.foreground)
                    .frame(width: 44, height: 32)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom")
            .accessibilityLabel("Zoom \(Int((model.zoomScale * 100).rounded())) percent")
            tool("Zoom In", "plus.magnifyingglass", help: "Zoom in ⌘+") { model.zoomIn() }
            tool("Zoom to Fit", "arrow.up.left.and.down.right.magnifyingglass", help: "Zoom to fit ⌘9", selected: model.zoom == nil) { model.zoomToFit() }

            HeroToolbarDivider()
            tool("Rotate Left", "rotate.left", help: "Rotate left ⌘L") { model.rotateLeft() }
            tool("Rotate Right", "rotate.right", help: "Rotate right ⌘R") { model.rotateRight() }
            tool("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") { model.flipHorizontal() }

            HeroToolbarDivider()
            tool("Auto-Enhance", "wand.and.stars", help: "Auto-enhance ⌥⌘E", selected: model.recipe.autoEnhance != nil) { model.toggleAutoEnhance() }
            tool("Remove Background", "person.and.background.dotted", help: "Remove background ⇧⌘K", selected: model.recipe.removeBackground) { model.toggleRemoveBackground() }
            tool("Live Text", "text.viewfinder", help: "Select text in the image ⌥⌘T", selected: model.liveTextEnabled) { model.liveTextEnabled.toggle() }
            tool("Pick Color", "eyedropper", help: "Pick a color and copy its hex value ⌥⌘C") { model.pickColor() }
            CompareButton(model: model)

            HeroToolbarDivider()
            tool("Info", "info.circle", help: "Image info ⌘I", selected: showInfo) { showInfo.toggle() }
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { InfoPopover(model: model) }
            tool("Export", "square.and.arrow.up", help: "Export, copy or share ⇧⌘E", selected: showExport) { showExport.toggle() }
                .popover(isPresented: $showExport, arrowEdge: .bottom) { ExportPopover(model: model) }
        }
        .onChange(of: model.requestedPopover, initial: true) {
            switch model.requestedPopover {
            case .info: showInfo = true
            case .export: showExport = true
            case nil: break
            }
            model.requestedPopover = nil
        }
    }

    private func tool(_ title: String, _ symbol: String, help: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: selected))
            .help(help)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Press and hold to see the original; VoiceOver users toggle it instead.
private struct CompareButton: View {
    let model: ImageEditorModel

    var body: some View {
        Button {} label: { Label("Compare with Original", systemImage: "square.split.2x1") }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: model.comparing))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.comparing { model.comparing = true } }
                    .onEnded { _ in model.comparing = false }
            )
            .help("Hold to compare with the original (or hold M)")
            .accessibilityAction(named: "Toggle original") { model.comparing.toggle() }
    }
}
