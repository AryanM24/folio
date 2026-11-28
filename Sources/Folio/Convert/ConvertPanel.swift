import AppKit
import FolioConvert
import FolioKit
import SwiftUI

/// Pick a format, a quality and two optional limits, then convert. ⏎ converts, Esc closes.
struct ConvertPanel: View {
    let inputs: [URL]
    let targets: [Target]
    @State private var choice: ConvertChoice
    @State private var maxText: String
    var onConvert: (ConvertChoice) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(
        inputs: [URL], targets: [Target], choice: ConvertChoice, onConvert: @escaping (ConvertChoice) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self.inputs = inputs
        self.targets = targets
        _choice = State(initialValue: choice)
        _maxText = State(initialValue: choice.maxMegabytes.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
        self.onConvert = onConvert
        self.onCancel = onCancel
    }

    private var selected: Target? { targets.first { $0.to == choice.target } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)
            if targets.isEmpty {
                Text(inputs.count > 1 ? "These files have no format in common" : "Folio can't convert this file yet")
                    .font(.system(size: 13))
                    .foregroundStyle(Hero.muted)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Hero.surfaceSecondary, in: .rect(cornerRadius: Hero.Radius.xl))
            } else {
                section("Format") {
                    FormatGrid(targets: targets, selection: $choice.target)
                    if let line = detail { Text(line).font(.system(size: 12)).foregroundStyle(Hero.muted) }
                }
                section("Quality") {
                    QualityPicker(
                        selection: $choice.quality, losslessAvailable: selected?.losslessAvailable ?? false,
                        losslessHelp: selected.map { "\($0.to.chipLabel) can't keep every detail of these files." } ?? "")
                }
                HStack(alignment: .bottom, spacing: 24) {
                    section("Max size", spacing: 8, bottom: 0) {
                        HStack(spacing: 8) {
                            TextField("No limit", text: $maxText)
                                .textFieldStyle(.hero)
                                .frame(width: 96)
                                .accessibilityLabel("Max size in megabytes")
                            Text("MB").font(.system(size: 13)).foregroundStyle(Hero.muted)
                        }
                    }
                    Toggle("Strip metadata", isOn: $choice.stripMetadata)
                        .toggleStyle(.hero)
                        .frame(height: 36)
                        .help("Removes location, camera and author details")
                    Spacer(minLength: 0)
                }
            }
            footer.padding(.top, 28)
        }
        .padding(24)
        .frame(width: 432)
        .heroOverlay(cornerRadius: Hero.Radius.xxxl)
        .onChange(of: choice.target) { choice = choice.fitted(to: targets) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(inputs.count == 1 ? "Convert \(inputs[0].lastPathComponent)" : "Convert \(inputs.count) files")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Hero.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Hero.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var subtitle: String {
        if inputs.count > 1 {
            let names = inputs.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
            return inputs.count > 2 ? "\(names) and \(inputs.count - 2) more" : names
        }
        let total = inputs.reduce(Int64(0)) { $0 + Engine.fileSize($1) }
        return "Originals stay as they are · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    /// What the chosen pair keeps, in plain words.
    private var detail: String? {
        guard let selected else { return nil }
        let keeps =
            switch choice.quality {
            case .lossless: "Lossless, verified"
            case .balanced: ConvertSummary.fidelity(selected.fidelity, verified: false) ?? ""
            case .small: "Smaller, some loss"
            }
        let drops = selected.drops.isEmpty ? "" : " · drops \(selected.drops.formatted(.list(type: .and)))"
        return keeps + drops
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.hero(.tertiary))
                .keyboardShortcut(.cancelAction)
            Button("Convert") {
                var out = choice
                out.maxMegabytes = Double(maxText.replacingOccurrences(of: ",", with: "."))
                onConvert(out)
            }
            .buttonStyle(.hero(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
    }

    private func section<Content: View>(
        _ title: String, spacing: CGFloat = 8, bottom: CGFloat = 20, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Hero.muted)
            content()
        }
        .padding(.bottom, bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Format chips: Hero chip fills at button height. Arrow keys move the selection.
private struct FormatGrid: View {
    let targets: [Target]
    @Binding var selection: Format?
    @FocusState private var focused: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(targets, id: \.to) { target in
                Chip(label: target.to.chipLabel, selected: selection == target.to) { selection = target.to }
                    .help(target.to.title)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.leftArrow) { step(-1) }
        .padding(2)
        .overlay {
            if focused { RoundedRectangle(cornerRadius: Hero.Radius.xxl + 2).strokeBorder(Hero.accent, lineWidth: 2) }
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let ids = targets.map(\.to)
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap(ids.firstIndex) ?? 0
        selection = ids[(index + delta + ids.count) % ids.count]
        return .handled
    }

    private struct Chip: View {
        let label: String
        let selected: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Hero.accentSoftForeground : Hero.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(selected ? Hero.accentSoft : hovered ? Hero.defaultHover : Hero.default, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(PressScale())
            .onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    /// The 0.97 press scale every Hero control has.
    private struct PressScale: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? Hero.pressScale : 1)
                .animation(Hero.animation, value: configuration.isPressed)
        }
    }
}

/// `Lossless | Balanced | Small` in the HeroTabs look, with lossless disabled where a target
/// can't be lossless. HeroTabs has no per-option disabled state, hence this small sibling.
private struct QualityPicker: View {
    @Binding var selection: Quality
    let losslessAvailable: Bool
    let losslessHelp: String
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Quality.allCases, id: \.self) { quality in
                let selected = quality == selection
                let enabled = quality != .lossless || losslessAvailable
                Button {
                    withAnimation(reduceMotion ? nil : Hero.animation) { selection = quality }
                } label: {
                    Text(quality.rawValue.capitalized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Hero.foreground : Hero.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if selected {
                                Capsule().fill(Hero.segment).heroSurfaceShadow().matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
                .help(enabled ? "" : losslessHelp)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(enabled ? "" : losslessHelp)
            }
        }
        .padding(4)
        .background(Hero.default, in: .rect(cornerRadius: Hero.Radius.track))
    }
}

// MARK: - Window

/// Hosts the Convert panel in a floating window, one at a time.
enum ConvertPanelWindow {
    private static var panel: FloatingPanel?

    /// Shows the panel for `inputs`, opening on the last choice for their family.
    static func show(_ inputs: [URL], preferring format: Format? = nil, targets: [Target]? = nil) {
        close()
        let targets = targets ?? SharedTargets.intersect(inputs.map(Engine.targets(for:)))
        let family = SharedTargets.family(of: inputs)
        let choice = (ConvertChoice.load(family: family) ?? ConvertChoice()).fitted(to: targets, preferring: format)
        let panel = FloatingPanel(activating: true) {
            ConvertPanel(inputs: inputs, targets: targets, choice: choice) { choice in
                choice.save(family: family)
                close()
                ConvertFlow.run(inputs, choice: choice)
            } onCancel: {
                close()
            }
        }
        panel.onCancel = { close() }
        self.panel = panel
        panel.layoutIfNeeded()
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
