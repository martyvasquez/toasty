#!/bin/zsh
# Builds libghostty-vt (Ghostty's embeddable VT library) as an XCFramework
# from a pinned Ghostty commit and vendors it into Vendor/.
#
#   scripts/build-ghostty-vt.sh [commit]
#
# The commit defaults to the one recorded in Vendor/GHOSTTY_VT_VERSION.
# Sources come from a private clone in ~/Library/Caches/Toasty/ghostty
# (seeded from GitHub), never from another checkout. Needs Zig 0.17.
set -euo pipefail

ROOT=${0:A:h:h}
VERSION_FILE="$ROOT/Vendor/GHOSTTY_VT_VERSION"
COMMIT=${1:-$(awk '/^commit/ {print $2}' "$VERSION_FILE" 2>/dev/null || true)}
[[ -n "$COMMIT" ]] || { echo "usage: $0 <ghostty commit>" >&2; exit 1; }

SRC="$HOME/Library/Caches/Toasty/ghostty"
if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "${SRC:h}"
  git clone --filter=blob:none --no-checkout https://github.com/ghostty-org/ghostty.git "$SRC"
fi
cd "$SRC"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch --filter=blob:none origin "$COMMIT"
git -c advice.detachedHead=false checkout -q --force "$COMMIT"

echo "Building libghostty-vt at $COMMIT…"
rm -rf zig-out/lib/ghostty-vt.xcframework
zig build -Demit-lib-vt -Doptimize=ReleaseFast

rm -rf "$ROOT/Vendor/GhosttyVt.xcframework"
cp -R zig-out/lib/ghostty-vt.xcframework "$ROOT/Vendor/GhosttyVt.xcframework"
{
  echo "commit $COMMIT"
  echo "date $(git log -1 --format=%cI "$COMMIT")"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) with zig $(zig version)"
} > "$VERSION_FILE"
echo "Vendored $ROOT/Vendor/GhosttyVt.xcframework"
