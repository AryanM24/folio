import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import FolioConvert

@testable import FolioAgent

/// A fresh folder under the temporary directory, resolved (no /var → /private/var surprises).
func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "folio-agent-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: PathPolicy.resolve(url.path))
}

/// Collects what the server sends, one JSON line at a time.
final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var messages: [JSONValue] { lock.withLock { lines.compactMap(JSONValue.init(parsing:)) } }

    /// Waits until a message matches, up to `timeout`.
    func wait(timeout: Duration = .seconds(10), for match: (JSONValue) -> Bool) async -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = messages.first(where: match) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func response(_ id: Int) async -> JSONValue? {
        await wait { $0["id"] == .int(Int64(id)) && $0["method"] == nil }
    }
}

func makeServer(tools: [MCPTool] = MCPTools.all, roots: [URL]) -> (MCPServer, Outbox) {
    let outbox = Outbox()
    let server = MCPServer(tools: tools, policy: PathPolicy(roots: roots), rootsTimeout: .seconds(2)) { outbox.append($0) }
    return (server, outbox)
}

extension MCPServer {
    func receive(_ message: JSONValue) async { await receive(message.encoded) }
}
