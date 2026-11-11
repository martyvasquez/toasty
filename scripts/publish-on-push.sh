#!/bin/zsh
# Publishes a Toasty update for a commit that was just pushed to main.
# Started in the background by scripts/hooks/pre-push; safe to run by hand:
#
#   scripts/publish-on-push.sh <commit>
#
# It builds in a checkout of its own (build/publish/src, a git worktree at
# the pushed commit), so work in progress here is never part of a release
# and editing during the build can't disturb it. Releases run one at a time:
# a push that arrives while one is building waits, and only the newest
# waiting push is released.
#
# Follow along:  tail -f build/publish/publish.log
# Turn off:      git config --unset core.hooksPath   (or push with --no-verify)
set -uo pipefail
# Started from a git hook: drop its git environment, and find Homebrew's tools.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMMIT="${1:?usage: publish-on-push.sh <commit>}"
DIR="$ROOT/build/publish"
SRC="$DIR/src"
mkdir -p "$DIR"

# One release at a time; a newer push replaces whatever is waiting.
echo "$COMMIT" > "$DIR/pending"
mkdir "$DIR/lock" 2>/dev/null || {
  if kill -0 "$(cat "$DIR/lock/pid" 2>/dev/null)" 2>/dev/null; then exit 0; fi
  # The run holding the lock died: take it over.
  rm -rf "$DIR/lock"; mkdir "$DIR/lock" || exit 0
}
echo $$ > "$DIR/lock/pid"
trap 'rm -rf "$DIR/lock"' EXIT

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

publish() {
  local commit="$1"
  echo; echo "━━ $(date '+%Y-%m-%d %H:%M:%S')  $(git log -1 --format='%h %s' "$commit")"

  # The hook runs before the push lands: wait for it, and stop if it didn't.
  local tries=0
  until [[ "$(git ls-remote origin refs/heads/main | cut -f1)" == "$commit" ]]; do
    (( ++tries > 30 )) && { echo "origin/main is not $commit (push failed, or a newer push landed); skipping."; return 0; }
    sleep 2
  done

  if [[ ! -d "$SRC" ]]; then
    git worktree prune
    git worktree add --detach "$SRC" "$commit" || return 1
  fi
  git -C "$SRC" checkout -q --detach "$commit" && git -C "$SRC" reset -q --hard "$commit" || return 1

  # What git doesn't hold (built frameworks, speech models), copied from
  # here as APFS clones: no time, no space.
  local item
  for item in Vendor/GhosttyVt.xcframework Vendor/CTranscribe.xcframework Vendor/TRANSCRIBE_VERSION; do
    [[ -e "$ROOT/$item" ]] || continue
    rm -rf "$SRC/$item"; cp -Rc "$ROOT/$item" "$SRC/$item"
  done
  mkdir -p "$SRC/Toasty/Resources/SpeechModels"
  for item in "$ROOT"/Toasty/Resources/SpeechModels/*.gguf(N); do
    [[ -e "$SRC/Toasty/Resources/SpeechModels/${item:t}" ]] || cp -c "$item" "$SRC/Toasty/Resources/SpeechModels/"
  done

  "$SRC/scripts/release.sh" --publish
}

while [[ -s "$DIR/pending" ]]; do
  commit="$(cat "$DIR/pending")"; : > "$DIR/pending"
  if publish "$commit" >> "$DIR/publish.log" 2>&1; then
    grep -q "✓ Published" <(tail -5 "$DIR/publish.log") && notify "Toasty update published" "$(git log -1 --format=%s "$commit")"
  else
    echo "✗ Release of $commit failed." >> "$DIR/publish.log"
    notify "Toasty update failed" "See build/publish/publish.log"
  fi
done
