#!/usr/bin/env bash
# Renders the windows app icon (windows/Drill/Assets/drill.ico) from
# docs/icon.png. Run after changing the icon art. Needs python3 with Pillow.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/make-windows-icon.py
