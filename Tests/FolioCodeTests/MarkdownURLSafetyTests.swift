import Testing

@testable import FolioCode

/// The Markdown preview renders links into a web view, so link URLs must never be able
/// to run script. These cases are the classic allowlist bypasses.
@Suite("Markdown URL safety")
struct MarkdownURLSafetyTests {
    @Test(
        "Rejects script schemes, however they're disguised",
        arguments: [
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            "java\rscript:alert(1)",
            " javascript:alert(1)",
            "\u{1}javascript:alert(1)",
            "vbscript:msgbox(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "jav_ascript:alert(1)",
        ])
    func rejectsUnsafe(url: String) {
        #expect(MarkdownRenderer.safeURL(url, image: false) == nil)
    }

    @Test(
        "Allows ordinary links",
        arguments: [
            "https://example.com/a?b=c#d", "http://example.com", "mailto:hi@example.com",
            "/relative/path", "relative.md", "#heading", "?query=a:b", "folder/file:name.md",
        ])
    func allowsSafe(url: String) {
        #expect(MarkdownRenderer.safeURL(url, image: false) != nil)
    }

    @Test func dataURLsOnlyForRasterImages() {
        #expect(MarkdownRenderer.safeURL("data:image/png;base64,AAAA", image: true) != nil)
        #expect(MarkdownRenderer.safeURL("data:image/png;base64,AAAA", image: false) == nil)
        #expect(MarkdownRenderer.safeURL("data:image/svg+xml,<svg onload=alert(1)>", image: true) == nil)
    }
}
