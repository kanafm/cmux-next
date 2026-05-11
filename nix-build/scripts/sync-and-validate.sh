#!/usr/bin/env bash
# Pre-push validation: pull latest from upstream into our fork, apply our
# patches on top, build the whole pipeline end to end, smoke-test the .app,
# and report whether it's safe to push to kanafm/cmux-next and kanafm/bonsplit.
#
# Run this manually from the repo root before each `git push`. Designed to
# avoid the cost of a GitHub Actions macOS runner while keeping the same
# safety net. No auto-push: the script prints the exact push commands at
# the end so you can review and run them yourself.
#
# Exit codes:
#   0   green, safe to push
#   2   rebase conflict (resolve, then rerun)
#   3   swift build failed
#   4   bundle assembly failed
#   5   stale /nix/store dylib reference in cmux binary
#   6   launch smoke test failed
#   1   other (uncategorized) error

set -euo pipefail

# Resolve repo root from script location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Auto-enter nix develop if not already inside it. Use a marker env var so
# the re-exec doesn't recurse.
if [[ "${CMUX_VALIDATE_INSIDE_NIX:-0}" != "1" ]]; then
    if ! command -v nix >/dev/null 2>&1; then
        echo "ERROR: nix is not on PATH. Install Nix and re-run." >&2
        exit 1
    fi
    exec nix develop --command env CMUX_VALIDATE_INSIDE_NIX=1 bash "$0" "$@"
fi

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m   warn: %s\033[0m\n' "$*" >&2; }
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

CMUX_START_SHA="$(git rev-parse HEAD)"
BONSPLIT_START_SHA="$(git -C vendor/bonsplit rev-parse HEAD)"
echo "    cmux HEAD     : $CMUX_START_SHA"
echo "    bonsplit HEAD : $BONSPLIT_START_SHA"

if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then
    fail "Not on cmux main branch. Switch to main first."
    exit 1
fi

if [[ "$(git -C vendor/bonsplit rev-parse --abbrev-ref HEAD)" != "main" ]]; then
    log "Switching vendor/bonsplit onto main branch (was detached or other branch)"
    git -C vendor/bonsplit checkout main
fi

# -------------------- Phase 2: bonsplit sync --------------------
log "Syncing vendor/bonsplit"

git -C vendor/bonsplit fetch --quiet origin
git -C vendor/bonsplit fetch --quiet kanafm 2>/dev/null || warn "kanafm remote not configured on bonsplit; skipping that fetch"

BONSPLIT_UPSTREAM_BEFORE="$(git -C vendor/bonsplit rev-parse origin/main)"
echo "    upstream main: $BONSPLIT_UPSTREAM_BEFORE"

if ! git -C vendor/bonsplit rebase origin/main; then
    fail "bonsplit rebase onto origin/main produced conflicts. Resolve them:"
    git -C vendor/bonsplit status --short
    git -C vendor/bonsplit rebase --abort
    git -C vendor/bonsplit checkout "$BONSPLIT_START_SHA"
    exit 2
fi

BONSPLIT_NEW_SHA="$(git -C vendor/bonsplit rev-parse HEAD)"
if [[ "$BONSPLIT_NEW_SHA" != "$BONSPLIT_START_SHA" ]]; then
    log "Bonsplit rebased to new HEAD $BONSPLIT_NEW_SHA"
    BONSPLIT_PUSH_NEEDED=1
else
    echo "    bonsplit already up to date"
    BONSPLIT_PUSH_NEEDED=0
fi

# -------------------- Phase 3: cmux sync --------------------
log "Syncing cmux"

git fetch --quiet origin
git fetch --quiet kanafm 2>/dev/null || warn "kanafm remote not configured on cmux; skipping that fetch"

CMUX_UPSTREAM_BEFORE="$(git rev-parse origin/main)"
echo "    upstream main: $CMUX_UPSTREAM_BEFORE"

if ! git rebase origin/main; then
    fail "cmux rebase onto origin/main produced conflicts. Resolve them:"
    git status --short
    git rebase --abort
    git checkout "$CMUX_START_SHA"
    git -C vendor/bonsplit checkout "$BONSPLIT_START_SHA"
    exit 2
fi

CMUX_NEW_SHA="$(git rev-parse HEAD)"
if [[ "$CMUX_NEW_SHA" != "$CMUX_START_SHA" ]]; then
    log "Cmux rebased to new HEAD $CMUX_NEW_SHA"
    CMUX_PUSH_NEEDED=1
else
    echo "    cmux already up to date"
    CMUX_PUSH_NEEDED=0
fi

# If bonsplit advanced, the parent repo now has a submodule pointer diff.
# Stage it but do not commit; the user decides whether to amend or add a
# new chore commit.
if [[ "$BONSPLIT_PUSH_NEEDED" -eq 1 ]]; then
    log "Bonsplit pointer in cmux needs bumping ($(git submodule status vendor/bonsplit))"
fi

# -------------------- Phase 4: build --------------------
log "Building cmux (swift build -c release)"
rm -rf .build
if ! MACOSX_DEPLOYMENT_TARGET=14.0 swift build -c release 2>&1 | tee /tmp/cmux-validate-build.log | tail -30; then
    fail "swift build failed. Full log: /tmp/cmux-validate-build.log"
    exit 3
fi
if [[ ! -x .build/arm64-apple-macosx/release/cmux ]]; then
    fail "swift build completed but .build/arm64-apple-macosx/release/cmux is missing"
    exit 3
fi

# -------------------- Phase 5: GhosttyKit + assemble --------------------
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

# -------------------- Phase 6: verify --------------------
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

# -------------------- Phase 7: launch smoke --------------------
log "Launch smoke test (5s)"
open cmux.app
sleep 5
if pgrep -f 'cmux.app/Contents/MacOS/cmux' >/dev/null; then
    LAUNCH_OK=1
    pkill -f 'cmux.app/Contents/MacOS/cmux' || true
    sleep 1
else
    LAUNCH_OK=0
fi

if [[ "$LAUNCH_OK" -ne 1 ]]; then
    fail "cmux.app exited within 5s. Check ~/Library/Logs/DiagnosticReports/cmux-*.ips"
    exit 6
fi

# -------------------- Phase 8: report --------------------
APP_SIZE="$(du -sh cmux.app | cut -f1)"

printf '\n\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  VALIDATION GREEN  %s safe to push\033[0m\n' "(cmux.app: $APP_SIZE)"
printf '\033[1;32m========================================\033[0m\n\n'

echo "Cmux:     $CMUX_START_SHA -> $CMUX_NEW_SHA"
echo "Bonsplit: $BONSPLIT_START_SHA -> $BONSPLIT_NEW_SHA"
echo

if [[ "$BONSPLIT_PUSH_NEEDED" -eq 1 ]]; then
    echo "Bonsplit changed. Push it first, then bump cmux's submodule pointer:"
    echo "    git -C vendor/bonsplit push kanafm main"
    echo "    git add vendor/bonsplit"
    echo "    git -c user.name=kanafm -c user.email=kanafm@users.noreply.github.com commit -m 'chore: bump bonsplit submodule'"
fi

if [[ "$CMUX_PUSH_NEEDED" -eq 1 || "$BONSPLIT_PUSH_NEEDED" -eq 1 ]]; then
    echo "Then push cmux:"
    echo "    git push kanafm main"
else
    echo "No new upstream commits; nothing to push."
fi

exit 0
