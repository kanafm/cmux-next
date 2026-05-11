import SwiftUI

// Centralized backports for newer SwiftUI APIs we want to use when available.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }

    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self.help(text)
        }
    }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        // The real `pointerStyle(_:)` modifier ships with macOS 15 SDK.
        // The Nix build uses apple-sdk-14.4 from nixpkgs, so the SDK doesn't
        // expose this symbol at compile time. Stub it to a no-op; pointer-style
        // hints are non-essential.
        return content
    }

    /// Backported onKeyPress that works on macOS 14+ and is a no-op on macOS 13.
    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
        if #available(macOS 14, *) {
            return content.onKeyPress(key, phases: [.down, .repeat], action: { keyPress in
                switch action(keyPress.modifiers) {
                case .handled: return .handled
                case .ignored: return .ignored
                }
            })
        } else {
            return content
        }
        #else
        return content
        #endif
    }
}

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    // `var official: PointerStyle` was here for the macOS 15 SDK build.
    // Removed for the Nix build (apple-sdk-14.4 from nixpkgs).
}
