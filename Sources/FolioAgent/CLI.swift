import Foundation

/// The `folio` command: `convert`, `inspect`, `extract`, `formats`, `tools`, `run`, `mcp`, `connect`.
public nonisolated enum CLI {
    /// Runs one invocation and returns the process exit code.
    public static func main(_ arguments: [String]) async -> Int32 {
        FileHandle.standardError.write(Data("folio: not implemented yet\n".utf8))
        return 2
    }
}
