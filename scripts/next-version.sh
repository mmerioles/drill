#!/usr/bin/env bash
# Prints the next semantic version, read from commit messages since the last
# v* tag (conventional commits):
#   "feat!: …" or "BREAKING CHANGE" → major
#   "feat: …"                       → minor
#   anything else                   → patch
# Prints 0.1.0 when there are no tags yet, and nothing when HEAD is already tagged.
set -euo pipefail

last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -z "$last" ]]; then
    echo 0.1.0
    exit 0
fi
[[ -z "$(git rev-list "$last..HEAD")" ]] && exit 0

log="$(git log --format='%s%n%b' "$last..HEAD")"
IFS=. read -r major minor patch <<<"${last#v}"

if grep -qE '^[a-z]+(\(.+\))?!:|BREAKING CHANGE' <<<"$log"; then
    major=$((major + 1)); minor=0; patch=0
elif grep -qE '^feat(\(.+\))?:' <<<"$log"; then
    minor=$((minor + 1)); patch=0
else
    patch=$((patch + 1))
fi
echo "$major.$minor.$patch"
