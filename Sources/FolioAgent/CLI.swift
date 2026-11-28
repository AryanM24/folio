import FolioConvert
import FolioKit
import Foundation

/// The `folio` command. Every subcommand calls the same ``Agent`` operation as its MCP tool,
/// and `--json` prints exactly that tool's `structuredContent`.
///
/// Exit codes: 0 all ok, 1 some items failed, 2 usage error, 3 nothing done, 130 cancelled.
public nonisolated enum CLI {
    /// Runs one invocation and returns the process exit code.
    public static func main(_ arguments: [String]) async -> Int32 {
        guard let name = arguments.first else {
            print(usage)
            return 2
        }
        switch name {
        case "--version", "-v", "version":
            print("folio \(Version.current)")
            return 0
        case "--help", "-h", "help":
            if let topic = arguments.dropFirst().first, let command = commands.first(where: { $0.name == topic }) {
                print(command.help)
            } else {
                print(usage)
            }
            return 0
        case "mcp":
            return await MCPServer.serveStdio()
        default:
            break
        }
        guard let command = commands.first(where: { $0.name == name }) else {
            printError("folio: unknown command “\(name)”.\n\n\(usage)")
            return 2
        }
        let invocation: Invocation
        do {
            invocation = try Invocation.parse(Array(arguments.dropFirst()), for: command)
        } catch {
            printError("folio \(name): \((error as? UsageError)?.message ?? "\(error)")\nRun folio \(name) --help for usage.")
            return 2
        }
        if invocation.has("help") {
            print(command.help)
            return 0
        }
        return await cancellable {
            do {
                return try await command.run(invocation)
            } catch let error as UsageError {
                printError("folio \(name): \(error.message)\nRun folio \(name) --help for usage.")
                return 2
            } catch {
                printError("folio \(name): \(error.localizedDescription)")
                return 1
            }
        }
    }

    /// Ctrl-C cancels the running work (so temporary files are cleaned up) and exits 130.
    private static func cancellable(_ body: @escaping @Sendable () async -> Int32) async -> Int32 {
        signal(SIGINT, SIG_IGN)
        let task = Task { await body() }
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { task.cancel() }
        source.resume()
        let code = await task.value
        source.cancel()
        signal(SIGINT, SIG_DFL)
        return task.isCancelled ? 130 : code
    }

    // MARK: Commands

    struct Command: Sendable {
        let name: String
        let summary: String
        let help: String
        /// Options that take a value.
        var values: Set<String> = []
        /// Options that may repeat (`--opt k=v --opt k=v`).
        var repeated: Set<String> = []
        /// On/off switches.
        var flags: Set<String> = []
        let run: @Sendable (Invocation) async throws -> Int32
    }

    static let usage = """
        folio: convert, compress and read files on this Mac. Nothing leaves your Mac.

        Usage: folio <command> [options]

        Commands:
        \(commands.map { "  \($0.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.summary)" }.joined(separator: "\n"))
          mcp        Run the MCP server on stdin and stdout (for agents)

        Run folio <command> --help for a command's options. folio --version prints the version.
        """

    static let commands: [Command] = [
        Command(
            name: "convert", summary: "Convert or compress files",
            help: """
                Usage: folio convert <files…> [--to FORMAT] [options]

                Writes new files next to each input (never overwriting); inputs are never changed.
                Omit --to to compress in the same format.

                  --to FORMAT            pdf docx rtf odt html md txt xlsx ods csv tsv png jpeg heic tiff mp4 m4a wav …
                  --quality LEVEL        lossless | balanced | small (default balanced)
                  --max-bytes SIZE       size budget per output, e.g. 25MB
                  --max-dimension PX     longest side for images and video
                  --out DIR              write into DIR instead of next to each input
                  --on-conflict MODE     rename | skip | fail (default rename)
                  --strip-metadata       drop location, camera and other metadata
                  --verify, --no-verify  re-open and check outputs (default: on for lossless)
                  --dry-run              show the plan, write nothing
                  --json                 print the result as JSON
                """,
            values: ["to", "quality", "max-bytes", "max-dimension", "out", "on-conflict"],
            flags: ["strip-metadata", "verify", "no-verify", "dry-run", "json"]
        ) { inv in
            let paths = try inv.paths()
            var options = Agent.ConvertOptions()
            if let to = inv.value("to") {
                guard let format = Format(id: to) else { throw UsageError("“\(to)” isn't a format Folio knows. See folio formats.") }
                options.target = format
            }
            options.quality = try inv.choice("quality", Quality.allCases) ?? .balanced
            options.maxBytes = try inv.value("max-bytes").map(parseSize)
            options.maxDimension = try inv.int("max-dimension")
            options.outputDir = inv.value("out")
            options.onConflict = try inv.choice("on-conflict", [ConvertRequest.OnConflict.rename, .skip, .fail]) ?? .rename
            options.stripMetadata = inv.has("strip-metadata")
            options.verify = inv.has("no-verify") ? false : inv.has("verify") ? true : nil
            options.dryRun = inv.has("dry-run")
            return emit(await Agent.convert(paths, options: options, context: context(progress: !inv.has("json"))), json: inv.has("json"))
        },
        Command(
            name: "inspect", summary: "Show what files are and what they can become",
            help: """
                Usage: folio inspect <files…> [--json]

                Prints each file's format, size, key facts and every format it can be converted to.
                """,
            flags: ["json"]
        ) { inv in
            emit(await Agent.inspect(try inv.paths(), context: context()), json: inv.has("json"))
        },
        Command(
            name: "extract", summary: "Print a document's text or Markdown",
            help: """
                Usage: folio extract <file> [--markdown | --text] [options]

                  --markdown         Markdown (default)
                  --text             plain text
                  --pages 1-5        page range for PDFs and documents
                  --sheet NAME       one sheet of a spreadsheet
                  --offset N         start at character N
                  --max-chars N      stop after N characters
                  --json             print the result as JSON
                """,
            values: ["pages", "sheet", "offset", "max-chars"], flags: ["markdown", "text", "json"]
        ) { inv in
            let path = try inv.single()
            var pages: ClosedRange<Int>?
            if let raw = inv.value("pages") {
                guard let range = MCPTools.parsePages(raw) else { throw UsageError("--pages must look like 3 or 1-5.") }
                pages = range
            }
            let output = await Agent.extract(
                path, as: inv.has("text") ? .text : .markdown, pages: pages, sheet: inv.value("sheet"), offset: try inv.int("offset") ?? 0,
                maxChars: try inv.int("max-chars"), context: context())
            if inv.has("json") || output.isError { return emit(output, json: inv.has("json")) }
            print(output.text)
            if let next = output.structured["next_offset"]?.int { printError("(truncated; continue with --offset \(next))") }
            return 0
        },
        Command(
            name: "preview", summary: "Save a small PNG of a page, image or frame",
            help: """
                Usage: folio preview <file> [--page N] [--time SECONDS] [--max-dimension PX] [--out FILE.png] [--json]

                Saves the preview next to the file as “<name> preview.png” unless --out is given.
                """,
            values: ["page", "time", "max-dimension", "out"], flags: ["json"]
        ) { inv in
            let path = try inv.single()
            let policy = PathPolicy.standard()
            let output = await Agent.preview(
                path, page: try inv.int("page") ?? 1, time: try inv.double("time"), maxDimension: try inv.int("max-dimension") ?? 768,
                context: ToolContext(policy: policy))
            guard let png = output.image, let source = output.structured["path"]?.string else { return emit(output, json: inv.has("json")) }
            let destination: URL
            if let out = inv.value("out") {
                destination = try policy.check(out, .write)
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw UsageError("\(out) already exists; Folio doesn't overwrite.")
                }
            } else {
                let input = URL(fileURLWithPath: source)
                destination = try policy.check(
                    FolioTool.unique(
                        in: input.deletingLastPathComponent(), name: input.deletingPathExtension().lastPathComponent + " preview",
                        ext: "png"
                    ).path,
                    .write)
            }
            try png.write(to: destination, options: .withoutOverwriting)
            if inv.has("json") {
                print(output.structured.encoded)
                printError("Saved \(destination.path)")
            } else {
                print("\(output.text)  → \(destination.path)")
            }
            return 0
        },
        Command(
            name: "formats", summary: "List every supported conversion",
            help: "Usage: folio formats [--json]", flags: ["json"]
        ) { inv in emit(Agent.formats(), json: inv.has("json")) },
        Command(
            name: "tools", summary: "List the file tools folio run can use",
            help: "Usage: folio tools [--json]\n\nWith --json, includes each tool's options and choices.", flags: ["json"]
        ) { inv in emit(Agent.tools(), json: inv.has("json")) },
        Command(
            name: "run", summary: "Run a file tool (combine PDFs, make a GIF…)",
            help: """
                Usage: folio run <tool> <files…> [--opt key=value …] [--out DIR] [--dry-run] [--json]

                Example: folio run pdf.rotate scan.pdf --opt degrees=90
                Run folio tools for the list of tools and folio tools --json for their options.
                """,
            values: ["out"], repeated: ["opt"], flags: ["dry-run", "json"]
        ) { inv in
            guard inv.positionals.count >= 2 else { throw UsageError("Give a tool id and at least one file.") }
            var options: [String: String] = [:]
            for pair in inv.repeatedValues("opt") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw UsageError("--opt takes key=value, not “\(pair)”.") }
                options[parts[0]] = parts[1]
            }
            let output = await Agent.run(
                tool: inv.positionals[0], paths: Array(inv.positionals.dropFirst()), options: options, outputDir: inv.value("out"),
                dryRun: inv.has("dry-run"), context: context(progress: !inv.has("json")))
            return emit(output, json: inv.has("json"))
        },
        Command(
            name: "connect", summary: "Set up Folio in Claude Code, Claude Desktop, Cursor or Codex",
            help: """
                Usage: folio connect claude|claude-desktop|cursor|codex [--print]

                Registers this folio binary as an MCP server for the client.
                  --print    show what would change without changing anything
                """,
            flags: ["print"]
        ) { inv in
            let raw = try inv.single()
            guard let client = Connect.Client(rawValue: raw) else {
                throw UsageError("Unknown client “\(raw)”. Use one of: \(Connect.targets.map(\.rawValue).joined(separator: ", ")).")
            }
            let plan = try Connect.plan(for: client)
            for warning in plan.warnings { printError("Warning: \(warning)") }
            if inv.has("print") || !plan.changesSomething {
                print(plan.summary)
                if case .manual = plan.action { return 1 }
                return 0
            }
            print(plan.summary)
            print(try Connect.apply(plan))
            return 0
        },
        Command(
            name: "install", summary: "Put folio on your PATH (~/.local/bin)",
            help: "Usage: folio install\n\nLinks ~/.local/bin/folio to this binary. No admin rights needed."
        ) { _ in
            print(try Connect.install())
            return 0
        },
    ]

    // MARK: Output

    private static func emit(_ output: ToolOutput, json: Bool) -> Int32 {
        if json {
            print(output.structured.encoded)
        } else if output.isError, output.failed == 1, output.ok == 0, output.structured["error"] != nil {
            printError(output.text)
        } else {
            print(output.text)
        }
        return exitCode(ok: output.ok, failed: output.failed)
    }

    static func exitCode(ok: Int, failed: Int) -> Int32 {
        failed == 0 ? 0 : ok == 0 ? 3 : 1
    }

    /// Progress goes to stderr, and only when a person is watching.
    private static func context(progress: Bool = false) -> ToolContext {
        guard progress, isatty(STDERR_FILENO) == 1 else { return ToolContext(policy: .standard()) }
        return ToolContext(policy: .standard()) { fraction, name in
            let line = fraction >= 1 ? "\r\u{1B}[K" : "\r\u{1B}[K\(Int(fraction * 100))%  \(name)"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// "25MB", "800K", "1.5 GB" or plain bytes. Decimal units, as Finder shows sizes.
    static func parseSize(_ text: String) throws -> Int64 {
        let trimmed = text.uppercased().filter { !$0.isWhitespace }
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
        let (number, scale) = units.first { trimmed.hasSuffix($0.0) }.map { (String(trimmed.dropLast($0.0.count)), $0.1) } ?? (trimmed, 1)
        guard let value = Double(number), value > 0 else { throw UsageError("--max-bytes takes a size like 25MB, not “\(text)”.") }
        return Int64(value * scale)
    }
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Parsed arguments for one command. Hand-rolled: `--key value`, `--key=value`, `--flag`,
/// and `--` to end options.
nonisolated struct Invocation: Sendable {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static func parse(_ arguments: [String], for command: CLI.Command) throws -> Invocation {
        var result = Invocation()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--" {
                result.positionals += rest
                break
            }
            guard argument.hasPrefix("-"), argument.count > 1 else {
                result.positionals.append(argument)
                continue
            }
            let body = argument.drop { $0 == "-" }
            let (name, inline) =
                body.firstIndex(of: "=").map { (String(body[..<$0]), String(body[body.index(after: $0)...])) } ?? (String(body), nil)
            if name == "help" || name == "h" {
                result.flags.insert("help")
            } else if command.values.contains(name) || command.repeated.contains(name) {
                guard let value = inline ?? rest.popFirst() else { throw UsageError("--\(name) needs a value.") }
                if command.values.contains(name), result.values[name] != nil { throw UsageError("--\(name) was given twice.") }
                result.values[name, default: []].append(value)
            } else if command.flags.contains(name), inline == nil {
                result.flags.insert(name)
            } else {
                throw UsageError("Unknown option \(argument).")
            }
        }
        return result
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ name: String) -> String? { values[name]?.last }
    func repeatedValues(_ name: String) -> [String] { values[name] ?? [] }

    func int(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let n = Int(raw), n >= 0 else { throw UsageError("--\(name) takes a whole number, not “\(raw)”.") }
        return n
    }

    func double(_ name: String) throws -> Double? {
        guard let raw = value(name) else { return nil }
        guard let n = Double(raw), n >= 0 else { throw UsageError("--\(name) takes a number, not “\(raw)”.") }
        return n
    }

    func choice<T: RawRepresentable>(_ name: String, _ cases: [T]) throws -> T? where T.RawValue == String {
        guard let raw = value(name) else { return nil }
        guard let value = cases.first(where: { $0.rawValue == raw }) else {
            throw UsageError("--\(name) must be one of: \(cases.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }

    func paths() throws -> [String] {
        guard !positionals.isEmpty else { throw UsageError("Give at least one file.") }
        guard positionals.count <= Agent.maxFiles else { throw UsageError("At most \(Agent.maxFiles) files at a time.") }
        return positionals
    }

    func single() throws -> String {
        guard positionals.count == 1 else { throw UsageError(positionals.isEmpty ? "Give one file." : "Give exactly one file.") }
        return positionals[0]
    }
}
