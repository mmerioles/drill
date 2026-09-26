#!/usr/bin/env bash
# Builds build/Tetodoro.app from the SwiftPM package (release, ad-hoc signed).
#   scripts/bundle.sh          build
#   scripts/bundle.sh --open   build and launch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Tetodoro
bin="$(swift build -c release --show-bin-path)/Tetodoro"

app=build/Tetodoro.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Tetodoro"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app" >/dev/null

echo "built $app"
[[ "${1:-}" == "--open" ]] && open "$app"
exit 0
