#!/bin/zsh
# Downloads the dictation models (pinned revision + sha256) into
# Toasty/Resources/SpeechModels/, which is bundled into the app.
# Build time only: Toasty never downloads anything at runtime.
#
#   scripts/fetch-speech-models.sh
#
# Already-present files with the right checksum are kept.
set -euo pipefail

ROOT=${0:A:h:h}
DEST="$ROOT/Toasty/Resources/SpeechModels"
mkdir -p "$DEST"

# repo  revision  filename  bytes  sha256
MODELS=(
  "handy-computer/parakeet-tdt-0.6b-v2-gguf 07cee0616125a08ef619729bb47f40ef747e4bc4 parakeet-tdt-0.6b-v2-Q8_0.gguf 729574912 f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa"
  "handy-computer/silero-vad-v6.2-gguf a9b2d61c20ae4ddf3644edb34969e8185a485448 silero-vad-v6.2-F32.gguf 1241056 0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6"
)

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

for entry in $MODELS; do
  read -r repo rev file bytes sum <<< "$entry"
  out="$DEST/$file"
  if [[ -f "$out" && "$(sha "$out")" == "$sum" ]]; then
    echo "✓ $file"
    continue
  fi
  echo "▸ Downloading $file ($repo @ ${rev:0:8})…"
  tmp="$out.partial"
  curl -fL --retry 3 --progress-bar -o "$tmp" "https://huggingface.co/$repo/resolve/$rev/$file"
  size=$(stat -f %z "$tmp")
  got=$(sha "$tmp")
  if [[ "$size" != "$bytes" || "$got" != "$sum" ]]; then
    rm -f "$tmp"
    echo "✗ $file: checksum mismatch (got $size bytes, sha256 $got; expected $bytes, $sum)" >&2
    exit 1
  fi
  mv "$tmp" "$out"
  echo "✓ $file"
done
