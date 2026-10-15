#!/usr/bin/env bash
# Generates the inspo list for mac, web and android from shared/inspo.json
# (windows embeds the json). Run after editing the json.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json

videos = json.load(open("shared/inspo.json"))
header = "Generated from shared/inspo.json by scripts/make-inspo.sh. Don't edit."

def swift(s):
    return json.dumps(s, ensure_ascii=False)

rows = "\n".join(
    f"        .init(number: {n}, youtube: {swift(v['id'])}, daily: {str(v['daily']).lower()},\n"
    f"              title: {swift(v['title'])}, japanese: {swift(v['japanese'])}),"
    for n, v in enumerate(videos, 1))
with open("mac/Sources/DrillApp/InspoVideos.swift", "w") as f:
    f.write(f"// {header}\n\nextension Inspo {{\n    static let videos: [Video] = [\n{rows}\n    ]\n}}\n")

rows = "\n".join(
    f"  [{swift(v['id'])}, {str(v['daily']).lower()}, {swift(v['title'])}, {swift(v['japanese'])}],"
    for v in videos)
with open("web/static/inspo-videos.js", "w") as f:
    f.write(f"// {header}\n// [youtube id, in the daily rotation, english, original title]\n\n"
            f"export const ROWS = [\n{rows}\n];\n")
def kotlin(s):
    return swift(s).replace("$", "\\$")

rows = "\n".join(
    f"    Inspo.Video({n}, {kotlin(v['id'])}, {str(v['daily']).lower()}, {kotlin(v['title'])}, {kotlin(v['japanese'])}),"
    for n, v in enumerate(videos, 1))
with open("android/app/src/main/java/io/github/mmerioles/drill/core/InspoVideos.kt", "w") as f:
    f.write(f"// {header}\n// Inspo.Video(number, youtube id, in the daily rotation, english, original title)\n\n"
            f"package io.github.mmerioles.drill.core\n\ninternal val INSPO_VIDEOS = listOf(\n{rows}\n)\n")
print(f"wrote {len(videos)} videos")
PY
