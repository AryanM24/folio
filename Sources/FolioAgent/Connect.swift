public import Foundation

/// Registers Folio's MCP server with agent clients. Used by `folio connect` and the app's
/// Settings > Agents pane.
///
/// This edits another app's configuration, so it always works in two steps: ``plan(for:in:)``
/// says exactly what would change, and only ``apply(_:)`` changes anything. File edits touch
/// only the `folio` entry, keep a backup and are written atomically.
public nonisolated enum Connect {
    public enum Client: String, CaseIterable, Sendable, Identifiable {
        case claude, claudeDesktop = "claude-desktop", cursor, codex
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .claude: "Claude Code"
            case .claudeDesktop: "Claude Desktop"
            case .cursor: "Cursor"
            case .codex: "Codex"
            }
        }
    }

    public static let targets = Client.allCases

    public struct Plan: Sendable {
        public enum Action: Sendable, Equatable {
            /// Already set up; nothing to do.
            case none
            /// Run these commands in order (`claude mcp add …`).
            case run([[String]])
            /// Replace this file with new contents (after a backup).
            case write(URL, String)
            /// Folio can't do it itself; show this to the person.
            case manual(String)
        }
        public let client: Client
        public let action: Action
        /// What will change, in plain words, shown before anything happens.
        public let summary: String
        public let warnings: [String]
        public var changesSomething: Bool {
            switch action {
            case .run, .write: true
            case .none, .manual: false
            }
        }
    }

    /// Where to look and what to register. Tests pass their own.
    public struct Environment: Sendable {
        public var home: URL
        public var binary: URL
        /// Folders searched for the `claude` and `codex` commands.
        public var searchPath: [String]

        public init(home: URL, binary: URL, searchPath: [String]) {
            self.home = home
            self.binary = binary
            self.searchPath = searchPath
        }

        public static var current: Environment {
            let home = FileManager.default.homeDirectoryForCurrentUser
            // GUI apps don't inherit the shell PATH, so also look where installers put these.
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let extra = [home.path + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home.path + "/.claude/local"]
            return Environment(home: home, binary: binaryURL, searchPath: path + extra)
        }
    }

    /// The `folio` binary to register: this executable when it's the CLI, else the helper
    /// inside the running app, else (a SwiftPM build of the app) the sibling `folio-cli`.
    public static var binaryURL: URL {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        if exe.lastPathComponent == "folio" || exe.lastPathComponent == "folio-cli" { return exe }
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL.appending(path: "Contents/Helpers/folio") }
        return exe.deletingLastPathComponent().appending(path: "folio-cli")
    }

    /// The one-liner people can paste into Terminal.
    public static func claudeCommand(binary: URL = binaryURL) -> String {
        shellLine(["claude", "mcp", "add", "--scope", "user", "folio", "--", binary.path, "mcp"])
    }

    // MARK: Plan

    public static func plan(for client: Client, in env: Environment = .current) throws -> Plan {
        let binary = env.binary.path
        let warnings = self.warnings(for: env.binary)
        switch client {
        case .claude:
            let configured = claudeEntry(env)
            if configured?["command"] as? String == binary {
                return Plan(client: client, action: .none, summary: "Claude Code already uses Folio.", warnings: warnings)
            }
            let add = ["mcp", "add", "--scope", "user", "folio", "--", binary, "mcp"]
            guard let claude = find("claude", in: env) else {
                return Plan(
                    client: client, action: .manual(claudeCommand(binary: env.binary)),
                    summary: "Folio couldn't find the claude command. Run this in Terminal:\n\(claudeCommand(binary: env.binary))",
                    warnings: warnings)
            }
            var commands = [[claude] + add]
            if configured != nil { commands.insert([claude, "mcp", "remove", "--scope", "user", "folio"], at: 0) }
            return Plan(
                client: client, action: .run(commands), summary: "Runs:\n" + commands.map(shellLine).joined(separator: "\n"),
                warnings: warnings)

        case .claudeDesktop, .cursor:
            let file = configFile(client, env)
            let existing = try? Data(contentsOf: file)
            guard let merged = try merged(json: existing, binary: binary) else {
                return Plan(client: client, action: .none, summary: "\(client.title) already uses Folio.", warnings: warnings)
            }
            let entry = shellJSON(["command": binary, "args": ["mcp"]])
            let backup = existing == nil ? "" : " A backup goes to \(file.lastPathComponent).folio-backup."
            return Plan(
                client: client, action: .write(file, merged),
                summary: "Sets mcpServers.folio in \(tilde(file, env)) to:\n\(entry)\nOther settings stay as they are.\(backup)",
                warnings: warnings)

        case .codex:
            let file = configFile(client, env)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard let appended = appendedTOML(existing, binary: binary) else {
                return Plan(client: client, action: .none, summary: "Codex already has a folio server.", warnings: warnings)
            }
            if let codex = find("codex", in: env) {
                let command = [codex, "mcp", "add", "folio", "--", binary, "mcp"]
                return Plan(client: client, action: .run([command]), summary: "Runs:\n" + shellLine(command), warnings: warnings)
            }
            let added = String(appended.dropFirst(existing.count)).trimmingCharacters(in: .newlines)
            return Plan(
                client: client, action: .write(file, appended), summary: "Appends to \(tilde(file, env)):\n\(added)", warnings: warnings)
        }
    }

    /// Carries out a plan. Returns a one-line confirmation.
    @discardableResult
    public static func apply(_ plan: Plan) throws -> String {
        switch plan.action {
        case .none:
            return plan.summary
        case .manual(let text):
            return text
        case .run(let commands):
            for command in commands { try run(command) }
            return "Connected \(plan.client.title). Restart it, or start a new session, to load Folio."
        case .write(let file, let contents):
            let fm = FileManager.default
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: file.path) {
                let backup = file.appendingPathExtension("folio-backup")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: file, to: backup)
            }
            try Data(contents.utf8).write(to: file, options: .atomic)
            return "Connected \(plan.client.title). Restart it to load Folio."
        }
    }

    /// Whether the client's configuration has a `folio` server.
    public static func isConnected(_ client: Client, in env: Environment = .current) -> Bool {
        switch client {
        case .claude:
            return claudeEntry(env) != nil
        case .claudeDesktop, .cursor:
            guard let data = try? Data(contentsOf: configFile(client, env)),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return (root["mcpServers"] as? [String: Any])?["folio"] != nil
        case .codex:
            return appendedTOML((try? String(contentsOf: configFile(client, env), encoding: .utf8)) ?? "", binary: "") == nil
        }
    }

    // MARK: Install the command

    /// Symlinks `~/.local/bin/folio` to the binary. No admin rights needed.
    @discardableResult
    public static func install(in env: Environment = .current) throws -> String {
        let fm = FileManager.default
        let bin = env.home.appending(path: ".local/bin")
        let link = bin.appending(path: "folio")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if target == env.binary.path { return "folio is already installed at \(tilde(link, env))." }
            try fm.removeItem(at: link)  // removes the link only, never what it points at
        } else if fm.fileExists(atPath: link.path) {
            throw ConnectError("\(tilde(link, env)) already exists and isn't a link to Folio. Move it away and try again.")
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: env.binary.path)
        var message = "Installed \(tilde(link, env)) → \(env.binary.path)."
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if !path.contains(bin.path) {
            message += "\n~/.local/bin isn't on your PATH. Add it with:\n  echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"
        }
        return message
    }

    // MARK: Pieces (internal for tests)

    static func configFile(_ client: Client, _ env: Environment) -> URL {
        switch client {
        case .claude: env.home.appending(path: ".claude.json")
        case .claudeDesktop: env.home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: env.home.appending(path: ".cursor/mcp.json")
        case .codex: env.home.appending(path: ".codex/config.toml")
        }
    }

    /// Claude Code keeps user-scope servers in `~/.claude.json` under `mcpServers`.
    static func claudeEntry(_ env: Environment) -> [String: Any]? {
        guard let data = try? Data(contentsOf: configFile(.claude, env)),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (root["mcpServers"] as? [String: Any])?["folio"] as? [String: Any]
    }

    /// The config with `mcpServers.folio` set, or `nil` when it's already right.
    /// Other keys, including other keys of an existing folio entry (like `env`), are kept.
    static func merged(json existing: Data?, binary: String) throws -> String? {
        var root: [String: Any] = [:]
        if let existing, !String(decoding: existing, as: UTF8.self).allSatisfy(\.isWhitespace) {
            guard let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw ConnectError("The config file isn't valid JSON, so Folio left it alone. Fix it, or add the entry by hand.")
            }
            root = object
        }
        var servers: [String: Any] = [:]
        if let value = root["mcpServers"] {
            guard let dict = value as? [String: Any] else {
                throw ConnectError("mcpServers in the config file isn't an object, so Folio left it alone.")
            }
            servers = dict
        }
        var entry = servers["folio"] as? [String: Any] ?? [:]
        if entry["command"] as? String == binary, entry["args"] as? [String] == ["mcp"] { return nil }
        entry["command"] = binary
        entry["args"] = ["mcp"]
        servers["folio"] = entry
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// `existing` plus a `[mcp_servers.folio]` table, or `nil` if one is already there.
    /// Appending (never rewriting) keeps a hand-edited file intact.
    static func appendedTOML(_ existing: String, binary: String) -> String? {
        let headers: Set<String> = ["[mcp_servers.folio]", "[mcp_servers.\"folio\"]", "[mcp_servers.'folio']"]
        let present = existing.split(whereSeparator: \.isNewline).contains { line in
            headers.contains(line.filter { !$0.isWhitespace })
        }
        if present { return nil }
        let escaped = binary.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        let separator = existing.isEmpty ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + separator + "[mcp_servers.folio]\ncommand = \"\(escaped)\"\nargs = [\"mcp\"]\n"
    }

    static func warnings(for binary: URL) -> [String] {
        let path = binary.path
        var warnings: [String] = []
        if path.contains("/AppTranslocation/") {
            warnings.append(
                "Folio is running from a temporary location. Move it to Applications and open it again, or this path will stop working.")
        } else if path.contains("/Downloads/") {
            warnings.append("Folio is in Downloads. Move it to Applications first so the path keeps working.")
        } else if path.contains("/.build/") {
            warnings.append("This is a development build; the path changes when you rebuild.")
        }
        if !FileManager.default.isExecutableFile(atPath: path) { warnings.append("There's no folio binary at \(path).") }
        return warnings
    }

    static func find(_ command: String, in env: Environment) -> String? {
        env.searchPath.lazy.map { ($0 as NSString).appendingPathComponent(command) }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func run(_ command: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        // `claude` is a Node script; from a GUI app, `env node` needs the usual folders on PATH.
        var environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: command[0]).deletingLastPathComponent().path
        environment["PATH"] = [folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""].joined(
            separator: ":")
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw ConnectError("\(shellLine(command)) failed: \(message.isEmpty ? "exit \(process.terminationStatus)" : message)")
        }
    }

    static func shellLine(_ words: [String]) -> String {
        words.map { word in
            word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) })
                ? word : "'" + word.replacing("'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    private static func shellJSON(_ object: [String: Any]) -> String {
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func tilde(_ url: URL, _ env: Environment) -> String {
        let home = env.home.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

public nonisolated struct ConnectError: Error, LocalizedError, Sendable {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
