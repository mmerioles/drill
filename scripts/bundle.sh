#!/usr/bin/env bash
# Builds build/Tetodoro.app from the SwiftPM package (release, ad-hoc signed).
#   scripts/bundle.sh          build
#   scripts/bundle.sh --open   build and launch
# Env: VERSION=1.2.3 stamps the version, BUILD_NUMBER sets the build,
#      UNIVERSAL=1 builds for both Apple Silicon and Intel.
set -euo pipefail
cd "$(dirname "$0")/.."

args=(-c release)
[[ "${UNIVERSAL:-}" == 1 ]] && args+=(--arch arm64 --arch x86_64)

swift build "${args[@]}" --product Tetodoro
bin="$(swift build "${args[@]}" --show-bin-path)/Tetodoro"

app=build/Tetodoro.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Tetodoro"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

plist="$app/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"

codesign --force --sign - "$app" >/dev/null

echo "built $app"
[[ "${1:-}" == "--open" ]] && open "$app"
exit 0
