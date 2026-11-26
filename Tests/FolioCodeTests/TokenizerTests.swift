import Testing
@testable import FolioCode

/// The text of every token of `kind`, in order.
private func spans(_ language: Language, _ source: String, _ kind: TokenKind) -> [String] {
    let units = Array(source.utf16)
    return language.lexer.tokenize(source).filter { $0.kind == kind }.map {
        String(decoding: units[$0.start..<$0.end], as: UTF16.self)
    }
}

@Suite("Tokenizers")
struct TokenizerTests {
    @Test func swiftKeywordsTypesStringsComments() {
        let code = #"let name: String = "hi" // greet"#
        #expect(spans(.swift, code, .keyword) == ["let"])
        #expect(spans(.swift, code, .type) == ["String"])
        #expect(spans(.swift, code, .string) == [#""hi""#])
        #expect(spans(.swift, code, .comment) == ["// greet"])
    }

    @Test func blockCommentSpansLines() {
        let code = "a /* one\ntwo */ let x = 1"
        #expect(spans(.swift, code, .comment) == ["/* one", "two */"])
        #expect(spans(.swift, code, .keyword) == ["let"])
        #expect(spans(.swift, code, .number) == ["1"])
    }

    @Test func swiftMultilineStringAndAttribute() {
        let code = "@MainActor\nlet s = \"\"\"\nhello\n\"\"\""
        #expect(spans(.swift, code, .attribute) == ["@MainActor"])
        #expect(spans(.swift, code, .string) == ["\"\"\"", "hello", "\"\"\""])
    }

    @Test func javascriptTemplateLiteralAndFunctionCall() {
        let code = "const t = `a\nb`; log(t)"
        #expect(spans(.javascript, code, .string) == ["`a", "b`"])
        #expect(spans(.javascript, code, .function) == ["log"])
        #expect(spans(.javascript, code, .keyword) == ["const"])
    }

    @Test func typescriptTypes() {
        #expect(spans(.typescript, "let n: number = 0", .type) == ["number"])
        #expect(spans(.typescript, "interface A {}", .keyword) == ["interface"])
    }

    @Test func cPreprocessorAndNumbers() {
        let code = "#include <stdio.h>\nint x = 0x1F + 1e-3;"
        #expect(spans(.c, code, .attribute) == ["#include"])
        #expect(spans(.c, code, .type) == ["int"])
        #expect(spans(.c, code, .number) == ["0x1F", "1e-3"])
    }

    @Test func goRawStringHasNoEscapes() {
        #expect(spans(.go, #"s := `C:\dir`"#, .string) == [#"`C:\dir`"#])
    }

    @Test func rustLifetimesDontOpenStrings() {
        let code = "fn f<'a>(x: &'a str) -> &'a str { x }"
        #expect(spans(.rust, code, .string).isEmpty)
        #expect(spans(.rust, code, .keyword) == ["fn"])
    }

    @Test func pythonTripleQuotesAndDecorators() {
        let code = "@cache\ndef f():\n    \"\"\"Doc\n    more\"\"\"\n    return None # done"
        #expect(spans(.python, code, .attribute) == ["@cache"])
        #expect(spans(.python, code, .keyword) == ["def", "return"])
        #expect(spans(.python, code, .literal) == ["None"])
        #expect(spans(.python, code, .comment) == ["# done"])
        #expect(spans(.python, code, .string).count == 2)
    }

    @Test func rubySymbolsAndIvars() {
        let code = "def go(x) = @count += x.fetch(:size)"
        #expect(spans(.ruby, code, .literal) == [":size"])
        #expect(spans(.ruby, code, .attribute) == ["@count"])
    }

    @Test func shellVariablesAndComments() {
        let code = "echo \"$HOME\" ${PATH} a#b # real comment"
        #expect(spans(.shell, code, .variable) == ["${PATH}"])
        #expect(spans(.shell, code, .comment) == ["# real comment"])
    }

    @Test func sqlIsCaseInsensitive() {
        let code = "SELECT id FROM users WHERE name = 'x' -- note"
        #expect(spans(.sql, code, .keyword) == ["SELECT", "FROM", "WHERE"])
        #expect(spans(.sql, code, .string) == ["'x'"])
        #expect(spans(.sql, code, .comment) == ["-- note"])
    }

    @Test func phpVariables() {
        #expect(spans(.php, "<?php $total = 1; # c", .variable) == ["$total"])
    }

    @Test func jsonKeysValuesLiterals() {
        let code = #"{"name": "Folio", "ok": true, "n": -1.5e3}"#
        #expect(spans(.json, code, .property) == [#""name""#, #""ok""#, #""n""#])
        #expect(spans(.json, code, .string) == [#""Folio""#])
        #expect(spans(.json, code, .literal) == ["true"])
        #expect(spans(.json, code, .number) == ["1.5e3"])
    }

    @Test func cssSelectorsPropertiesColors() {
        let code = ".card, a { color: #fff; margin: 4px }\n@media print {}"
        #expect(spans(.css, code, .type) == [".card"])
        #expect(spans(.css, code, .tag) == ["a", "print"])
        #expect(spans(.css, code, .property) == ["color", "margin"])
        #expect(spans(.css, code, .number) == ["#fff", "4px"])
        #expect(spans(.css, code, .attribute) == ["@media"])
    }

    @Test func htmlTagsAttributesCommentsEntities() {
        let code = "<a href=\"x\">Tom &amp; Jerry</a><!-- a\nb -->"
        #expect(spans(.html, code, .tag) == ["<a", ">", "</a", ">"])
        #expect(spans(.html, code, .attribute) == ["href"])
        #expect(spans(.html, code, .string) == ["\"x\""])
        #expect(spans(.html, code, .literal) == ["&amp;"])
        #expect(spans(.html, code, .comment) == ["<!-- a", "b -->"])
    }

    @Test func multiLineTagKeepsAttributeState() {
        #expect(spans(.svg, "<svg\n  width=\"10\">", .attribute) == ["width"])
    }

    @Test func yamlKeysCommentsAnchors() {
        let code = "name: Folio # app\nlist:\n  - &a 1\n  - true\n---"
        #expect(spans(.yaml, code, .property) == ["name", "list"])
        #expect(spans(.yaml, code, .comment) == ["# app"])
        #expect(spans(.yaml, code, .attribute) == ["&a"])
        #expect(spans(.yaml, code, .number) == ["1"])
        #expect(spans(.yaml, code, .literal) == ["true"])
    }

    @Test func tomlSectionsAndMultilineStrings() {
        let code = "[package]\nname = \"folio\"\ndoc = \"\"\"\nline\n\"\"\""
        #expect(spans(.toml, code, .keyword) == ["[package]"])
        #expect(spans(.toml, code, .property) == ["name", "doc"])
        #expect(spans(.toml, code, .string) == ["\"folio\"", "\"\"\"", "line", "\"\"\""])
    }

    @Test func iniSemicolonComments() {
        let code = "; note\n[core]\neditor = vim"
        #expect(spans(.ini, code, .comment) == ["; note"])
        #expect(spans(.ini, code, .property) == ["editor"])
        #expect(spans(.ini, code, .string) == ["vim"])
    }

    @Test func markdownStructure() {
        let code = "# Title\n- [x] **done** `code`\n```swift\nlet a\n```\n[link](http://a)"
        #expect(spans(.markdown, code, .heading) == ["# Title"])
        #expect(spans(.markdown, code, .keyword) == ["-", "[x]"])
        #expect(spans(.markdown, code, .punctuation).contains("**"))
        #expect(spans(.markdown, code, .code) == ["`code`", "let a"])
        #expect(spans(.markdown, code, .link) == ["[link]"])
    }

    @Test func snakeCaseIsNotEmphasis() {
        #expect(spans(.markdown, "use snake_case_name here", .punctuation).isEmpty)
    }

    @Test func plainHasNoTokens() {
        #expect(Language.plain.lexer.tokenize("let x = 1").isEmpty)
    }

    @Test("Detects language from names and extensions", arguments: [
        ("main.swift", Language.swift), ("App.tsx", .typescript), ("Makefile", .shell), ("README.md", .markdown),
        ("data.JSON", .json), ("ci.yml", .yaml), ("Cargo.toml", .toml), ("x.unknown", .plain), ("icon.svg", .svg),
    ])
    func detectsLanguage(name: String, expected: Language) {
        #expect(Language.detect(fileName: name) == expected)
    }

    @Test func detectsShebang() {
        #expect(Language.detect(fileName: "run", firstLine: "#!/usr/bin/env python3") == .python)
        #expect(Language.detect(fileName: "run", firstLine: "#!/bin/zsh") == .shell)
    }

    @Test func tokensAreOrderedAndInsideTheLine() {
        let samples: [(Language, String)] = [
            (.swift, "func f(_ a: Int) -> [String: Any] { return [\"a\": 1.0e10] } /* x"),
            (.markdown, "**a *b* `c` [d](e) <http://f> ~~g~~"), (.html, "<p class='x'>&nbsp;</p"),
            (.css, "a:hover{b:c}"), (.yaml, "- key: 'v' # c"), (.shell, "x=$(( $1 + 2 ))"),
        ]
        for (language, line) in samples {
            var last = 0
            for token in language.lexer.tokenize(line) {
                #expect(token.start >= last && token.end > token.start && token.end <= line.utf16.count, "\(language) \(token)")
                last = token.end
            }
        }
    }
}
