#!/usr/bin/env bash
# Packs build/Drill.app into build/drill_<version>.dmg, with an
# Applications shortcut to drag onto and the app icon as the volume icon.
# Run scripts/bundle.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Drill.app
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
out="build/drill_$version.dmg"

tmp="$(mktemp -d)"
mnt=""
trap '[[ -n "$mnt" ]] && hdiutil detach -quiet -force "$mnt"; rm -rf "$tmp"' EXIT

stage="$tmp/stage"
mkdir "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

# Build writable, mount it to set the volume icon, then compress.
rw="$tmp/rw.dmg"
hdiutil create -quiet -volname Drill -srcfolder "$stage" -fs HFS+ -format UDRW "$rw"
mnt="$tmp/mnt"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mnt" "$rw"
cp Support/AppIcon.icns "$mnt/.VolumeIcon.icns"
# FinderInfo with the kHasCustomIcon flag, so Finder uses .VolumeIcon.icns.
xattr -wx com.apple.FinderInfo \
    0000000000000000040000000000000000000000000000000000000000000000 "$mnt"
hdiutil detach -quiet "$mnt"
mnt=""

hdiutil convert -quiet "$rw" -format UDZO -ov -o "$out"
echo "$out"
