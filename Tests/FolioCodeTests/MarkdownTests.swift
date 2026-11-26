import Testing
@testable import FolioCode

/// Renders and strips `data-line` attributes so expectations stay readable.
private func html(_ markdown: String) -> String {
    MarkdownRenderer.render(markdown)
        .replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Markdown rendering")
struct MarkdownTests {
    @Test func headingsAndParagraphs() {
        #expect(html("# Hello *world*\n\nText") == "<h1 id=\"hello-world\">Hello <em>world</em></h1>\n<p>Text</p>")
        #expect(html("Title\n===\nSub\n---") == "<h1 id=\"title\">Title</h1>\n<h2 id=\"sub\">Sub</h2>")
        #expect(html("## Closed ##") == "<h2 id=\"closed\">Closed</h2>")
    }

    @Test func inlineFormatting() {
        #expect(html("**b** _i_ ***bi*** ~~s~~ `c<d>`") ==
            "<p><strong>b</strong> <em>i</em> <em><strong>bi</strong></em> <del>s</del> <code>c&lt;d&gt;</code></p>")
        #expect(html("snake_case_word and 2 * 3 * 4") == "<p>snake_case_word and 2 * 3 * 4</p>")
        #expect(html("\\*not em\\*") == "<p>*not em*</p>")
    }

    @Test func hardBreaks() {
        #expect(html("one  \ntwo\\\nthree\nfour") == "<p>one<br>\ntwo<br>\nthree\nfour</p>")
    }

    @Test func links() {
        #expect(html("[Folio](https://folio.app \"Home\")") == "<p><a href=\"https://folio.app\" title=\"Home\">Folio</a></p>")
        #expect(html("See [docs][d].\n\n[d]: https://x.dev/docs") == "<p>See <a href=\"https://x.dev/docs\">docs</a>.</p>")
        #expect(html("Visit https://example.com/a_b.") == "<p>Visit <a href=\"https://example.com/a_b\">https://example.com/a_b</a>.</p>")
        #expect(html("<https://a.b>") == "<p><a href=\"https://a.b\">https://a.b</a></p>")
        #expect(html("![Logo](img/logo.png)") == "<p><img src=\"img/logo.png\" alt=\"Logo\"></p>")
    }

    @Test func sanitizesScriptsAndDangerousURLs() {
        #expect(html("<script>alert(1)</script>") == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
        #expect(html("[x](javascript:alert(1))") == "<p>x</p>")
        #expect(html("![x](file:///etc/passwd)") == "<p>x</p>")
        #expect(html("<img src=x onerror=alert(1)>") == "<p>&lt;img src=x onerror=alert(1)&gt;</p>")
        #expect(html("[a](\"onmouseover=\"x)").contains("&quot;"))
    }

    @Test func fencedCodeIsHighlightedAndEscaped() {
        let out = html("```swift\nlet a = \"<b>\"\n```")
        #expect(out == "<pre><code class=\"language-swift\"><span class=\"tok-keyword\">let</span> a = <span class=\"tok-string\">&quot;&lt;b&gt;&quot;</span></code></pre>")
        #expect(html("    indented\n    code") == "<pre><code>indented\ncode</code></pre>")
    }

    @Test func lists() {
        #expect(html("- a\n- b\n  - c\n- d") == "<ul>\n<li>a</li>\n<li>b\n<ul>\n<li>c</li>\n</ul></li>\n<li>d</li>\n</ul>")
        #expect(html("3. x\n4. y") == "<ol start=\"3\">\n<li>x</li>\n<li>y</li>\n</ol>")
        #expect(html("- a\n\n- b") == "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>")
    }

    @Test func taskLists() {
        #expect(html("- [x] done\n- [ ] todo") ==
            "<ul class=\"contains-task-list\">\n<li class=\"task-list-item\"><input type=\"checkbox\" disabled checked> done</li>\n<li class=\"task-list-item\"><input type=\"checkbox\" disabled> todo</li>\n</ul>")
    }

    @Test func tablesWithAlignment() {
        let out = html("| A | B |\n|:--|--:|\n| 1 | `a|b` |")
        #expect(out == "<table>\n<thead>\n<tr><th style=\"text-align: left\">A</th><th style=\"text-align: right\">B</th></tr>\n</thead>\n<tbody>\n<tr><td style=\"text-align: left\">1</td><td style=\"text-align: right\"><code>a|b</code></td></tr>\n</tbody>\n</table>")
    }

    @Test func blockquotesAndRules() {
        #expect(html("> quote\nlazy\n\n---") == "<blockquote>\n<p>quote\nlazy</p>\n</blockquote>\n<hr>")
    }

    @Test func topLevelBlocksCarrySourceLines() {
        let out = MarkdownRenderer.render("# A\n\npara\n\n- x")
        #expect(out.contains("<h1 data-line=\"0\""))
        #expect(out.contains("<p data-line=\"2\">"))
        #expect(out.contains("<ul data-line=\"4\">"))
    }

    @Test func pageWrapsContentWithStrictCSP() {
        let page = HTMLPage.document(body: "<p>x</p>", title: "<T>")
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("<title>&lt;T&gt;</title>"))
        #expect(page.contains("prefers-color-scheme: dark"))
        #expect(!HTMLPage.document(body: "", title: "", appearance: .light).contains("prefers-color-scheme"))
    }
}
