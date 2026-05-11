#!/usr/bin/env bash
# Package cmux.app as a DMG and upload it to kanafm/cmux-next Releases.
# Assumes cmux.app already exists at the repo root, was assembled with
# CMUX_SCRUB=1, and passed validate-build.sh. Run sync-and-validate.sh
# first to produce a fresh signed bundle.
#
# Usage:
#   ./nix-build/scripts/publish-release.sh                  # auto tag: nix-YYYY.MM.DD-<sha>
#   ./nix-build/scripts/publish-release.sh --tag <tag>      # explicit tag
#   ./nix-build/scripts/publish-release.sh --dry-run        # build DMG, skip upload
#
# Exit codes:
#   0   uploaded (or dry-run completed)
#   1   cmux.app missing or stale
#   2   binary still contains build-host paths (scrub regression)
#   3   DMG creation failed
#   4   gh release upload failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m   FAIL: %s\033[0m\n' "$*" >&2; }

APP="$REPO_ROOT/cmux.app"
DMG="$REPO_ROOT/cmux-macos.dmg"
REPO="kanafm/cmux-next"

DRY_RUN=0
TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1 ;;
        --tag) TAG="${2:-}"; shift ;;
        *) echo "warn: unknown arg: $1" >&2 ;;
    esac
    shift
done

if [[ ! -d "$APP" ]]; then
    fail "$APP missing. Run sync-and-validate.sh or validate-build.sh first."
    exit 1
fi

# Pre-flight: verify scrub actually held. validate-build.sh already checks
# this, but publish is a second gate before bytes go out to a public mirror.
log "Verifying scrub on cmux.app"
LEAK="$(/usr/bin/strings "$APP/Contents/MacOS/cmux" \
    | grep -E '/Users/[a-zA-Z][^/$\{]*/' \
    | grep -v '/Users/Shared/' \
    | head -5 || true)"
if [[ -n "$LEAK" ]]; then
    fail "cmux binary contains build-host paths. Aborting upload:"
    echo "$LEAK" | sed 's/^/    /'
    exit 2
fi

if [[ -z "$TAG" ]]; then
    TAG="nix-$(date +%Y.%m.%d)-$(git rev-parse --short HEAD)"
fi
log "Release tag: $TAG"

# Normalize filesystem attributes inside the bundle. Strip xattrs (quarantine,
# Spotlight metadata) and reset ownership to current user. The DMG embeds
# UID on file entries; UID alone is not personally identifying (commonly 501)
# but the xattr strip removes incidental metadata leaks.
log "Normalizing bundle attributes"
/usr/bin/xattr -cr "$APP"
/bin/chmod -R u+rwX,go+rX,go-w "$APP"

# Build compressed DMG (UDZO = zlib-compressed read-only image).
log "Creating DMG"
rm -f "$DMG"
if ! /usr/bin/hdiutil create \
    -srcfolder "$APP" \
    -volname "cmux" \
    -format UDZO \
    -fs HFS+ \
    -ov \
    "$DMG" >/dev/null; then
    fail "hdiutil create failed"
    exit 3
fi

SIZE="$(du -h "$DMG" | cut -f1)"
SHA256="$(/usr/bin/shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    DMG    : $DMG"
echo "    size   : $SIZE"
echo "    sha256 : $SHA256"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "Dry run: skipping upload."
    echo "Would tag : $TAG"
    echo "Would push: refs/tags/$TAG to kanafm"
    echo "Would run : gh release create $TAG --repo $REPO --prerelease"
    exit 0
fi

# Tag the current HEAD and push the tag to the fork remote.
TAG_BODY="Automated nix-build release. Scrub: enabled (strip -Sx, no CMUXCommit). SHA256: $SHA256"
log "Tagging $TAG and pushing to kanafm"
git tag -af "$TAG" -m "$TAG_BODY" HEAD
git push --force kanafm "refs/tags/$TAG"

# Create or update the Release.
log "Uploading DMG to $REPO Releases"
if /usr/bin/env gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    if ! /usr/bin/env gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber; then
        fail "gh release upload failed"
        exit 4
    fi
else
    if ! /usr/bin/env gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "$TAG" \
        --notes "$TAG_BODY" \
        --prerelease; then
        fail "gh release create failed"
        exit 4
    fi
fi

echo
echo "Released: https://github.com/$REPO/releases/tag/$TAG"
exit 0
