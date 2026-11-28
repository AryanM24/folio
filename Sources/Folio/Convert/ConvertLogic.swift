import AppKit
import FolioConvert

// The Convert surfaces' pure logic: what a selection can become, what was chosen last time,
// how results read, and where a Dock drop goes. No UI here, so tests cover all of it.

/// Targets every file in a selection can reach, in the first file's order.
///
/// A shared target is only as good as its weakest pair: fidelity is the worst across files,
/// and lossless is offered only when every file can be lossless.
nonisolated enum SharedTargets {
    static func intersect(_ lists: [[Target]]) -> [Target] {
        guard let first = lists.first else { return [] }
        return first.compactMap { target in
            let matches = lists.compactMap { list in list.first { $0.to == target.to } }
            guard matches.count == lists.count else { return nil }
            var shared = target
            shared.fidelity = matches.map(\.fidelity).max { rank($0) < rank($1) } ?? target.fidelity
            shared.losslessAvailable = matches.allSatisfy(\.losslessAvailable)
            shared.drops = Array(Set(matches.flatMap(\.drops))).sorted()
            return shared
        }
    }

    /// Higher is lossier.
    static func rank(_ fidelity: Fidelity) -> Int {
        switch fidelity {
        case .lossless: 0
        case .visuallyLossless: 1
        case .lossy: 2
        case .contentOnly: 3
        }
    }

    /// The family a selection is remembered under: its own, or `mixed`.
    static func family(of urls: [URL]) -> String {
        let families = Set(urls.compactMap { Format.detect($0)?.family.rawValue })
        return families.count == 1 ? families.first! : "mixed"
    }
}

/// What the Convert panel last ran for a source family, so the next panel opens on it.
nonisolated struct ConvertChoice: Codable, Equatable {
    var target: Format?
    var quality: Quality = .balanced
    /// Per-output budget in megabytes (1 MB = 1,000,000 bytes, as Finder counts).
    var maxMegabytes: Double?
    var stripMetadata = false

    var maxBytes: Int64? { maxMegabytes.flatMap { $0 > 0 ? Int64(($0 * 1_000_000).rounded()) : nil } }

    static func key(for family: String) -> String { "convert.last.\(family)" }

    static func load(family: String, defaults: UserDefaults = .standard) -> ConvertChoice? {
        defaults.data(forKey: key(for: family)).flatMap { try? JSONDecoder().decode(ConvertChoice.self, from: $0) }
    }

    func save(family: String, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(for: family))
    }

    /// The remembered choice fitted to what this selection offers: a target it has (else the
    /// preferred one, else the first), and lossless only where that target allows it.
    func fitted(to targets: [Target], preferring preferred: Format? = nil) -> ConvertChoice {
        var out = self
        let ids = targets.map(\.to)
        if let preferred, ids.contains(preferred) {
            out.target = preferred
        } else if out.target.map(ids.contains) != true {
            out.target = ids.first
        }
        let lossless = targets.first { $0.to == out.target }?.losslessAvailable ?? false
        if out.quality == .lossless && !lossless { out.quality = .balanced }
        return out
    }
}

/// One file's result as the result card and the shelf show it. Built from a `ConvertResult`,
/// or directly in tests and previews.
nonisolated struct ConvertRow: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var output: URL?
    var bytesIn: Int64
    var bytesOut: Int64?
    var fidelity: Fidelity?
    var verified = false
    var durationMs: Int
    var failed = false
    var message: String?
    var hint: String?

    init(
        name: String, output: URL? = nil, bytesIn: Int64, bytesOut: Int64? = nil, fidelity: Fidelity? = nil, verified: Bool = false,
        durationMs: Int = 0, failed: Bool = false, message: String? = nil, hint: String? = nil
    ) {
        self.name = name
        self.output = output
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.fidelity = fidelity
        self.verified = verified
        self.durationMs = durationMs
        self.failed = failed
        self.message = message
        self.hint = hint
    }

    init(_ result: ConvertResult) {
        let input = URL(fileURLWithPath: result.input)
        self.init(
            name: result.output.map { URL(fileURLWithPath: $0).lastPathComponent } ?? input.lastPathComponent,
            output: result.status == .ok ? result.output.map(URL.init(fileURLWithPath:)) : nil,
            bytesIn: result.bytesIn, bytesOut: result.bytesOut, fidelity: result.fidelity,
            verified: result.verification?.passed == true, durationMs: result.durationMs, failed: result.status == .failed,
            message: result.error?.message ?? (result.status == .skipped ? result.warnings.first : nil),
            hint: result.error?.hint)
    }

    static func == (a: ConvertRow, b: ConvertRow) -> Bool { a.id == b.id }
}

/// The words on a result: sizes, savings, fidelity and time.
nonisolated enum ConvertSummary {
    /// "18.9 MB → 4.1 MB · −78 %". Uses a real minus sign, as typographers would.
    static func sizes(_ bytesIn: Int64, _ bytesOut: Int64) -> String {
        let a = ByteCountFormatter.string(fromByteCount: bytesIn, countStyle: .file)
        let b = ByteCountFormatter.string(fromByteCount: bytesOut, countStyle: .file)
        return "\(a) → \(b) · \(change(bytesIn, bytesOut))"
    }

    /// "−78 %", "+12 %" or "0 %".
    static func change(_ bytesIn: Int64, _ bytesOut: Int64) -> String {
        guard bytesIn > 0 else { return "0 %" }
        let percent = Int((Double(bytesOut - bytesIn) / Double(bytesIn) * 100).rounded())
        return percent < 0 ? "\u{2212}\(-percent) %" : percent > 0 ? "+\(percent) %" : "0 %"
    }

    static func fidelity(_ fidelity: Fidelity?, verified: Bool) -> String? {
        switch fidelity {
        case .lossless: verified ? "Lossless, verified" : "Lossless"
        case .visuallyLossless: "Visually lossless"
        case .lossy: "Smaller, some loss"
        case .contentOnly: "Content only"
        case nil: nil
        }
    }

    /// "0.4 s", "12.0 s", "2 min 5 s".
    static func duration(_ ms: Int) -> String {
        ms < 60_000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms / 60_000) min \(ms % 60_000 / 1000) s"
    }

    /// The card's one-line meta: "Visually lossless · 0.4 s". Mixed fidelities show the lossiest.
    static func meta(_ rows: [ConvertRow]) -> String {
        let ok = rows.filter { $0.output != nil }
        let worst = ok.compactMap(\.fidelity).max { SharedTargets.rank($0) < SharedTargets.rank($1) }
        let label = fidelity(worst, verified: !ok.isEmpty && ok.allSatisfy(\.verified))
        let time = duration(rows.map(\.durationMs).max() ?? 0)
        return [label, time].compactMap { $0 }.joined(separator: " · ")
    }

    /// Totals over the rows that produced a file.
    static func totals(_ rows: [ConvertRow]) -> String? {
        let ok = rows.filter { $0.output != nil }
        guard !ok.isEmpty else { return nil }
        return sizes(ok.reduce(0) { $0 + $1.bytesIn }, ok.reduce(0) { $0 + ($1.bytesOut ?? 0) })
    }
}

/// Files dropped on the Dock icon: opened, or converted while ⌥ is held.
nonisolated enum DockDrop {
    enum Route: Equatable { case open, convert }

    static func route(_ flags: NSEvent.ModifierFlags) -> Route {
        flags.intersection(.deviceIndependentFlagsMask).contains(.option) ? .convert : .open
    }
}

extension Format {
    /// Chip label: the name people say ("PNG", "Markdown"), not the file extension.
    nonisolated var chipLabel: String {
        switch self {
        case .md: "Markdown"
        case .txt: "Text"
        case .alac: "Apple Lossless"
        case .m4a: "AAC"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .jxl: "JPEG XL"
        default: rawValue.uppercased()
        }
    }
}
