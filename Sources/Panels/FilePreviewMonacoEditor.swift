import AppKit
import SwiftUI
import WebKit

/// SwiftUI host for the Monaco-based file preview editor. Mirrors the
/// NSViewRepresentable pattern from MarkdownPreviewView: the WKWebView is
/// reused for the lifetime of the panel; file switches and reverts go
/// through `window.cmuxEditor.setContent`, never a fresh WebView.
struct FilePreviewMonacoEditor: NSViewRepresentable {
    @ObservedObject var panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    @AppStorage("filePreviewFontSize") private var storedFontSize: Double = 13

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> MonacoEditorHostView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContent = WKUserContentController()
        for name in ["ready", "change", "cursor", "focusChanged"] {
            userContent.add(context.coordinator, name: name)
        }
        configuration.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        let host = MonacoEditorHostView(webView: webView)
        host.isHidden = !isVisibleInUI
        host.panel = panel
        host.setInitialFontSize(CGFloat(storedFontSize))
        let storedFontSizeBinding = $storedFontSize
        host.setFontSizeHandler { newSize in
            storedFontSizeBinding.wrappedValue = Double(newSize)
        }
        host.layer?.backgroundColor = themeBackgroundColor.cgColor

        context.coordinator.host = host
        context.coordinator.webView = webView
        context.coordinator.pendingContent = panel.textContent
        context.coordinator.pendingFilePath = panel.filePath
        context.coordinator.pendingFontSize = CGFloat(storedFontSize)
        context.coordinator.pendingTheme = themePayload(for: context.environment.colorScheme)

        panel.attachPreviewFocus(root: host, primaryResponder: webView, intent: .textEditor)
        panel.attachMonacoEditor(host)

        loadTemplate(into: webView)
        return host
    }

    func updateNSView(_ host: MonacoEditorHostView, context: Context) {
        host.isHidden = !isVisibleInUI
        host.panel = panel
        host.layer?.backgroundColor = themeBackgroundColor.cgColor

        context.coordinator.panel = panel
        context.coordinator.applyTheme(themePayload(for: context.environment.colorScheme))
        context.coordinator.applyContent(content: panel.textContent, filePath: panel.filePath)
    }

    static func dismantleNSView(_ host: MonacoEditorHostView, coordinator: Coordinator) {
        coordinator.dispose()
    }

    private func themePayload(for colorScheme: ColorScheme) -> Coordinator.ThemePayload {
        let isDark = colorScheme == .dark
        return Coordinator.ThemePayload(
            name: isDark ? "cmux-dark" : "cmux-light",
            background: hexString(themeBackgroundColor),
            foreground: hexString(themeForegroundColor),
            selection: hexString(NSColor.selectedTextBackgroundColor)
        )
    }

    private func hexString(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func loadTemplate(into webView: WKWebView) {
        guard let indexURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "monaco-editor"
        ) else {
            #if DEBUG
            NSLog("FilePreviewMonacoEditor: missing monaco-editor/index.html in bundle")
            #endif
            webView.loadHTMLString(
                "<html><body style=\"font-family:-apple-system;padding:24px\">cmux: Monaco editor assets missing from bundle. Run <code>./nix-build/scripts/fetch-monaco.sh</code> to populate them.</body></html>",
                baseURL: nil
            )
            return
        }
        let monacoDir = indexURL.deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: monacoDir)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var panel: FilePreviewPanel
        weak var host: MonacoEditorHostView?
        weak var webView: WKWebView?
        var isReady = false
        var contentVersion: Int = 0
        var pendingContent: String?
        var pendingFilePath: String?
        var pendingFontSize: CGFloat?
        var pendingTheme: ThemePayload?
        var lastAppliedContent: String?
        var lastAppliedFilePath: String?
        var lastAppliedTheme: ThemePayload?

        init(panel: FilePreviewPanel) {
            self.panel = panel
        }

        struct ThemePayload: Equatable {
            let name: String
            let background: String
            let foreground: String
            let selection: String
        }

        func dispose() {
            if let webView {
                let controller = webView.configuration.userContentController
                for name in ["ready", "change", "cursor", "focusChanged"] {
                    controller.removeScriptMessageHandler(forName: name)
                }
                webView.navigationDelegate = nil
            }
            host = nil
            webView = nil
        }

        func applyTheme(_ theme: ThemePayload) {
            guard isReady, let webView else {
                pendingTheme = theme
                return
            }
            guard theme != lastAppliedTheme else { return }
            lastAppliedTheme = theme
            let body = encode(theme)
            webView.evaluateJavaScript("if (window.cmuxEditor) { window.cmuxEditor.applyTheme(\(body)); }", completionHandler: nil)
        }

        func applyContent(content: String, filePath: String) {
            let pathChanged = filePath != lastAppliedFilePath
            let contentChanged = content != lastAppliedContent
            guard contentChanged || pathChanged else { return }

            guard isReady, let webView else {
                pendingContent = content
                pendingFilePath = filePath
                return
            }
            contentVersion += 1
            lastAppliedContent = content
            lastAppliedFilePath = filePath
            pendingContent = nil
            pendingFilePath = nil
            let payload = encodeContent(content: content, filePath: filePath, version: contentVersion, resetUndo: true)
            webView.evaluateJavaScript("if (window.cmuxEditor) { window.cmuxEditor.setContent(\(payload)); }", completionHandler: nil)
        }

        // MARK: - WKScriptMessageHandler

        nonisolated func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let name = message.name
            let body = message.body
            Task { @MainActor [weak self] in
                self?.handleMessage(name: name, body: body)
            }
        }

        private func handleMessage(name: String, body: Any) {
            switch name {
            case "ready":
                handleReady()
            case "change":
                guard let dict = body as? [String: Any],
                      let content = dict["content"] as? String else { return }
                // Mark this content as already-applied so the subsequent
                // updateNSView (triggered by panel.textContent changing) does
                // not echo the same string back into Monaco.
                lastAppliedContent = content
                panel.updateTextContent(content)
            case "cursor", "focusChanged":
                // Wired now, intentionally unused. Future: status-bar
                // cursor position; focus-coordinator hand-off.
                break
            default:
                break
            }
        }

        private func handleReady() {
            isReady = true
            guard let webView else { return }
            if let theme = pendingTheme {
                lastAppliedTheme = theme
                pendingTheme = nil
                let body = encode(theme)
                webView.evaluateJavaScript("if (window.cmuxEditor) { window.cmuxEditor.applyTheme(\(body)); }", completionHandler: nil)
            }
            if let size = pendingFontSize {
                pendingFontSize = nil
                webView.evaluateJavaScript("if (window.cmuxEditor) { window.cmuxEditor.setFontSize({size: \(size)}); }", completionHandler: nil)
            }
            if let content = pendingContent {
                let filePath = pendingFilePath ?? ""
                contentVersion += 1
                lastAppliedContent = content
                lastAppliedFilePath = filePath
                pendingContent = nil
                pendingFilePath = nil
                let payload = encodeContent(content: content, filePath: filePath, version: contentVersion, resetUndo: true)
                webView.evaluateJavaScript("if (window.cmuxEditor) { window.cmuxEditor.setContent(\(payload)); }", completionHandler: nil)
            }
        }

        // MARK: - Navigation

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if !isMainFrame || scheme == "file" || scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        // MARK: - JSON encoding

        private func encode(_ theme: ThemePayload) -> String {
            return "{name:\(quote(theme.name)),background:\(quote(theme.background)),foreground:\(quote(theme.foreground)),selection:\(quote(theme.selection))}"
        }

        private func encodeContent(content: String, filePath: String, version: Int, resetUndo: Bool) -> String {
            return "{content:\(quote(content)),filePath:\(quote(filePath)),version:\(version),resetUndo:\(resetUndo)}"
        }

        private func quote(_ value: String) -> String {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(value),
                  let s = String(data: data, encoding: .utf8) else { return "\"\"" }
            return s
        }
    }
}
