import FolioKit
import SwiftUI

/// Every Folio tool as a card, grouped by the kind of file it works on. Click a card to
/// pick files and run it, or drop files straight onto it.
struct ToolsGridView: View {
    @State private var runner = ToolRunner.shared

    /// Tool ids are "<module>.<verb>"; the module names the group.
    private static let groups: [(prefix: String, title: String)] = [
        ("pdf", "PDF"), ("docs", "Documents"), ("sheets", "Spreadsheets"), ("image", "Images"),
        ("code", "Text & Code"), ("media", "Audio & Video"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Self.groups, id: \.prefix) { group in
                    let tools = ToolCatalog.all.filter { $0.id.hasPrefix(group.prefix + ".") }
                    if !tools.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Hero.foreground)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                                ForEach(tools) { tool in
                                    ToolCard(tool: tool, running: runner.running?.id == tool.id) { runner.start(tool, inputs: $0) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }
}

private struct ToolCard: View {
    let tool: FolioTool
    let running: Bool
    let run: ([URL]) -> Void
    @State private var hovering = false
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            run([])
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(Hero.foreground)
                    .frame(width: 40, height: 40)
                    .background(hovering ? Hero.defaultHover : Hero.default, in: .rect(cornerRadius: Hero.Radius.xl))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Hero.foreground)
                    Text(tool.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Hero.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if running {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 76)
            .background(dropTargeted ? Hero.accentSoft : Hero.surface, in: .rect(cornerRadius: Hero.Radius.xxxl))
            .overlay {
                RoundedRectangle(cornerRadius: Hero.Radius.xxxl)
                    .strokeBorder(
                        dropTargeted ? Hero.accent : (scheme == .dark || hovering ? Hero.border : .clear),
                        lineWidth: dropTargeted ? 2 : 1)
            }
            .heroSurfaceShadow()
            .contentShape(.rect(cornerRadius: Hero.Radius.xxxl))
        }
        .buttonStyle(PressScale())
        .disabled(running)
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter(tool.accepts)
            guard !accepted.isEmpty else { return false }
            run(accepted)
            return true
        } isTargeted: {
            dropTargeted = $0
        }
        .help("\(tool.subtitle) Or drop files here.")
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.subtitle)
    }
}
