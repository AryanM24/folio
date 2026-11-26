import FolioKit
import SwiftUI

/// Floating find bar: Hero search field, match count, previous/next, close.
/// Typing searches after a short pause; Return finds the next match, ⇧Return the
/// previous one, Esc closes.
struct FindBar: View {
    @Bindable var model: PDFEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Hero.muted)
                TextField("Find in PDF", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit {
                        if NSEvent.modifierFlags.contains(.shift) { model.findPrevious() } else { model.findNext() }
                    }
                    .accessibilityLabel("Find in PDF")
                if model.searching {
                    ProgressView().controlSize(.mini)
                } else if !model.query.isEmpty {
                    Text(countLabel)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Hero.muted)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 260, height: 36)
            .background(Hero.field, in: .rect(cornerRadius: Hero.Radius.xl))
            .overlay {
                RoundedRectangle(cornerRadius: Hero.Radius.xl)
                    .strokeBorder(focused ? Hero.accent : Hero.border, lineWidth: focused ? 2 : 1)
            }
            Button("Previous Match", systemImage: "chevron.up") { model.findPrevious() }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Previous ⇧⌘G")
                .disabled(model.matches.isEmpty)
            Button("Next Match", systemImage: "chevron.down") { model.findNext() }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Next ⌘G")
                .disabled(model.matches.isEmpty)
            Button("Close Find", systemImage: "xmark") { model.hideFind() }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Close (Esc)")
        }
        .padding(6)
        .heroOverlay(cornerRadius: Hero.Radius.track)
        .onExitCommand { model.hideFind() }
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            model.search(model.query)
        }
    }

    private var countLabel: String {
        model.matches.isEmpty ? "No matches" : "\(model.matchIndex + 1) of \(model.matches.count)"
    }
}
