import SwiftUI
import UniformTypeIdentifiers
import FolioKit
import FolioPDF
import FolioDocs
import FolioSheets
import FolioImage
import FolioCode
import FolioMedia

/// Every tool from every module, in menu order.
enum ToolCatalog {
    static let all: [FolioTool] =
        PDFTools.all + ImageTools.all + DocumentTools.all + SpreadsheetTools.all + MediaTools.all + CodeTools.all

    static func tool(id: String) -> FolioTool? { all.first { $0.id == id } }
}

/// Runs a tool end to end: pick inputs (unless given), ask for options, run, reveal results.
@Observable
final class ToolRunner {
    static let shared = ToolRunner()

    private(set) var running: FolioTool?

    private let log = Log.make("Tools")

    /// Start a tool. With no inputs, shows an open panel filtered to the tool's types.
    func start(_ tool: FolioTool, inputs: [URL] = []) {
        Task {
            var inputs = inputs.filter(tool.accepts)
            if inputs.isEmpty {
                inputs = await Exporter.pick(types: tool.inputTypes, multiple: true, window: nil)
            }
            guard !inputs.isEmpty else { return }
            guard inputs.count >= tool.minimumInputs else {
                Alert.show(FolioError("Choose at least \(tool.minimumInputs) files."), title: tool.title, window: nil)
                return
            }
            guard let options = askOptions(for: tool, count: inputs.count) else { return }
            await run(tool, inputs: inputs, options: options)
        }
    }

    /// Native options prompt: one pop-up per option. `nil` when cancelled.
    private func askOptions(for tool: FolioTool, count: Int) -> [String: String]? {
        var values = Dictionary(uniqueKeysWithValues: tool.options.map { ($0.id, $0.defaultValue) })
        guard !tool.options.isEmpty else { return values }
        let alert = NSAlert()
        alert.messageText = tool.title
        alert.informativeText = "\(count) file\(count == 1 ? "" : "s") selected"
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let popups = tool.options.map { option -> NSPopUpButton in
            let popup = NSPopUpButton()
            popup.addItems(withTitles: option.choices.map(\.label))
            popup.selectItem(at: option.choices.firstIndex { $0.value == option.defaultValue } ?? 0)
            grid.addRow(with: [NSTextField(labelWithString: option.label + ":"), popup])
            return popup
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(popups.count) * 30)
        alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        for (option, popup) in zip(tool.options, popups) {
            values[option.id] = option.choices[popup.indexOfSelectedItem].value
        }
        return values
    }

    func run(_ tool: FolioTool, inputs: [URL], options: [String: String]) async {
        running = tool
        defer { running = nil }
        do {
            let outputs = try await tool.run(inputs, options)
            log.info("\(tool.id, privacy: .public) produced \(outputs.count) file(s)")
            if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        } catch {
            log.error("\(tool.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            Alert.show(error, title: "\(tool.title) didn't finish", window: nil)
        }
    }
}

/// The Tools tab of the Welcome window.
struct ToolsListView: View {
    @State private var runner = ToolRunner.shared

    var body: some View {
        Group {
            if ToolCatalog.all.isEmpty {
                ContentUnavailableView("No tools yet", systemImage: "wrench.and.screwdriver")
            } else {
                List(ToolCatalog.all) { tool in
                    Button { runner.start(tool) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tool.symbol)
                                .font(.title3)
                                .frame(width: 28)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title)
                                Text(tool.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if runner.running?.id == tool.id { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}
