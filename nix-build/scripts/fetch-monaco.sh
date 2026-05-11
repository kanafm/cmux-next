#!/usr/bin/env bash
# Fetch the monaco-editor npm tarball, verify its sha256, and extract
# package/min/vs/ to Resources/monaco-editor/vs/ at the repo root.
#
# Idempotent: a .version stamp in the destination short-circuits when the
# cached contents already match MONACO_VERSION. Bump the pin below to
# upgrade.
#
# If MONACO_TARBALL is set in the environment (the Nix dev shell exports
# this from flake.nix's fetchurl), copy from that path instead of curling.
# Both code paths verify MONACO_SHA256, so the two paths are byte-equivalent.
#
# Exit codes:
#   0   cache hit, or fresh fetch+extract succeeded
#   1   missing tooling (curl, shasum, tar)
#   2   curl failed (no network on first build, npm down, etc.)
#   3   sha256 mismatch (corrupt download, registry compromise, bad pin)
#   4   tar extraction failed

set -euo pipefail

# -- Pin ---------------------------------------------------------------------
MONACO_VERSION="0.55.1"
MONACO_SHA256="eec3721fb6b1dc5a0bd1a73e38a5eb5d0c3791af684f7d2571efb90ad8634871"
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEST="$REPO_ROOT/Resources/monaco-editor"
VERSION_FILE="$DEST/.version"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m   FAIL: %s\033[0m\n' "$*" >&2; }

for tool in curl shasum tar; do
    command -v "$tool" >/dev/null 2>&1 || { fail "$tool not on PATH"; exit 1; }
done

mkdir -p "$DEST"

if [[ -f "$VERSION_FILE" ]] && [[ "$(cat "$VERSION_FILE")" == "$MONACO_VERSION" ]] && [[ -f "$DEST/vs/loader.js" ]]; then
    # Cache hit. Nothing to do.
    exit 0
fi

log "Fetching monaco-editor $MONACO_VERSION"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

TARBALL_LOCAL="$TMPDIR/monaco.tgz"

if [[ -n "${MONACO_TARBALL:-}" ]]; then
    log "Using nix-store tarball: $MONACO_TARBALL"
    cp "$MONACO_TARBALL" "$TARBALL_LOCAL"
else
    URL="https://registry.npmjs.org/monaco-editor/-/monaco-editor-${MONACO_VERSION}.tgz"
    log "Downloading $URL"
    if ! curl -fSL "$URL" -o "$TARBALL_LOCAL"; then
        fail "curl failed; check network connectivity"
        exit 2
    fi
fi

ACTUAL_SHA="$(shasum -a 256 "$TARBALL_LOCAL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$MONACO_SHA256" ]]; then
    fail "sha256 mismatch"
    echo "    expected: $MONACO_SHA256"
    echo "    actual  : $ACTUAL_SHA"
    exit 3
fi
log "sha256 verified"

log "Extracting package/min/vs and package/LICENSE"
if ! tar -xzf "$TARBALL_LOCAL" -C "$TMPDIR" package/min/vs package/LICENSE; then
    fail "tar extraction failed"
    exit 4
fi

# Atomic-ish swap: remove the old vs/, rename the new one into place.
# .version is written last so a partial extraction does not appear cached.
rm -rf "$DEST/vs"
mv "$TMPDIR/package/min/vs" "$DEST/vs"
cp "$TMPDIR/package/LICENSE" "$DEST/LICENSE"
printf '%s\n' "$MONACO_VERSION" > "$VERSION_FILE.tmp"
mv "$VERSION_FILE.tmp" "$VERSION_FILE"

log "monaco-editor $MONACO_VERSION installed at $DEST/vs"
