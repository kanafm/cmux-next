import AppKit
import WebKit

/// NSView wrapper around a WKWebView hosting Monaco. Intercepts Cmd+S (via
/// KeyboardShortcutSettings.shortcut(for: .saveFilePreview)), Cmd+= / Cmd+- /
/// Cmd+0 font zoom, trackpad magnify, and Cmd-scroll zoom before the WebView
/// sees the event. Forwards focus to the WebView when it becomes first
/// responder so Monaco's contentEditable surface receives keystrokes.
final class MonacoEditorHostView: NSView {
    static let defaultFontSize: CGFloat = 13
    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 36

    weak var panel: FilePreviewPanel?
    let webView: WKWebView
    private var saveMatcher = FilePreviewSaveShortcutMatcher()
    private var currentFontSize: CGFloat = MonacoEditorHostView.defaultFontSize
    private var onFontSizeChange: ((CGFloat) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not implemented") }

    func setFontSizeHandler(_ handler: @escaping (CGFloat) -> Void) {
        onFontSizeChange = handler
    }

    func setInitialFontSize(_ size: CGFloat) {
        currentFontSize = clampFontSize(size)
    }

    func insertTextAtCursor(_ text: String) {
        guard !text.isEmpty, let encoded = jsonEncodedString(text) else { return }
        let script = """
        if (window.cmuxEditor && window.cmuxEditor.insertAtCursor) {
            window.cmuxEditor.insertAtCursor({text: \(encoded)});
        }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.window?.makeFirstResponder(self.webView)
        }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if let shouldSave = saveMatcher.match(event: event) {
            if shouldSave {
                _ = panel?.saveTextContent()
            }
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Intercept font-size shortcuts before Monaco's own bindings.
        if flags == .command, let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "=", "+":
                adjustFontSize(by: 1.1)
                return true
            case "-":
                adjustFontSize(by: 1.0 / 1.1)
                return true
            case "0":
                setFontSize(Self.defaultFontSize)
                return true
            default:
                break
            }
        }
        // Cmd+Shift+P and Cmd+P would otherwise reach Monaco's quickCommand
        // / quickOpen widgets. In our CSP + no-worker WebView those widgets
        // can lock the main thread on first activation (observed: cmux hung
        // until force-quit). Return false WITHOUT calling super so the
        // WKWebView subview is skipped; the event then walks up the
        // responder chain to cmux's app menu (Cmd+Shift+P opens cmux's
        // command palette). The JS-side addKeybindingRule null-outs in
        // bootstrap.js are defense-in-depth but cannot be trusted alone.
        if (flags == [.command, .shift] || flags == .command),
           event.charactersIgnoringModifiers?.lowercased() == "p" {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    private func adjustFontSize(by factor: CGFloat) {
        setFontSize(currentFontSize * factor)
    }

    private func setFontSize(_ next: CGFloat) {
        let clamped = clampFontSize(next)
        guard clamped.isFinite else { return }
        currentFontSize = clamped
        let script = "if (window.cmuxEditor) { window.cmuxEditor.setFontSize({size: \(clamped)}); }"
        webView.evaluateJavaScript(script, completionHandler: nil)
        onFontSizeChange?(clamped)
    }

    private func clampFontSize(_ value: CGFloat) -> CGFloat {
        return min(max(value, Self.minimumFontSize), Self.maximumFontSize)
    }

    private func jsonEncodedString(_ value: String) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
