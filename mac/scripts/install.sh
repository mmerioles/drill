#!/usr/bin/env bash
# Builds Drill and installs it to /Applications (or ~/Applications if
# /Applications isn't writable), then launches it. Safe to re-run to update;
# your sessions live in ~/Library/Application Support/Drill and are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null; then
    echo "swift not found. install Apple's command line tools first:  xcode-select --install" >&2
    exit 1
fi

scripts/bundle.sh

dest=/Applications
[[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

osascript -e 'quit app "Drill"' >/dev/null 2>&1 || true
pkill -x Drill 2>/dev/null || true
rm -rf "$dest/Drill.app"
cp -R build/Drill.app "$dest/"
echo "installed $dest/Drill.app"
open "$dest/Drill.app"
