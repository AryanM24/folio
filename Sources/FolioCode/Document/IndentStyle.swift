import Foundation

/// Tabs or N spaces. Detected from the file so Tab keeps matching what's already there.
nonisolated struct IndentStyle: Hashable, Sendable {
    var usesTabs: Bool
    var width: Int

    /// What one press of Tab inserts at the start of a line.
    var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    var title: String { usesTabs ? "Tabs" : "Spaces: \(width)" }

    static let choices: [IndentStyle] = [
        IndentStyle(usesTabs: false, width: 2), IndentStyle(usesTabs: false, width: 4),
        IndentStyle(usesTabs: false, width: 8), IndentStyle(usesTabs: true, width: 4),
    ]

    /// Looks at the first few thousand lines. `nil` when the file has no indentation to go by.
    static func detect(in text: String) -> IndentStyle? {
        var tabLines = 0, spaceLines = 0
        var deltas: [Int: Int] = [:]
        var previous = 0
        var scanned = 0
        for line in text.utf8.split(separator: 10, maxSplits: 4000, omittingEmptySubsequences: true) {
            scanned += 1
            if scanned > 4000 { break }
            guard let first = line.first else { continue }
            if first == 9 { tabLines += 1; continue }
            let spaces = line.prefix { $0 == 32 }.count
            if spaces == line.count { continue }
            if spaces > 0 { spaceLines += 1 }
            let delta = abs(spaces - previous)
            if delta >= 2 { deltas[delta, default: 0] += 1 }
            previous = spaces
        }
        if tabLines > spaceLines, tabLines > 0 { return IndentStyle(usesTabs: true, width: 4) }
        guard spaceLines > 0 else { return nil }
        // The most common step between indentation levels, among the usual widths.
        let width = [2, 4, 8].max { (deltas[$0] ?? 0) < (deltas[$1] ?? 0) } ?? 4
        return IndentStyle(usesTabs: false, width: (deltas[width] ?? 0) > 0 ? width : 4)
    }
}
