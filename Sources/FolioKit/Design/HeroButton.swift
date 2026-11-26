public import SwiftUI

/// HeroUI's `Button`: pill-shaped, 13 pt medium, six variants, three sizes.
///
/// ```swift
/// Button("Export", systemImage: "square.and.arrow.up") { … }
///     .buttonStyle(.hero(.primary))
/// Button("Delete", systemImage: "trash") { … }
///     .buttonStyle(.hero(.dangerSoft, size: .sm, iconOnly: true))
/// ```
/// Metrics follow `components/button.css` at desktop size: md 36 pt tall, sm 32, lg 40;
/// icon-only buttons are square. Pressing scales to 0.97.
public struct HeroButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        /// Accent fill. One per view: the main action.
        case primary
        /// Neutral fill, accent text.
        case secondary
        /// Neutral fill, normal text.
        case tertiary
        /// Hairline border, no fill.
        case outline
        /// No fill until hovered. Toolbars.
        case ghost
        case danger
        case dangerSoft
    }

    public enum Size: Sendable {
        case sm, md, lg
        var height: CGFloat {
            switch self {
            case .sm: 32;
            case .md: 36;
            case .lg: 40
            }
        }
        var padding: CGFloat {
            switch self {
            case .sm: 12;
            case .md: 16;
            case .lg: 16
            }
        }
        var font: Font { self == .lg ? .system(size: 14, weight: .medium) : .system(size: 13, weight: .medium) }
    }

    let variant: Variant
    let size: Size
    let iconOnly: Bool
    /// Fills the width (`fullWidth` in HeroUI).
    let fullWidth: Bool
    /// Selected state for toggle buttons in toolbars.
    let isSelected: Bool

    public init(_ variant: Variant = .primary, size: Size = .md, iconOnly: Bool = false, fullWidth: Bool = false, isSelected: Bool = false)
    {
        self.variant = variant
        self.size = size
        self.iconOnly = iconOnly
        self.fullWidth = fullWidth
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        HeroButtonBody(configuration: configuration, style: self)
    }

    func colors(hovered: Bool, pressed: Bool) -> (background: Color, foreground: Color) {
        let active = hovered || pressed
        switch variant {
        case .primary: return (active ? Hero.accentHover : Hero.accent, Hero.accentForeground)
        case .secondary: return (active ? Hero.defaultHover : Hero.default, Hero.accentSoftForeground)
        case .tertiary: return (active ? Hero.defaultHover : Hero.default, Hero.foreground)
        case .outline: return (active ? Hero.defaultHover : .clear, Hero.foreground)
        case .ghost:
            if isSelected { return (Hero.default, Hero.foreground) }
            return (active ? Hero.defaultHover : .clear, Hero.foreground)
        case .danger: return (active ? Hero.dangerHover : Hero.danger, Hero.accentForeground)
        case .dangerSoft: return (active ? Hero.dangerSoftHover : Hero.dangerSoft, Hero.dangerSoftForeground)
        }
    }
}

private struct HeroButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: HeroButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let colors = style.colors(hovered: hovered, pressed: configuration.isPressed)
        configuration.label
            .labelStyle(HeroLabelStyle(iconOnly: style.iconOnly))
            .font(style.size.font)
            .lineLimit(1)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, style.iconOnly ? 0 : style.size.padding)
            .frame(width: style.iconOnly ? style.size.height : nil, height: style.size.height)
            .frame(maxWidth: style.fullWidth ? .infinity : nil)
            .background(colors.background, in: .capsule)
            .overlay {
                if style.variant == .outline { Capsule().strokeBorder(Hero.border) }
            }
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? Hero.pressScale : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Hero.animation, value: configuration.isPressed)
            .animation(Hero.animation, value: hovered)
            .onHover { hovered = isEnabled && $0 }
    }
}

/// Icon + title with HeroUI spacing; icon-only hides the title but keeps it for VoiceOver.
private struct HeroLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon.font(.system(size: 15, weight: .regular))
        } else {
            HStack(spacing: 8) {
                configuration.icon.font(.system(size: 14, weight: .regular))
                configuration.title
            }
        }
    }
}

public extension ButtonStyle where Self == HeroButtonStyle {
    /// HeroUI button. See ``HeroButtonStyle``.
    static func hero(
        _ variant: HeroButtonStyle.Variant = .primary,
        size: HeroButtonStyle.Size = .md,
        iconOnly: Bool = false,
        fullWidth: Bool = false,
        isSelected: Bool = false
    ) -> HeroButtonStyle {
        HeroButtonStyle(variant, size: size, iconOnly: iconOnly, fullWidth: fullWidth, isSelected: isSelected)
    }
}
