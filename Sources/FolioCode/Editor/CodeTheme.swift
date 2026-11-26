import AppKit

/// Syntax and chrome colors as light/dark hex pairs, shared by the editor (``CodeTheme``)
/// and the preview's CSS so code looks the same in both.
///
/// Built from Hero tokens. Each syntax hue is a Hero accent/status hue, darkened in light
/// mode and lightened in dark mode until it reaches 4.5:1 on `Hero.surface`:
/// keywords = `accentSoftForeground`, types = `dangerSoftForeground`, strings = `success`,
/// numbers/literals/attributes = `warning`, comments = `muted`. Functions and plain words
/// keep the text color. Five hues is the whole palette.
nonisolated enum SyntaxPalette {
    struct Pair: Sendable { let light: UInt32; let dark: UInt32 }

    static let background = Pair(light: 0xFFFFFF, dark: 0x18181B)  // Hero.surface
    static let foreground = Pair(light: 0x18181B, dark: 0xFCFCFC)  // Hero.foreground
    static let muted = Pair(light: 0x71717A, dark: 0x9F9FA9)  // Hero.muted
    static let border = Pair(light: 0xDEDEE0, dark: 0x28282C)  // Hero.border
    static let codeBackground = Pair(light: 0xF4F4F5, dark: 0x232325)  // between surface and surfaceSecondary
    static let accent = Pair(light: 0x0485F7, dark: 0x0485F7)  // Hero.accent

    static let keyword = Pair(light: 0x1E63AE, dark: 0x61A8FB)
    static let type = Pair(light: 0xA43433, dark: 0xEB7872)
    static let string = Pair(light: 0x177A3E, dark: 0x5BD48C)
    static let number = Pair(light: 0x9A5B00, dark: 0xF7B750)

    /// `nil` = draw in the text color.
    static func pair(for kind: TokenKind) -> Pair? {
        switch kind {
        case .keyword, .tag, .heading, .property: keyword
        case .type, .variable: type
        case .string, .code: string
        case .number, .literal, .attribute: number
        case .comment, .punctuation: muted
        case .link: keyword
        case .function, .emphasis: nil
        }
    }

    static func css(_ value: UInt32) -> String { "#" + String(format: "%06X", value) }
}

/// AppKit colors for the editor. Dynamic, so they follow light/dark without redrawing logic.
nonisolated enum CodeTheme {
    static let background = color(SyntaxPalette.background)
    static let foreground = color(SyntaxPalette.foreground)
    static let muted = color(SyntaxPalette.muted)
    static let accent = color(SyntaxPalette.accent)
    /// A whisper of the text color, so the caret line reads without competing with selection.
    static let currentLine = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 0, alpha: 0.035)
    }
    /// Hero.accentSoft: 15 % accent in light mode, a bit stronger in dark so it reads on #18181B.
    static let selection = NSColor(name: nil) { appearance in
        NSColor(srgbRed: 0x04 / 255, green: 0x85 / 255, blue: 0xF7 / 255, alpha: appearance.isDark ? 0.32 : 0.2)
    }
    static let bracket = NSColor(name: nil) { appearance in
        NSColor(srgbRed: 0x04 / 255, green: 0x85 / 255, blue: 0xF7 / 255, alpha: appearance.isDark ? 0.35 : 0.22)
    }
    static let invisible = NSColor(name: nil) { appearance in
        hex(appearance.isDark ? SyntaxPalette.muted.dark : SyntaxPalette.muted.light).withAlphaComponent(0.55)
    }

    private static let kindColors: [TokenKind: NSColor] = Dictionary(uniqueKeysWithValues: TokenKind.allCases.compactMap { kind in
        SyntaxPalette.pair(for: kind).map { (kind, color($0)) }
    })

    static func color(for kind: TokenKind) -> NSColor? { kindColors[kind] }

    static func color(_ pair: SyntaxPalette.Pair) -> NSColor {
        NSColor(name: nil) { appearance in hex(appearance.isDark ? pair.dark : pair.light) }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

nonisolated extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
