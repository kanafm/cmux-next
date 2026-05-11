#!/usr/bin/env bash
# Validate that the current local tree builds a working cmux.app.
# Pre-flight, build, assemble, codesign verify, leak check, launch smoke.
# No git operations, no remote interaction, no pushes.
#
# Run from the repo root (or anywhere; the script resolves its location).
#
# Exit codes:
#   0   green
#   1   pre-flight failed (dirty tree, missing tooling)
#   3   swift build did not complete or binary missing
#   4   assemble or codesign verify failed
#   5   stale /nix/store dylib reference (would SIGKILL at launch)
#   6   launch smoke test failed (cmux exited within 5s)
#   7   build-host path leaked into binary after scrub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Auto-enter nix develop if not already inside it.
if [[ "${CMUX_VALIDATE_INSIDE_NIX:-0}" != "1" ]]; then
    if ! command -v nix >/dev/null 2>&1; then
        echo "ERROR: nix is not on PATH. Install Nix and re-run." >&2
        exit 1
    fi
    exec nix develop --command env CMUX_VALIDATE_INSIDE_NIX=1 bash "$0" "$@"
fi

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m   FAIL: %s\033[0m\n' "$*" >&2; }

# -------------------- Phase 1: pre-flight --------------------
log "Pre-flight checks"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    fail "Working tree has uncommitted changes. Commit or stash them first:"
    git status --short
    exit 1
fi

if [[ -n "$(git -C vendor/bonsplit status --porcelain --untracked-files=no)" ]]; then
    fail "vendor/bonsplit working tree is dirty:"
    git -C vendor/bonsplit status --short
    exit 1
fi

# -------------------- Phase 2: build --------------------
log "Building cmux (swift build -c release)"

# Build outputs go to a neutral scratch path so the SwiftPM-generated
# `resource_bundle_accessor.swift` files do not embed the build host's
# $HOME in the binary. The .build symlink keeps the repo root looking
# normal for editor tooling while the actual outputs live elsewhere.
SCRATCH_PATH="/private/tmp/cmux-build"
rm -rf "$SCRATCH_PATH" .build
mkdir -p "$SCRATCH_PATH"
ln -sf "$SCRATCH_PATH" .build

# nixpkgs swift emits a spurious 'error: unexpected binary framework' during
# manifest parsing (pkg-config for sqlite3 isn't found) but the build itself
# completes and produces a working binary. Trust the produced artifact, not
# the swift exit code: success = "Build complete!" in the log AND the binary
# exists on disk.
set +e
MACOSX_DEPLOYMENT_TARGET=14.0 swift build -c release --scratch-path "$SCRATCH_PATH" 2>&1 | tee /tmp/cmux-validate-build.log | tail -30
set -e
if ! grep -q "Build complete!" /tmp/cmux-validate-build.log; then
    fail "swift build did not complete. Full log: /tmp/cmux-validate-build.log"
    exit 3
fi
BIN_DIR="$SCRATCH_PATH/arm64-apple-macosx/release"
if [[ ! -x "$BIN_DIR/cmux" ]]; then
    fail "swift build reported completion but $BIN_DIR/cmux is missing"
    exit 3
fi
export BIN_DIR

# -------------------- Phase 3: GhosttyKit + assemble --------------------
log "Ensuring GhosttyKit.xcframework"
if ! ./scripts/ensure-ghosttykit.sh 2>&1 | tail -10; then
    fail "ensure-ghosttykit.sh failed"
    exit 4
fi

log "Assembling cmux.app"
rm -rf cmux.app
if ! ./nix-build/scripts/assemble-app.sh 2>&1 | tail -10; then
    fail "assemble-app.sh failed"
    exit 4
fi

# -------------------- Phase 4: verify --------------------
log "Verifying codesign"
if ! codesign --verify --deep --strict cmux.app; then
    fail "codesign verification failed"
    exit 4
fi

log "Checking for stale /nix/store dylib references"
STALE="$(otool -L cmux.app/Contents/MacOS/cmux | awk '/\/nix\/store\// {print $1}' || true)"
if [[ -n "$STALE" ]]; then
    fail "cmux binary still references /nix/store dylibs that would SIGKILL at launch:"
    echo "$STALE" | sed 's/^/    /'
    echo
    fail "Update nix-build/scripts/assemble-app.sh's install_name_tool block to redirect these."
    exit 5
fi

log "Checking for build-host path leaks in binary"
# Match /Users/<name>/ where <name> starts with a letter and does not contain
# $ or {. This catches real usernames like /Users/kana/ while ignoring shell
# script literals like /Users/$cmux_dock_user/ that are runtime templates,
# not build-host paths.
LEAK="$(strings cmux.app/Contents/MacOS/cmux \
    | grep -E '/Users/[a-zA-Z][^/$\{]*/' \
    | grep -v '/Users/Shared/' \
    | head -5 || true)"
if [[ -n "$LEAK" ]]; then
    fail "cmux binary still contains build-host paths after scrub:"
    echo "$LEAK" | sed 's/^/    /'
    fail "Check that --scratch-path and -file-compilation-dir are applied."
    exit 7
fi

# -------------------- Phase 5: launch smoke --------------------
log "Launch smoke test (5s)"
open cmux.app
sleep 5
if pgrep -f 'cmux.app/Contents/MacOS/cmux' >/dev/null; then
    pkill -f 'cmux.app/Contents/MacOS/cmux' || true
    sleep 1
else
    fail "cmux.app exited within 5s. Check ~/Library/Logs/DiagnosticReports/cmux-*.ips"
    exit 6
fi

# -------------------- Phase 6: report --------------------
APP_SIZE="$(du -sh cmux.app | cut -f1)"
printf '\n\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  VALIDATION GREEN  (cmux.app: %s)\033[0m\n' "$APP_SIZE"
printf '\033[1;32m========================================\033[0m\n'

exit 0
