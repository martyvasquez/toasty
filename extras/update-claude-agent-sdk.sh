#!/bin/bash
# mostty: update the vendored Claude Agent SDK used by native Claude tabs.
# Usage: extras/update-claude-agent-sdk.sh [version]   (default: latest)
set -euo pipefail
version="${1:-latest}"
dest="$(cd "$(dirname "$0")/.." && pwd)/macos/Sources/Features/Claude/Bridge"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && npm pack --silent "@anthropic-ai/claude-agent-sdk@$version" >/dev/null && tar xzf ./*.tgz)
v="$(node -p "require('$tmp/package/package.json').version")"
cc="$(node -p "require('$tmp/package/manifest.json').version" 2>/dev/null || echo '?')"
cp "$tmp/package/sdk.mjs" "$dest/claude-agent-sdk.mjs"
cp "$tmp/package/LICENSE.md" "$dest/claude-agent-sdk-LICENSE.md"
printf '@anthropic-ai/claude-agent-sdk %s (sdk.mjs, built for Claude Code %s), vendored unmodified. Update with extras/update-claude-agent-sdk.sh\n' "$v" "$cc" > "$dest/claude-agent-sdk-VERSION.txt"
echo "Vendored claude-agent-sdk $v (Claude Code $cc)"
