#!/bin/zsh
# Builds transcribe.cpp (Hex's fork, the speech engine for dictation) as an
# XCFramework from a pinned commit and vendors it into Vendor/.
#
#   scripts/build-transcribe.sh [commit]
#
# The commit defaults to the one recorded in Vendor/TRANSCRIBE_VERSION, else
# the pinned one below. Sources come from a private clone in
# ~/Library/Caches/Toasty/transcribe.cpp. Needs cmake (Homebrew).
#
# The framework is DYNAMIC (module CTranscribe, Metal library embedded) by the
# engine's own design — a static ggml-metal makes apps crash at launch without
# -ObjC/-force_load — so project.yml embeds and signs it (unlike GhosttyVt).
set -euo pipefail

PINNED=2778ae4bf5ca5f394d129a39467f4ad9552dc34f
ROOT=${0:A:h:h}
VERSION_FILE="$ROOT/Vendor/TRANSCRIBE_VERSION"
COMMIT=${1:-$(awk '/^commit/ {print $2}' "$VERSION_FILE" 2>/dev/null || true)}
COMMIT=${COMMIT:-$PINNED}

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }

SRC="$HOME/Library/Caches/Toasty/transcribe.cpp"
if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "${SRC:h}"
  git clone --filter=blob:none --no-checkout https://github.com/anomalyco/transcribe.cpp.git "$SRC"
fi
cd "$SRC"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch --filter=blob:none origin "$COMMIT"
git -c advice.detachedHead=false checkout -q --force "$COMMIT"
git clean -qfdx -e tmp/

echo "Building transcribe.cpp at $COMMIT…"
TRANSCRIBE_XCFRAMEWORK_SLICES=macos MACOS_MIN_OS_VERSION=26.0 scripts/ci/build_xcframework.sh

rm -rf "$ROOT/Vendor/CTranscribe.xcframework"
cp -R bindings/swift/build-apple/TranscribeCpp.xcframework "$ROOT/Vendor/CTranscribe.xcframework"
{
  echo "commit $COMMIT"
  echo "date $(git log -1 --format=%cI "$COMMIT")"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(cmake --version | head -1), $(xcrun clang --version | head -1)"
} > "$VERSION_FILE"
echo "Vendored $ROOT/Vendor/CTranscribe.xcframework"
