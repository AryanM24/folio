import SwiftUI
import WebKit

/// Rendered preview for Markdown, HTML and SVG.
///
/// Page JavaScript is off and a Content-Security-Policy blocks remote loads, so previewing
/// a file can't run its scripts or contact the network. Markdown updates swap the content
/// element's HTML in place (no reload, so the scroll position holds); clicking a link opens
/// it in the default browser.
struct PreviewPane: NSViewRepresentable {
    enum Kind { case markdown, html, svg }

    let kind: Kind
    /// Markdown: the rendered body. HTML/SVG: the file's source.
    let content: String
    let title: String
    let baseURL: URL?
    /// Source line at the top of the editor, for scroll sync (Markdown).
    let topLine: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = CodeTheme.background
        webView.setAccessibilityLabel("Preview")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(webView, with: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var shownContent: String?
        private var pageLoaded = false
        private var scrolledLine = -1
        private var pendingLine: Int?

        func update(_ webView: WKWebView, with pane: PreviewPane) {
            if pane.content != shownContent {
                shownContent = pane.content
                switch pane.kind {
                case .markdown:
                    if pageLoaded {
                        // `evaluateJavaScript` runs as the app, unaffected by the page's JS setting.
                        webView.evaluateJavaScript("document.getElementById('\(HTMLPage.contentID)').innerHTML = \(Self.jsString(pane.content));")
                    } else {
                        webView.loadHTMLString(HTMLPage.document(body: pane.content, title: pane.title), baseURL: pane.baseURL)
                    }
                case .html:
                    pageLoaded = false
                    webView.loadHTMLString(Self.lockDown(pane.content), baseURL: pane.baseURL)
                case .svg:
                    pageLoaded = false
                    webView.loadHTMLString(Self.svgPage(pane.content), baseURL: pane.baseURL)
                }
            }
            if pane.kind == .markdown, pane.topLine != scrolledLine {
                if pageLoaded { scroll(webView, to: pane.topLine) } else { pendingLine = pane.topLine }
            }
        }

        private func scroll(_ webView: WKWebView, to line: Int) {
            scrolledLine = line
            webView.evaluateJavaScript("""
            (function(line) {
              var els = document.querySelectorAll('[data-line]'), target = null;
              for (var i = 0; i < els.length; i++) { if (+els[i].getAttribute('data-line') <= line) target = els[i]; else break; }
              window.scrollTo(0, target && line > 0 ? target.getBoundingClientRect().top + window.scrollY - 16 : 0);
            })(\(line));
            """)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            pageLoaded = true
            if let line = pendingLine {
                pendingLine = nil
                scroll(webView, to: line)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // In-page anchors scroll; everything else opens outside Folio.
            if url.fragment != nil, url.path == webView.url?.path || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }

        static func jsString(_ text: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
                  let json = String(data: data, encoding: .utf8) else { return "''" }
            return json
        }

        /// Adds a CSP to a user's HTML so its preview can't load anything from the network.
        static func lockDown(_ html: String) -> String {
            let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline' file:; img-src data: file:; font-src data: file:\">"
            if html.prefix(15).lowercased().hasPrefix("<!doctype"), let end = html.firstIndex(of: ">") {
                var copy = html
                copy.insert(contentsOf: csp, at: copy.index(after: end))
                return copy
            }
            return csp + html
        }

        static func svgPage(_ svg: String) -> String {
            let body = svg.range(of: "<svg", options: .caseInsensitive).map { String(svg[$0.lowerBound...]) } ?? svg
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; height: 100%; background: \(SyntaxPalette.css(SyntaxPalette.codeBackground.light)); }
            @media (prefers-color-scheme: dark) { html, body { background: \(SyntaxPalette.css(SyntaxPalette.codeBackground.dark)); } }
            body { display: grid; place-items: center; padding: 24px; box-sizing: border-box; }
            svg { max-width: 100%; max-height: 100%; height: auto; }
            </style></head><body>\(body)</body></html>
            """
        }
    }
}
