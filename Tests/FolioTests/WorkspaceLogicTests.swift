import AppKit
import FolioKit
import Testing

@testable import Folio

private func item(
    _ name: String, kind: FileKind? = nil, folder: Bool = false, size: Int64 = 0, modified: TimeInterval = 0, used: TimeInterval? = nil
) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isFolder: folder, kind: folder ? nil : kind ?? .document,
        size: folder ? nil : size, modified: Date(timeIntervalSince1970: modified), lastUsed: used.map(Date.init(timeIntervalSince1970:)),
        isFavorite: false)
}

@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    @Test func requiresCharactersInOrder() {
        #expect(FuzzyMatch.score("qrpt", in: "Q3 report.pdf") != nil)
        #expect(FuzzyMatch.score("tpr", in: "Q3 report.pdf") == nil)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }

    @Test func prefixAndRunsBeatScatteredMatches() throws {
        let prefix = try #require(FuzzyMatch.score("bud", in: "Budget.xlsx"))
        let scattered = try #require(FuzzyMatch.score("bud", in: "a big bad cloud.txt"))
        #expect(prefix > scattered)
        let wordStart = try #require(FuzzyMatch.score("plan", in: "Launch Plan.md"))
        let midWord = try #require(FuzzyMatch.score("plan", in: "explanation.md"))
        #expect(wordStart > midWord)
    }

    @Test func ignoresCaseAndSpaces() {
        #expect(FuzzyMatch.score("NEW doc", in: "New Document") != nil)
    }
}

@Suite("Sorting and filtering")
struct FileQueryTests {
    let items = [
        item("b.pdf", kind: .pdf, size: 300, modified: 10),
        item("Archive", folder: true, modified: 1),
        item("a.docx", size: 100, modified: 30),
        item("c.xlsx", kind: .spreadsheet, size: 200, modified: 20, used: 50),
    ]

    @Test func foldersStayOnTop() {
        for sort in FileSort.allCases {
            #expect(sort.sorted(items, ascending: true).first?.name == "Archive")
            #expect(sort.sorted(items, ascending: false).first?.name == "Archive")
        }
    }

    @Test func sortsByEachKey() {
        #expect(FileSort.name.sorted(items, ascending: true).map(\.name) == ["Archive", "a.docx", "b.pdf", "c.xlsx"])
        #expect(FileSort.size.sorted(items, ascending: false).map(\.name) == ["Archive", "b.pdf", "c.xlsx", "a.docx"])
        // Last opened beats last modified when it's newer.
        #expect(FileSort.lastOpened.sorted(items, ascending: false).map(\.name) == ["Archive", "c.xlsx", "a.docx", "b.pdf"])
    }

    @Test func chipsListOnlyKindsPresentWithCounts() {
        let chips = KindFilter.chips(for: items)
        #expect(chips.map(\.filter.kind) == [nil, .pdf, .document, .spreadsheet])
        #expect(chips.map(\.count) == [4, 1, 1, 1])
    }

    @Test func searchAndKindFilterCombine() {
        let pdfs = FileQuery.apply(items, query: "", filter: KindFilter(kind: .pdf), sort: .name, ascending: true)
        #expect(pdfs.map(\.name) == ["b.pdf"])
        let search = FileQuery.apply(items, query: "xls", filter: .all, sort: .name, ascending: true)
        #expect(search.map(\.name) == ["c.xlsx"])
    }
}

@Suite("Relative dates")
struct RelativeDateTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let locale = Locale(identifier: "en_US_POSIX")
    // Wednesday, March 12, 2025, 15:00 UTC.
    let now = Date(timeIntervalSince1970: 1_741_791_600)

    func string(_ secondsAgo: TimeInterval) -> String {
        RelativeDate.string(for: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale)
    }

    @Test func recentTimesAreRelative() {
        #expect(string(20) == "Just now")
        #expect(string(5 * 60) == "5 min ago")
        #expect(string(3 * 3600) == "3 hr ago")
        #expect(string(20 * 3600) == "Yesterday")
    }

    @Test func olderDatesUseWeekdayThenDate() {
        #expect(string(3 * 86400) == "Sunday")
        #expect(string(30 * 86400) == "Feb 10")
        #expect(string(400 * 86400) == "Feb 6, 2024")
    }
}

@Suite("Renaming")
struct FileNamingTests {
    let doc = URL(fileURLWithPath: "/tmp/Report.docx")

    @Test func keepsTheExtensionWhenLeftOut() {
        #expect(FileNaming.renamed(doc, to: "Final", isFolder: false)?.lastPathComponent == "Final.docx")
        #expect(FileNaming.renamed(doc, to: "Final.DOCX", isFolder: false)?.lastPathComponent == "Final.DOCX")
        #expect(FileNaming.renamed(URL(fileURLWithPath: "/tmp/Old"), to: "New.v2", isFolder: true)?.lastPathComponent == "New.v2")
    }

    @Test func rejectsNamesFinderWouldRefuse() {
        for bad in ["", "   ", ".hidden", "a/b", "a:b"] {
            #expect(FileNaming.renamed(doc, to: bad, isFolder: false) == nil, "\(bad)")
        }
    }
}

@Suite("New files and listings")
struct LibraryTests {
    func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "folio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func newFilesGetFinderStyleUniqueNames() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try NewFile.document.create(in: dir)
        let second = try NewFile.document.create(in: dir)
        #expect(first.lastPathComponent == "Untitled document.docx")
        #expect(second.lastPathComponent == "Untitled document 2.docx")
        #expect(try Data(contentsOf: first).starts(with: Data("PK".utf8)))
    }

    @Test func everyNewFileOpensInItsEditor() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for kind in NewFile.allCases {
            let url = try kind.create(in: dir)
            #expect(FileKind.kind(for: url) == kind.kind, "\(kind)")
        }
    }

    @Test func listingSkipsHiddenAndUneditableFiles() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "notes.md"))
        try Data().write(to: dir.appending(path: ".secret.md"))
        try Data().write(to: dir.appending(path: "setup.exe"))
        try FileManager.default.createDirectory(at: dir.appending(path: "Sub"), withIntermediateDirectories: true)
        let names = Set(FileItem.list(folder: dir).map(\.name))
        #expect(names == ["notes.md", "Sub"])
    }

    @Test func favoriteTagRoundTrips() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.txt")
        try Data().write(to: url)
        try Favorites.set(true, for: url)
        #expect(FileItem.load(url)?.isFavorite == true)
        try Favorites.set(false, for: url)
        #expect(FileItem.load(url)?.isFavorite == false)
    }
}

@Suite("Trusted folders")
struct TrustedFolderTests {
    @Test func filesInsideAChosenFolderAreTrustedEvenUnderLibrary() {
        let root = URL(fileURLWithPath: "/Users/me/Library/Application Support/Folio", isDirectory: true)
        #expect(TrustedFolders.contains(URL(fileURLWithPath: "/Users/me/Library/Application Support/Folio/Notes.md"), in: [root]))
        #expect(TrustedFolders.contains(URL(fileURLWithPath: "/Users/me/Library/Application Support/Folio/Sub/a.pdf"), in: [root]))
    }

    @Test func siblingsWithASharedPrefixAreNotTrusted() {
        let root = URL(fileURLWithPath: "/Users/me/Documents/Folio", isDirectory: true)
        #expect(!TrustedFolders.contains(URL(fileURLWithPath: "/Users/me/Documents/Folio Old/a.pdf"), in: [root]))
        #expect(!TrustedFolders.contains(URL(fileURLWithPath: "/Users/me/Library/Caches/a.pdf"), in: [root]))
    }

    @Test func trailingSlashesDoNotMatter() {
        let withSlash = URL(fileURLWithPath: "/tmp/lib/", isDirectory: true)
        let withoutSlash = URL(fileURLWithPath: "/tmp/lib")
        #expect(TrustedFolders.contains(URL(fileURLWithPath: "/tmp/lib/x.txt"), in: [withSlash]))
        #expect(TrustedFolders.contains(URL(fileURLWithPath: "/tmp/lib/x.txt"), in: [withoutSlash]))
    }
}
