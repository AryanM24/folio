import AppKit
import FolioConvert
import Testing

@testable import FolioAgent

@Suite("Path policy")
struct PathPolicyTests {
    func denied(_ policy: PathPolicy, _ path: String, _ access: PathPolicy.Access = .read) -> Bool {
        do {
            _ = try policy.check(path, access)
            return false
        } catch {
            return error.code == .pathNotAllowed
        }
    }

    @Test("Files inside a root are allowed and come back resolved")
    func inside() throws {
        let root = try makeTempFolder()
        let policy = PathPolicy(roots: [root])
        #expect(try policy.check(root.appending(path: "a.pdf").path, .read).path == root.path + "/a.pdf")
        // An output folder that doesn't exist yet still resolves.
        #expect(try policy.check(root.path + "/new/deeper", .write).path == root.path + "/new/deeper")
    }

    @Test("A sibling sharing the root's prefix is not inside it")
    func prefixTrick() throws {
        let base = try makeTempFolder()
        let docs = base.appending(path: "Docs")
        let evil = base.appending(path: "Docs-evil")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        let policy = PathPolicy(roots: [docs])
        #expect(denied(policy, evil.path + "/secret.txt"))
        #expect(!denied(policy, docs.path + "/fine.txt"))
    }

    @Test("A symlink inside a root can't reach outside it")
    func symlinkEscape() throws {
        let base = try makeTempFolder()
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "etc"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let policy = PathPolicy(roots: [root])
        #expect(denied(policy, root.path + "/link/secret.txt"))
        #expect(denied(policy, root.path + "/link/new-output", .write))
        #expect(denied(policy, root.path + "/etc/hosts"))
        #expect(denied(policy, root.path + "/../outside/secret.txt"))
    }

    @Test("Credential, Library and system folders are denied even under an allowed home")
    func alwaysDenied() throws {
        let home = try makeTempFolder()
        for folder in [".ssh", "Library/Preferences", "Library/Mobile Documents/com~apple~CloudDocs"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        let policy = PathPolicy(roots: [home, URL(fileURLWithPath: "/")], home: home)
        #expect(denied(policy, "~/.ssh/id_rsa"))
        #expect(denied(policy, home.path + "/.SSH/id_rsa"))  // case-insensitive volumes
        #expect(denied(policy, "~/.aws/credentials"))
        #expect(denied(policy, "~/Library/Preferences/x.plist"))
        #expect(denied(policy, "~/Library/LaunchAgents/evil.plist", .write))
        #expect(!denied(policy, "~/Library/Mobile Documents/com~apple~CloudDocs/report.docx"))
        #expect(denied(policy, "/etc/passwd"))
        #expect(denied(policy, "/usr/bin/true"))
        #expect(denied(policy, "/System/Library/CoreServices"))
    }

    @Test("Writes into .git are denied; reads are fine")
    func gitFolder() throws {
        let root = try makeTempFolder()
        let policy = PathPolicy(roots: [root])
        #expect(denied(policy, root.path + "/repo/.git/hooks", .write))
        #expect(!denied(policy, root.path + "/repo/.git/config", .read))
    }

    @Test("Relative paths resolve against the working folder")
    func relative() throws {
        let root = try makeTempFolder()
        let policy = PathPolicy(roots: [root], cwd: root)
        #expect(try policy.check("sub/a.png", .read).path == root.path + "/sub/a.png")
        #expect(denied(policy, "../elsewhere.png"))
    }
}
