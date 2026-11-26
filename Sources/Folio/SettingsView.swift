import FolioKit
import SwiftUI

/// Folio > Settings (⌘,). Each editor stores its preferences under `<module>.<key>`
/// in `UserDefaults` via `@AppStorage`, and gets one tab here.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Editor", systemImage: "chevron.left.forwardslash.chevron.right") { CodeSettings() }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage("general.showWelcome") private var showWelcome = true

    var body: some View {
        Form {
            Toggle("Show the Welcome window at launch", isOn: $showWelcome)
            LabeledContent("Saving") {
                Text("Folio saves as you edit. Use File > Revert To to go back to any earlier version.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CodeSettings: View {
    @AppStorage("code.fontSize") private var fontSize = 13.0
    @AppStorage("code.wrapLines") private var wrapLines = true
    @AppStorage("code.showLineNumbers") private var showLineNumbers = true
    @AppStorage("code.tabWidth") private var tabWidth = 4

    var body: some View {
        Form {
            Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...28)
            Picker("Tab width", selection: $tabWidth) {
                ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
            }
            Toggle("Wrap lines", isOn: $wrapLines)
            Toggle("Show line numbers", isOn: $showLineNumbers)
        }
    }
}
