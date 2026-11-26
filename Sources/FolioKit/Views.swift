public import SwiftUI

// Small shared views so every editor's chrome looks like one app.
// Prefer system controls; add something here only when two editors need it.

/// The thin bar at the bottom of an editor window (word counts, cursor position, zoom).
public struct StatusBar<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: 16) { content }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Hero.muted)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Hero.surface)
            .overlay(alignment: .top) { Rectangle().fill(Hero.separator).frame(height: 1) }
    }
}

/// A titled group in an inspector sidebar.
public struct InspectorSection<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Hero.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of color swatches with a checkmark on the current one.
public struct ColorSwatches: View {
    private let colors: [Color]
    @Binding private var selection: Color
    public init(_ colors: [Color] = ColorSwatches.ink, selection: Binding<Color>) {
        self.colors = colors
        _selection = selection
    }

    /// A small, distinct palette that reads on white paper.
    public static let ink: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple, .white]

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button { selection = color } label: {
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(Hero.border))
                        .overlay {
                            if color == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(color == .white || color == .yellow ? .black : .white)
                            }
                        }
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(color.description))
            }
        }
    }
}

/// Shown while a large file loads or an export runs.
public struct BusyOverlay: View {
    private let message: LocalizedStringKey
    public init(_ message: LocalizedStringKey) { self.message = message }
    public var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message).font(.system(size: 13)).foregroundStyle(Hero.muted)
        }
        .padding(20)
        .heroOverlay()
    }
}
