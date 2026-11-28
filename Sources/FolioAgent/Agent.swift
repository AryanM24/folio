public import FolioConvert
import FolioKit
public import Foundation
import UniformTypeIdentifiers

/// What a tool call needs besides its arguments.
public nonisolated struct ToolContext: Sendable {
    public var policy: PathPolicy
    /// Overall fraction (0…1) and the file being worked on.
    public var progress: (@Sendable (Double, String) -> Void)?

    public init(policy: PathPolicy, progress: (@Sendable (Double, String) -> Void)? = nil) {
        self.policy = policy
        self.progress = progress
    }
}

/// One tool's answer. `structured` is the MCP `structuredContent` and exactly what
/// `--json` prints; `text` is the short summary for older clients and the CLI.
public nonisolated struct ToolOutput: Sendable {
    public var structured: JSONValue
    public var text: String
    /// PNG bytes for `folio_preview`.
    public var image: Data?
    public var isError: Bool
    /// Item counts, for the CLI's exit code.
    public var ok: Int
    public var failed: Int

    static func failure(_ error: ConvertError) -> ToolOutput {
        ToolOutput(
            structured: ["error": JSONValue(encoding: error)], text: Human.error(error), image: nil, isError: true, ok: 0, failed: 1)
    }
}

/// The operations behind both the CLI and the MCP tools. Typed parameters in, `ToolOutput` out.
public nonisolated enum Agent {
    public static let maxFiles = 500

    // MARK: Inspect

    public static func inspect(_ paths: [String], includeTargets: Bool = true, context: ToolContext) async -> ToolOutput {
        var files: [JSONValue] = []
        var lines: [String] = []
        var failed = 0
        for path in paths {
            var entry: [String: JSONValue]
            do {
                let url = try context.policy.check(path, .read)
                let info = await Engine.inspect(url)
                entry = JSONValue(encoding: info).object ?? [:]
                entry["uti"] = UTType(filenameExtension: url.pathExtension).map { .string($0.identifier) }
                entry["tools"] = .array(AgentCatalog.all.filter { $0.accepts(url) }.map { .string($0.id) })
                if !includeTargets { entry["targets"] = nil }
                if let error = info.error {
                    failed += 1
                    lines.append("\(url.lastPathComponent): \(Human.error(error))")
                } else {
                    lines.append(Human.inspectLine(info))
                }
            } catch {
                failed += 1
                entry = ["path": .string(path), "bytes": 0, "meta": [:], "targets": [], "tools": [], "error": JSONValue(encoding: error)]
                lines.append("\(path): \(Human.error(error))")
            }
            files.append(.object(entry))
        }
        return ToolOutput(
            structured: ["files": .array(files)], text: lines.joined(separator: "\n"), image: nil,
            isError: failed == paths.count && !paths.isEmpty, ok: paths.count - failed, failed: failed)
    }

    // MARK: Convert

    public struct ConvertOptions: Sendable {
        public var target: Format?
        public var quality: Quality = .balanced
        public var maxBytes: Int64?
        public var maxDimension: Int?
        public var outputDir: String?
        public var onConflict: ConvertRequest.OnConflict = .rename
        public var stripMetadata = false
        public var verify: Bool?
        public var dryRun = false
        public init() {}
    }

    public static func convert(_ paths: [String], options: ConvertOptions, context: ToolContext) async -> ToolOutput {
        let start = ContinuousClock.now
        var slots = [ConvertResult?](repeating: nil, count: paths.count)
        var allowed: [(index: Int, url: URL)] = []
        var outputDirectory: URL?
        if let dir = options.outputDir {
            do { outputDirectory = try context.policy.check(dir, .write) } catch {
                return finish(paths.map { failedResult($0, error) }, start: start)
            }
        }
        for (index, path) in paths.enumerated() {
            do {
                let url = try context.policy.check(path, .read)
                if outputDirectory == nil { _ = try context.policy.check(url.deletingLastPathComponent().path, .write) }
                allowed.append((index, url))
            } catch {
                slots[index] = failedResult(path, error)
            }
        }
        if !allowed.isEmpty {
            let request = ConvertRequest(
                inputs: allowed.map(\.url), target: options.target, quality: options.quality, maxBytes: options.maxBytes,
                maxDimension: options.maxDimension, stripMetadata: options.stripMetadata, outputDirectory: outputDirectory,
                onConflict: options.onConflict, verify: options.verify, dryRun: options.dryRun)
            let report = await Engine.run(request, progress: context.progress)
            for (slot, result) in zip(allowed, report.results) { slots[slot.index] = result }
        }
        return finish(slots.compactMap { $0 }, start: start)
    }

    /// Wraps results as `{results, summary}`, the shape shared by `folio_convert` and `folio_run`.
    static func finish(_ results: [ConvertResult], start: ContinuousClock.Instant) -> ToolOutput {
        let ok = results.count { $0.status == .ok || $0.status == .planned }
        let failed = results.count { $0.status == .failed }
        let summary: JSONValue = [
            "ok": .int(Int64(results.count { $0.status == .ok })),
            "failed": .int(Int64(failed)),
            "skipped": .int(Int64(results.count { $0.status == .skipped })),
            "bytes_in": .int(results.reduce(0) { $0 + $1.bytesIn }),
            "bytes_out": .int(results.reduce(0) { $0 + ($1.bytesOut ?? 0) }),
            "duration_ms": .int(Int64(milliseconds(since: start))),
        ]
        var lines = results.map(Human.resultLine)
        if results.count > 1 { lines.append(Human.summaryLine(results, durationMs: milliseconds(since: start))) }
        return ToolOutput(
            structured: ["results": JSONValue(encoding: results), "summary": summary], text: lines.joined(separator: "\n"),
            image: nil, isError: failed > 0 && failed == results.count, ok: ok, failed: failed)
    }

    // MARK: Run a catalog tool

    public static func run(
        tool id: String, paths: [String], options: [String: String] = [:], outputDir: String? = nil, dryRun: Bool = false,
        context: ToolContext
    ) async -> ToolOutput {
        let start = ContinuousClock.now
        func failAll(_ error: any Error) -> ToolOutput { finish(paths.map { failedResult($0, error) }, start: start) }

        guard let tool = AgentCatalog.tool(id: id) else {
            return failAll(ConvertError(.unsupportedPair, "There's no Folio tool “\(id)”.", hint: "Run folio tools to list them."))
        }
        var values = Dictionary(uniqueKeysWithValues: tool.options.map { ($0.id, $0.defaultValue) })
        for (key, value) in options {
            guard let option = tool.options.first(where: { $0.id == key }) else {
                return failAll(ConvertError(.unsupportedInput, "\(id) has no option “\(key)”.", hint: optionHint(tool)))
            }
            guard option.choices.contains(where: { $0.value == value }) else {
                return failAll(ConvertError(.unsupportedInput, "“\(value)” isn't a choice for \(key).", hint: optionHint(tool)))
            }
            values[key] = value
        }
        var inputs: [URL] = []
        do {
            for path in paths {
                let url = try context.policy.check(path, .read)
                guard FileManager.default.fileExists(atPath: url.path) else { throw ConvertError(.notFound, "No file at \(path).") }
                guard tool.accepts(url) else {
                    throw ConvertError(
                        .unsupportedInput, "\(tool.title) doesn't take \(url.lastPathComponent).",
                        hint: "Call folio_inspect to see which tools accept it.")
                }
                // Catalog tools write next to their inputs.
                _ = try context.policy.check(url.deletingLastPathComponent().path, .write)
                inputs.append(url)
            }
            guard inputs.count >= tool.minimumInputs else {
                throw ConvertError(.unsupportedInput, "\(tool.title) needs at least \(tool.minimumInputs) files.")
            }
        } catch {
            return failAll(error)
        }
        var destination: URL?
        if let outputDir {
            do { destination = try context.policy.check(outputDir, .write) } catch { return failAll(error) }
        }
        let bytesIn = inputs.reduce(0) { $0 + Engine.fileSize($1) }

        if dryRun {
            return finish(
                inputs.map { ConvertResult(input: $0.path, status: .planned, bytesIn: Engine.fileSize($0), durationMs: 0) }, start: start)
        }

        context.progress?(0, inputs[0].lastPathComponent)
        var outputs: [URL]
        do {
            try Task.checkCancellation()
            outputs = try await tool.run(inputs, values)
            if let destination { outputs = try move(outputs, into: destination) }
        } catch {
            return failAll(error)
        }
        context.progress?(1, inputs[0].lastPathComponent)
        let duration = milliseconds(since: start)
        let results = outputs.enumerated().map { index, output -> ConvertResult in
            // One result per output. Paired one-to-one when counts match; otherwise every
            // output (a combined PDF, split pages) is credited to all inputs together.
            let paired = inputs.count == outputs.count
            let input = paired ? inputs[index] : inputs[0]
            var result = ConvertResult(
                input: input.path, status: .ok, bytesIn: paired ? Engine.fileSize(input) : bytesIn, durationMs: duration)
            let bytesOut = size(of: output)
            result.output = output.path
            result.method = "tool"
            result.bytesOut = bytesOut
            result.ratio = result.bytesIn > 0 ? (Double(bytesOut) / Double(result.bytesIn) * 1000).rounded() / 1000 : nil
            result.details = ["tool": .string(tool.id)]
            if !paired, inputs.count > 1 { result.details["inputs"] = .array(inputs.map { .string($0.path) }) }
            return result
        }
        return finish(results, start: start)
    }

    private static func optionHint(_ tool: FolioTool) -> String {
        tool.options.isEmpty
            ? "\(tool.id) takes no options."
            : "Options: " + tool.options.map { "\($0.id) = \($0.choices.map(\.value).joined(separator: " | "))" }.joined(separator: "; ")
    }

    /// Moves tool outputs into `folder` under free names. `moveItem` never overwrites.
    private static func move(_ outputs: [URL], into folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try outputs.map { url in
            let ext = url.pathExtension
            let target = FolioTool.unique(in: folder, name: url.deletingPathExtension().lastPathComponent, ext: ext)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    // MARK: Extract

    public static func extract(
        _ path: String, as kind: ExtractKind = .markdown, pages: ClosedRange<Int>? = nil, sheet: String? = nil, offset: Int = 0,
        maxChars: Int? = nil, context: ToolContext
    ) async -> ToolOutput {
        let text: String
        let url: URL
        do {
            url = try context.policy.check(path, .read)
            text = try await Engine.extract(url, as: kind, options: ExtractOptions(pages: pages, sheet: sheet))
        } catch {
            return .failure(Engine.wrap(error))
        }
        let total = text.count
        let from = min(max(offset, 0), total)
        let length = min(maxChars ?? total, total - from)
        let lower = text.index(text.startIndex, offsetBy: from)
        let slice = String(text[lower..<text.index(lower, offsetBy: length)])
        let truncated = from + length < total
        var structured: [String: JSONValue] = [
            "path": .string(url.path), "format": .string(kind.rawValue), "text": .string(slice), "chars": .int(Int64(length)),
            "total_chars": .int(Int64(total)), "offset": .int(Int64(from)), "truncated": .bool(truncated), "untrusted_content": true,
        ]
        if truncated { structured["next_offset"] = .int(Int64(from + length)) }
        return ToolOutput(structured: .object(structured), text: slice, image: nil, isError: false, ok: 1, failed: 0)
    }

    /// The model-facing wrapper: file text is data, so it's fenced and marked untrusted.
    /// A closing tag inside the file is defused so content can't break out of the fence.
    static func fenced(_ text: String, path: String) -> String {
        let attribute = path.replacing("&", with: "&amp;").replacing("\"", with: "&quot;").replacing("<", with: "&lt;")
        let body = text.replacing("</file-content", with: "<\\/file-content")
        return "<file-content path=\"\(attribute)\" untrusted=\"true\">\n\(body)\n</file-content>"
    }

    // MARK: Formats and tools

    public static func formats() -> ToolOutput {
        let pairs: [JSONValue] = Engine.formats().flatMap { from, targets in
            targets.map { target in
                [
                    "from": .string(from.rawValue), "to": .string(target.to.rawValue), "fidelity": .string(target.fidelity.rawValue),
                    "lossless_available": .bool(target.losslessAvailable), "drops": .array(target.drops.map { .string($0) }),
                ]
            }
        }
        let structured: JSONValue = [
            "pairs": .array(pairs),
            "qualities": .array(Quality.allCases.map { .string($0.rawValue) }),
            "tools": .array(AgentCatalog.all.map { .string($0.id) }),
            "version": .string(Version.current),
        ]
        let text =
            pairs.isEmpty
            ? "No conversion pairs are available in this build. Catalog tools: \(AgentCatalog.all.map(\.id).joined(separator: ", "))."
            : Engine.formats().map { "\($0.from.rawValue) → \($0.targets.map(\.to.rawValue).joined(separator: ", "))" }.joined(
                separator: "\n")
        return ToolOutput(structured: structured, text: text, image: nil, isError: false, ok: 1, failed: 0)
    }

    public static func tools() -> ToolOutput {
        ToolOutput(
            structured: ["tools": .array(AgentCatalog.all.map(AgentCatalog.describe))],
            text: AgentCatalog.all.map { "\($0.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \($0.subtitle)" }.joined(
                separator: "\n"),
            image: nil, isError: false, ok: 1, failed: 0)
    }

    // MARK: Helpers

    /// `ConvertResult` has no public initializer, so build it the way it decodes.
    static func failedResult(_ path: String, _ error: any Error) -> ConvertResult {
        var result = ConvertResult(input: path, status: .failed, bytesIn: 0, durationMs: 0)
        result.error = Engine.wrap(error)
        return result
    }

    static func size(of url: URL) -> Int64 {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else { return Engine.fileSize(url) }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { $0 as? URL } ?? []
        return files.reduce(0) { $0 + Engine.fileSize($1) }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

