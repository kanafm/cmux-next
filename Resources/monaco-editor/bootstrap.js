/* cmux Monaco bootstrap.
 *
 * Loads Monaco via its AMD loader, exposes a small `window.cmuxEditor` API
 * for Swift to drive, and forwards model lifecycle events back to Swift via
 * webkit.messageHandlers. See FilePreviewMonacoEditor.swift for the host side.
 */
(function () {
    "use strict";

    function post(name, payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
            window.webkit.messageHandlers[name].postMessage(payload || {});
        }
    }

    function debounce(fn, ms) {
        var timer = null;
        return function () {
            var ctx = this;
            var args = arguments;
            if (timer) clearTimeout(timer);
            timer = setTimeout(function () {
                timer = null;
                fn.apply(ctx, args);
            }, ms);
        };
    }

    require.config({ paths: { vs: "vs" } });
    require(["vs/editor/editor.main"], function () {
        var extToLang = Object.create(null);
        var fileToLang = Object.create(null);
        monaco.languages.getLanguages().forEach(function (lang) {
            (lang.extensions || []).forEach(function (ext) {
                extToLang[ext.toLowerCase()] = lang.id;
            });
            (lang.filenames || []).forEach(function (name) {
                fileToLang[name.toLowerCase()] = lang.id;
            });
        });

        function inferLanguage(filePath) {
            if (!filePath || typeof filePath !== "string") return "plaintext";
            var slash = filePath.lastIndexOf("/");
            var base = slash >= 0 ? filePath.substring(slash + 1) : filePath;
            var fileMatch = fileToLang[base.toLowerCase()];
            if (fileMatch) return fileMatch;
            var dot = base.lastIndexOf(".");
            if (dot < 0) return "plaintext";
            var ext = base.substring(dot).toLowerCase();
            return extToLang[ext] || "plaintext";
        }

        // Pre-define theme slots so initial render is not white.
        monaco.editor.defineTheme("cmux-dark", {
            base: "vs-dark", inherit: true, rules: [],
            colors: { "editor.background": "#1e1e1e" }
        });
        monaco.editor.defineTheme("cmux-light", {
            base: "vs", inherit: true, rules: [],
            colors: { "editor.background": "#ffffff" }
        });

        var editor = monaco.editor.create(document.getElementById("root"), {
            value: "",
            language: "plaintext",
            theme: "cmux-dark",
            automaticLayout: true,
            fontSize: 13,
            fontFamily: "Menlo, Monaco, 'Courier New', monospace",
            minimap: { enabled: true },
            scrollBeyondLastLine: false,
            renderWhitespace: "selection",
            tabSize: 4,
            wordWrap: "on",
            smoothScrolling: true,
        });

        // Strip Monaco bindings that collide with cmux's app menu.
        function unbind(keybinding) {
            monaco.editor.addKeybindingRule({ keybinding: keybinding, command: null });
        }
        unbind(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyP);
        unbind(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyP);

        var currentVersion = 0;
        var isApplyingExternal = false;

        var emitChange = debounce(function () {
            post("change", {
                content: editor.getValue(),
                version: currentVersion,
            });
        }, 100);

        var emitCursor = debounce(function () {
            var pos = editor.getPosition();
            if (!pos) return;
            post("cursor", { line: pos.lineNumber, column: pos.column });
        }, 200);

        editor.onDidChangeModelContent(function () {
            if (isApplyingExternal) return;
            emitChange();
        });
        editor.onDidChangeCursorPosition(function () {
            emitCursor();
        });
        editor.onDidFocusEditorText(function () {
            post("focusChanged", { focused: true });
        });
        editor.onDidBlurEditorText(function () {
            post("focusChanged", { focused: false });
        });

        window.cmuxEditor = {
            setContent: function (payload) {
                payload = payload || {};
                isApplyingExternal = true;
                try {
                    currentVersion = payload.version || 0;
                    var content = typeof payload.content === "string" ? payload.content : "";
                    var language = typeof payload.language === "string" && payload.language
                        ? payload.language
                        : inferLanguage(payload.filePath);
                    var existing = editor.getModel();
                    if (payload.resetUndo || !existing) {
                        var fresh = monaco.editor.createModel(content, language);
                        editor.setModel(fresh);
                        if (existing) existing.dispose();
                    } else {
                        existing.setValue(content);
                        monaco.editor.setModelLanguage(existing, language);
                    }
                } finally {
                    isApplyingExternal = false;
                }
            },
            applyTheme: function (payload) {
                payload = payload || {};
                var name = payload.name === "cmux-light" ? "cmux-light" : "cmux-dark";
                var base = name === "cmux-dark" ? "vs-dark" : "vs";
                var colors = {};
                if (payload.background) colors["editor.background"] = payload.background;
                if (payload.foreground) colors["editor.foreground"] = payload.foreground;
                if (payload.selection) colors["editor.selectionBackground"] = payload.selection;
                if (payload.lineHighlight) colors["editor.lineHighlightBackground"] = payload.lineHighlight;
                monaco.editor.defineTheme(name, {
                    base: base, inherit: true, rules: [], colors: colors,
                });
                monaco.editor.setTheme(name);
            },
            setFontSize: function (payload) {
                if (!payload || typeof payload.size !== "number") return;
                editor.updateOptions({ fontSize: payload.size });
            },
            setReadOnly: function (payload) {
                editor.updateOptions({ readOnly: !!(payload && payload.readOnly) });
            },
            setMinimapEnabled: function (payload) {
                editor.updateOptions({ minimap: { enabled: !!(payload && payload.enabled) } });
            },
            focus: function () {
                editor.focus();
            },
            insertAtCursor: function (payload) {
                var text = (payload && typeof payload.text === "string") ? payload.text : "";
                if (!text) return;
                var selection = editor.getSelection();
                if (!selection) return;
                editor.executeEdits("cmux-insert", [{
                    range: selection,
                    text: text,
                    forceMoveMarkers: true,
                }]);
                editor.focus();
            },
        };

        post("ready", {});
    });
})();
