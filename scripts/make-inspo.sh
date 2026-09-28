#!/usr/bin/env bash
# Writes the inspo video list, Support/inspo.json, out for both apps:
#   Sources/TetodoroApp/InspoVideos.swift and web/static/inspo-videos.js.
# Edit the json, then run this. Order is numbering: add new videos at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json

videos = json.load(open("Support/inspo.json"))
header = "Generated from Support/inspo.json by scripts/make-inspo.sh. Don't edit."

def swift(s):
    return json.dumps(s, ensure_ascii=False)

rows = "\n".join(
    f"        .init(number: {n}, youtube: {swift(v['id'])}, daily: {str(v['daily']).lower()},\n"
    f"              title: {swift(v['title'])}, japanese: {swift(v['japanese'])}),"
    for n, v in enumerate(videos, 1))
with open("Sources/TetodoroApp/InspoVideos.swift", "w") as f:
    f.write(f"// {header}\n\nextension Inspo {{\n    static let videos: [Video] = [\n{rows}\n    ]\n}}\n")

rows = "\n".join(
    f"  [{swift(v['id'])}, {str(v['daily']).lower()}, {swift(v['title'])}, {swift(v['japanese'])}],"
    for v in videos)
with open("web/static/inspo-videos.js", "w") as f:
    f.write(f"// {header}\n// [youtube id, in the daily rotation, english, original title]\n\n"
            f"export const ROWS = [\n{rows}\n];\n")
print(f"wrote {len(videos)} videos")
PY
