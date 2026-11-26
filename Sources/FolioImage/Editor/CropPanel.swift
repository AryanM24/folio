import FolioKit
import SwiftUI

/// Aspect presets, straighten, rotate and flip, and resize.
struct CropPanel: View {
    let model: ImageEditorModel
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var keepAspect = true
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            InspectorSection("Aspect ratio") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(CropAspect.allCases) { aspect in
                        Button(aspect.title) { model.setAspect(aspect) }
                            .buttonStyle(
                                .hero(
                                    model.cropAspect == aspect ? .secondary : .ghost, size: .sm, fullWidth: true,
                                    isSelected: model.cropAspect == aspect)
                            )
                            .accessibilityAddTraits(model.cropAspect == aspect ? .isSelected : [])
                    }
                }
            }
            InspectorSection("Rotate") {
                RecipeSlider(
                    model: model, title: "Straighten", keyPath: \.straighten, range: -45...45, step: 0.1,
                    format: { String(format: "%.1f°", $0) })
                HStack(spacing: 6) {
                    iconButton("Rotate Left", "rotate.left") { model.rotateLeft() }
                    iconButton("Rotate Right", "rotate.right") { model.rotateRight() }
                    iconButton("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { model.flipHorizontal() }
                    iconButton("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") { model.flipVertical() }
                }
            }
            InspectorSection("Size") {
                resize
            }
            Button("Reset Crop and Rotation") { model.resetCrop() }
                .buttonStyle(.hero(.ghost, size: .sm))
        }
        .onAppear(perform: syncFields)
        .onChange(of: model.geometry.outputSize) { syncFields() }
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.tertiary, size: .sm, iconOnly: true))
            .help(title)
    }

    @ViewBuilder private var resize: some View {
        HStack(spacing: 8) {
            TextField("Width", text: $widthText)
                .textFieldStyle(.hero)
                .onSubmit { applySize(changedWidth: true) }
                .accessibilityLabel("Width in pixels")
            Text("×").foregroundStyle(Hero.muted)
            TextField("Height", text: $heightText)
                .textFieldStyle(.hero)
                .onSubmit { applySize(changedWidth: false) }
                .accessibilityLabel("Height in pixels")
            Text("px").font(.system(size: 12)).foregroundStyle(Hero.muted)
        }
        Toggle("Keep aspect ratio", isOn: $keepAspect).toggleStyle(.hero)
        HStack(spacing: 6) {
            ForEach([25, 50, 75, 100], id: \.self) { percent in
                Button("\(percent)%") { setPercent(Double(percent)) }
                    .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
            }
        }
        Text("Cropped size \(Int(model.geometry.croppedSize.width)) × \(Int(model.geometry.croppedSize.height)) px. Press Return to apply.")
            .font(.system(size: 12))
            .foregroundStyle(Hero.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func syncFields() {
        let size = model.geometry.outputSize
        widthText = "\(Int(size.width))"
        heightText = "\(Int(size.height))"
    }

    private func setPercent(_ percent: Double) {
        let target = PixelSize(model.geometry.croppedSize).scaled(percent: percent)
        model.commit("Resize") { $0.resize = percent == 100 ? nil : target }
    }

    private func applySize(changedWidth: Bool) {
        let cropped = model.geometry.croppedSize
        guard let w = Int(widthText.filter(\.isNumber)), let h = Int(heightText.filter(\.isNumber)), w > 0, h > 0, w <= 30_000, h <= 30_000
        else {
            syncFields()
            return
        }
        var size = PixelSize(width: w, height: h)
        if keepAspect {
            let ratio = cropped.width / cropped.height
            size =
                changedWidth
                ? PixelSize(width: w, height: Int((Double(w) / ratio).rounded()))
                : PixelSize(width: Int((Double(h) * ratio).rounded()), height: h)
        }
        model.commit("Resize") { $0.resize = size.cgSize == cropped ? nil : size }
        syncFields()
    }
}
