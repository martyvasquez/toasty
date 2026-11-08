#!/bin/zsh
# Builds a Developer ID–signed Release of Toasty and zips it. No updater:
# the zip is the release.
#
#   scripts/release.sh                       # build + sign + verify + zip
#   scripts/release.sh --notarize            # ...then notarize and staple (zip is re-made)
#   scripts/release.sh --notarize --install  # ...and copy to /Applications
#
# Notarization credentials, either:
#   • App Store Connect API key:
#       export TOASTY_ASC_KEY_ID=…  TOASTY_ASC_ISSUER_ID=…
#     with the key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   • or a notarytool keychain profile (default "toasty-notary"):
#       xcrun notarytool store-credentials toasty-notary
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${TOASTY_NOTARY_PROFILE:-toasty-notary}"
OUT=build/release
ARCHIVE="$OUT/Toasty.xcarchive"
APP="$OUT/export/Toasty.app"
ZIP="$OUT/Toasty.zip"
NOTARIZE=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

KEY_ID="${TOASTY_ASC_KEY_ID:-}"; ISSUER_ID="${TOASTY_ASC_ISSUER_ID:-}"
NOTARY_AUTH=(--keychain-profile "$PROFILE")
if [[ -n "$KEY_ID" && -n "$ISSUER_ID" ]]; then
  KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
  [[ -f "$KEY_PATH" ]] || { echo "API key not found at $KEY_PATH"; exit 1; }
  NOTARY_AUTH=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID")
fi

[[ -d Vendor/GhosttyVt.xcframework ]] || { echo "▸ Building libghostty-vt…"; scripts/build-ghostty-vt.sh; }
[[ -d Vendor/CTranscribe.xcframework ]] || { echo "▸ Building transcribe.cpp…"; scripts/build-transcribe.sh; }
echo "▸ Checking speech models…"; scripts/fetch-speech-models.sh

rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate -q

echo "▸ Archiving (Release)…"
xcodebuild -project Toasty.xcodeproj -scheme Toasty -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive -quiet

echo "▸ Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$OUT/export" -quiet

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier|Runtime"

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
ditto -c -k --keepParent "$APP" "$ZIP"

if (( INSTALL )); then
  echo "▸ Installing to /Applications…"
  osascript -e 'tell application id "com.martyvasquez.toasty" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Toasty.app
  ditto "$APP" /Applications/Toasty.app
  echo "Installed /Applications/Toasty.app"
fi
echo "✓ Done: $ZIP"
