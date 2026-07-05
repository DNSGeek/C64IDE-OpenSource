import Cocoa
import SwiftUI
import WebKit

// MARK: - Claude Tab Controller

/// Chat UI for the Claude AI bottom panel tab.
/// Uses WKWebView for message display and NSTextField for input.
final class ClaudeTabController: NSViewController {

    // MARK: - UI

    private var webView: WKWebView!
    private var inputField: NSTextField!
    private var sendButton: NSButton!
    private var statusLabel: NSTextField!
    private var settingsButton: NSButton!
    private var inputBar: NSView!

    // MARK: - State

    private var history: [ClaudeChatMessage] = []
    private var isWaiting = false
    private var sessionInputTokens  = 0
    private var sessionOutputTokens = 0
    /// Swift-side store of code blocks — keyed by index so JS only passes an Int.
    /// This prevents XSS and keeps raw code out of the DOM/JS string layer.
    private var codeBlocks: [(code: String, fileType: C64FileType)] = []

    // MARK: - Dependencies

    /// Provide fresh IDE context on each send. Wired by MainWindowController.
    weak var contextProvider: ClaudeIDEContextProvider?

    /// Called when user clicks "Open in New Tab" on a code block. Wired by MainWindowController.
    var onOpenInNewTab: ((_ code: String, _ fileType: C64FileType) -> Void)?

    // MARK: - Colors / Style

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    // MARK: - Lifecycle

    override func loadView() {
        self.view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        setupInputBar()
        loadInitialHTML()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
    }

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyThemeColors()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyThemeColors()
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        inputBar?.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        inputField?.backgroundColor = AppTheme.current.panelDetailBackground
        inputField?.textColor = AppTheme.current.defaultText
        statusLabel?.textColor = AppTheme.current.statusLabel
        reloadChat()
    }

    // MARK: - Layout

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "openInTab")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        view.addSubview(webView)
    }

    private func setupInputBar() {
        // Settings button (gear)
        settingsButton = NSButton(title: "⚙", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        settingsButton.isBordered = false
        settingsButton.font = NSFont.systemFont(ofSize: 14)
        settingsButton.toolTip = "Claude API Settings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = AppTheme.current.statusLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Input field
        inputField = NSTextField()
        inputField.placeholderString = "Ask Claude about your C64 code…"
        inputField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        inputField.bezelStyle = .roundedBezel
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.delegate = self
        inputField.backgroundColor = AppTheme.current.panelDetailBackground
        inputField.textColor = AppTheme.current.defaultText

        // Send button
        sendButton = NSButton(title: "Send", target: self, action: #selector(sendTapped))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        // Input bar container
        inputBar = NSView()
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.wantsLayer = true
        inputBar.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor

        inputBar.addSubview(settingsButton)
        inputBar.addSubview(statusLabel)
        inputBar.addSubview(inputField)
        inputBar.addSubview(sendButton)
        view.addSubview(inputBar)

        NSLayoutConstraint.activate([
            // Input bar pinned to bottom
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inputBar.heightAnchor.constraint(equalToConstant: 36),

            // WebView fills the rest
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            // Settings button
            settingsButton.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: 6),
            settingsButton.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),

            // Status label
            statusLabel.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 4),
            statusLabel.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 160),

            // Send button
            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -6),
            sendButton.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 60),

            // Input field fills remaining space
            inputField.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 4),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            inputField.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
        ])
    }

    // MARK: - Initial HTML

    private func loadInitialHTML() {
        let html = baseHTML(messages: "")
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func baseHTML(messages: String) -> String {
        // Theme colors are captured at render time. For dynamic updates, 
        // consider injecting CSS variables via JS or reloading on theme change.
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          :root {
            --bg: \(AppTheme.current.isDark ? "#17171c" : "#f7f6f2");
            --bg2: \(AppTheme.current.isDark ? "#1e1e28" : "#edecea");
            --bg3: \(AppTheme.current.isDark ? "#2e2e3e" : "#dddbd6");
            --border: \(AppTheme.current.isDark ? "#2a2a38" : "#cccac4");
            --text: \(AppTheme.current.isDark ? "#d8d8d8" : "#1a1a1e");
            --user-role: \(AppTheme.current.isDark ? "#66aaff" : "#1a55cc");
            --asst-role: \(AppTheme.current.isDark ? "#66dd99" : "#1a7a40");
            --empty: \(AppTheme.current.isDark ? "#555" : "#999");
            --btn-color: \(AppTheme.current.isDark ? "#aaa" : "#666");
            --btn-hover: \(AppTheme.current.isDark ? "#ddd" : "#222");
          }
          body {
            background: var(--bg);
            color: var(--text);
            font-family: -apple-system, 'SF Pro Text', sans-serif;
            font-size: 12px;
            line-height: 1.55;
            padding: 8px 10px;
          }
          .message { margin-bottom: 10px; }
          .message .role {
            font-size: 10px;
            font-weight: 600;
            letter-spacing: 0.04em;
            margin-bottom: 2px;
          }
          .message.user .role   { color: var(--user-role); }
          .message.assistant .role { color: var(--asst-role); }
          .message .body {
            white-space: pre-wrap;
            word-break: break-word;
          }
          code {
            font-family: 'SF Mono', Menlo, monospace;
            font-size: 11px;
            background: var(--bg2);
            padding: 1px 4px;
            border-radius: 3px;
          }
          .code-block { position: relative; margin: 4px 0; }
          .code-block pre { margin: 0; }
          .code-block .open-btn {
            position: absolute;
            top: 5px;
            right: 6px;
            background: var(--bg3);
            color: var(--btn-color);
            border: 1px solid var(--border);
            border-radius: 3px;
            font-size: 9px;
            padding: 2px 6px;
            cursor: pointer;
            font-family: -apple-system, sans-serif;
            line-height: 1.4;
          }
          .code-block .open-btn:hover { background: var(--bg3); color: var(--btn-hover); }
          pre {
            background: var(--bg2);
            border: 1px solid var(--border);
            border-radius: 5px;
            padding: 8px 10px;
            overflow-x: auto;
            margin: 4px 0;
          }
          pre code {
            background: none;
            padding: 0;
            font-size: 11px;
          }
          .error { color: #ff6666; font-style: italic; }
          .empty-hint {
            color: var(--empty);
            font-style: italic;
            margin-top: 16px;
            text-align: center;
          }
        </style>
        </head>
        <body>
        <div id="messages">\(messages.isEmpty ? "<p class='empty-hint'>Ask Claude anything about your C64 code.</p>" : messages)</div>
        <script>
          function scrollToBottom() {
            window.scrollTo(0, document.body.scrollHeight);
          }
          scrollToBottom();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Rendering

    /// Rebuilds the full HTML from the current history and reloads the webview.
    private func reloadChat() {
        codeBlocks = []
        var html = ""
        for msg in history {
            let roleLabel = msg.role == "user" ? "You" : "Claude"
            let formatted = formatMessage(msg.content)
            html += "<div class='message \(msg.role)'><div class='role'>\(roleLabel)</div><div class='body'>\(formatted)</div></div>\n"
        }
        let full = baseHTML(messages: html)
        webView.loadHTMLString(full, baseURL: nil)
    }

    /// Formats a raw message string into HTML.
    /// Prose sections are HTML-escaped. Code blocks are HTML-escaped for display
    /// but stored raw (unescaped) in codeBlocks for "Open in New Tab".
    /// JS only receives the integer index — no code ever touches JS strings.
    private func formatMessage(_ raw: String) -> String {
        var output = ""
        var remainder = raw[raw.startIndex...]

        while let tickStart = remainder.range(of: "```") {
            // Escape and append prose before this code block
            output += escapeHTML(String(remainder[remainder.startIndex..<tickStart.lowerBound]))
            let afterTick = remainder[tickStart.upperBound...]

            if let newline = afterTick.firstIndex(of: "\n") {
                let lang = String(afterTick[afterTick.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
                let afterLang = afterTick[afterTick.index(after: newline)...]
                if let closeRange = afterLang.range(of: "```") {
                    let rawCode = String(afterLang[afterLang.startIndex..<closeRange.lowerBound])

                    let fileType: C64FileType
                    switch lang.lowercased() {
                    case "asm", "s", "assembly", "6502": fileType = .assembly
                    default: fileType = .basic
                    }

                    // Store raw (unescaped) for the new tab; escape only for display
                    let idx = codeBlocks.count
                    codeBlocks.append((code: rawCode, fileType: fileType))

                    output += "<div class='code-block'>"
                    output += "<pre><code>\(escapeHTML(rawCode))</code></pre>"
                    output += "<button class='open-btn' onclick='window.webkit.messageHandlers.openInTab.postMessage(\(idx))'>Open in New Tab</button>"
                    output += "</div>"

                    remainder = afterLang[closeRange.upperBound...]
                    continue
                }
            }
            output += "```"
            remainder = afterTick
        }
        // Escape remaining prose
        output += escapeHTML(String(remainder))

        // Inline code: `...`
        // Note: This regex operates on already-escaped text, so & < > are safe.
        let result = output.replacingOccurrences(of: #"`([^`]+)`"#,
                                                  with: "<code>$1</code>",
                                                  options: .regularExpression)
        return result
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Send

    @objc private func sendTapped() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWaiting else { return }

        guard ClaudeAPIService.shared.hasAPIKey else {
            appendError("No API key configured. Click ⚙ to add your Anthropic API key.")
            return
        }

        inputField.stringValue = ""
        history.append(ClaudeChatMessage(role: "user", content: text))
        reloadChat()
        setWaiting(true)

        let context = contextProvider?.currentIDEContext() ?? .empty

        Task { [weak self] in
            guard let self else { return }
            do {
                let (reply, usage) = try await ClaudeAPIService.shared.sendMessage(
                    history: self.history,
                    context: context
                )
                await MainActor.run {
                    self.sessionInputTokens  += usage.inputTokens
                    self.sessionOutputTokens += usage.outputTokens
                    self.history.append(ClaudeChatMessage(role: "assistant", content: reply))
                    self.reloadChat()
                    self.setWaiting(false)
                }
            } catch {
                await MainActor.run {
                    self.appendError(error.localizedDescription)
                    self.setWaiting(false)
                }
            }
        }
    }

    private func setWaiting(_ waiting: Bool) {
        isWaiting = waiting
        sendButton.isEnabled = !waiting
        inputField.isEnabled = !waiting
        if waiting {
            statusLabel.stringValue = "Thinking…"
        } else if sessionInputTokens > 0 {
            let total = sessionInputTokens + sessionOutputTokens
            statusLabel.stringValue = "↑\(sessionInputTokens) ↓\(sessionOutputTokens) (\(total) total)"
        } else {
            statusLabel.stringValue = ""
        }
    }

    private func appendError(_ message: String) {
        // Safely serialize the error message to a JS string literal.
        // JSONEncoder guarantees proper escaping of quotes, backslashes, newlines, and control chars.
        let encoded: String
        if let data = try? JSONEncoder().encode([message]),
           let json = String(data: data, encoding: .utf8),
           json.count >= 2 {
            encoded = String(json.dropFirst().dropLast())   // strip [ ]
        } else {
            encoded = "\"\""
        }
        let js = """
        var el = document.createElement('p');
        el.className = 'error';
        el.textContent = \(encoded);
        document.getElementById('messages').appendChild(el);
        window.scrollTo(0, document.body.scrollHeight);
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Clear

    func clearHistory() {
        history = []
        codeBlocks = []
        sessionInputTokens  = 0
        sessionOutputTokens = 0
        statusLabel.stringValue = ""
        loadInitialHTML()
    }

    // MARK: - Settings

    @objc private func openSettings() {
        guard let window = view.window else { return }
        let vm = ClaudePreferencesViewModel()
        // onDismiss ends whatever sheet is attached to the host window (our prefs
        // sheet). We deliberately don't capture prefsWindow here: the window owns
        // the SwiftUI view which owns this closure, so capturing it would create a
        // retain cycle and leak a window each time settings is opened.
        let hostingController = NSHostingController(
            rootView: ClaudePreferencesView(viewModel: vm, onDismiss: { [weak window] in
                guard let window, let sheet = window.attachedSheet else { return }
                window.endSheet(sheet)
            })
        )
        let prefsWindow = NSWindow(contentViewController: hostingController)
        prefsWindow.title = "Claude AI Settings"
        prefsWindow.styleMask = [.titled, .closable]
        prefsWindow.center()
        window.beginSheet(prefsWindow, completionHandler: nil)
    }
}

// MARK: - NSTextFieldDelegate (Enter to send)

extension ClaudeTabController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            sendTapped()
            return true
        }
        return false
    }
}

// MARK: - WKScriptMessageHandler (Open in New Tab)

extension ClaudeTabController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "openInTab",
              let idx = message.body as? Int,
              idx >= 0, idx < codeBlocks.count else { return }

        let block = codeBlocks[idx]
        DispatchQueue.main.async { [weak self] in
            self?.onOpenInNewTab?(block.code, block.fileType)
        }
    }
}

// MARK: - WKNavigationDelegate

extension ClaudeTabController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Scroll to bottom after each reload
        webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);", completionHandler: nil)
    }
}

