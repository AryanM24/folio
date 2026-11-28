import FolioConvert
import Foundation

/// One-line, human-readable renderings, shared by the CLI and the MCP text content.
nonisolated enum Human {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func seconds(_ ms: Int) -> String {
        String(format: "%.1f s", Double(ms) / 1000)
    }

    static func fidelity(_ fidelity: Fidelity) -> String {
        fidelity.rawValue.replacing("_", with: " ")
    }

    static func error(_ error: ConvertError) -> String {
        var line = "\(error.code.rawValue): \(error.message)"
        if let hint = error.hint { line += " \(hint)" }
        return line
    }

    static func error(_ error: any Error) -> String {
        self.error(Engine.wrapped(error))
    }

    /// `report.docx → report.pdf  482 KB → 391 KB  visually lossless  0.4 s ✓`
    static func resultLine(_ result: ConvertResult) -> String {
        let input = (result.input as NSString).lastPathComponent
        let output = result.output.map { ($0 as NSString).lastPathComponent }
        let arrow = output.map { "\(input) → \($0)" } ?? input
        switch result.status {
        case .failed:
            return "\(input)  ✗ " + (result.error.map(error) ?? "failed")
        case .skipped:
            return "\(arrow)  skipped" + (result.warnings.first.map { ": \($0)" } ?? "")
        case .planned:
            return "\(arrow)  planned" + (result.fidelity.map { "  \(fidelity($0))" } ?? "")
        case .ok:
            var parts = [arrow, "\(bytes(result.bytesIn)) → \(bytes(result.bytesOut ?? 0))"]
            if let f = result.fidelity { parts.append(fidelity(f)) }
            parts.append(seconds(result.durationMs) + " ✓")
            return parts.joined(separator: "  ")
        }
    }

    static func summaryLine(_ results: [ConvertResult], durationMs: Int) -> String {
        let ok = results.count { $0.status == .ok }
        let failed = results.count { $0.status == .failed }
        let skipped = results.count { $0.status == .skipped }
        var counts = ["\(ok) done"]
        if failed > 0 { counts.append("\(failed) failed") }
        if skipped > 0 { counts.append("\(skipped) skipped") }
        let bytesIn = results.filter { $0.status == .ok }.reduce(0) { $0 + $1.bytesIn }
        let bytesOut = results.reduce(0) { $0 + ($1.status == .ok ? $1.bytesOut ?? 0 : 0) }
        return "\(counts.joined(separator: ", "))  \(bytes(bytesIn)) → \(bytes(bytesOut))  \(seconds(durationMs))"
    }

    /// `report.docx  DOCX, 482 KB  pages 12  → pdf (visually lossless), md (content only)`
    static func inspectLine(_ info: FileInfo) -> String {
        let name = (info.path as NSString).lastPathComponent
        var parts = [name, [info.format?.title, bytes(info.bytes)].compactMap { $0 }.joined(separator: ", ")]
        let meta = info.meta.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
            switch value {
            case .string(let s): "\(key) \(s)"
            case .int(let i): "\(key) \(i)"
            case .double(let d): "\(key) \(d)"
            case .bool(let b): "\(key) \(b)"
            default: nil
            }
        }
        if !meta.isEmpty { parts.append(meta.joined(separator: ", ")) }
        parts.append(
            info.targets.isEmpty
                ? "no conversions" : "→ " + info.targets.map { "\($0.to.rawValue) (\(fidelity($0.fidelity)))" }.joined(separator: ", "))
        return parts.joined(separator: "  ")
    }
}

/// The version people see in `folio --version` and MCP `serverInfo`.
public nonisolated enum Version {
    /// The enclosing app's `CFBundleShortVersionString` (the binary lives in
    /// `Folio.app/Contents/Helpers/`), or "dev" for a SwiftPM build.
    public static let current: String = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
        let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let version = info["CFBundleShortVersionString"] as? String
        else { return "dev" }
        return version
    }()
}
