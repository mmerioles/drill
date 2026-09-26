#!/usr/bin/env bash
# Regenerates Support/AppIcon.icns from the IconMaker target.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swift run -c release IconMaker "$tmp/icon.png" >/dev/null

set_dir="$tmp/AppIcon.iconset"
mkdir "$set_dir"
for size in 16 32 128 256 512; do
    sips -z $size $size "$tmp/icon.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$tmp/icon.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Support/AppIcon.icns
cp "$tmp/icon.png" docs/icon.png
echo "wrote Support/AppIcon.icns"
