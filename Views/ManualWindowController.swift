//  ManualWindowController.swift
//  C64 IDE
//
//  Help → C64 IDE Help. Renders the bundled MANUAL.md with marked.js inside a
//  WKWebView, with a toolbar search field and theme-aware styling.

import Cocoa
import WebKit

// ═══════════════════════════════════════════════════════════
// MARK: - Manual Window Controller
// ═══════════════════════════════════════════════════════════

/// A single reusable window that displays the user manual.
///
/// `MANUAL.md` (the same file shown on GitHub) and `marked.umd.js` are copied
/// into the app bundle, so the manual always matches the installed build and
/// works offline. Links inside the page are intercepted in JavaScript:
///   • `#anchor` links scroll within the page
///   • `http(s)` / `mailto` links open in the default browser / mail client
///   • relative links (e.g. `SECURITY.md`) open on the GitHub repository
class ManualWindowController: NSWindowController, NSToolbarDelegate {

    private static let searchItemID = NSToolbarItem.Identifier("ManualSearch")
    private static let repositoryBlobURL = "https://github.com/DNSGeek/C64IDE-OpenSource/blob/main/"

    private var webView: WKWebView!
    private var searchField: NSSearchField?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "C64 IDE Help"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.setFrameAutosaveName("ManualWindow")
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)

        setupWebView()
        setupToolbar()
        webView.loadHTMLString(Self.pageHTML(), baseURL: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "openLink")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window?.contentView = webView
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "ManualToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchItemID else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        let field = item.searchField
        field.placeholderString = "Search Manual"
        field.toolTip = "Return finds the next match, Shift-Return the previous one"
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(searchFieldAction(_:))
        item.preferredWidthForSearchField = 240
        searchField = field
        return item
    }

    // MARK: - Page

    /// Builds the complete HTML page: styles, marked.js, and the manual text
    /// embedded as a JSON string literal so no Markdown content is ever
    /// interpreted as HTML or script before marked parses it.
    private static func pageHTML() -> String {
        guard
            let mdURL = Bundle.main.url(forResource: "MANUAL", withExtension: "md"),
            let jsURL = Bundle.main.url(forResource: "marked.umd", withExtension: "js"),
            let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
            let markedJS = try? String(contentsOf: jsURL, encoding: .utf8),
            let jsonData = try? JSONSerialization.data(withJSONObject: markdown, options: .fragmentsAllowed),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return missingManualHTML()
        }
        // Belt and braces: never let a literal "</" close the <script> element.
        let markdownLiteral = jsonString.replacingOccurrences(of: "</", with: "<\\/")

        return """
        <!DOCTYPE html>
        <html class="\(AppTheme.current.isDark ? "dark" : "")">
        <head>
        <meta charset="UTF-8">
        <style>\(css)</style>
        </head>
        <body>
        <article id="content"></article>
        <script>\(markedJS)</script>
        <script>
        (function () {
          const content = document.getElementById('content');
          content.innerHTML = marked.parse(\(markdownLiteral), { gfm: true });

          // GitHub-compatible heading anchors so the manual's table of
          // contents links (e.g. #1-getting-started) resolve.
          const seen = {};
          content.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (h) {
            let slug = h.textContent.trim().toLowerCase()
              .replace(/[^\\p{L}\\p{M}\\p{N}\\p{Pc} -]/gu, '')
              .replace(/ /g, '-');
            if (seen[slug] !== undefined) {
              seen[slug] += 1;
              slug += '-' + seen[slug];
            } else {
              seen[slug] = 0;
            }
            h.id = slug;
          });

          document.addEventListener('click', function (e) {
            const a = e.target.closest('a');
            if (!a) return;
            const href = a.getAttribute('href') || '';
            e.preventDefault();
            if (href.startsWith('#')) {
              const target = document.getElementById(decodeURIComponent(href.slice(1)));
              if (target) target.scrollIntoView({ block: 'start' });
            } else if (href) {
              window.webkit.messageHandlers.openLink.postMessage(href);
            }
          });
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func missingManualHTML() -> String {
        """
        <!DOCTYPE html>
        <html class="\(AppTheme.current.isDark ? "dark" : "")">
        <head><meta charset="UTF-8"><style>\(css)</style></head>
        <body><article id="content">
        <h1>Manual unavailable</h1>
        <p>The manual could not be loaded from the application bundle.
        It is also available <a href="MANUAL.md">on GitHub</a>.</p>
        </article>
        <script>
        document.addEventListener('click', function (e) {
          const a = e.target.closest('a');
          if (!a) return;
          e.preventDefault();
          window.webkit.messageHandlers.openLink.postMessage(a.getAttribute('href') || '');
        });
        </script>
        </body></html>
        """
    }

    /// Light palette on `:root`, dark palette under `html.dark`. The class is
    /// toggled live when the app theme changes, preserving scroll position.
    private static let css = """
    :root {
      --bg: #f7f6f2;
      --bg2: #edecea;
      --border: #cccac4;
      --text: #1a1a1e;
      --muted: #5c5c66;
      --link: #1a55cc;
      --heading: #111114;
    }
    html.dark {
      --bg: #17171c;
      --bg2: #1e1e28;
      --border: #2e2e3e;
      --text: #d8d8d8;
      --muted: #9a9aa6;
      --link: #66aaff;
      --heading: #f0f0f0;
    }
    * { box-sizing: border-box; }
    html { background: var(--bg); }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.6 -apple-system, 'SF Pro Text', sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    #content { max-width: 820px; margin: 0 auto; padding: 24px 32px 64px; }
    h1, h2, h3, h4 { color: var(--heading); line-height: 1.25; scroll-margin-top: 12px; }
    h1 { font-size: 28px; margin: 8px 0 16px; }
    h2 { font-size: 21px; margin: 36px 0 12px; padding-bottom: 6px; border-bottom: 1px solid var(--border); }
    h3 { font-size: 16px; margin: 26px 0 8px; }
    h4 { font-size: 14px; margin: 20px 0 6px; }
    p, ul, ol, table, pre, blockquote { margin: 0 0 12px; }
    ul, ol { padding-left: 24px; }
    li + li { margin-top: 3px; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
    code {
      font: 12.5px 'SF Mono', Menlo, monospace;
      background: var(--bg2);
      padding: 1px 5px;
      border-radius: 4px;
    }
    pre {
      background: var(--bg2);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 10px 12px;
      overflow-x: auto;
    }
    pre code { background: none; padding: 0; }
    blockquote { color: var(--muted); border-left: 3px solid var(--border); padding: 0 0 0 12px; margin-left: 0; }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    th, td { border: 1px solid var(--border); padding: 5px 10px; text-align: left; vertical-align: top; }
    th { background: var(--bg2); font-weight: 600; }
    kbd { font: 12px 'SF Mono', Menlo, monospace; }
    ::selection { background: rgba(102, 170, 255, 0.35); }
    """

    // MARK: - Theme

    @objc private func themeDidChange(_ note: Notification) {
        window?.backgroundColor = AppTheme.current.panelBackground
        let isDark = AppTheme.current.isDark ? "true" : "false"
        webView.evaluateJavaScript(
            "document.documentElement.classList.toggle('dark', \(isDark));",
            completionHandler: nil)
    }

    // MARK: - Search

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let text = sender.stringValue
        guard !text.isEmpty else { return }
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        find(text, backwards: backwards)
    }

    private func find(_ text: String, backwards: Bool) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }

    /// Edit → Find… (⌘F) focuses the toolbar search field.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard let field = searchField else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// File → Close Tab (⌘W) closes the window, matching other tool windows.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: - Links

    /// Opens a link from the page outside the web view. Only web and mail
    /// links are followed; relative paths resolve against the GitHub repo.
    fileprivate func openLink(_ href: String) {
        let resolved: URL?
        if let url = URL(string: href), let scheme = url.scheme?.lowercased() {
            resolved = ["http", "https", "mailto"].contains(scheme) ? url : nil
        } else {
            resolved = URL(string: href, relativeTo: URL(string: Self.repositoryBlobURL))?.absoluteURL
        }
        if let url = resolved {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - WKScriptMessageHandler

extension ManualWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "openLink", let href = message.body as? String else { return }
        openLink(href)
    }
}

// MARK: - WKNavigationDelegate

extension ManualWindowController: WKNavigationDelegate {
    /// The page is generated once; any navigation other than that initial load
    /// (which clicks are already routed around in JavaScript) is refused.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other,
           navigationAction.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                openLink(url.absoluteString)
            }
            decisionHandler(.cancel)
        }
    }
}
