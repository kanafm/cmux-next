#!/usr/bin/env bash
# One-time: convert Assets.xcassets/AppIcon.appiconset PNGs into a single
# AppIcon.icns committed under nix-build/Resources/AppIcon.icns.
#
# Run from the repo root. `sips` and `iconutil` are at /usr/bin/ on every
# macOS install — no CLT, Xcode, or nix needed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
SRC="$REPO_ROOT/Assets.xcassets/AppIcon.appiconset"
DEST_DIR="$REPO_ROOT/nix-build/Resources"
DEST="$DEST_DIR/AppIcon.icns"

if [[ ! -d "$SRC" ]]; then
    echo "error: $SRC not found" >&2
    exit 1
fi

TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP" "$DEST_DIR"

# Standard .iconset layout. Light variants only — dark icon is dropped.
for s in 16 32 128 256 512; do
    if [[ ! -f "$SRC/${s}.png" || ! -f "$SRC/${s}@2x.png" ]]; then
        echo "error: missing $SRC/${s}.png or $SRC/${s}@2x.png" >&2
        exit 1
    fi
    cp "$SRC/${s}.png"    "$TMP/icon_${s}x${s}.png"
    cp "$SRC/${s}@2x.png" "$TMP/icon_${s}x${s}@2x.png"
done

iconutil -c icns "$TMP" -o "$DEST"
echo "wrote $DEST"
