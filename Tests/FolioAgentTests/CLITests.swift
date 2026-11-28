import AppKit
import Testing

@testable import FolioAgent

@Suite("CLI", .timeLimit(.minutes(1)))
struct CLITests {
    @Test("Usage errors exit 2")
    func usageErrors() async {
        #expect(await CLI.main([]) == 2)
        #expect(await CLI.main(["frobnicate"]) == 2)
        #expect(await CLI.main(["convert"]) == 2)
        #expect(await CLI.main(["convert", "a.png", "--quality", "ultra"]) == 2)
        #expect(await CLI.main(["convert", "a.png", "--bogus"]) == 2)
        #expect(await CLI.main(["convert", "a.png", "--to"]) == 2)
        #expect(await CLI.main(["convert", "a.png", "--to", "zzz"]) == 2)
        #expect(await CLI.main(["extract", "a.pdf", "b.pdf"]) == 2)
        #expect(await CLI.main(["connect", "notepad"]) == 2)
        #expect(await CLI.main(["run", "pdf.rotate"]) == 2)
    }

    @Test("Version and help exit 0")
    func info() async {
        #expect(await CLI.main(["--version"]) == 0)
        #expect(await CLI.main(["--help"]) == 0)
        #expect(await CLI.main(["convert", "--help"]) == 0)
    }

    @Test("Nothing converted exits 3")
    func nothingConverted() async {
        #expect(await CLI.main(["convert", "/tmp/folio-agent-tests-missing.png", "--to", "jpeg", "--json"]) == 3)
        #expect(await CLI.main(["run", "pdf.rotate", "/tmp/folio-agent-tests-missing.pdf", "--json"]) == 3)
    }

    @Test("Exit codes follow ok and failed counts")
    func exitCodes() {
        #expect(CLI.exitCode(ok: 3, failed: 0) == 0)
        #expect(CLI.exitCode(ok: 0, failed: 0) == 0)
        #expect(CLI.exitCode(ok: 2, failed: 1) == 1)
        #expect(CLI.exitCode(ok: 0, failed: 2) == 3)
    }

    @Test("Options parse as --key value, --key=value, repeats and --")
    func parsing() throws {
        let run = try #require(CLI.commands.first { $0.name == "run" })
        let inv = try Invocation.parse(
            ["pdf.rotate", "a.pdf", "--opt", "degrees=90", "--opt=x=y", "--out=/tmp/o", "--json", "--", "--weird.pdf"], for: run)
        #expect(inv.positionals == ["pdf.rotate", "a.pdf", "--weird.pdf"])
        #expect(inv.repeatedValues("opt") == ["degrees=90", "x=y"])
        #expect(inv.value("out") == "/tmp/o")
        #expect(inv.has("json"))

        let convert = try #require(CLI.commands.first { $0.name == "convert" })
        #expect(throws: UsageError.self) { try Invocation.parse(["a", "--to", "pdf", "--to", "png"], for: convert) }
        #expect(throws: UsageError.self) { try Invocation.parse(["a", "--json=yes"], for: convert) }
    }

    @Test("Sizes accept units")
    func sizes() throws {
        #expect(try CLI.parseSize("25MB") == 25_000_000)
        #expect(try CLI.parseSize("800k") == 800_000)
        #expect(try CLI.parseSize("1.5 GB") == 1_500_000_000)
        #expect(try CLI.parseSize("1024") == 1024)
        #expect(throws: UsageError.self) { try CLI.parseSize("lots") }
    }
}
