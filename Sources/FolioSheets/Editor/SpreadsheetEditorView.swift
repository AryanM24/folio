import FolioKit
public import SwiftUI

/// The spreadsheet editor window: formatting toolbar, formula bar, grid, optional
/// chart panel, and sheet tabs with selection statistics.
public struct SpreadsheetEditorView: View {
    @ObservedObject private var document: SpreadsheetDocument
    @State private var controller: SheetController?
    @Environment(\.undoManager) private var undoManager

    public init(document: SpreadsheetDocument) { self.document = document }

    public var body: some View {
        Group {
            if let controller {
                EditorContent(controller: controller)
            } else {
                Hero.surface
            }
        }
        .onAppear {
            // Created once per window; `@State` keeps it across view updates.
            if controller == nil { controller = SheetController(document: document) }
            controller?.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, new in controller?.undoManager = new }
    }
}

private struct EditorContent: View {
    let controller: SheetController

    var body: some View {
        VStack(spacing: 0) {
            FormatToolbar(controller: controller)
            FormulaBar(controller: controller)
            if let warning = formatWarning {
                FormatWarningBanner(message: warning) { controller.document.dismissFormatWarning() }
            }
            HStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    GridContainer(controller: controller)
                    if controller.showFind {
                        FindBar(controller: controller)
                            .padding(12)
                            .transition(.opacity)
                    }
                }
                if let chart = controller.chart {
                    ChartPanel(controller: controller, spec: chart)
                        .frame(width: 360)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(Hero.animation, value: controller.showFind)
            .animation(Hero.animation, value: controller.chart?.range)
            SheetTabBar(controller: controller)
        }
        .background(Hero.background)
        .frame(minWidth: 640, idealWidth: 1100, minHeight: 420, idealHeight: 720)
        .focusedSceneValue(\.spreadsheet, controller)
    }

    private var formatWarning: String? {
        _ = controller.revision
        return controller.document.formatWarning
    }
}

/// One-time, non-modal notice that the file format can't keep something.
private struct FormatWarningBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Hero.warning)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Hero.foreground)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("OK", action: dismiss)
                .buttonStyle(.hero(.tertiary, size: .sm))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Hero.warning.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Hero.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct SpreadsheetFocusKey: FocusedValueKey {
    typealias Value = SheetController
}

extension FocusedValues {
    /// The spreadsheet editor in the key window, for `SpreadsheetCommands`.
    /// (Spelled out rather than `@Entry`: the Command Line Tools lack SwiftUI's macro plugin.)
    var spreadsheet: SheetController? {
        get { self[SpreadsheetFocusKey.self] }
        set { self[SpreadsheetFocusKey.self] = newValue }
    }
}
