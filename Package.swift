// swift-tools-version: 5.10
//
// Top-level SwiftPM manifest for the Nix-driven cmux build (no xcodebuild).
// Sits alongside GhosttyTabs.xcodeproj so upstream contributors with Xcode
// keep the unchanged xcodeproj path. See nix-build/README.md and DIVERGENCE.md.
//
// Notes:
//   - Located at the repo root because SwiftPM disallows target `path:` values
//     outside the package root. Xcode prioritizes the .xcodeproj; the
//     Package.swift is only consumed when invoked via `swift build` /
//     `nix build .#cmux`.
//   - Local Packages/* are inlined as our own targets (not via .package(path:))
//     to bypass their `swift-tools-version: 6.0` manifests; nixpkgs ships
//     Swift 5.10.1 as of 2026-05.
//   - We attempted a custom @Observable macro plugin but nixpkgs's swift
//     compiler was built without macro language support ("macros are not
//     supported in this compiler" on any `public macro X()` declaration).
//     Falling back to manual @Observable → ObservableObject conversion via
//     `#if CMUX_NIX_BUILD` guards in upstream files.

import PackageDescription

let package = Package(
    name: "cmux",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux", targets: ["cmux"]),
        .library(name: "CMUXAppShim", targets: ["CMUXAppShim"]),
    ],
    dependencies: [
        // Remote SwiftPM packages — same set as XCRemoteSwiftPackageReference in project.pbxproj.
        // (Sparkle removed — see nix-build/Sources/Sparkle/Sparkle.swift for the stub.
        //  The real Sparkle.framework's XPC services trigger a SIGKILL/Code-Signature-Invalid
        //  crash under nixpkgs ad-hoc signing that we couldn't unstick.)
        // (Sentry removed — see nix-build/Sources/Sentry/Sentry.swift for the
        //  stub. The real Sentry.framework's static lib pages seem to be
        //  triggering the same "Code Signature Invalid" SIGKILL pattern as
        //  Sparkle did. Stubbing it lets the app launch.)
        // PostHog is stubbed out — see nix-build/Sources/PostHog/PostHog.swift.
        // The real posthog-ios vendors PHPLCrashReporter (Obj-C/C++) which doesn't
        // compile under nixpkgs cc-wrapper + apple-sdk-14.4 (Foundation.h PCH issue).
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),

        // swift-syntax dep removed (was for the CMUXObservation macro attempt;
        // nixpkgs swift doesn't support macros as a language feature, so the
        // macro path is blocked).

        // vendor/bonsplit ships its own Package.swift (swift-tools-version 5.9).
        .package(path: "vendor/bonsplit"),

        // vendor/stack-auth-swift-sdk-prerelease is a checked-in local package
        // (not a git submodule), pulled in from cmux's Auth/AuthManager.swift.
        .package(path: "vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        // Compatibility shim used only in the Nix build path.
        .target(
            name: "CMUXAppShim",
            path: "nix-build/Sources/CMUXAppShim"
        ),

        // Stub for `import PostHog`. Real SDK doesn't build under nixpkgs (see comment above).
        .target(
            name: "PostHog",
            path: "nix-build/Sources/PostHog"
        ),

        // Stub for `import Sparkle`. Real Sparkle.framework's XPC services
        // SIGKILL the app with "Code Signature Invalid" under nixpkgs ad-hoc
        // signing; we stub the API instead. Auto-update is disabled in the
        // Nix build path — non-essential for "try out cmux".
        .target(
            name: "Sparkle",
            path: "nix-build/Sources/Sparkle"
        ),

        // Stub for `import Sentry`. Same SIGKILL pattern as Sparkle. Error
        // reporting is disabled in the Nix build path.
        .target(
            name: "Sentry",
            path: "nix-build/Sources/Sentry"
        ),

        // GhosttyKit is built by ghostty's zig as an xcframework at the repo root
        // (./scripts/ensure-ghosttykit.sh). Declared here as a binary target so
        // Swift code can `import GhosttyKit` directly.
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),

        // Custom SQLite3 system module — nixpkgs apple-sdk-14.4's modulemap
        // declares SQLite3 but doesn't ship sqlite3.h. pkgs.sqlite (added to
        // flake buildInputs) provides the header via clang -I; this shim
        // exposes it as a fresh module so upstream code can do
        // `import CMUXSQLite` (under #if CMUX_NIX_BUILD) without touching the
        // SDK's broken SQLite3 module.
        .systemLibrary(
            name: "CMUXSQLite",
            path: "nix-build/Sources/CMUXSQLite",
            pkgConfig: "sqlite3"
        ),

        // CMUXObservation macro infrastructure removed — nixpkgs swift
        // doesn't support macros as a language feature. See DIVERGENCE.md.

        // -- Local packages, inlined --
        .target(
            name: "CMUXDebugLog",
            path: "Packages/CMUXDebugLog/Sources/CMUXDebugLog"
        ),
        .target(
            name: "CMUXAuthCore",
            path: "Packages/CMUXAuthCore/Sources/CMUXAuthCore"
        ),
        .target(
            name: "CMUXWorkstream",
            path: "Packages/CMUXWorkstream/Sources/CMUXWorkstream",
            swiftSettings: [.define("CMUX_NIX_BUILD")]
        ),
        .target(
            name: "CMUXPasteboardFidelity",
            path: "Packages/CMUXPasteboardFidelity/Sources/CMUXPasteboardFidelity"
        ),
        .target(
            name: "CMUXAgentVault",
            dependencies: ["CMUXSQLite"],
            path: "Packages/CMUXAgentVault/Sources/CMUXAgentVault",
            swiftSettings: [.define("CMUX_NIX_BUILD")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "CMUXAgentLaunch",
            dependencies: ["CMUXAgentVault"],
            path: "Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch",
            swiftSettings: [.define("CMUX_NIX_BUILD")]
        ),

        // -- The app --
        .executableTarget(
            name: "cmux",
            dependencies: [
                "Sparkle",  // local stub target
                "Sentry",   // local stub target
                "PostHog",  // local stub target
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
                "GhosttyKit",
                "CMUXAuthCore",
                "CMUXWorkstream",
                "CMUXPasteboardFidelity",
                "CMUXAgentVault",
                "CMUXAgentLaunch",
                "CMUXDebugLog",
                "CMUXAppShim",
                "CMUXSQLite",
            ],
            path: "Sources",
            exclude: [
                // Separate Xcode target in upstream — Nix build skips dock-tile plugin.
                "AppIconDockTilePlugin.swift",
            ],
            swiftSettings: [
                .define("CMUX_NIX_BUILD"),
                .unsafeFlags([
                    "-import-objc-header", "cmux-Bridging-Header.h",
                    "-Xcc", "-F", "-Xcc", "GhosttyKit.xcframework/macos-arm64_x86_64",
                    // Upstream cmux uses Xcode 26 / Swift 6 with looser
                    // MainActor isolation checking than nixpkgs's Swift
                    // 5.10.1 default. Force minimal strict concurrency to
                    // match upstream behavior.
                    "-strict-concurrency=minimal",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),  // Sentry's SentryNSDataUtils uses deflate/inflate; comes from pkgs.zlib via flake buildInputs
                .linkedLibrary("c++"),  // Ghostty's C++ helpers
                // GhosttyKit.xcframework is a static-library xcframework; the
                // .binaryTarget gives us the headers but the .a archive must
                // be linked explicitly.
                .unsafeFlags([
                    "-Xlinker", "GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a",
                    // App-bundle convention: Sparkle.framework lives at
                    // Contents/Frameworks/, the executable at Contents/MacOS/.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ]
)
