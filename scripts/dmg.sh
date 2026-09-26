#!/usr/bin/env bash
# Packs build/Tetodoro.app into build/Tetodoro-<version>.dmg, with an
# Applications shortcut to drag onto. Run scripts/bundle.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Tetodoro.app
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
out="build/Tetodoro-$version.dmg"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

hdiutil create -quiet -volname Tetodoro -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"
echo "$out"
