#!/usr/bin/env bash
# One-time: copy each Assets.xcassets/AgentIcons/<Name>.imageset's largest PNG
# to nix-build/Resources/AgentIcons/<Name>.png so the Nix build can ship them
# as loose bundle resources instead of compiling an asset catalog.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
SRC="$REPO_ROOT/Assets.xcassets/AgentIcons"
DEST="$REPO_ROOT/nix-build/Resources/AgentIcons"

if [[ ! -d "$SRC" ]]; then
    echo "error: $SRC not found" >&2
    exit 1
fi

mkdir -p "$DEST"

count=0
for dir in "$SRC"/*.imageset; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir" .imageset)"

    # Prefer SVG (vector — perfect at any size) > @3x PNG > @2x > @1x.
    # NSImage on macOS Big Sur+ handles SVG natively.
    if   [[ -f "$dir/$name.svg"    ]]; then cp "$dir/$name.svg"    "$DEST/$name.svg"
    elif [[ -f "$dir/$name@3x.png" ]]; then cp "$dir/$name@3x.png" "$DEST/$name.png"
    elif [[ -f "$dir/$name@2x.png" ]]; then cp "$dir/$name@2x.png" "$DEST/$name.png"
    elif [[ -f "$dir/$name.png"    ]]; then cp "$dir/$name.png"    "$DEST/$name.png"
    else
        echo "warning: no PNG/SVG found in $dir, skipping" >&2
        continue
    fi

    count=$((count + 1))
done

echo "wrote $count icon(s) to $DEST"
