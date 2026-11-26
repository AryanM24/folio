import FolioKit
import SwiftUI

/// The document's headings; click one to jump there. The heading whose section
/// holds the caret is highlighted.
struct OutlineSidebar: View {
    let controller: DocumentEditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Hero.muted)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if controller.outline.isEmpty {
                Text("Headings you add appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(controller.outline.enumerated()), id: \.element.id) { index, item in
                                row(item, current: index == controller.currentHeading).id(item.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: controller.currentHeading) { _, index in
                        if let index, controller.outline.indices.contains(index) {
                            withAnimation(Hero.animation) { proxy.scrollTo(controller.outline[index].id) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Hero.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline")
    }

    private func row(_ item: OutlineItem, current: Bool) -> some View {
        Button {
            controller.reveal(item)
        } label: {
            Text(item.title)
                .font(.system(size: item.level == 0 ? 13 : 12, weight: item.level <= 1 ? .medium : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(current ? Hero.accentSoftForeground : (item.level >= 2 ? Hero.muted : Hero.foreground))
                .padding(.leading, CGFloat(max(0, item.level - 1)) * 12 + 8)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(current ? Hero.accentSoft : .clear, in: .rect(cornerRadius: Hero.Radius.lg))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint("Heading level \(max(1, item.level)). Jumps to this heading.")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
