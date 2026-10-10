#!/usr/bin/env bash
# Gate a release tag, and optionally write its notes.
#
#   scripts/check-release-version.sh <tag> [--notes <file>]
#
# Each published artifact has its own version and tag, and the tag names it:
#   decdn-node-X.Y.Z   the decdn-node Helm chart (charts/decdn-node/Chart.yaml)
#   collection-vX.Y.Z  the decdn.node collection (ansible/galaxy/galaxy.yml)
# The artifact's version must equal X.Y.Z and its changelog must carry a released
# `## [X.Y.Z]` heading (not "unreleased"). The other artifact is not looked at. With
# --notes, that changelog section is written to <file> as the GitHub Release body.
set -euo pipefail

usage() { echo "usage: $0 decdn-node-X.Y.Z|collection-vX.Y.Z [--notes <file>]" >&2; exit 2; }
tag="" notes=""
case $# in
  1) tag="$1" ;;
  3) [[ "$2" == "--notes" && -n "$3" ]] || usage; tag="$1" notes="$3" ;;
  *) usage ;;
esac

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$tag" =~ ^decdn-node-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  manifest="charts/decdn-node/Chart.yaml"
  changelog="charts/decdn-node/CHANGELOG.md"
  title="Helm chart \`decdn-node\`"
elif [[ "$tag" =~ ^collection-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  manifest="ansible/galaxy/galaxy.yml"
  changelog="ansible/galaxy/CHANGELOG.md"
  title="Ansible collection \`decdn.node\`"
else
  echo "tag '$tag' is neither decdn-node-X.Y.Z (chart) nor collection-vX.Y.Z (collection)" >&2
  exit 1
fi
version="${BASH_REMATCH[1]}"

fail=0
current="$(sed -nE 's/^version:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$repo/$manifest")"
[[ "$current" == "$version" ]] || { echo "$manifest version is $current, tag is $tag" >&2; fail=1; }

# Print the body of the `## [X.Y.Z]` section, or fail if it is missing, not dated, or
# has no entries. The version is matched literally (awk index, not a regex), and the
# body ends at the next `## [` heading or at the file's trailing comment or link
# reference definitions, which belong to no section.
section() {
  local file="$1" heading body
  heading="$(awk -v v="## [$version]" 'index($0, v) == 1' "$file")"
  if [[ -z "$heading" ]]; then
    echo "$file has no '## [$version]' section" >&2; return 1
  fi
  if grep -qi 'unreleased' <<<"$heading"; then
    echo "$file still marks $version as unreleased: $heading" >&2; return 1
  fi
  if ! [[ "$heading" =~ ^"## [$version] — "[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "$file: '$heading' is not one '## [$version] — YYYY-MM-DD' heading" >&2; return 1
  fi
  body="$(awk -v v="## [$version]" '
    index($0, v) == 1 {on=1; next}
    on && (/^## \[/ || /^<!--/ || /^\[[^]]+\]: /) {exit}
    on' "$file")"
  if ! grep -q '^- ' <<<"$body"; then
    echo "$file: the '## [$version]' section has no '- ' entries" >&2; return 1
  fi
  printf '%s\n' "$body"
}
body="$(section "$repo/$changelog")" || fail=1
((fail == 0)) || exit 1

if [[ -n "$notes" ]]; then
  {
    echo "## $title $version"
    echo "$body"
  } > "$notes"
fi
echo "release $tag: $manifest is $version"
