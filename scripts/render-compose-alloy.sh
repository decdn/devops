#!/usr/bin/env bash
# Regenerate compose/alloy/config.alloy, the Grafana Alloy configuration the Compose
# `alloy` profile runs, from the grafana_alloy role's own template
# (ansible/roles/grafana_alloy/templates/config.alloy.j2, its `compose` runtime):
# one template for both deploy paths, so a change to the pipeline (the URL
# redaction, a level rule, a collector) reaches Compose only through here.
#
#   scripts/render-compose-alloy.sh           # rewrite compose/alloy/config.alloy
#   scripts/render-compose-alloy.sh --check   # exit 1 if it differs from a fresh render
#
# It runs ansible/tests/alloy-config/render.yml's `compose`-tagged task (the same
# playbook `make lint-alloy` renders every case with), so it needs ansible-core.
# `make test-scripts` runs --check; `make lint-alloy` validates the committed file
# with the real pinned Alloy binary.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/compose/alloy/config.alloy"
die() { echo "render-compose-alloy: $*" >&2; exit 2; }

check=""
case "${1:-}" in
  "") ;;
  --check) check=1 ;;
  *) die "usage: render-compose-alloy.sh [--check]" ;;
esac
command -v ansible-playbook >/dev/null || die "needs ansible-playbook (ansible-core) on PATH"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# From ansible/ so the project's ansible.cfg applies, as validate.sh runs it.
(cd "$repo/ansible" && ALLOY_RENDER_DIR="$work" \
  ansible-playbook -i localhost, -c local tests/alloy-config/render.yml --tags compose \
  </dev/null >"$work/log" 2>&1) \
  || { cat "$work/log" >&2; die "rendering the compose configuration failed (see above)"; }
[ -s "$work/compose.alloy" ] || die "render.yml's compose task wrote nothing"

if [ -n "$check" ]; then
  if ! diff -u "$target" "$work/compose.alloy" >&2; then
    echo "render-compose-alloy: $target differs from a fresh render of the grafana_alloy template;" \
      "run scripts/render-compose-alloy.sh and commit the result" >&2
    exit 1
  fi
  echo "compose/alloy/config.alloy matches the grafana_alloy template"
else
  mkdir -p "$(dirname "$target")"
  install -m 0644 "$work/compose.alloy" "$target"
  echo "wrote $target"
fi
