#!/usr/bin/env bash
# Tests for the repo's own guard rails that no molecule scenario or chart render
# exercises: the ansible/ Makefile's scoping guards, the release gate, the
# lint-compose invariants (negative cases), and — with UPSTREAM=<decdn checkout> —
# the upstream-mirror generators' exit codes. `make test-scripts` runs it; CI's
# `scripts` job does too. Needs make, docker (compose v2), jq.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
skipped=()
pass() { echo "ok   $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# expect <exit-code> <description> <command...>: the command must exit with exactly that code.
expect() {
  local want="$1" desc="$2" got=0; shift 2
  "$@" >"$work/out" 2>&1 || got=$?
  [[ "$got" == "$want" ]] || { cat "$work/out" >&2; fail "$desc: exit $got, want $want"; }
  pass "$desc"
}

# --- ansible/Makefile scoping guards (dry runs: make -n never runs a playbook) ------
mk() { make -s -C "$repo/ansible" -n "$@"; }
expect 2 "decommission refuses a missing LIMIT"             mk decommission
expect 2 "decommission refuses an empty LIMIT"              mk decommission LIMIT=
expect 2 "decommission refuses LIMIT from the environment"  env LIMIT=h make -s -C "$repo/ansible" -n decommission
expect 2 "deploy refuses INVENTORY from the environment"    env INVENTORY=x make -s -C "$repo/ansible" -n deploy
expect 2 "backup refuses ANSIBLE_ARGS from the environment" env ANSIBLE_ARGS=-v make -s -C "$repo/ansible" -n backup
mk decommission LIMIT=h | grep -q -- "playbooks/decommission.yml --limit 'h'" \
  || fail "decommission LIMIT=h does not scope the playbook"
pass "decommission LIMIT=h scopes playbooks/decommission.yml"
mk backup | grep -q -- "playbooks/backup.yml" || fail "backup does not run playbooks/backup.yml"
pass "backup runs playbooks/backup.yml fleet-wide by default"

# --- release gate ----------------------------------------------------------------------
gate="$repo/scripts/check-release-version.sh"
expect 2 "release gate rejects a stray argument" "$gate" v0.1.0 notes.md
expect 2 "release gate rejects no arguments"     "$gate"
expect 1 "release gate rejects a malformed tag"  "$gate" 0.1.0
expect 1 "release gate rejects a version mismatch" "$gate" v9.9.9
# A released copy of the tree: both changelogs dated, versions equal to the tag.
rel="$work/rel"
mkdir -p "$rel/scripts" "$rel/ansible/galaxy" "$rel/charts/decdn-node"
cp "$gate" "$rel/scripts/"
cp "$repo/ansible/galaxy/galaxy.yml" "$repo/ansible/galaxy/CHANGELOG.md" "$rel/ansible/galaxy/"
cp "$repo/charts/decdn-node/Chart.yaml" "$repo/charts/decdn-node/CHANGELOG.md" "$rel/charts/decdn-node/"
version="$(sed -nE 's/^version:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$rel/charts/decdn-node/Chart.yaml")"
expect 1 "release gate rejects an 'unreleased' changelog heading" "$rel/scripts/check-release-version.sh" "v$version"
sed -i -E "s/^## \[$version\] — unreleased$/## [$version] — 2099-01-01/" \
  "$rel/ansible/galaxy/CHANGELOG.md" "$rel/charts/decdn-node/CHANGELOG.md"
expect 0 "release gate accepts a released tree" "$rel/scripts/check-release-version.sh" "v$version" --notes "$work/notes.md"
for section in '^## Ansible collection' '^## Helm chart'; do
  grep -q "$section" "$work/notes.md" || fail "release notes miss '$section'"
done
pass "release notes carry both changelog sections"

# --- lint-compose negatives: each broken variant must be rejected ----------------------
compose="$repo/compose/compose.yaml"
variant() { # <name> <sed expression>
  sed -E "$2" "$compose" > "$work/$1.yaml"
  cmp -s "$compose" "$work/$1.yaml" && fail "variant $1 did not change compose.yaml"
  # make exits 2 for any failing recipe, so tell "invariant violated" from "could
  # not render" by the message, not the exit code.
  if make -s -C "$repo" lint-compose COMPOSE_FILE="$work/$1.yaml" >"$work/out" 2>&1; then
    fail "lint-compose accepted: $1"
  fi
  grep -q 'violates an invariant' "$work/out" || { cat "$work/out" >&2; fail "lint-compose failed for another reason: $1"; }
  pass "lint-compose rejects: $1"
}
variant "bridge network"        's/^(\s*)network_mode: host$/\1network_mode: bridge/'
variant "writable rootfs"       's/^(\s*)read_only: true$/\1read_only: false/'
variant "short stop grace"      's/^(\s*)stop_grace_period: 300s$/\1stop_grace_period: 10s/'
variant "capabilities kept"     's/^(\s*)cap_drop: \[ALL\]$/\1cap_drop: [NET_RAW]/'
variant "published port"        's/^(\s*)network_mode: host$/\1ports: ["127.0.0.1:9090:9090"]/'
variant "tag instead of digest" 's#^(\s*)image: .*#\1image: ghcr.io/decdn/decdn-node:latest#'

# --- upstream-mirror generators (optional: needs a decdn/decdn checkout) --------------
if [[ -n "${UPSTREAM:-}" ]]; then
  expect 0 "network profiles current"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" --check
  expect 0 "monitoring assets current" "$repo/scripts/sync-monitoring.sh" "$UPSTREAM" --check
  expect 2 "network profiles: bad ref is an error, not drift"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" --ref no/such/ref --check
  expect 2 "monitoring assets: bad ref is an error, not drift" "$repo/scripts/sync-monitoring.sh" "$UPSTREAM" no/such/ref --check
else
  skipped+=("upstream-mirror generators (set UPSTREAM=<decdn checkout>)")
fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
echo "all script tests passed"
