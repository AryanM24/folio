import Foundation

/// Wraps rendered Markdown in a full HTML page styled with Hero tokens.
///
/// The preview and the HTML export share this, so what you export is what you saw. The
/// Content-Security-Policy forbids scripts and remote loads: the preview never touches the
/// network, even if a document links remote images.
nonisolated enum HTMLPage {
    enum Appearance { case automatic, light }

    /// The id of the element whose contents the preview replaces on each edit.
    static let contentID = "folio-content"

    static func document(body: String, title: String, appearance: Appearance = .automatic) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: file:">
        <title>\(MarkdownRenderer.escape(title))</title>
        <style>\(css(appearance))</style>
        </head>
        <body>
        <main id="\(contentID)">
        \(body)
        </main>
        </body>
        </html>
        """
    }

    static func css(_ appearance: Appearance) -> String {
        typealias P = SyntaxPalette
        func vars(_ pick: (P.Pair) -> UInt32) -> String {
            """
            --bg: \(P.css(pick(P.background))); --fg: \(P.css(pick(P.foreground))); --muted: \(P.css(pick(P.muted)));
            --border: \(P.css(pick(P.border))); --code-bg: \(P.css(pick(P.codeBackground))); --accent: \(P.css(pick(P.accent)));
            --link: \(P.css(pick(P.keyword))); --k: \(P.css(pick(P.keyword))); --t: \(P.css(pick(P.type)));
            --s: \(P.css(pick(P.string))); --n: \(P.css(pick(P.number)));
            """
        }
        let dark = appearance == .automatic ? "@media (prefers-color-scheme: dark) { :root { \(vars(\.dark)) } }" : ""
        return """
            :root { color-scheme: \(appearance == .automatic ? "light dark" : "light"); \(vars(\.light)) }
            \(dark)
            * { box-sizing: border-box; }
            html { background: var(--bg); }
            body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.65 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
            main { max-width: 760px; margin: 0 auto; padding: 28px 32px 64px; overflow-wrap: break-word; }
            h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.6em 0 0.6em; }
            main > :first-child { margin-top: 0; }
            h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4 { font-size: 1.05em; }
            h5, h6 { font-size: 0.95em; color: var(--muted); }
            p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
            a { color: var(--link); text-decoration: none; }
            a:hover { text-decoration: underline; }
            strong { font-weight: 600; }
            hr { border: 0; border-top: 1px solid var(--border); margin: 2em 0; }
            blockquote { padding: 0 0 0 16px; border-left: 3px solid var(--border); color: var(--muted); }
            ul, ol { padding-left: 1.6em; }
            li + li { margin-top: 0.25em; }
            li > ul, li > ol { margin: 0.25em 0 0; }
            .task-list-item { list-style: none; }
            .task-list-item input { margin: 0 0.5em 0 -1.35em; vertical-align: -1px; accent-color: var(--accent); }
            code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.86em; }
            code { background: var(--code-bg); border-radius: 6px; padding: 0.15em 0.4em; }
            pre { background: var(--code-bg); border-radius: 12px; padding: 14px 16px; overflow-x: auto; line-height: 1.5; }
            pre code { background: none; padding: 0; font-size: 1em; }
            table { border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: 1px solid var(--border); padding: 6px 12px; }
            th { font-weight: 600; background: var(--code-bg); }
            img { max-width: 100%; border-radius: 8px; }
            del { color: var(--muted); }
            .tok-keyword, .tok-tag, .tok-heading, .tok-property, .tok-link { color: var(--k); }
            .tok-type, .tok-variable { color: var(--t); }
            .tok-string, .tok-code { color: var(--s); }
            .tok-number, .tok-literal, .tok-attribute { color: var(--n); }
            .tok-comment, .tok-punctuation { color: var(--muted); }
            @media print { main { max-width: none; padding: 0; } pre { white-space: pre-wrap; } }
            """
    }
}
