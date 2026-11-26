import FolioKit
import SwiftUI

/// Home: start a new file in one click, then pick up where you left off.
struct HomeView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("Start something")
                StartRow(model: model)
                    .padding(.bottom, 32)

                HStack(alignment: .firstTextBaseline) {
                    SectionTitle("Recent")
                    Spacer()
                    if model.recent.count > model.visibleItems.count {
                        Button("Show All") { model.go(.recent) }
                            .buttonStyle(.hero(.ghost, size: .sm))
                            .padding(.bottom, 12)
                    }
                }
                recent
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .contentShape(.rect)
        .onTapGesture { model.selection = [] }
    }

    @ViewBuilder private var recent: some View {
        let items = model.visibleItems
        if !items.isEmpty {
            FileGrid(model: model, items: items)
        } else if model.loadingRecent {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
        } else if !model.query.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "No recent file matches “\(model.query)”.")
        } else {
            EmptyState(
                symbol: "clock", title: "Nothing recent yet", message: "Files you open in Folio, or change in your library, appear here.")
        }
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Hero.foreground)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The "Start something" tiles: one per new-file kind, plus Open….
struct StartRow: View {
    let model: WorkspaceModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 12)], spacing: 12) {
            ForEach(NewFile.allCases) { kind in
                StartTile(title: kind.title, subtitle: kind.subtitle) {
                    Miniature(kind: kind)
                } action: {
                    model.create(kind)
                }
                .help("New \(kind.title.lowercased()) in your library")
                .accessibilityLabel("New \(kind.title)")
            }
            StartTile(title: "Open…", subtitle: "Any file", dashed: true) {
                Image(systemName: "folder")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Hero.muted)
                    .frame(width: 44, height: 44)
                    .background(Hero.default, in: .circle)
            } action: {
                model.showOpenPanel()
            }
            .help("Open a file ⌘O")
        }
    }
}

/// A tile with a drawn preview in a soft well, a title and a format line.
private struct StartTile<Preview: View>: View {
    let title: String
    let subtitle: String
    var dashed = false
    @ViewBuilder var preview: Preview
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Hero.Radius.xxl)
                        .fill(dashed ? .clear : Hero.surfaceSecondary)
                    preview
                        .scaleEffect(hovering ? 1.04 : 1)
                        .offset(y: hovering ? -1 : 0)
                }
                .frame(height: 92)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Hero.foreground)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Hero.muted)
                }
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
            .padding(8)
            .background(dashed ? .clear : Hero.surface, in: .rect(cornerRadius: Hero.Radius.xxxl))
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: Hero.Radius.xxxl)
                        .strokeBorder(Hero.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                } else if scheme == .dark || hovering {
                    RoundedRectangle(cornerRadius: Hero.Radius.xxxl)
                        .strokeBorder(hovering ? Hero.border : Hero.border.opacity(0.8), lineWidth: 1)
                }
            }
            .modifier(OptionalShadow(enabled: !dashed))
            .contentShape(.rect(cornerRadius: Hero.Radius.xxxl))
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
    }
}

private struct OptionalShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.heroSurfaceShadow() } else { content }
    }
}

/// Hero's 0.97 press feedback for custom tiles.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Hero.pressScale : 1)
            .animation(Hero.animation, value: configuration.isPressed)
    }
}
