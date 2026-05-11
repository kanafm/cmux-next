// Compatibility shim used only in the Nix build path.
//
// Upstream cmux ships icons via Assets.xcassets, which Xcode compiles into
// Assets.car using `actool` (Xcode-only, not in nixpkgs). The Nix build skips
// the asset catalog and ships loose PNGs at Resources/AgentIcons/<Name>.png.
// On startup we register each loose PNG with NSImage so existing
// `NSImage(named: "Claude")` call sites in the upstream Sources/ tree keep
// working unmodified.
//
// Call CMUXAppShim.bootstrap() once at app launch (gated behind
// `#if CMUX_NIX_BUILD` in upstream code, so the upstream xcodeproj build is
// untouched).

import AppKit
import Foundation

public enum CMUXAppShim {
    /// Register every Resources/AgentIcons/*.png as a named NSImage so that
    /// `NSImage(named:)` resolves against loose bundle resources.
    /// Idempotent.
    public static func bootstrap() {
        registerAgentIcons()
    }

    private static var didRegisterAgentIcons = false

    private static func registerAgentIcons() {
        guard !didRegisterAgentIcons else { return }
        didRegisterAgentIcons = true

        let bundle = Bundle.main
        guard let dir = bundle.url(forResource: "AgentIcons", withExtension: nil) else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "png" || ext == "svg" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let image = NSImage(contentsOf: url) {
                image.setName(name)
            }
        }
    }
}
