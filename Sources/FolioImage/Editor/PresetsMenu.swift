import FolioKit
import SwiftUI

/// Save, apply and manage tone presets.
struct PresetsMenu: View {
    let model: ImageEditorModel
    @State private var saved: [ImagePreset] = []
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            Section("Folio") {
                ForEach(ImagePreset.builtIn) { preset in Button(preset.name) { apply(preset) } }
            }
            if !saved.isEmpty {
                Section("My Presets") {
                    ForEach(saved) { preset in Button(preset.name) { apply(preset) } }
                }
            }
            Divider()
            Button("Save Current Look…") {
                name = ""
                naming = true
            }
            if !saved.isEmpty {
                Menu("Delete Preset") {
                    ForEach(saved) { preset in Button(preset.name, role: .destructive) { delete(preset) } }
                }
            }
        } label: {
            Label("Presets", systemImage: "camera.filters")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Hero.foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Hero.default, in: .capsule)
                .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Apply a look, or save this one for other photos")
        .onAppear { saved = PresetLibrary.shared.load() }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the Adjust sliders, Tone settings (except white balance) and filter.")
        }
    }

    private func apply(_ preset: ImagePreset) {
        do {
            let applied = try preset.applied(to: model.recipe, store: model.document.assets)
            model.commit("Apply “\(preset.name)”") { $0 = applied }
        } catch {
            model.show(error, title: "Couldn't apply “\(preset.name)”")
        }
    }

    private func save() {
        do {
            let preset = try ImagePreset(
                name: name.trimmingCharacters(in: .whitespaces), recipe: model.recipe, store: model.document.assets)
            try PresetLibrary.shared.save(preset)
            saved = PresetLibrary.shared.load()
            model.showToast("Saved “\(preset.name)”")
        } catch {
            model.show(error, title: "Couldn't save the preset")
        }
    }

    private func delete(_ preset: ImagePreset) {
        do {
            try PresetLibrary.shared.delete(preset)
            saved = PresetLibrary.shared.load()
        } catch {
            model.show(error, title: "Couldn't delete “\(preset.name)”")
        }
    }
}
