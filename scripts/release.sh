#!/bin/zsh
# Builds a Developer ID–signed Release of Toasty and zips it.
#
#   scripts/release.sh                       # build + sign + verify + zip
#   scripts/release.sh --notarize            # ...then notarize and staple (zip is re-made)
#   scripts/release.sh --notarize --install  # ...and copy to /Applications
#   scripts/release.sh --publish             # notarize, then publish it as an update
#
# The version is <MARKETING_VERSION in project.yml>.<build>, where <build> is
# the commit count (always increasing on main): 0.1.431. TOASTY_BUILD
# overrides the build number (local test builds only).
#
# --publish makes GitHub release v<version> holding the zip, delta updates
# from the last few releases, and appcast.xml: the feed installed copies of
# Toasty read (Info.plist SUFeedURL; Toasty/App/Updater.swift). The feed is
# signed with the "toasty" EdDSA key in your login keychain, made once with
# Sparkle's `generate_keys --account toasty`; its public half is
# SUPublicEDKey in project.yml. It needs a clean tree at origin/main.
# Every push to main runs it (scripts/publish-on-push.sh).
#
# Notarization credentials, either:
#   • App Store Connect API key:
#       export TOASTY_ASC_KEY_ID=…  TOASTY_ASC_ISSUER_ID=…
#     with the key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   • or a notarytool keychain profile (default "toasty-notary"):
#       xcrun notarytool store-credentials toasty-notary
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="martyvasquez/toasty"
KEY_ACCOUNT="toasty"
# GitHub releases kept; older ones (and their tags) are deleted on publish.
# The feed only ever points at the newest few.
KEEP_RELEASES=5
PROFILE="${TOASTY_NOTARY_PROFILE:-toasty-notary}"
OUT=build/release
ARCHIVE="$OUT/Toasty.xcarchive"
APP="$OUT/export/Toasty.app"
ZIP="$OUT/Toasty.zip"
# Kept between releases: the last few zips (deltas are made against them)
# and the feed.
UPDATES=build/updates
# Swift packages resolve here, so Sparkle's tools have a known path.
PACKAGES=build/SourcePackages
SPARKLE_BIN="$PACKAGES/artifacts/sparkle/Sparkle/bin"

NOTARIZE=0; INSTALL=0; PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --install) INSTALL=1 ;;
    --publish) PUBLISH=1; NOTARIZE=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

BUILD="${TOASTY_BUILD:-$(git rev-list --count HEAD)}"
BASE="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
[[ "$BASE" =~ '^[0-9]+\.[0-9]+$' ]] || { echo "MARKETING_VERSION in project.yml should be x.y (is \"$BASE\")"; exit 1; }
VERSION="$BASE.$BUILD"
TAG="v$VERSION"
COMMIT="$(git rev-parse HEAD)"

KEY_ID="${TOASTY_ASC_KEY_ID:-}"; ISSUER_ID="${TOASTY_ASC_ISSUER_ID:-}"
NOTARY_AUTH=(--keychain-profile "$PROFILE")
if [[ -n "$KEY_ID" && -n "$ISSUER_ID" ]]; then
  KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
  [[ -f "$KEY_PATH" ]] || { echo "API key not found at $KEY_PATH"; exit 1; }
  NOTARY_AUTH=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID")
fi

# Everything that can stop a release is checked before the long build.
if (( NOTARIZE )); then
  xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || {
    echo "No notarization credentials. Run once:  xcrun notarytool store-credentials $PROFILE"; exit 1; }
fi
if (( PUBLISH )); then
  [[ -z "${TOASTY_BUILD:-}" ]] || { echo "TOASTY_BUILD is for local test builds; not with --publish."; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean; commit first."; exit 1; }
  git fetch -q origin main
  [[ "$COMMIT" == "$(git rev-parse origin/main)" ]] || { echo "HEAD is not origin/main; push (or pull) first."; exit 1; }
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then echo "Release $TAG already exists."; exit 1; fi
fi

[[ -d Vendor/GhosttyVt.xcframework ]] || { echo "▸ Building libghostty-vt…"; scripts/build-ghostty-vt.sh; }
[[ -d Vendor/CTranscribe.xcframework ]] || { echo "▸ Building transcribe.cpp…"; scripts/build-transcribe.sh; }
echo "▸ Checking speech models…"; scripts/fetch-speech-models.sh

rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate -q

echo "▸ Archiving Toasty $VERSION (Release)…"
xcodebuild -project Toasty.xcodeproj -scheme Toasty -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive -quiet

echo "▸ Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$OUT/export" -quiet

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier|Runtime"

if (( NOTARIZE )); then
  echo "▸ Notarizing…"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
  echo "▸ Stapling…"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "▸ Zipping…"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if (( PUBLISH )); then
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Sparkle's tools not found in $SPARKLE_BIN"; exit 1; }
  mkdir -p "$UPDATES"
  cp -c "$ZIP" "$UPDATES/Toasty-$VERSION.zip" 2>/dev/null || cp "$ZIP" "$UPDATES/Toasty-$VERSION.zip"

  # What changed: the commits since the last release.
  LAST="$(gh release list --repo "$REPO" --limit 1 --exclude-drafts --json tagName --jq '.[0].tagName // empty')"
  SINCE=""
  if [[ -n "$LAST" ]]; then
    SINCE="$(gh release view "$LAST" --repo "$REPO" --json targetCommitish --jq .targetCommitish)"
    git cat-file -e "$SINCE^{commit}" 2>/dev/null && git merge-base --is-ancestor "$SINCE" HEAD || SINCE=""
  fi
  NOTES_MD="$OUT/notes.md"; NOTES_HTML="$UPDATES/Toasty-$VERSION.html"
  if [[ -n "$SINCE" ]]; then RANGE=("$SINCE..HEAD"); else RANGE=(-1 HEAD); fi
  git log --no-merges --format='- %s' "${RANGE[@]}" > "$NOTES_MD"
  { echo "<ul>"
    git log --no-merges --format='%s' "${RANGE[@]}" \
      | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<li>&</li>|'
    echo "</ul>"; } > "$NOTES_HTML"

  echo "▸ Writing the update feed…"
  "$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    --embed-release-notes \
    --maximum-versions 3 --maximum-deltas 3 \
    -o "$UPDATES/appcast.xml" "$UPDATES"
  # generate_appcast points every entry at this release; older entries'
  # files are in their own releases.
  sed -i '' -E \
    -e 's#/download/[^/"]*/Toasty-([0-9.]+)\.zip#/download/v\1/Toasty-\1.zip#g' \
    -e "s#/download/[^/\"]*/Toasty([0-9]+)-#/download/v$BASE.\\1/Toasty\\1-#g" "$UPDATES/appcast.xml"
  grep -q "sparkle:version>$BUILD<" "$UPDATES/appcast.xml" || { echo "The feed doesn't list build $BUILD"; exit 1; }
  grep -q 'sparkle:edSignature' "$UPDATES/appcast.xml" || { echo "The feed is missing its EdDSA signature"; exit 1; }
  # Zips the feed no longer lists are moved here; they're published already.
  rm -rf "$UPDATES/old_updates"

  echo "▸ Publishing $TAG…"
  # Deltas to this build from the releases before it (Toasty<build>-<from>.delta).
  DELTAS=("$UPDATES"/Toasty"$BUILD"-*.delta(N))
  gh release create "$TAG" "$UPDATES/Toasty-$VERSION.zip" "${DELTAS[@]}" "$UPDATES/appcast.xml" \
    --repo "$REPO" --title "Toasty $VERSION" --notes-file "$NOTES_MD" --target "$COMMIT"
  # Deltas to older builds are no use to anyone now.
  for delta in "$UPDATES"/*.delta(N); do
    (( ${DELTAS[(Ie)$delta]} )) || rm -f "$delta"
  done

  # Old releases: nothing points at them once they leave the feed.
  gh release list --repo "$REPO" --limit 200 --json tagName,createdAt \
      --jq 'sort_by(.createdAt) | reverse | .[].tagName' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -n +$((KEEP_RELEASES + 1)) \
    | while read -r old; do
        echo "  removing old release $old"
        gh release delete "$old" --repo "$REPO" --cleanup-tag --yes || true
      done
  echo "✓ Published https://github.com/$REPO/releases/tag/$TAG"
fi

if (( INSTALL )); then
  echo "▸ Installing to /Applications…"
  osascript -e 'tell application id "com.martyvasquez.toasty" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Toasty.app
  ditto "$APP" /Applications/Toasty.app
  echo "Installed /Applications/Toasty.app"
fi
echo "✓ Done: $ZIP"
