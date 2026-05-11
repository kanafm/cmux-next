import AppKit
import SwiftUI
import WebKit

/// SwiftUI view that renders a markdown string via a sandboxed WKWebView
/// loading a bundled HTML template + marked.min.js. Used by both
/// MarkdownPanelView (Cmd-click route) and FilePreviewPanelView (files-tab
/// .markdownPreview mode). Scroll position is preserved across content
/// updates because we re-render via evaluateJavaScript rather than a full
/// navigation reload.
struct MarkdownPreviewView: NSViewRepresentable {
    let content: String
    var baseDirectory: URL?
    var sourceWorkspaceId: UUID?
    var sourcePanelId: UUID?

    init(
        content: String,
        baseDirectory: URL? = nil,
        sourceWorkspaceId: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) {
        self.content = content
        self.baseDirectory = baseDirectory
        self.sourceWorkspaceId = sourceWorkspaceId
        self.sourcePanelId = sourcePanelId
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "link")
        contentController.add(context.coordinator, name: "ready")
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        context.coordinator.webView = webView
        context.coordinator.pendingContent = content
        context.coordinator.pendingTheme = themeName(for: context.environment.colorScheme)
        context.coordinator.pendingBaseHref = baseHrefString
        context.coordinator.sourceWorkspaceId = sourceWorkspaceId
        context.coordinator.sourcePanelId = sourcePanelId

        loadTemplate(into: webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.sourceWorkspaceId = sourceWorkspaceId
        context.coordinator.sourcePanelId = sourcePanelId
        context.coordinator.apply(
            content: content,
            baseHref: baseHrefString,
            webView: webView
        )
        context.coordinator.apply(
            theme: themeName(for: context.environment.colorScheme),
            webView: webView
        )
    }

    private var baseHrefString: String? {
        guard let baseDirectory else { return nil }
        // Always trailing-slash so relative paths resolve as
        // <dir>/<relative>, not as siblings of the dir.
        let absolute = baseDirectory.absoluteString
        return absolute.hasSuffix("/") ? absolute : absolute + "/"
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "link")
        contentController.removeScriptMessageHandler(forName: "ready")
        coordinator.webView = nil
    }

    private func themeName(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "dark" : "light"
    }

    private func loadTemplate(into webView: WKWebView) {
        guard let templateURL = Bundle.main.url(
            forResource: "markdown-template",
            withExtension: "html",
            subdirectory: "markdown-renderer"
        ) else {
            #if DEBUG
            NSLog("MarkdownPreviewView: missing markdown-renderer/markdown-template.html in bundle")
            #endif
            webView.loadHTMLString(
                "<html><body style=\"font-family:-apple-system\">cmux: markdown renderer assets missing from bundle.</body></html>",
                baseURL: nil
            )
            return
        }
        // Grant the WebView read access to the whole filesystem under
        // file:// so markdown files anywhere can pull in their own
        // relative images. CSP keeps the request kinds tight (img-src
        // file: only; default-src none; connect-src none).
        let readAccessURL = URL(fileURLWithPath: "/")
        webView.loadFileURL(templateURL, allowingReadAccessTo: readAccessURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var isReady = false
        var pendingContent: String?
        var lastRenderedContent: String?
        var pendingTheme: String?
        var lastAppliedTheme: String?
        var pendingBaseHref: String?
        var lastAppliedBaseHref: String?
        var sourceWorkspaceId: UUID?
        var sourcePanelId: UUID?

        func apply(content: String, baseHref: String?, webView: WKWebView) {
            if isReady {
                let baseChanged = baseHref != lastAppliedBaseHref
                let contentChanged = content != lastRenderedContent
                guard contentChanged || baseChanged else { return }
                lastRenderedContent = content
                lastAppliedBaseHref = baseHref
                pendingContent = nil
                pendingBaseHref = nil
                evaluateRender(content: content, baseHref: baseHref, in: webView)
            } else {
                pendingContent = content
                pendingBaseHref = baseHref
            }
        }

        func apply(theme: String, webView: WKWebView) {
            if isReady {
                guard theme != lastAppliedTheme else { return }
                lastAppliedTheme = theme
                pendingTheme = nil
                evaluateTheme(theme: theme, in: webView)
            } else {
                pendingTheme = theme
            }
        }

        private func evaluateRender(content: String, baseHref: String?, in webView: WKWebView) {
            guard let encodedContent = jsonEncodedString(content) else { return }
            let encodedBase = (baseHref.flatMap { jsonEncodedString($0) }) ?? "null"
            webView.evaluateJavaScript(
                "window.renderMarkdown(\(encodedContent), \(encodedBase));"
            ) { _, error in
                #if DEBUG
                if let error {
                    cmuxDebugLog("markdown.evaluateRender error: \(error)")
                }
                #endif
                _ = error
            }
        }

        private func evaluateTheme(theme: String, in webView: WKWebView) {
            guard let encoded = jsonEncodedString(theme) else { return }
            webView.evaluateJavaScript(
                "document.documentElement.dataset.theme = \(encoded);"
            ) { _, error in
                #if DEBUG
                if let error {
                    cmuxDebugLog("markdown.evaluateTheme error: \(error)")
                }
                #endif
                _ = error
            }
        }

        private func jsonEncodedString(_ value: String) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            guard let data = try? encoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "ready":
                handleReady()
            case "link":
                if let href = message.body as? String {
                    handleLink(href: href)
                }
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
                evaluateTheme(theme: theme, in: webView)
            }
            if let content = pendingContent {
                let baseHref = pendingBaseHref
                lastRenderedContent = content
                lastAppliedBaseHref = baseHref
                pendingContent = nil
                pendingBaseHref = nil
                evaluateRender(content: content, baseHref: baseHref, in: webView)
            }
        }

        private func handleLink(href: String) {
            guard let url = URL(string: href) else { return }
            // Anchor-only navigations like "#section" arrive here because
            // bootstrap.js calls event.preventDefault() on every link. They
            // have no scheme; skip.
            guard let scheme = url.scheme?.lowercased() else { return }
            // cmux's embedded browser only handles http(s). Route those
            // through the workspace's preferred-target helper. Everything
            // else (mailto/file/ftp/etc.) falls back to NSWorkspace.
            if (scheme == "http" || scheme == "https"),
               let workspaceId = sourceWorkspaceId,
               let panelId = sourcePanelId {
                let host = url.host ?? ""
                let opened = GhosttyApp.openEmbeddedBrowserLink(
                    url: url,
                    sourceWorkspaceId: workspaceId,
                    sourcePanelId: panelId,
                    host: host
                )
                if opened { return }
                // Helper already attempted NSWorkspace.open on its fallback
                // paths; no second open here.
                return
            }
            guard ["http", "https", "mailto", "file", "ftp"].contains(scheme) else {
                return
            }
            NSWorkspace.shared.open(url)
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            // Allow the initial template load (file://) and any subframe
            // navigation; cancel everything else. Link clicks are already
            // intercepted by the bootstrap.js handler and posted through
            // the 'link' script message bridge, so they shouldn't reach
            // here. Defense in depth: if bootstrap.js fails to bind, the
            // default-nav click still gets cancelled and routed below.
            if !isMainFrame || scheme == "file" || scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            cmuxDebugLog("markdown.didFinish url=\(webView.url?.absoluteString ?? "nil")")
            #endif
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            #if DEBUG
            cmuxDebugLog("markdown.didFail error=\(error)")
            #endif
            _ = error
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            #if DEBUG
            cmuxDebugLog("markdown.didFailProvisionalNavigation error=\(error)")
            #endif
            _ = error
        }
    }
}
