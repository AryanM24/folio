import FolioConvert
import Foundation

/// A local MCP server over stdio: newline-delimited JSON-RPC 2.0, written by hand with
/// Foundation (no SDK; Folio needs eight methods). See docs/AGENTS.md.
///
/// Each `tools/call` runs in its own task so `notifications/cancelled` can stop it, and every
/// outgoing line goes through one locked writer so lines never interleave.
public actor MCPServer {
    public static let protocolVersion = "2025-11-25"
    static let supportedVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26"]

    let tools: [MCPTool]
    let send: @Sendable (String) -> Void
    let defaultPolicy: PathPolicy
    private(set) var policy: PathPolicy
    private var clientHasRoots = false
    private var running: [String: Task<Void, Never>] = [:]
    private var pending: [String: CheckedContinuation<JSONValue?, Never>] = [:]
    private var rootsTask: Task<Void, Never>?
    private var nextRequest = 0
    /// How long to wait for the client to answer `roots/list` before using the defaults.
    let rootsTimeout: Duration

    /// `send` receives one JSON line at a time and must be safe to call from any thread.
    public init(
        tools: [MCPTool] = MCPTools.all, policy: PathPolicy = .standard(), rootsTimeout: Duration = .seconds(5),
        send: @escaping @Sendable (String) -> Void
    ) {
        self.tools = tools
        self.send = send
        self.defaultPolicy = policy
        self.policy = policy
        self.rootsTimeout = rootsTimeout
    }

    /// Serves stdin and stdout until the client closes stdin. Returns the exit code.
    public static func serveStdio() async -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        // Keep a private copy of stdout for JSON-RPC and point fd 1 at stderr, so a stray
        // print from any framework can never corrupt the protocol stream.
        let rpc = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let lock = NSLock()
        let server = MCPServer { line in
            lock.withLock { try? rpc.write(contentsOf: Data((line + "\n").utf8)) }
        }
        // stdin is read on its own thread: the main thread stays free for conversions that
        // hop to the main actor (PDF pagination, WebKit).
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        for await line in lines { await server.receive(line) }
        // stdin closed: finish what was asked (a piped batch), then exit.
        await server.drain()
        return 0
    }

    /// Waits until no tool call is running.
    func drain() async {
        while let task = running.values.first { await task.value }
    }

    // MARK: Incoming

    /// Handles one line from the client. Requests are answered through `send`.
    public func receive(_ line: String) async {
        guard !line.allSatisfy(\.isWhitespace) else { return }
        guard let message = JSONValue(parsing: line) else { return reply(error: -32700, "Parse error", id: .null) }
        guard message.object != nil else { return reply(error: -32600, "Invalid request", id: .null) }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            // A response to one of our requests (roots/list).
            if let id, let waiter = pending.removeValue(forKey: Self.key(id)) { waiter.resume(returning: message["result"]) }
            return
        }
        let params = message["params"]?.object ?? [:]
        guard let id, id != .null else { return notification(method, params) }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? ""
            clientHasRoots = params["capabilities"]?["roots"] != nil
            reply(
                [
                    "protocolVersion": .string(Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "folio", "title": "Folio", "version": .string(Version.current)],
                    "instructions":
                        "Folio converts, compresses, previews and reads local files on this Mac with built-in engines. Call folio_inspect first to see what a file can become. Folio only writes new files; it never changes or deletes inputs.",
                ], id: id)
        case "ping":
            reply([:], id: id)
        case "tools/list":
            reply(["tools": .array(tools.map(\.definition))], id: id)
        case "tools/call":
            call(params, id: id)
        default:
            reply(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    private func notification(_ method: String, _ params: [String: JSONValue]) {
        switch method {
        case "notifications/initialized", "notifications/roots/list_changed":
            if clientHasRoots { refreshRoots() }
        case "notifications/cancelled":
            if let id = params["requestId"] { running.removeValue(forKey: Self.key(id))?.cancel() }
        default:
            break  // other notifications need no action
        }
    }

    // MARK: Tools

    private func call(_ params: [String: JSONValue], id: JSONValue) {
        guard let name = params["name"]?.string, let tool = tools.first(where: { $0.name == name }) else {
            return reply(error: -32602, "Unknown tool: \(params["name"]?.string ?? "(none)")", id: id)
        }
        let arguments = Arguments(params["arguments"]?.object ?? [:])
        let progress = params["_meta"]?["progressToken"].map(progressReporter)
        let key = Self.key(id)
        running[key] = Task {
            let policy = await self.policyForCall()
            let output: ToolOutput
            do {
                output = try await tool.call(arguments, ToolContext(policy: policy, progress: progress))
            } catch let error as ArgumentError {
                output = .failure(
                    ConvertError(.unsupportedInput, error.message, hint: "Check the arguments against the tool's inputSchema."))
            } catch {
                output = .failure(Engine.wrapped(error))
            }
            // A cancelled request gets no response (MCP cancellation rules).
            if !Task.isCancelled { self.reply(Self.result(output, tool: tool.name), id: id) }
            self.finished(key)
        }
    }

    private func finished(_ key: String) { running[key] = nil }

    /// Ids of requests still running, for tests.
    var runningCount: Int { running.count }

    static func result(_ output: ToolOutput, tool: String) -> JSONValue {
        var content: [JSONValue] = []
        if let png = output.image {
            content.append(["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"])
        }
        // Older clients only read `content`, so it carries the data as JSON too (as the spec
        // suggests). Extract is the exception: its text is already the fenced file content.
        let text = tool == "folio_extract" && !output.isError ? output.text : output.text + "\n\n" + output.structured.encoded
        content.append(["type": "text", "text": .string(text)])
        return ["content": .array(content), "structuredContent": output.structured, "isError": .bool(output.isError)]
    }

    /// Progress notifications for one request, never going backwards and at most one per percent.
    private nonisolated func progressReporter(_ token: JSONValue) -> @Sendable (Double, String) -> Void {
        let last = Highest()
        let send = self.send
        return { fraction, name in
            let rounded = (min(max(fraction, 0), 1) * 100).rounded() / 100
            guard last.raise(to: rounded) else { return }
            let message: JSONValue = [
                "jsonrpc": "2.0", "method": "notifications/progress",
                "params": ["progressToken": token, "progress": .double(rounded), "total": 1.0, "message": .string(name)],
            ]
            send(message.encoded)
        }
    }

    // MARK: Roots

    private func refreshRoots() {
        rootsTask = Task {
            let result = await self.request("roots/list")
            let urls = result?["roots"]?.array?.compactMap { $0["uri"]?.string.flatMap(URL.init(string:)) }.filter(\.isFileURL) ?? []
            self.applyRoots(urls)
        }
    }

    private func applyRoots(_ urls: [URL]) {
        // No roots (or no answer) means the client isn't scoping us; use the defaults.
        policy = urls.isEmpty ? defaultPolicy : PathPolicy(roots: urls)
    }

    private func policyForCall() async -> PathPolicy {
        await rootsTask?.value
        return policy
    }

    /// Sends a request to the client and waits for its result, or `nil` after the timeout.
    private func request(_ method: String) async -> JSONValue? {
        nextRequest += 1
        let id = JSONValue.string("folio-\(nextRequest)")
        let key = Self.key(id)
        let timeout = rootsTimeout
        Task {
            try? await Task.sleep(for: timeout)
            self.resolve(key, with: nil)
        }
        return await withCheckedContinuation { continuation in
            pending[key] = continuation
            send((["jsonrpc": "2.0", "id": id, "method": .string(method)] as JSONValue).encoded)
        }
    }

    private func resolve(_ key: String, with value: JSONValue?) {
        pending.removeValue(forKey: key)?.resume(returning: value)
    }

    // MARK: Outgoing

    private func reply(_ result: JSONValue, id: JSONValue) {
        send((["jsonrpc": "2.0", "id": id, "result": result] as JSONValue).encoded)
    }

    private func reply(error code: Int, _ message: String, id: JSONValue) {
        send((["jsonrpc": "2.0", "id": id, "error": ["code": .int(Int64(code)), "message": .string(message)]] as JSONValue).encoded)
    }

    /// JSON-RPC ids are strings or numbers; `5` and `"5"` are different requests.
    static func key(_ id: JSONValue) -> String {
        switch id {
        case .string(let s): "s:" + s
        default: "n:" + id.encoded
        }
    }
}

/// A value that only goes up, shared by progress callbacks on any thread.
private nonisolated final class Highest: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1.0

    func raise(to new: Double) -> Bool {
        lock.withLock {
            guard new > value else { return false }
            value = new
            return true
        }
    }
}
