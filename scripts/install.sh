#!/usr/bin/env bash
# Builds Tetodoro and installs it to /Applications (or ~/Applications if
# /Applications isn't writable), then launches it. Safe to re-run to update;
# your sessions live in ~/Library/Application Support/Tetodoro and are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null; then
    echo "swift not found. install Apple's command line tools first:  xcode-select --install" >&2
    exit 1
fi

scripts/bundle.sh

dest=/Applications
[[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

osascript -e 'quit app "Tetodoro"' >/dev/null 2>&1 || true
pkill -x Tetodoro 2>/dev/null || true
rm -rf "$dest/Tetodoro.app"
cp -R build/Tetodoro.app "$dest/"
echo "installed $dest/Tetodoro.app"
open "$dest/Tetodoro.app"
