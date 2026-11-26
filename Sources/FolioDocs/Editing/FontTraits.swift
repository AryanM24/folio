import AppKit

/// Font changes that keep everything else about a font.
///
/// Uses font descriptors rather than `NSFontManager` so the same code runs in pure,
/// off-main-thread helpers (Markdown import) and in the editor.
nonisolated extension NSFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }

    /// This font with `trait` added. Families without that face (e.g. no bold) return
    /// the font unchanged rather than a substitute family.
    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }

    func removing(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.subtracting(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }

    /// Same family and traits at another size.
    func withSize(_ size: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: size) ?? self
    }

    /// Another family, keeping size, bold and italic where that family has them.
    func withFamily(_ family: String) -> NSFont {
        let traits = fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family]).withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize)
            ?? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: pointSize)
            ?? self
    }
}
