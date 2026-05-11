#!/usr/bin/env bash
# Pull latest from upstream, apply our fork's patches on top, validate via
# validate-build.sh, and push to kanafm/main when green. Optionally chains
# into publish-release.sh to upload a DMG to GitHub Releases.
#
# Run this manually from the repo root once per day (or before each push).
# Designed to avoid the cost of a GitHub Actions macOS runner while keeping
# the same safety net.
#
# Usage:
#   ./nix-build/scripts/sync-and-validate.sh              # sync, validate, push
#   ./nix-build/scripts/sync-and-validate.sh --dry-run    # sync, validate, skip push
#   ./nix-build/scripts/sync-and-validate.sh --release    # sync, validate, push, DMG upload
#
# Exit codes:
#   0   green, pushed (or pushed nothing if no diff)
#   1   pre-flight failed (dirty tree, missing tooling)
#   2   rebase conflict or kanafm/main divergence
#   3   swift build failed
#   4   bundle assembly or codesign failed
#   5   stale /nix/store dylib reference in cmux binary
#   6   launch smoke test failed
#   7   build-host path leaked into binary

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

DRY_RUN=0
DO_RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --release|-r) DO_RELEASE=1 ;;
        *) echo "warn: unknown arg: $arg" >&2 ;;
    esac
done

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

# Reconcile local with kanafm/main first (in case it was advanced externally,
# e.g. via the GitHub UI "Sync fork" button). Three cases:
#   - kanafm/main matches local       : nothing to do
#   - kanafm/main is ahead of local   : fast-forward local to kanafm/main
#   - kanafm/main has diverged        : bail; user must resolve manually
if git -C vendor/bonsplit show-ref --verify --quiet refs/remotes/kanafm/main; then
    BONSPLIT_FORK_SHA="$(git -C vendor/bonsplit rev-parse kanafm/main)"
    if [[ "$BONSPLIT_FORK_SHA" != "$BONSPLIT_START_SHA" ]]; then
        if git -C vendor/bonsplit merge-base --is-ancestor "$BONSPLIT_START_SHA" "$BONSPLIT_FORK_SHA"; then
            log "bonsplit kanafm/main advanced; fast-forwarding local to $BONSPLIT_FORK_SHA"
            git -C vendor/bonsplit merge --ff-only kanafm/main
        elif git -C vendor/bonsplit merge-base --is-ancestor "$BONSPLIT_FORK_SHA" "$BONSPLIT_START_SHA"; then
            echo "    local bonsplit is ahead of kanafm/main; nothing to fast-forward"
        else
            fail "bonsplit local main and kanafm/main have diverged. Resolve manually:"
            echo "    local      : $BONSPLIT_START_SHA"
            echo "    kanafm/main: $BONSPLIT_FORK_SHA"
            exit 2
        fi
    fi
fi

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
fi

# -------------------- Phase 3: cmux sync --------------------
log "Syncing cmux"

git fetch --quiet origin
git fetch --quiet kanafm 2>/dev/null || warn "kanafm remote not configured on cmux; skipping that fetch"

CMUX_UPSTREAM_BEFORE="$(git rev-parse origin/main)"
echo "    upstream main: $CMUX_UPSTREAM_BEFORE"

# Same reconciliation logic as bonsplit: fast-forward from kanafm/main if it
# advanced externally; bail on divergence.
if git show-ref --verify --quiet refs/remotes/kanafm/main; then
    CMUX_FORK_SHA="$(git rev-parse kanafm/main)"
    if [[ "$CMUX_FORK_SHA" != "$CMUX_START_SHA" ]]; then
        if git merge-base --is-ancestor "$CMUX_START_SHA" "$CMUX_FORK_SHA"; then
            log "cmux kanafm/main advanced; fast-forwarding local to $CMUX_FORK_SHA"
            git merge --ff-only kanafm/main
        elif git merge-base --is-ancestor "$CMUX_FORK_SHA" "$CMUX_START_SHA"; then
            echo "    local cmux is ahead of kanafm/main; nothing to fast-forward"
        else
            fail "cmux local main and kanafm/main have diverged. Resolve manually:"
            echo "    local      : $CMUX_START_SHA"
            echo "    kanafm/main: $CMUX_FORK_SHA"
            git -C vendor/bonsplit checkout "$BONSPLIT_START_SHA"
            exit 2
        fi
    fi
fi

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
fi

# If bonsplit advanced, the parent repo now has a submodule pointer diff in
# its working tree. Commit it before validating so the build runs against
# the final intended history (and so validate-build's clean-tree pre-flight
# passes).
if [[ -n "$(git status --porcelain --untracked-files=no vendor/bonsplit)" ]]; then
    log "Bumping bonsplit submodule pointer in cmux"
    git add vendor/bonsplit
    git -c user.name=kanafm -c user.email=kanafm@users.noreply.github.com \
        commit -m "chore: bump bonsplit submodule pointer after upstream rebase"
fi

# Compute push-needed by comparing local HEAD to kanafm/main, not by
# checking whether the rebase moved HEAD. This covers the case where the
# user made a local commit but upstream had nothing new: rebase is a no-op,
# but local is still ahead of kanafm/main and needs to be pushed.
BONSPLIT_PUSH_NEEDED=0
if git -C vendor/bonsplit show-ref --verify --quiet refs/remotes/kanafm/main \
   && [[ "$(git -C vendor/bonsplit rev-parse HEAD)" != "$(git -C vendor/bonsplit rev-parse kanafm/main)" ]]; then
    BONSPLIT_PUSH_NEEDED=1
fi
CMUX_PUSH_NEEDED=0
if git show-ref --verify --quiet refs/remotes/kanafm/main \
   && [[ "$(git rev-parse HEAD)" != "$(git rev-parse kanafm/main)" ]]; then
    CMUX_PUSH_NEEDED=1
fi

# -------------------- Phase 4: validate --------------------
"$SCRIPT_DIR/validate-build.sh"

# -------------------- Phase 5: push --------------------
echo
echo "Cmux:     $CMUX_START_SHA -> $(git rev-parse HEAD)"
echo "Bonsplit: $BONSPLIT_START_SHA -> $(git -C vendor/bonsplit rev-parse HEAD)"
echo

# Push bonsplit BEFORE cmux. cmux's submodule pointer references a bonsplit
# SHA, so pushing cmux first leaves a window where the pointer references a
# SHA not yet present on the bonsplit remote.
if [[ "$BONSPLIT_PUSH_NEEDED" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Would push: git -C vendor/bonsplit push --force-with-lease kanafm main"
    else
        log "Pushing vendor/bonsplit to kanafm/main"
        git -C vendor/bonsplit push --force-with-lease kanafm main
    fi
fi

if [[ "$CMUX_PUSH_NEEDED" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Would push: git push --force-with-lease kanafm main"
    else
        log "Pushing cmux to kanafm/main"
        git push --force-with-lease kanafm main
    fi
elif [[ "$BONSPLIT_PUSH_NEEDED" -eq 0 ]]; then
    echo "No changes to push to kanafm/main."
fi

# -------------------- Phase 6: optional release --------------------
if [[ "$DO_RELEASE" -eq 1 ]]; then
    log "Publishing DMG to kanafm/cmux-next Releases"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        "$SCRIPT_DIR/publish-release.sh" --dry-run
    else
        "$SCRIPT_DIR/publish-release.sh"
    fi
fi

exit 0
