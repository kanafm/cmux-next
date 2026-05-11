#!/usr/bin/env bash
# Assemble cmux.app from a built `swift build -c release` output.
# Run from the repo root inside `nix develop`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
cd "$REPO_ROOT"

OUT_APP="${OUT_APP:-$REPO_ROOT/cmux.app}"
BIN_DIR="${BIN_DIR:-$REPO_ROOT/.build/arm64-apple-macosx/release}"
EXEC="$BIN_DIR/cmux"
RESOURCES_DIR="$REPO_ROOT/nix-build/Resources"
SPARKLE_FRAMEWORK="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
UPSTREAM_RESOURCES="$REPO_ROOT/Resources"

if [[ ! -x "$EXEC" ]]; then
    echo "error: $EXEC not found. Run 'swift build -c release' first." >&2
    exit 1
fi

echo "==> Assembling $OUT_APP"
rm -rf "$OUT_APP"
mkdir -p "$OUT_APP/Contents/MacOS"
mkdir -p "$OUT_APP/Contents/Resources"
mkdir -p "$OUT_APP/Contents/Frameworks"

# 1. Executable
cp "$EXEC" "$OUT_APP/Contents/MacOS/cmux"
chmod +x "$OUT_APP/Contents/MacOS/cmux"

# 2. Info.plist + entitlements + AppIcon + AgentIcons
cp "$RESOURCES_DIR/Info.plist"      "$OUT_APP/Contents/Info.plist"
cp "$RESOURCES_DIR/AppIcon.icns"    "$OUT_APP/Contents/Resources/AppIcon.icns"
cp -R "$RESOURCES_DIR/AgentIcons"   "$OUT_APP/Contents/Resources/AgentIcons"

# 3. Stamp git short SHA into Info.plist (matches upstream's build phase).
#    Skipped by default (CMUX_SCRUB=1) so the assembled bundle doesn't link
#    to a specific fork commit. Set CMUX_SCRUB=0 to keep the legacy behavior
#    for local debugging.
if [[ "${CMUX_SCRUB:-1}" != "1" ]]; then
    COMMIT="$(git -C "$REPO_ROOT" rev-parse --short=9 HEAD 2>/dev/null || true)"
    if [[ -n "$COMMIT" ]]; then
        /usr/libexec/PlistBuddy -c "Add :CMUXCommit string $COMMIT" "$OUT_APP/Contents/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :CMUXCommit $COMMIT" "$OUT_APP/Contents/Info.plist"
    fi
fi

# 4. Sparkle is stubbed (nix-build/Sources/Sparkle). No real framework to embed.
#    Auto-update is disabled in this build path — see DIVERGENCE.md.

# 5. Ghostty share-tree (port of upstream's build-phase rsync logic)
GHOSTTY_SRC_SHARE="$REPO_ROOT/ghostty/zig-out/share"
FALLBACK_GHOSTTY="$UPSTREAM_RESOURCES/ghostty"
GHOSTTY_DEST="$OUT_APP/Contents/Resources/ghostty"
TERMINFO_DEST="$OUT_APP/Contents/Resources/terminfo"
SHELL_INTEGRATION_DEST="$OUT_APP/Contents/Resources/shell-integration"

if [[ -d "$GHOSTTY_SRC_SHARE/ghostty" ]]; then
    mkdir -p "$GHOSTTY_DEST"
    rsync -a --delete "$GHOSTTY_SRC_SHARE/ghostty/" "$GHOSTTY_DEST/"
elif [[ -d "$FALLBACK_GHOSTTY" ]]; then
    mkdir -p "$GHOSTTY_DEST"
    rsync -a --delete "$FALLBACK_GHOSTTY/" "$GHOSTTY_DEST/"
fi

if [[ -d "$GHOSTTY_SRC_SHARE/terminfo" ]]; then
    mkdir -p "$TERMINFO_DEST"
    rsync -a --delete "$GHOSTTY_SRC_SHARE/terminfo/" "$TERMINFO_DEST/"
elif [[ -d "$FALLBACK_GHOSTTY/terminfo" ]]; then
    mkdir -p "$TERMINFO_DEST"
    rsync -a --delete "$FALLBACK_GHOSTTY/terminfo/" "$TERMINFO_DEST/"
fi

# Apply cmux terminfo overlay if present
if [[ -d "$UPSTREAM_RESOURCES/terminfo-overlay" ]]; then
    mkdir -p "$TERMINFO_DEST"
    rsync -a "$UPSTREAM_RESOURCES/terminfo-overlay/" "$TERMINFO_DEST/"
fi

# Shell integration (zsh/bash/fish init bits)
if [[ -d "$UPSTREAM_RESOURCES/shell-integration" ]]; then
    mkdir -p "$SHELL_INTEGRATION_DEST"
    rsync -a "$UPSTREAM_RESOURCES/shell-integration/." "$SHELL_INTEGRATION_DEST/"
fi

# Ghostty's own zsh integration file
GHOSTTY_ZSH_SRC="$REPO_ROOT/ghostty/src/shell-integration/zsh/ghostty-integration"
if [[ -f "$GHOSTTY_ZSH_SRC" ]]; then
    mkdir -p "$SHELL_INTEGRATION_DEST"
    cp "$GHOSTTY_ZSH_SRC" "$SHELL_INTEGRATION_DEST/ghostty-integration.zsh"
fi

# Bundled markdown renderer (HTML template + marked.min.js) for MarkdownPreviewView.
if [[ -d "$UPSTREAM_RESOURCES/markdown-renderer" ]]; then
    mkdir -p "$OUT_APP/Contents/Resources/markdown-renderer"
    cp -R "$UPSTREAM_RESOURCES/markdown-renderer/." "$OUT_APP/Contents/Resources/markdown-renderer/"
fi

# 6. Rewrite nix-store dylib references to the SYSTEM paths shipped with
#    macOS (/usr/lib/libsqlite3.dylib, /usr/lib/libz.1.dylib). The nix-store
#    originals have no code signature, which macOS rejects at runtime even
#    with `com.apple.security.cs.disable-library-validation`. The system
#    copies are Apple-signed and load cleanly.
#
#    These system libraries are part of macOS itself (not Xcode/CLT) and
#    are present on every Mac, so cmux.app stays portable.
nix_dylib_path() {
    /usr/bin/otool -L "$OUT_APP/Contents/MacOS/cmux" \
        | awk -v name="$1" '$1 ~ name {print $1; exit}'
}

# libsqlite3: /nix/store/.../libsqlite3.dylib -> /usr/lib/libsqlite3.dylib
SQLITE_SRC="$(nix_dylib_path libsqlite3.dylib)"
if [[ -n "$SQLITE_SRC" && "$SQLITE_SRC" == /nix/store/* ]]; then
    /usr/bin/install_name_tool -change "$SQLITE_SRC" /usr/lib/libsqlite3.dylib "$OUT_APP/Contents/MacOS/cmux"
fi

# libz: /nix/store/.../libz.dylib -> /usr/lib/libz.1.dylib (macOS's stable system name)
ZLIB_SRC="$(nix_dylib_path libz.dylib)"
if [[ -n "$ZLIB_SRC" && "$ZLIB_SRC" == /nix/store/* ]]; then
    /usr/bin/install_name_tool -change "$ZLIB_SRC" /usr/lib/libz.1.dylib "$OUT_APP/Contents/MacOS/cmux"
fi

# libswift_StringProcessing: the nix-store copy is "tainted" per macOS kernel
# code-signing — when cmux loads it lazily for regex, the kernel SIGKILLs
# with "Code Signature Invalid". macOS 15 ships its own properly-signed copy
# at /usr/lib/swift/, so redirect there instead. (Strictly, dyld_shared_cache
# resolves /usr/lib/swift/* without needing an on-disk file.)
SP_SRC="$(nix_dylib_path libswift_StringProcessing.dylib)"
if [[ -n "$SP_SRC" && "$SP_SRC" == /nix/store/* ]]; then
    /usr/bin/install_name_tool -change "$SP_SRC" /usr/lib/swift/libswift_StringProcessing.dylib "$OUT_APP/Contents/MacOS/cmux"
fi

# 6b. Scrub build-host paths from the binary.
#
# `swift build -c release` embeds DWARF debug-info sections containing
# absolute source paths like /Users/<user>/Desktop/.../cmux/Sources/...
# Those leak the build host's username if the bundle is distributed.
# `strip -S` removes the DWARF section; `strip -x` drops local symbols
# (which can also embed path-derived names). Together they leave a
# functioning release binary with no path leaks visible to `strings`.
if [[ "${CMUX_SCRUB:-1}" == "1" ]]; then
    /usr/bin/strip -Sx "$OUT_APP/Contents/MacOS/cmux"
fi

# 7. Strip any existing signatures, then re-sign inside-out.
#
# Strip first because install_name_tool may have invalidated existing
# signatures, and macOS's dyld page-hash check at runtime is unforgiving:
# stale signature + modified bytes = SIGKILL "Code Signature Invalid".
# Fresh signing from a known-no-signature state is the safest path.
ENTITLEMENTS="$RESOURCES_DIR/cmux.entitlements"

# Strip signatures from all Mach-O files in the bundle.
find "$OUT_APP" -type d -name "_CodeSignature" -exec rm -rf {} + 2>/dev/null || true
find "$OUT_APP" -type f \( -name "*.dylib" -o -name "*.so" \) -exec codesign --remove-signature {} \; 2>/dev/null || true
codesign --remove-signature "$OUT_APP/Contents/MacOS/cmux" 2>/dev/null || true

# (No Sparkle.framework to sign — it's stubbed out.)

# (Bundled nix dylibs path removed — we point at system libsqlite3/libz instead.)

# Sign main executable explicitly (since install_name_tool modified its content)
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$OUT_APP/Contents/MacOS/cmux"

# Outer bundle signature — NO --deep flag.
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$OUT_APP"

echo "==> cmux.app assembled at $OUT_APP"
codesign --verify --verbose "$OUT_APP" 2>&1 | head -5 || true
