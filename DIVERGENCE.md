# Divergence from upstream manaflow-ai/cmux

This fork (`kanafm/cmux-next`) adds a Nix flake that builds a runnable `cmux.app` on macOS without requiring Xcode.app or Xcode Command Line Tools to be installed. The flake provides everything (Swift compiler, macOS SDK, sqlite, zlib, zig) via nixpkgs.

The upstream xcodeproj based build (`./scripts/reload.sh`) is preserved and unchanged. Use it if you have Xcode and want the upstream developer experience. Use the Nix path (`swift build`, `./nix-build/scripts/assemble-app.sh`) if you want to build from source without touching Xcode.

## TL;DR

```
nix develop
swift build -c release
./nix-build/scripts/assemble-app.sh
open cmux.app
```

The resulting `.app` is ad-hoc signed, English only, missing the dock-tile plugin, and ships with stubbed auto-update and telemetry. Functionally it is cmux. You can use the terminal, open splits, browse tabs, manage files, run agents, all the core features. Sparkle update checks, Sentry crash reports, and PostHog analytics are no-ops.

## Why these changes exist

nixpkgs (as of `nixos-unstable` 2026-05) ships Swift 5.10.1 on Darwin, while upstream cmux assumes Swift 6 (Xcode 26). Swift's macro language feature is also absent from nixpkgs's compiler build. Several closed-source Apple tools (`actool`, `xcstringstool`, `ibtool`) only ship inside Xcode.app and can never be packaged for nixpkgs.

To bridge that gap we made these intentional deviations:

### 1. SwiftPM build instead of xcodebuild

A top-level `Package.swift` at the repo root drives a SwiftPM build of the same source tree the xcodeproj normally builds. Xcode build phases are reimplemented in shell (`nix-build/scripts/assemble-app.sh`). The xcodeproj is untouched and continues to work.

### 2. Sentry pinned to 8.x

`Package.swift` constrains `sentry-cocoa` to `"8.50.0"..<"9.0.0"`. Sentry 9.x requires `swift-tools-version: 6.0`, which nixpkgs Swift 5.10.1 refuses to read. cmux uses 4 stable SentrySDK calls (`start`, `addBreadcrumb`, `capture`, `crash`) that work identically in 8.x and 9.x. When nixpkgs ships Swift 6, this pin can be removed.

In practice the Sentry framework is currently stubbed out entirely (see point 3). The 8.x pin survives as the path of least resistance for when nixpkgs catches up.

### 3. Sentry, Sparkle, and PostHog stubbed

`nix-build/Sources/{Sentry,Sparkle,PostHog}/` contain hand-written stub modules that match each SDK's public API surface as cmux uses it, with no-op implementations.

- **Sparkle:** the real Sparkle.framework ships XPC services (Downloader.xpc, Installer.xpc) that load lazily at runtime. Under nixpkgs ad-hoc signing the XPC services fail dyld's page-hash check with `SIGKILL (Code Signature Invalid)`. The stub avoids the framework entirely. Auto-update is disabled.
- **PostHog:** the real `posthog-ios` SDK vendors PHPLCrashReporter (Objective-C/C++) which fails to compile under nixpkgs's cc-wrapper + apple-sdk combination (a Foundation.h PCH parsing issue). The stub takes over the import. Telemetry is disabled.
- **Sentry:** similar runtime signing issue with Sentry's prebuilt xcframework. Crash reporting is disabled.

The stubs preserve the entire cmux Source/ surface that imports these SDKs. Nothing in upstream cmux's source code needed editing to support the stubs.

### 4. Local Packages inlined as targets

The six packages under `Packages/` declare `swift-tools-version: 6.0`, which nixpkgs SwiftPM 5.10.1 refuses to read. The top-level `Package.swift` works around this by referencing each package's source directory via `.target(path: "Packages/.../Sources/...")` instead of `.package(path:)`. SwiftPM never reads those manifests in the Nix build.

This works because none of cmux's six local packages actually use Swift 6 language features. The 6.0 tools-version was forward-looking declaration, not a real requirement.

### 5. bonsplit forked

The split-pane subsystem lives in the `vendor/bonsplit` submodule. Upstream `manaflow-ai/bonsplit` uses Swift 5.9 `@Observable` (Observation framework macro). nixpkgs Swift 5.10.1's compiler was built without macro language support, so `@Observable` declarations fail with `unknown attribute 'Observable'`.

The submodule now points at [`kanafm/bonsplit`](https://github.com/kanafm/bonsplit) on the `nix-build-compat` branch. That branch converts the four `@Observable` classes (`PaneState`, `SplitState`, `SplitViewController`, `BonsplitController`) to the older `ObservableObject + @Published` pattern, and updates their SwiftUI consumers (`@Bindable` to `@ObservedObject`, `@Environment(T.self)` to `@EnvironmentObject`, `.environment(controller)` to `.environmentObject(controller)`).

Behavioral diff: `ObservableObject` fires `objectWillChange` on every `@Published` mutation, while `@Observable` only fires for properties a view actually reads. For cmux's usage patterns this is not perceptible.

### 6. SQLite via custom modulemap

cmux imports `SQLite3` for several stores (`Sources/SessionIndexStore.swift`, `Packages/CMUXAgentVault`, etc.). nixpkgs's apple-sdk declares a `SQLite3` module in its `module.modulemap` but doesn't ship the `sqlite3.h` header itself, so the build fails on the import.

`nix-build/Sources/CMUXSQLite/` provides a SwiftPM `systemLibrary` target with its own `module.modulemap` that points at `pkgs.sqlite`'s header. Five upstream files swap `import SQLite3` for `import CMUXSQLite` under `#if CMUX_NIX_BUILD`. The C ABI of `sqlite3_*` is identical.

### 7. `nonisolated` modifier strips

Swift 6 lets you write `nonisolated struct Foo {}` and `nonisolated extension Bar {}` at the type level. Swift 5.10 rejects this syntax. Seven files in `Sources/` had top level `nonisolated` modifiers stripped. Types are nonisolated by default in Swift 5 mode anyway, so this is purely a syntax adjustment, not a semantics change.

### 8. `@MainActor` annotations added

Swift 6 strict concurrency infers `@MainActor` aggressively, especially for SwiftUI helper methods. Swift 5.10 does not. About 20 methods across cmux Sources/ (concentrated in `BrowserPanelView.swift`, `FeedPanelView.swift`, `cmuxApp.swift`, `GhosttyTerminalView.swift`, `Auth/AuthManager.swift`, others) had `@MainActor` added so they can call other `@MainActor` APIs without isolation errors. Behavior under Xcode 26 is unchanged since the inference Swift 6 was already doing is now spelled out explicitly.

A handful of closures that capture `self` for `Task { @MainActor in ... }` also got explicit `[weak self]` capture lists to silence Swift 5.10's stricter capture analysis.

### 9. macOS 15 API stubs

`Sources/Backport.swift` and `Sources/Panels/BrowserWebAuthnSupport.swift` referenced a few APIs that only exist in the macOS 15 SDK (`PointerStyle`, `ASAuthorizationSecurityKey*.transports`, `ASAuthorizationSecurityKey*.appID`). nixpkgs ships apple-sdk-14.4. The macOS 15 only branches are now stubbed to return empty values on the Nix path. The corresponding features (custom pointer styles, WebAuthn appID/transports) silently degrade.

### 10. Asset catalog dropped, single icon, English only

`Assets.xcassets` is compiled by `actool` (Xcode only). The Nix build cannot use it. Instead:

- `nix-build/Resources/AppIcon.icns` is pre-built from `Assets.xcassets/AppIcon.appiconset` using `iconutil`. Single icon, no Debug or Nightly variants, no automatic dark mode icon swap.
- `nix-build/Resources/AgentIcons/` ships the agent provider icons (Claude, Codex, HermesAgent, OpenCode, RovoDev) as loose `.png` and `.svg` files.
- `nix-build/Sources/CMUXAppShim/AssetCompat.swift` registers each loose AgentIcon with `NSImage.setName` at bundle initialization, so existing `NSImage(named: "Claude")` call sites in upstream Sources/ resolve at runtime without an asset catalog.

`Resources/Localizable.xcstrings` and `Resources/InfoPlist.xcstrings` are compiled by `xcstringstool` (Xcode only). The Nix build does not bundle compiled strings catalogs. Foundation's `String(localized: "key", defaultValue: "English text")` falls back to the English default at every call site, so the UI is English only.

### 11. Dock tile plugin not built

`Sources/AppIconDockTilePlugin.swift` is a separate `wrapper.cfbundle` Xcode target that ships inside the upstream `.app/Contents/PlugIns/` and provides dynamic dock badge updates when the app is closed. The Nix build does not build this target; `NSDockTilePlugIn` is omitted from Info.plist. Dock badges still work while cmux is running, but not when it's quit.

### 12. Code signing is ad-hoc

`assemble-app.sh` signs with `codesign --sign -` (ad-hoc identity) using a minimal entitlements file at `nix-build/Resources/cmux.entitlements`. Distribution via Developer ID or notarization is out of scope. Sparkle update signature verification is disabled (`SUPublicEDKey` is empty).

The entitlements grant `com.apple.security.cs.disable-library-validation`, `com.apple.security.cs.allow-unsigned-executable-memory`, and `com.apple.security.cs.allow-dyld-environment-variables`. These are required because the bundle loads nix-store dylibs and uses `DYLD_*` lookup paths.

### 13. `libswift_StringProcessing.dylib` redirected to system

This is the one that took the longest to chase down. The Swift compiler's link step adds an `LC_LOAD_DYLIB` for `/nix/store/.../swift-5.10.1-lib/lib/swift/macosx/libswift_StringProcessing.dylib`. cmux uses regex features that pull this dylib in at process start.

nixpkgs's copy of `libswift_StringProcessing.dylib` is marked `tainted:1` by macOS's kernel code-signing check, even though `codesign --verify` says it is valid. The exact taint cause is not fully understood; likely related to how nixpkgs strips or normalizes Mach-O metadata when packaging the dylib. Result: at runtime the kernel rejects every page of that dylib with `cs_invalid_page` and SIGKILLs the process.

The fix is one line in `assemble-app.sh`: `install_name_tool -change` rewrites the load command from the nix-store path to `/usr/lib/swift/libswift_StringProcessing.dylib`. macOS 15 ships this dylib through the dyld_shared_cache, signed by Apple. No more taint, no more SIGKILL.

The same redirect applies to `libsqlite3.dylib` (nix-store -> `/usr/lib/libsqlite3.dylib`) and `libz.dylib` (nix-store -> `/usr/lib/libz.1.dylib`). Both system copies are Apple-signed.

### 14. cmux-cli not built

`Sources/cmux-cli` (the `cmux` command-line binary upstream bundles inside the `.app`) is not built by the Nix path. It would be a separate `.executableTarget` in `Package.swift`. Tractable; just out of scope for the first cut.

## How to maintain this fork against upstream

Most upstream merges flow through cleanly. Watch out for:

- New `@Observable` usages in cmux Sources/: convert to `ObservableObject + @Published` or wait for nixpkgs to gain Swift macro support.
- New `import SQLite3`: wrap in the `#if CMUX_NIX_BUILD` swap.
- New `XCRemoteSwiftPackageReference` entries in `GhosttyTabs.xcodeproj`: mirror into `Package.swift`. If the new dep ships a dylib/xcframework, expect signing surgery.
- New Xcode-only assets in `Assets.xcassets`: re-run `./nix-build/scripts/extract-agent-icons.sh` and `./nix-build/scripts/bake-icon.sh`.
- New non-asset bundle resources under `Resources/` (HTML/JS/CSS templates, loose plug-in scripts, etc.) need an explicit `cp` in `nix-build/scripts/assemble-app.sh`. The Xcode build's "Copy Bundle Resources" phase picks them up automatically; the Nix script uses an allowlist, so a forgotten cp produces a `.app` whose code looks for a missing bundle resource at runtime.
- New `nonisolated` type-level declarations or other Swift 6 syntax in upstream Sources/: strip or wait for nixpkgs Swift 6.

When nixpkgs eventually ships Swift 6 on Darwin:
- Drop the Sentry 8.x pin.
- Remove the @Observable conversion in `vendor/bonsplit`'s `nix-build-compat` branch (or merge it upstream as #if-guarded compat). 
- Drop the `nonisolated` strips and `@MainActor` annotations (or leave them, they're harmless).

## Files that exist only on this fork

```
flake.nix
flake.lock
Package.swift
DIVERGENCE.md
nix-build/
  Package.swift              # (older; not used; superseded by root Package.swift)
  Resources/
    AppIcon.icns
    AgentIcons/*.png, *.svg
    Info.plist
    cmux.entitlements
  Sources/
    CMUXAppShim/
    CMUXSQLite/
    PostHog/                 # stub
    Sparkle/                 # stub
    Sentry/                  # stub
  scripts/
    bake-icon.sh
    extract-agent-icons.sh
    assemble-app.sh
  default.nix                # WIP, not yet wired
```

Upstream source files modified on this fork: about 20 across `Sources/` and `Packages/`, mostly `@MainActor` additions, `nonisolated` strips, the `#if CMUX_NIX_BUILD` import swaps, and a few small captured-var fixes for Swift 5.10's stricter concurrency analysis. None of them change behavior under Xcode 26.
