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

    /// `NSServices` entries for every tool, as JSON for scripts/bundle.sh.
    ///
    /// Each tool becomes a Finder Quick Action / Services item titled
    /// "<Tool title> with Folio" that sends the selected files to `AppDelegate.runTool`.
    static func servicesJSON() -> String {
        let entries: [[String: Any]] = all.map { tool in
            [
                "NSMenuItem": ["default": "\(tool.title) with Folio"],
                "NSMessage": "runTool",
                "NSPortName": "Folio",
                "NSUserData": tool.id,
                "NSSendFileTypes": tool.inputTypes.map(\.identifier),
                "NSRequiredContext": [String: String](),
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
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

/// The Tools tab of the Welcome window: one row per tool, grouped by the module that owns it.
struct ToolsListView: View {
    @State private var runner = ToolRunner.shared

    var body: some View {
        if ToolCatalog.all.isEmpty {
            ContentUnavailableView("No tools yet", systemImage: "wrench.and.screwdriver")
                .foregroundStyle(Hero.muted)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ToolCatalog.all) { tool in
                        ToolRow(tool: tool, running: runner.running?.id == tool.id) { runner.start(tool) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct ToolRow: View {
    let tool: FolioTool
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Hero.foreground)
                    .frame(width: 36, height: 36)
                    .background(Hero.default, in: .rect(cornerRadius: Hero.Radius.lg + 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Hero.foreground)
                    Text(tool.subtitle).font(.system(size: 12)).foregroundStyle(Hero.muted).lineLimit(1)
                }
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Hero.muted)
                }
            }
            .padding(10)
            .background(hovering ? Hero.surfaceHover : Hero.surface, in: .rect(cornerRadius: Hero.Radius.xxl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
        .disabled(running)
    }
}
