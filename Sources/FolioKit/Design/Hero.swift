public import SwiftUI
import AppKit

/// Folio's design system: a SwiftUI port of HeroUI v3's default theme.
///
/// Values come straight from `@heroui/styles@3.2.8` (`themes/default/variables.css`):
/// OKLCH tokens converted to sRGB, `color-mix()` tokens pre-mixed in OKLab, and
/// component metrics (heights, radii, shadows) from `components/*.css`.
/// Every color adapts to light and dark appearance automatically.
///
/// Use these instead of raw colors so the whole app keeps one look:
/// ```swift
/// Text("Saved").foregroundStyle(Hero.muted)
/// Button("Export") { … }.buttonStyle(.hero(.primary))
/// VStack { … }.heroCard()
/// ```
/// See docs/DESIGN.md for the full token table and usage rules.
public enum Hero {
    // MARK: Surfaces (back to front)
    public static let background = dynamic(light: 0xF5F5F5, dark: 0x060607)
    public static let backgroundSecondary = dynamic(light: 0xEBEBEB, dark: 0x0C0C0E)
    public static let backgroundTertiary = dynamic(light: 0xE1E1E1, dark: 0x131316)
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x18181B)
    public static let surfaceSecondary = dynamic(light: 0xEFEFF0, dark: 0x232325)
    public static let surfaceTertiary = dynamic(light: 0xEAEAEB, dark: 0x262728)
    public static let surfaceHover = dynamic(light: 0xEAEAEA, dark: 0x27272A)
    /// Popovers, menus, floating toolbars.
    public static let overlay = dynamic(light: 0xFFFFFF, dark: 0x18181B)
    /// Text fields.
    public static let field = dynamic(light: 0xFFFFFF, dark: 0x18181B)
    /// The selected pill in a segmented control.
    public static let segment = dynamic(light: 0xFFFFFF, dark: 0x46464C)

    // MARK: Text
    public static let foreground = dynamic(light: 0x18181B, dark: 0xFCFCFC)
    public static let muted = dynamic(light: 0x71717A, dark: 0x9F9FA9)

    // MARK: Neutral fills
    /// Secondary/tertiary buttons, chips, tab tracks, kbd.
    public static let `default` = dynamic(light: 0xEBEBEC, dark: 0x27272A)
    public static let defaultHover = dynamic(light: 0xE1E1E2, dark: 0x2E2E31)

    // MARK: Lines
    public static let border = dynamic(light: 0xDEDEE0, dark: 0x28282C)
    public static let separator = dynamic(light: 0xE4E4E7, dark: 0x212124)

    // MARK: Accent and status
    public static let accent = Color(hex: 0x0485F7)
    public static let accentHover = Color(hex: 0x3592F9)
    public static let accentForeground = Color(hex: 0xFCFCFC)
    public static let accentSoft = dynamic(light: 0x0485F7, dark: 0x0485F7, lightAlpha: 0.15, darkAlpha: 0.12)
    public static let accentSoftHover = dynamic(light: 0x0485F7, dark: 0x0485F7, lightAlpha: 0.20, darkAlpha: 0.16)
    public static let accentSoftForeground = dynamic(light: 0x1E63AE, dark: 0x61A8FB)
    public static let danger = dynamic(light: 0xFF383C, dark: 0xDB3B3E)
    public static let dangerHover = dynamic(light: 0xFF5551, dark: 0xE15451)
    public static let dangerSoft = dynamic(light: 0xFF383C, dark: 0xDB3B3E, lightAlpha: 0.15, darkAlpha: 0.15)
    public static let dangerSoftHover = dynamic(light: 0xFF383C, dark: 0xDB3B3E, lightAlpha: 0.20, darkAlpha: 0.20)
    public static let dangerSoftForeground = dynamic(light: 0xA43433, dark: 0xEB7872)
    public static let success = Color(hex: 0x17C964)
    public static let warning = dynamic(light: 0xF5A524, dark: 0xF7B750)

    // MARK: Radii (`--radius: 0.5rem` scale)
    public enum Radius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 6
        public static let lg: CGFloat = 8
        /// Fields, tooltips.
        public static let xl: CGFloat = 12
        /// Chips, menu items.
        public static let xxl: CGFloat = 16
        /// Cards, modals, pill buttons.
        public static let xxxl: CGFloat = 24
        /// Segmented-control track (`--radius * 2.5`).
        public static let track: CGFloat = 20
    }

    /// Press feedback used by every Hero control.
    public static let pressScale: CGFloat = 0.97
    /// Standard easing for state changes: short, no bounce.
    public static let animation = Animation.easeOut(duration: 0.15)

    // MARK: Helpers

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: opacity))
    }
}
