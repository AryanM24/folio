public import Foundation

/// Counts shown in the status bar. Computed off the main thread from a plain `String`
/// so a 300-page document never stalls typing.
public nonisolated struct TextStats: Equatable, Sendable {
    public var words = 0
    public var characters = 0
    /// Minutes at 238 words per minute (average adult silent reading speed), at least 1
    /// for any non-empty text.
    public var readingMinutes = 0
    /// Estimated printed pages.
    public var pages = 1

    public static let zero = TextStats()

    /// Words per page used for the estimate: a single-spaced 12 pt page holds about 500.
    static let wordsPerPage = 500

    public init() {}

    /// Counts words with the system's word boundaries (so "don't" is one word and CJK
    /// text counts sensibly). Page breaks (form feeds) each start a new page.
    public init(string: String) {
        var words = 0
        string.enumerateSubstrings(in: string.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        self.words = words
        // Exclude line breaks and object-replacement characters from the character count.
        characters = string.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 0x0A, 0x0D, 0x0C, 0x2028, 0x2029, 0xFFFC: count
            default: count + 1
            }
        }
        readingMinutes = words == 0 ? 0 : max(1, Int((Double(words) / 238).rounded()))
        let breaks = string.utf16.reduce(0) { $0 + ($1 == 0x0C ? 1 : 0) }
        pages = max(1, Int((Double(words) / Double(Self.wordsPerPage)).rounded(.up))) + breaks
    }
}
