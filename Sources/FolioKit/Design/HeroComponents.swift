public import SwiftUI

// HeroUI components beyond buttons. Each mirrors a file in `@heroui/styles/components/`.

// MARK: - Surfaces (card.css, popover.css)

public extension View {
    /// HeroUI `Card`: surface fill, 24 pt corners, soft layered shadow in light mode only.
    func heroCard(padding: CGFloat = 16, fill: Color = Hero.surface) -> some View {
        self.padding(padding)
            .background(fill, in: .rect(cornerRadius: Hero.Radius.xxxl))
            .modifier(SurfaceShadow())
    }

    /// Floating panels (inspectors, popovers, floating toolbars): overlay fill and the
    /// HeroUI overlay shadow. In dark mode the shadow becomes a faint inner highlight.
    func heroOverlay(cornerRadius: CGFloat = Hero.Radius.xxl) -> some View {
        self.background(Hero.overlay, in: .rect(cornerRadius: cornerRadius))
            .modifier(OverlayShadow(cornerRadius: cornerRadius))
    }
}

private struct SurfaceShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark {
            content
        } else {
            content
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 2)
        }
    }
}

private struct OverlayShadow: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark {
            content.overlay {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
        } else {
            content
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.08), radius: 14, y: 14)
        }
    }
}

// MARK: - Text field (input.css)

/// HeroUI `Input`: 12 pt corners, field fill, field shadow, accent focus ring.
public struct HeroTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    public init() {}
    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Hero.field, in: .rect(cornerRadius: Hero.Radius.xl))
            .overlay {
                RoundedRectangle(cornerRadius: Hero.Radius.xl)
                    .strokeBorder(focused ? Hero.accent : Hero.border.opacity(0.6), lineWidth: focused ? 2 : 0.5)
            }
            .modifier(SurfaceShadow())
            .animation(Hero.animation, value: focused)
    }
}

public extension TextFieldStyle where Self == HeroTextFieldStyle {
    static var hero: HeroTextFieldStyle { HeroTextFieldStyle() }
}

// MARK: - Tabs / segmented control (tabs.css)

/// HeroUI `Tabs`: a `default`-filled track with a white sliding pill under the selection.
public struct HeroTabs<Value: Hashable>: View {
    private let options: [(value: Value, label: String, symbol: String?)]
    @Binding private var selection: Value
    @Namespace private var pill

    public init(_ options: [(value: Value, label: String, symbol: String?)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option.value }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol { Image(systemName: symbol) }
                        Text(option.label)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Hero.foreground : Hero.muted)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background {
                        if selected {
                            Capsule().fill(Hero.segment)
                                .modifier(SurfaceShadow())
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Hero.default, in: .rect(cornerRadius: Hero.Radius.track))
    }
}

// MARK: - Chip (chip.css)

public struct HeroChip: View {
    public enum Tone: Sendable { case `default`, accent, success, warning, danger }
    private let text: String
    private let tone: Tone
    public init(_ text: String, tone: Tone = .default) {
        self.text = text
        self.tone = tone
    }
    public var body: some View {
        let (fill, fg): (Color, Color) =
            switch tone {
            case .default: (Hero.default, Hero.foreground)
            case .accent: (Hero.accentSoft, Hero.accentSoftForeground)
            case .success: (Hero.success.opacity(0.15), Hero.success)
            case .warning: (Hero.warning.opacity(0.15), Hero.warning)
            case .danger: (Hero.dangerSoft, Hero.dangerSoftForeground)
            }
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(fill, in: .rect(cornerRadius: Hero.Radius.xxl))
    }
}

// MARK: - Kbd (kbd.css)

/// A keyboard shortcut hint, e.g. `HeroKbd("⌘K")`.
public struct HeroKbd: View {
    private let keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Hero.muted)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Hero.default, in: .rect(cornerRadius: Hero.Radius.lg))
    }
}

// MARK: - Switch (switch.css)

/// HeroUI `Switch`: 40×20 track, white thumb with field shadow, accent when on.
public struct HeroSwitchStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Hero.accent : Hero.foreground.opacity(0.2))
                        .frame(width: 40, height: 20)
                    Capsule()
                        .fill(.white)
                        .frame(width: 24, height: 16)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        .padding(.horizontal, 2)
                }
                .animation(.snappy(duration: 0.2), value: configuration.isOn)
                configuration.label
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.foreground)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

public extension ToggleStyle where Self == HeroSwitchStyle {
    static var hero: HeroSwitchStyle { HeroSwitchStyle() }
}

// MARK: - Slider (slider.css)

/// HeroUI `Slider`: label and value on top, `default` track with an accent fill and a
/// white rounded-rect thumb. Supports keyboard (arrow keys) through the native slider
/// underneath, which is kept invisible for accessibility.
public struct HeroSlider: View {
    private let label: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String
    private let onEditingChanged: (Bool) -> Void

    public init(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String = { String(Int($0.rounded())) },
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(Hero.foreground)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(Hero.muted)
            }
            .font(.system(size: 13, weight: .medium))
            GeometryReader { geo in
                let fraction = (value - range.lowerBound) / max(.ulpOfOne, range.upperBound - range.lowerBound)
                let thumbW: CGFloat = 20
                let x = CGFloat(fraction) * (geo.size.width - thumbW)
                ZStack(alignment: .leading) {
                    Capsule().fill(Hero.default).frame(height: 20)
                    Capsule().fill(Hero.accent).frame(width: x + thumbW, height: 20)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white)
                        .frame(width: thumbW - 6, height: 14)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                        .offset(x: x + 3)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            onEditingChanged(true)
                            let f = min(1, max(0, (g.location.x - thumbW / 2) / (geo.size.width - thumbW)))
                            let raw = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                            value = (raw / step).rounded() * step
                        }
                        .onEnded { _ in onEditingChanged(false) }
                )
            }
            .frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Toolbar group

/// A floating HeroUI toolbar (the pill of tools over a canvas).
public struct HeroToolbar<Content: View>: View {
    private let axis: Axis
    private let content: Content
    public init(_ axis: Axis = .horizontal, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.content = content()
    }
    public var body: some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 2) { content }
            } else {
                VStack(spacing: 2) { content }
            }
        }
        .padding(4)
        .heroOverlay(cornerRadius: Hero.Radius.track)
    }
}

/// A short divider for toolbars.
public struct HeroToolbarDivider: View {
    private let axis: Axis
    public init(_ axis: Axis = .horizontal) { self.axis = axis }
    public var body: some View {
        Rectangle()
            .fill(Hero.separator)
            .frame(width: axis == .horizontal ? 1 : 20, height: axis == .horizontal ? 20 : 1)
            .padding(axis == .horizontal ? .horizontal : .vertical, 4)
    }
}
