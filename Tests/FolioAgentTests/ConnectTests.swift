import AppKit
import Testing

@testable import FolioAgent

@Suite("Connect", .timeLimit(.minutes(1)))
struct ConnectTests {
    let binary = "/Applications/Folio.app/Contents/Helpers/folio"

    func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("Merging JSON sets only mcpServers.folio and keeps everything else")
    func mergeKeepsOtherKeys() throws {
        let existing = #"{"theme":"dark","mcpServers":{"other":{"command":"x","args":["y"]},"folio":{"command":"/old","env":{"A":"1"}}}}"#
        let merged = try object(try #require(try Connect.merged(json: Data(existing.utf8), binary: binary)))
        #expect(merged["theme"] as? String == "dark")
        let servers = try #require(merged["mcpServers"] as? [String: Any])
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "x")
        let folio = try #require(servers["folio"] as? [String: Any])
        #expect(folio["command"] as? String == binary)
        #expect(folio["args"] as? [String] == ["mcp"])
        #expect((folio["env"] as? [String: String]) == ["A": "1"])
    }

    @Test("Merging is a no-op when already set, and refuses broken files")
    func mergeEdges() throws {
        let done = try #require(try Connect.merged(json: nil, binary: binary))
        #expect(try Connect.merged(json: Data(done.utf8), binary: binary) == nil)
        #expect(throws: ConnectError.self) { try Connect.merged(json: Data("{nope".utf8), binary: binary) }
        #expect(throws: ConnectError.self) { try Connect.merged(json: Data(#"{"mcpServers":[]}"#.utf8), binary: binary) }
    }

    @Test("Appending the Codex TOML table is idempotent and keeps the file")
    func tomlAppend() throws {
        let existing = "model = \"o4\"\n\n[mcp_servers.other]\ncommand = \"x\""
        let once = try #require(Connect.appendedTOML(existing, binary: binary))
        #expect(once.hasPrefix(existing + "\n\n"))
        #expect(once.contains("[mcp_servers.folio]\ncommand = \"\(binary)\"\nargs = [\"mcp\"]\n"))
        #expect(Connect.appendedTOML(once, binary: binary) == nil)
        #expect(Connect.appendedTOML("[ mcp_servers.\"folio\" ]\ncommand = \"y\"\n", binary: binary) == nil)
        #expect(Connect.appendedTOML("", binary: "/a \"b\"")?.contains(#"command = "/a \"b\"""#) == true)
    }

    @Test("Cursor: plan, apply with a backup, then nothing left to do")
    func cursorRoundTrip() throws {
        let home = try makeTempFolder()
        let env = Connect.Environment(home: home, binary: URL(fileURLWithPath: binary), searchPath: [])
        let file = home.appending(path: ".cursor/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: file)

        #expect(!Connect.isConnected(.cursor, in: env))
        let plan = try Connect.plan(for: .cursor, in: env)
        #expect(plan.changesSomething)
        #expect(plan.summary.contains("~/.cursor/mcp.json"))
        try Connect.apply(plan)
        #expect(Connect.isConnected(.cursor, in: env))
        #expect(FileManager.default.fileExists(atPath: file.path + ".folio-backup"))
        #expect(try Connect.plan(for: .cursor, in: env).action == .none)
    }

    @Test("Without the claude or codex commands, Folio prints or writes instead")
    func noCommands() throws {
        let home = try makeTempFolder()
        let env = Connect.Environment(home: home, binary: URL(fileURLWithPath: binary), searchPath: [])
        guard case .manual(let line) = try Connect.plan(for: .claude, in: env).action else {
            Issue.record("expected a manual step")
            return
        }
        #expect(line == "claude mcp add --scope user folio -- \(binary) mcp")
        guard case .write(let file, _) = try Connect.plan(for: .codex, in: env).action else {
            Issue.record("expected a file write")
            return
        }
        #expect(file.path.hasSuffix(".codex/config.toml"))
    }

    @Test("Install links ~/.local/bin/folio and is idempotent")
    func install() throws {
        let home = try makeTempFolder()
        let env = Connect.Environment(home: home, binary: URL(fileURLWithPath: binary), searchPath: [])
        try Connect.install(in: env)
        let link = home.appending(path: ".local/bin/folio").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == binary)
        #expect(try Connect.install(in: env).contains("already installed"))
    }

    @Test("Paths with spaces are quoted for the shell")
    func quoting() {
        #expect(Connect.shellLine(["claude", "/Volumes/My Disk/folio"]) == "claude '/Volumes/My Disk/folio'")
    }
}
