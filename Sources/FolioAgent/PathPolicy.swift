public import FolioConvert
public import Foundation

/// Which files an agent may make Folio read or write.
///
/// Every input and output folder passes through ``check(_:_:)`` first. Paths are resolved
/// with `realpath` before they're compared, and compared by path component, which closes the
/// two holes found in the reference filesystem MCP server: a symlink inside an allowed
/// folder pointing outside it (CVE-2025-53109), and `/Users/me/Docs-evil` passing a
/// string-prefix check for `/Users/me/Docs` (CVE-2025-53110).
public nonisolated struct PathPolicy: Sendable {
    public enum Access: Sendable { case read, write }

    /// Resolved allowed folders.
    public let roots: [String]
    let home: String
    /// Resolved folders that are never allowed, whatever the roots say.
    let denied: [String]
    /// Exceptions inside `denied` (iCloud Drive lives under ~/Library).
    let reallowed: [String]
    /// Relative paths resolve against this.
    let cwd: String

    public init(roots: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser, cwd: URL? = nil) {
        let home = Self.resolve(home.path(percentEncoded: false))
        self.home = home
        self.cwd = Self.resolve((cwd ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path(percentEncoded: false))
        self.roots = roots.map { Self.resolve($0.path(percentEncoded: false)) }
        denied =
            ["Library", ".ssh", ".aws", ".gnupg", ".config", ".kube", ".docker"].map { home + "/" + $0 }
            + ["/System", "/usr", "/etc", "/private/etc", "/bin", "/sbin", "/Library/Keychains", "/private/var/db"]
        reallowed = [home + "/Library/Mobile Documents"]
    }

    /// The default when the client sends no roots: the working folder, home, external
    /// volumes, /tmp and this user's temporary folder (`$TMPDIR`), plus anything in `FOLIO_ALLOWED_DIRS` (colon-separated).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> PathPolicy {
        let fm = FileManager.default
        var roots = [
            URL(fileURLWithPath: fm.currentDirectoryPath), fm.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Volumes"),
            URL(fileURLWithPath: "/tmp"), fm.temporaryDirectory,
        ]
        if let extra = environment["FOLIO_ALLOWED_DIRS"] {
            roots += extra.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return PathPolicy(roots: roots)
    }

    /// Resolves `path` and returns it if allowed, else throws `PATH_NOT_ALLOWED`.
    ///
    /// The returned URL is the resolved one: callers must use it, not the original string,
    /// so a symlink can't be swapped between the check and the use.
    public func check(_ path: String, _ access: Access) throws(ConvertError) -> URL {
        let expanded = path.hasPrefix("~/") || path == "~" ? home + path.dropFirst() : path
        let absolute = expanded.hasPrefix("/") ? expanded : cwd + "/" + expanded
        let resolved = Self.resolve(absolute)
        let parts = Self.components(resolved)

        func inside(_ folder: String) -> Bool {
            let f = Self.components(folder)
            return parts.count >= f.count && Array(parts.prefix(f.count)) == f
        }
        let isDenied = denied.contains(where: inside) && !reallowed.contains(where: inside)
        guard roots.contains(where: inside), !isDenied else {
            throw ConvertError(
                .pathNotAllowed, "Folio isn't allowed to \(access == .read ? "read" : "write") \(path).",
                hint: isDenied
                    ? "System, Library and credential folders are always off limits."
                    : "Allowed folders: \(roots.joined(separator: ", ")). Set FOLIO_ALLOWED_DIRS or add a root in your client to widen this."
            )
        }
        if access == .write, parts.contains(".git") {
            throw ConvertError(.pathNotAllowed, "Folio doesn't write inside .git folders.", hint: "Choose an output folder outside .git.")
        }
        return URL(fileURLWithPath: resolved)
    }

    /// `realpath` of the longest existing prefix, with the missing tail appended, so output
    /// folders that don't exist yet still resolve through any symlinked parent.
    static func resolve(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let last = ns.lastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        let base = resolve(parent)
        switch last {
        case "..": return (base as NSString).deletingLastPathComponent
        case ".", "": return base
        default: return base == "/" ? "/" + last : base + "/" + last
        }
    }

    /// Lowercased: the Mac's default volumes ignore case, so `~/.SSH` is `~/.ssh`.
    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.lowercased() }
    }
}
