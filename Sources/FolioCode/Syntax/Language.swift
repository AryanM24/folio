import Foundation
import UniformTypeIdentifiers

/// A language the editor knows how to color, comment and preview.
public nonisolated enum Language: String, CaseIterable, Identifiable, Sendable {
    case plain, markdown
    case swift, javascript, typescript, java, kotlin, c, cpp, csharp, go, rust, php
    case python, ruby, shell, sql
    case html, xml, svg, css
    case json, yaml, toml, ini

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plain: "Plain Text"
        case .markdown: "Markdown"
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .go: "Go"
        case .rust: "Rust"
        case .php: "PHP"
        case .python: "Python"
        case .ruby: "Ruby"
        case .shell: "Shell"
        case .sql: "SQL"
        case .html: "HTML"
        case .xml: "XML"
        case .svg: "SVG"
        case .css: "CSS"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .ini: "INI"
        }
    }

    var lexer: any Lexer {
        switch self {
        case .plain: PlainLexer()
        case .markdown: MarkdownLexer()
        case .swift: GenericLexer(grammar: Grammars.swift)
        case .javascript: GenericLexer(grammar: Grammars.javascript)
        case .typescript: GenericLexer(grammar: Grammars.typescript)
        case .java: GenericLexer(grammar: Grammars.java)
        case .kotlin: GenericLexer(grammar: Grammars.kotlin)
        case .c: GenericLexer(grammar: Grammars.c)
        case .cpp: GenericLexer(grammar: Grammars.cpp)
        case .csharp: GenericLexer(grammar: Grammars.csharp)
        case .go: GenericLexer(grammar: Grammars.go)
        case .rust: GenericLexer(grammar: Grammars.rust)
        case .php: GenericLexer(grammar: Grammars.php)
        case .python: GenericLexer(grammar: Grammars.python)
        case .ruby: GenericLexer(grammar: Grammars.ruby)
        case .shell: GenericLexer(grammar: Grammars.shell)
        case .sql: GenericLexer(grammar: Grammars.sql)
        case .html, .xml, .svg: MarkupLexer()
        case .css: GenericLexer(grammar: Grammars.css)
        case .json: GenericLexer(grammar: Grammars.json)
        case .yaml: ConfigLexer(flavor: .yaml)
        case .toml: ConfigLexer(flavor: .toml)
        case .ini: ConfigLexer(flavor: .ini)
        }
    }

    /// Token for ⌘/ on a single line, if the language has one.
    var lineComment: String? {
        switch self {
        case .swift, .javascript, .typescript, .java, .kotlin, .c, .cpp, .csharp, .go, .rust, .php: "//"
        case .python, .ruby, .shell, .yaml, .toml: "#"
        case .ini: ";"
        case .sql: "--"
        case .plain, .markdown, .html, .xml, .svg, .css, .json: nil
        }
    }

    /// Used for ⌘/ when there's no line comment.
    var blockComment: (open: String, close: String)? {
        switch self {
        case .html, .xml, .svg, .markdown: ("<!--", "-->")
        case .css: ("/*", "*/")
        default: nil
        }
    }

    /// A trailing `:` opens an indented block (Python, YAML).
    var colonIndents: Bool { self == .python || self == .yaml }

    /// Quotes are auto-paired in code; in prose an apostrophe is far more likely.
    var pairsQuotes: Bool { self != .plain && self != .markdown }

    /// Languages with a rendered preview pane.
    var hasPreview: Bool { self == .markdown || self == .html || self == .svg }

    // MARK: Detection

    /// Picks a language from a file name, falling back to the declared content type and a
    /// shebang line. Plain text when nothing matches.
    static func detect(fileName: String?, contentType: UTType? = nil, firstLine: String? = nil) -> Language {
        if let fileName {
            let name = (fileName as NSString).lastPathComponent.lowercased()
            if let byName = byFileName[name] { return byName }
            let ext = (name as NSString).pathExtension
            if let byExt = byExtension[ext] { return byExt }
        }
        if let firstLine, firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return .python }
            if firstLine.contains("ruby") { return .ruby }
            if firstLine.contains("node") || firstLine.contains("deno") { return .javascript }
            if firstLine.contains("php") { return .php }
            return .shell
        }
        if let contentType {
            for (type, language) in byType where contentType.conforms(to: type) { return language }
        }
        return .plain
    }

    /// Matches the info string of a Markdown fence (```` ```swift ````).
    init?(fenceName: String) {
        let name = fenceName.lowercased()
        if let language = Language.byExtension[name] ?? Language.aliases[name] ?? Language(rawValue: name) {
            self = language
        } else {
            return nil
        }
    }

    private static let byExtension: [String: Language] = [
        "txt": .plain, "text": .plain, "log": .plain,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "swift": .swift,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "java": .java, "kt": .kotlin, "kts": .kotlin,
        "c": .c, "h": .c, "m": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "mm": .cpp,
        "cs": .csharp, "go": .go, "rs": .rust, "php": .php,
        "py": .python, "pyw": .python, "pyi": .python,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "command": .shell,
        "sql": .sql,
        "html": .html, "htm": .html, "xhtml": .html,
        "xml": .xml, "plist": .xml, "xib": .xml, "storyboard": .xml, "xsd": .xml, "xsl": .xml, "rss": .xml, "atom": .xml,
        "svg": .svg, "css": .css, "scss": .css, "less": .css,
        "json": .json, "jsonc": .json, "geojson": .json, "webmanifest": .json,
        "yaml": .yaml, "yml": .yaml, "toml": .toml,
        "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "env": .ini,
    ]

    private static let byFileName: [String: Language] = [
        "makefile": .shell, "dockerfile": .shell, ".bashrc": .shell, ".zshrc": .shell, ".bash_profile": .shell,
        ".profile": .shell, ".env": .ini, ".gitconfig": .ini, ".editorconfig": .ini,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "package.resolved": .json,
    ]

    private static let aliases: [String: Language] = [
        "objc": .c, "objective-c": .c, "c++": .cpp, "c#": .csharp, "golang": .go,
        "py": .python, "python3": .python, "sh": .shell, "bash": .shell, "zsh": .shell, "console": .shell,
        "js": .javascript, "node": .javascript, "ts": .typescript, "yml": .yaml, "text": .plain, "txt": .plain,
    ]

    private static let byType: [(UTType, Language)] = [
        (.swiftSource, .swift), (.pythonScript, .python), (.shellScript, .shell), (.javaScript, .javascript),
        (.json, .json), (.yaml, .yaml), (.svg, .svg), (.html, .html), (.xml, .xml), (.propertyList, .xml),
        (.cSource, .c), (.cHeader, .c), (.cPlusPlusSource, .cpp), (.rubyScript, .ruby), (.phpScript, .php),
        (UTType("net.daringfireball.markdown") ?? .plainText, .markdown),
    ]
}
