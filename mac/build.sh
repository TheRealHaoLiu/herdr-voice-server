#!/bin/bash
# build.sh [destination]: compile HerdrVoice.app (default: ~/Applications). No login item is created.
# Build products go to a cache folder outside the repo. The keychain is never consulted: every
# dependency is public, so no stored GitHub login is needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$HOME/Applications}"
scratch="${HERDR_VOICE_BUILD:-$HOME/Library/Caches/herdr-voice-build}"
app="$dest/HerdrVoice.app"
swift build -c release --disable-keychain --package-path "$here" --scratch-path "$scratch"
tmp="$(mktemp -d)"
mkdir -p "$tmp/HerdrVoice.app/Contents/MacOS" "$tmp/HerdrVoice.app/Contents/Resources"
cp "$scratch/release/HerdrVoice" "$tmp/HerdrVoice.app/Contents/MacOS/HerdrVoice"
# Resource bundles the speech library needs at run time.
for b in "$scratch"/release/*.bundle; do [ -e "$b" ] && cp -R "$b" "$tmp/HerdrVoice.app/Contents/Resources/"; done
cp "$here/Info.plist" "$tmp/HerdrVoice.app/Contents/Info.plist"
codesign --force --deep --sign - "$tmp/HerdrVoice.app" 2>/dev/null
mkdir -p "$dest"
if [ -e "$app" ]; then mv "$app" "$HOME/.Trash/HerdrVoice-$(date +%s).app"; fi
mv "$tmp/HerdrVoice.app" "$app"
echo "Built $app"
