import AppKit

/// Matches the `.saveFilePreview` keyboard shortcut, including chord prefixes.
/// Extracted from the original SavingTextView so multiple editor host views
/// share a single source of truth for save-shortcut behavior.
struct FilePreviewSaveShortcutMatcher {
    private var pendingChordPrefix: ShortcutStroke?

    /// Returns:
    /// - `true`  → the event completes the save shortcut; caller should save.
    /// - `false` → the event matched the first stroke of a chord; caller
    ///             should consume the event but not save yet.
    /// - `nil`   → the event does not match; caller should fall through.
    mutating func match(event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }

        if let pendingPrefix = pendingChordPrefix {
            pendingChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else {
                return nil
            }
            return secondStroke.matches(event: event) ? true : nil
        }

        if shortcut.firstStroke.matches(event: event) {
            pendingChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}
