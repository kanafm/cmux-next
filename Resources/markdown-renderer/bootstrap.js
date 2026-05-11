// cmux markdown preview bootstrap.
// Lifted out of an inline <script> so CSP "script-src 'self'" can stay
// strict without 'unsafe-inline'. Loaded after marked.min.js.

(function () {
    if (typeof marked === "undefined" || typeof marked.parse !== "function") {
        var contentEl = document.getElementById("content");
        if (contentEl) {
            contentEl.textContent = "cmux: failed to load marked.min.js";
        }
        return;
    }
    marked.setOptions({ gfm: true, breaks: false });

    var contentEl = document.getElementById("content");

    function setBaseHref(href) {
        if (!href) return;
        var existing = document.head.querySelector("base");
        if (existing) {
            if (existing.getAttribute("href") !== href) {
                existing.setAttribute("href", href);
            }
            return;
        }
        var base = document.createElement("base");
        base.setAttribute("href", href);
        // Insert as the first child of head so it precedes any later URL-relative tags.
        if (document.head.firstChild) {
            document.head.insertBefore(base, document.head.firstChild);
        } else {
            document.head.appendChild(base);
        }
    }

    window.renderMarkdown = function (text, baseHref) {
        if (typeof text !== "string") text = String(text == null ? "" : text);
        if (typeof baseHref === "string" && baseHref.length > 0) {
            setBaseHref(baseHref);
        }
        try {
            contentEl.innerHTML = marked.parse(text);
        } catch (e) {
            contentEl.textContent = "cmux: marked.parse failed: " + (e && e.message ? e.message : e);
        }
    };

    // Intercept link clicks so AppKit can route them via NSWorkspace or the
    // embedded cmux browser. Reads the raw href attribute (not the resolved
    // URL) so absolute http(s)/mailto/file/ftp schemes pass through cleanly;
    // relative refs like "./other.md" stay as "./other.md" and Swift's
    // scheme allowlist filters them out.
    contentEl.addEventListener("click", function (event) {
        var target = event.target;
        while (target && target !== contentEl && target.tagName !== "A") {
            target = target.parentNode;
        }
        if (!target || target.tagName !== "A") return;
        var href = target.getAttribute("href");
        if (!href) return;
        event.preventDefault();
        try {
            window.webkit.messageHandlers.link.postMessage(href);
        } catch (e) {
            // No-op when running outside WKWebView (e.g. opened in a browser for debug).
        }
    });

    // Signal readiness so Swift can replay any queued content.
    try {
        window.webkit.messageHandlers.ready.postMessage("");
    } catch (e) {
        // No-op outside WKWebView.
    }
})();
