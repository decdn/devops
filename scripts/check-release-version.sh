#!/usr/bin/env bash
# Gate a release tag, and optionally write its notes.
#
#   scripts/check-release-version.sh v0.1.0 [--notes <file>]
#
# One repo version covers both published artifacts: the tag vX.Y.Z must equal the
# decdn.node collection version (ansible/galaxy/galaxy.yml) AND the chart version
# (charts/decdn-node/Chart.yaml), and both changelogs must carry a released
# `## [X.Y.Z]` heading (not "unreleased"). With --notes, the two changelog sections
# are written to <file> as the GitHub Release body.
set -euo pipefail

tag="${1:-}"; notes=""
[[ "${2:-}" == "--notes" ]] && notes="${3:?--notes needs a file}"
[[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "tag '$tag' is not vX.Y.Z" >&2; exit 1; }
version="${BASH_REMATCH[1]}"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
galaxy_changelog="$repo/ansible/galaxy/CHANGELOG.md"
chart_changelog="$repo/charts/decdn-node/CHANGELOG.md"
collection="$(sed -nE 's/^version:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$repo/ansible/galaxy/galaxy.yml")"
chart="$(sed -nE 's/^version:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$repo/charts/decdn-node/Chart.yaml")"

fail=0
[[ "$collection" == "$version" ]] || { echo "ansible/galaxy/galaxy.yml version is $collection, tag is $tag" >&2; fail=1; }
[[ "$chart" == "$version" ]] || { echo "charts/decdn-node/Chart.yaml version is $chart, tag is $tag" >&2; fail=1; }

# Print the body of the `## [X.Y.Z]` section, or fail if it is missing or unreleased.
section() {
  local file="$1" heading
  heading="$(grep -E "^## \[$version\]" "$file" || true)"
  if [[ -z "$heading" ]]; then
    echo "$file has no '## [$version]' section" >&2; return 1
  fi
  if grep -qi 'unreleased' <<<"$heading"; then
    echo "$file still marks $version as unreleased: $heading" >&2; return 1
  fi
  awk -v v="## [$version]" 'index($0, v) == 1 {on=1; next} on && /^## \[/ {exit} on' "$file"
}
galaxy_notes="$(section "$galaxy_changelog")" || fail=1
chart_notes="$(section "$chart_changelog")" || fail=1
((fail == 0)) || exit 1

if [[ -n "$notes" ]]; then
  {
    echo "## Ansible collection \`decdn.node\` $version"
    echo "$galaxy_notes"
    echo
    echo "## Helm chart \`decdn-node\` $version"
    echo "$chart_notes"
  } > "$notes"
fi
echo "release $tag: collection and chart are both $version"
