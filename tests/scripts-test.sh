#!/usr/bin/env bash
# Tests for the repo's own guard rails that no molecule scenario or chart render
# exercises: the ansible/ Makefile's scoping guards, the molecule driver's guards
# and locks (scripts/molecule.sh), the release gate and scripts/release.sh, the
# lint-compose and lint-cloud-init invariants (negative cases), compose/decdn-compose's
# unit tests, the firewall holes
# playbooks/group_vars/ derives per host, ci.yml's helm path filter, and — with
# UPSTREAM=<decdn checkout> — the upstream-mirror generators' exit codes.
# `make test-scripts` runs it; CI's `scripts` job does too. Needs make, docker
# (compose v2), jq, flock, gpg; the cloud-init cases also need cloud-init, shellcheck and yq,
# the firewall-holes case ansible-core.
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
for t in deploy-relay deploy-dns check-node deploy-node check-origin deploy-origin check-publisher deploy-publisher; do
  expect 2 "$t refuses LIMIT from the environment" env LIMIT=h make -s -C "$repo/ansible" -n "$t"
done
# Every playbook target, read from the guard block's own list so a new one is covered:
# exactly one ansible-playbook run, of the target's playbook, scoped to LIMIT, with
# limit_guard checking that same playbook and LIMIT first. Captured, then matched:
# `make -n | grep -q` can SIGPIPE make before it prints the line that matters.
targets="$(sed -nE 's/^ifneq \(\$\(filter ([a-z -]+),\$\(MAKECMDGOALS\)\),\)$/\1/p' "$repo/ansible/Makefile")"
(($(wc -w <<<"$targets") >= 16)) || fail "could not read the playbook targets from ansible/Makefile: $targets"
declare -A want_pb=([check]=site [deploy]=site [backup]=backup [decommission]=decommission
  [check-node]=node [deploy-node]=node [check-origin]=origin [deploy-origin]=origin
  [check-publisher]=publisher [deploy-publisher]=publisher [check-sponsord]=sponsord [deploy-sponsord]=sponsord
  [check-relay]=iroh_relay [deploy-relay]=iroh_relay [check-dns]=iroh_dns_server [deploy-dns]=iroh_dns_server)
for t in $targets; do
  pb="playbooks/${want_pb[$t]:?ansible/Makefile guards $t, which this test does not map to a playbook}.yml"
  check=""; [[ $t == check* ]] && check=" --check --diff"
  for lim in h ""; do
    [[ -z $lim && $t == decommission ]] && continue
    largs=(); [[ -z $lim ]] || largs=(LIMIT="$lim")
    out="$(mk "$t" "${largs[@]}")" || fail "make -n $t ${largs[*]} failed"
    scope=""; [[ -z $lim ]] || scope=" --limit '$lim'"
    want_run="ANSIBLE_INVENTORY_UNPARSED_FAILED=True ansible-playbook -i 'inventory/hosts.yml' $pb$check$scope"
    want_guard="ANSIBLE_INVENTORY_UNPARSED_FAILED=True ../scripts/limit-guard.sh 'inventory/hosts.yml' $pb '$lim'"
    # shellcheck disable=SC2001 # per line: the recipes' trailing spaces (empty LIMIT/ANSIBLE_ARGS)
    out="$(sed 's/ *$//' <<<"$out")"
    [[ "$out" == "$want_guard"$'\n'"$want_run" ]] \
      || fail "make $t ${largs[*]} does not run limit_guard on $pb, then $pb${lim:+ scoped to $lim}:"$'\n'"$out"
  done
done
pass "every playbook target (${targets// /, }) runs limit_guard, then its own playbook, scoped to LIMIT"

# --- molecule driver (scripts/molecule.sh): selection, guards, locks ------------------
# Against a throwaway ansible/ layout, so nothing here can start a container or touch
# the real collections/: every case below stops before `molecule test`, and the deps
# cases hold the collections lock so no install runs either.
fake="$work/ansible"
mkdir -p "$fake/molecule/a" "$fake/molecule/b" "$fake/molecule/c"
for s in a b c; do : >"$fake/molecule/$s/molecule.yml"; done
echo 'collections: []' >"$fake/requirements.yml"
prefix="$work/mol"
# mol [VAR=value...] <mode>: the driver in the fake layout, with a clean selection env.
mol() {
  local vars=()
  while [[ "$1" == *=* ]]; do vars+=("$1"); shift; done
  (cd "$fake" && env -u SCENARIOS -u JOBS -u SLOW_FIRST MOLECULE_LOCK_PREFIX="$prefix" \
    "${vars[@]}" "$repo/scripts/molecule.sh" "$@")
}
# said <description> <pattern>: the last command's output must contain the pattern.
said() { grep -qF -- "$2" "$work/out" || { cat "$work/out" >&2; fail "$1: output lacks '$2'"; }; }
no_deps() { ! grep -q "ansible-galaxy" "$work/out" || { cat "$work/out" >&2; fail "$1 ran deps"; }; }

expect 0 "molecule list: every scenario, SLOW_FIRST first, the rest by name" mol SLOW_FIRST=c list
[[ "$(<"$work/out")" == '["c","a","b"]' ]] || fail "molecule list printed $(<"$work/out")"
expect 0 "molecule list: a subset, sorted when nothing in it is slow" mol 'SCENARIOS=c a' list
[[ "$(<"$work/out")" == '["a","c"]' ]] || fail "molecule list SCENARIOS='c a' printed $(<"$work/out")"
expect 1 "molecule refuses an unknown scenario" mol SCENARIOS=nope list
said "unknown scenario" "unknown scenario 'nope'"
expect 1 "molecule refuses an empty SCENARIOS" mol SCENARIOS= list
said "empty SCENARIOS" "SCENARIOS is empty"
expect 1 "molecule refuses a stale SLOW_FIRST entry" mol SLOW_FIRST=gone list
said "stale SLOW_FIRST" "SLOW_FIRST names 'gone'"
mkdir "$fake/molecule/d"
expect 1 "molecule refuses a scenario dir without molecule.yml" mol list
said "truncated discovery" "refusing to run a silently-truncated suite"
rmdir "$fake/molecule/d"
for jobs in 0 00 x; do
  expect 1 "molecule refuses JOBS=$jobs before deps" mol JOBS=$jobs parallel
  said "JOBS=$jobs" "JOBS must be a positive integer"
  no_deps "JOBS=$jobs"
done

# A held scenario lock refuses the whole run up front: nothing starts, no deps.
mkdir "$prefix.b.lock"
# The sleep itself holds the lock fd, so killing it releases the lock (a
# `flock <path> sleep` holder would leave an orphaned sleep holding it).
( exec 9<"$prefix.b.lock"; flock 9; exec sleep 60 ) & holder=$!
until ! flock -n "$prefix.b.lock" true; do sleep 0.1; done
for mode in parallel serial; do
  expect 75 "molecule $mode refuses while another run holds one of its scenarios" mol 'SCENARIOS=a b' "$mode"
  said "$mode lock refusal" "another molecule run holds scenario b ($prefix.b.lock)"
  no_deps "$mode lock refusal"
done
kill "$holder"; wait "$holder" 2>/dev/null || true

# deps beside a running scenario (shared collections lock held): it never rewrites
# the tree, and proceeds only if the tree was installed from this requirements.yml.
mkdir -p "$prefix.collections.lock" "$fake/collections"
( exec 9<"$prefix.collections.lock"; flock -s 9; exec sleep 60 ) & holder=$!
until ! flock -n -x "$prefix.collections.lock" true; do sleep 0.1; done
expect 1 "deps refuses a changed requirements.yml while a run uses collections/" mol deps
said "deps refusal" "requirements.yml changed while another molecule run is using collections/"
no_deps "the deps refusal"
(cd "$fake" && sha256sum requirements.yml | cut -d' ' -f1 >collections/.requirements.sha256)
expect 0 "deps leaves a current collections/ alone while a run uses it" mol deps
said "deps skip" "not reinstalling"
no_deps "the deps skip"
kill "$holder"; wait "$holder" 2>/dev/null || true

# Whole runs against stand-ins for molecule and ansible-galaxy: every selected
# scenario stays reserved until the run ends (a queued one included, so a second run
# wanting it refuses up front), the locks go with the run, and a failing scenario
# fails the run by name. The stand-in molecule waits while $FAKE_HOLD exists and
# fails the scenario named in $FAKE_FAIL.
mkdir -p "$work/bin"
cat >"$work/bin/molecule" <<'EOF'
#!/usr/bin/env bash
echo "fake molecule $*"
while [[ -e "${FAKE_HOLD:-/nonexistent}" ]]; do sleep 0.1; done
[[ " $* " != *" -s ${FAKE_FAIL:-none} "* ]]
EOF
cat >"$work/bin/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
mkdir -p collections && echo "fake ansible-galaxy $*"
EOF
chmod +x "$work/bin/molecule" "$work/bin/ansible-galaxy"
fake_path="PATH=$work/bin:$PATH"

touch "$work/hold"
mol "$fake_path" FAKE_HOLD="$work/hold" 'SCENARIOS=a b' serial >"$work/run.out" 2>&1 & runner=$!
until grep -q 'fake molecule test -s a' "$work/run.out" 2>/dev/null; do sleep 0.1; done
! flock -n "$prefix.b.lock" true || fail "scenario b, queued behind a, is not reserved by the run"
pass "a run reserves every selected scenario, the queued ones included"
expect 75 "a second run wanting a reserved scenario refuses up front" mol "$fake_path" SCENARIOS=b serial
said "the reserved-scenario refusal" "another molecule run holds scenario b"
rm "$work/hold"
rc=0; wait "$runner" || rc=$?
[[ $rc == 0 ]] || { cat "$work/run.out" >&2; fail "the reserving run exited $rc"; }
if ! { grep -q 'fake molecule test -s b' "$work/run.out" && grep -q 'fake ansible-galaxy' "$work/run.out"; }; then
  cat "$work/run.out" >&2; fail "the run did not install deps and run both scenarios"
fi
pass "the run installs deps, then runs both scenarios"
for lock in a b collections; do
  flock -n -x "$prefix.$lock.lock" true || fail "the $lock lock outlived the run that took it"
done
pass "the run's locks end with it"
expect 123 "a failing scenario fails a parallel run (xargs 123)" mol "$fake_path" FAKE_FAIL=b 'SCENARIOS=a b' parallel
said "the failing scenario" "[b] SCENARIO FAILED"

# The real Makefile wiring: the lock refusal reaches make (which reports it as 2).
mkdir "$prefix.default.lock"
( exec 9<"$prefix.default.lock"; flock 9; exec sleep 60 ) & holder=$!
until ! flock -n "$prefix.default.lock" true; do sleep 0.1; done
for target in molecule molecule-serial; do
  expect 2 "make $target refuses while another run holds the scenario" \
    env -u JOBS -u SLOW_FIRST make -C "$repo/ansible" "$target" SCENARIOS=default MOLECULE_LOCK_PREFIX="$prefix"
  said "make $target lock refusal" "another molecule run holds scenario default"
  no_deps "make $target lock refusal"
done
kill "$holder"; wait "$holder" 2>/dev/null || true

# CI's matrix is make molecule-list: exactly the scenario dirs, and SLOW_FIRST valid.
expect 0 "make molecule-list lists the real scenarios" \
  env -u SCENARIOS -u SLOW_FIRST make -s -C "$repo/ansible" molecule-list
want="$(cd "$repo/ansible/molecule" && for d in */molecule.yml; do echo "${d%/molecule.yml}"; done | sort)"
[[ "$(jq -r '.[]' "$work/out" | sort)" == "$want" ]] \
  || { cat "$work/out" >&2; fail "make molecule-list does not match ansible/molecule/*/molecule.yml"; }

# Split scenarios share one converge, so their inventories must not drift apart.
if command -v yq >/dev/null; then
  for pair in sponsord:sponsord-install sponsord-onramp:sponsord-onramp-caddy \
      sponsord-onramp:sponsord-onramp-source sponsord-onramp:sponsord-onramp-lifecycle \
      iroh-relay:iroh-relay-lifecycle iroh-relay:iroh-relay-install \
      iroh-relay:iroh-relay-certificate iroh-relay:iroh-relay-gate \
      iroh-dns-server:iroh-dns-server-certificate iroh-dns-server:iroh-dns-server-install \
      iroh-dns-server:iroh-dns-server-lifecycle iroh-dns-server:iroh-dns-server-gate \
      source-build:source-build-rollback source-build:source-build-recovery; do
    a="$repo/ansible/molecule/${pair%%:*}/molecule.yml" b="$repo/ansible/molecule/${pair##*:}/molecule.yml"
    [[ "$(yq -o=json '.provisioner.inventory' "$a")" == "$(yq -o=json '.provisioner.inventory' "$b")" ]] \
      || fail "molecule ${pair%%:*} and ${pair##*:} inventories differ (they share one converge)"
    pass "molecule ${pair%%:*} and ${pair##*:} share one inventory"
  done
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the split-scenario inventory check would be skipped"
else
  skipped+=("split-scenario inventory check (needs yq)")
fi
# --- Galaxy collections: every role ships in exactly one --------------------------------
# galaxy/<collection>/roles.txt is the one role list build.sh and release.sh read: a role
# listed twice would ship in both collections, a role in neither would never ship.
shipped="$(cat "$repo"/ansible/galaxy/{node,publisher}/roles.txt | grep -vE '^[[:space:]]*(#|$)' | LC_ALL=C sort)"
dups="$(uniq -d <<<"$shipped")"
[[ -z "$dups" ]] || fail "roles listed by both collections' roles.txt: $(xargs <<<"$dups")"
roles_dir="$(cd "$repo/ansible/roles" && printf '%s\n' */ | tr -d / | LC_ALL=C sort)"
[[ "$(xargs <<<"$shipped")" == "$(xargs <<<"$roles_dir")" ]] \
  || fail "the collections' roles.txt list $(xargs <<<"$shipped"), not every role under ansible/roles: $(xargs <<<"$roles_dir")"
pass "every role under ansible/roles ships in exactly one Galaxy collection"
expect 2 "galaxy/build.sh rejects an unknown collection" "$repo/ansible/galaxy/build.sh" all
expect 2 "galaxy/build.sh rejects no collection" "$repo/ansible/galaxy/build.sh"

# --- release gate ----------------------------------------------------------------------
gate="$repo/scripts/check-release-version.sh"
expect 2 "release gate rejects a stray argument" "$gate" decdn-node-0.1.0 notes.md
expect 2 "release gate rejects no arguments"     "$gate"
# <description> <tag>: refused for its shape. The message is checked because the real
# changelogs may be unreleased, which would refuse any tag.
bad_tag() {
  expect 1 "release gate rejects $1" "$gate" "$2"
  grep -q "is neither decdn-node-X.Y.Z" "$work/out" || { cat "$work/out" >&2; fail "release gate: $2 refused for another reason"; }
}
bad_tag "a bare version"                 0.1.0
bad_tag "the retired shared vX.Y.Z tag"  v0.1.0
bad_tag "a chart tag with a v"           decdn-node-v0.1.0
bad_tag "the retired collection-vX.Y.Z tag" collection-v0.1.0
bad_tag "a collection tag without a v"   node-collection-0.1.0
bad_tag "an unknown collection"          relay-collection-v0.1.0
bad_tag "a pre-release suffix"           decdn-node-0.1.0-rc.1
bad_tag "a trailing character"           publisher-collection-v0.1.0x
expect 1 "release gate rejects a chart version mismatch" "$gate" decdn-node-9.9.9
grep -q "Chart.yaml version is" "$work/out" || fail "release gate: no chart version mismatch reported"
for c in node publisher; do
  expect 1 "release gate rejects a $c collection version mismatch" "$gate" "$c-collection-v9.9.9"
  grep -q "galaxy/$c/galaxy.yml version is" "$work/out" || fail "release gate: no $c collection version mismatch reported"
done
# A copy of the tree where each artifact is released alone: dating one changelog lets
# that artifact's tag through and leaves the others refused, each way round. The copy
# does not depend on where the real changelogs are in their release history: every
# manifest is set to 9.9.9, and each changelog gets an undated 9.9.9 section of its
# own above its first `## [` heading.
rel="$work/rel"
relgate="$rel/scripts/check-release-version.sh"
chart_log="$rel/charts/decdn-node/CHANGELOG.md"
mkdir -p "$rel/scripts" "$rel/charts/decdn-node"
cp "$gate" "$rel/scripts/"
cp "$repo/charts/decdn-node/Chart.yaml" "$repo/charts/decdn-node/CHANGELOG.md" "$rel/charts/decdn-node/"
for c in node publisher; do
  mkdir -p "$rel/ansible/galaxy/$c"
  cp "$repo/ansible/galaxy/$c/galaxy.yml" "$repo/ansible/galaxy/$c/CHANGELOG.md" "$rel/ansible/galaxy/$c/"
done
version="9.9.9" cversion="9.9.9"
sed -i -E "s/^version:.*/version: $version/" "$rel/charts/decdn-node/Chart.yaml" "$rel"/ansible/galaxy/*/galaxy.yml
# <artifact>: its tag and its changelog in the copy
declare -A rel_tag=([chart]="decdn-node-$version" [node]="node-collection-v$cversion" [publisher]="publisher-collection-v$cversion")
declare -A rel_log=([chart]="$chart_log" [node]="$rel/ansible/galaxy/node/CHANGELOG.md" [publisher]="$rel/ansible/galaxy/publisher/CHANGELOG.md")
for a in chart node publisher; do
  log="${rel_log[$a]}"
  awk -v v="$version" '!done && /^## \[/ {
      print "## [" v "] — unreleased"; print ""; print "### Added"; print ""
      print "- A fixture entry for the release gate tests."; print ""; done=1
    } {print}' "$log" > "$log.new"
  mv "$log.new" "$log"
  cp "$log" "$work/$a-changelog-unreleased.md"
done
# <description> <expected message, fixed string> <gate> <tag>
refused() {
  expect 1 "release gate rejects $1" "$3" "$4"
  grep -qF -- "$2" "$work/out" || { cat "$work/out" >&2; fail "release gate: wrong refusal for $1"; }
}
date_section() { sed -i -E "s/^## \[$1\] — unreleased$/## [$1] — 2099-01-01/" "$2"; } # <version> <changelog>
for a in chart node publisher; do
  refused "an 'unreleased' $a changelog heading" "still marks" "$relgate" "${rel_tag[$a]}"
done
for a in chart node publisher; do
  date_section "$version" "${rel_log[$a]}"
  expect 0 "release gate accepts a released $a" "$relgate" "${rel_tag[$a]}" --notes "$work/notes-$a.md"
  for other in chart node publisher; do
    [[ "$other" == "$a" ]] || refused "the $other while only the $a is released" "still marks" "$relgate" "${rel_tag[$other]}"
  done
  cp "$work/$a-changelog-unreleased.md" "${rel_log[$a]}"
done
# All released from here on: the release steps below read them.
for a in chart node publisher; do date_section "$version" "${rel_log[$a]}"; done
# <notes file> <its heading> <the other artifact's heading>
notes_for() {
  grep -q "^## $2 " "$1" || fail "release notes $1 miss '## $2'"
  ! grep -q "^## $3 " "$1" || fail "release notes $1 carry the other artifact's '## $3'"
  (($(grep -c '^- ' "$1") > 0)) || fail "release notes $1 carry no changelog entries"
  ! grep -qE '^(<!--|\[[^]]+\]: )' "$1" || fail "release notes $1 carry the changelog's trailing comment or link references"
}
notes_for "$work/notes-chart.md" 'Helm chart' 'Ansible collection'
node_heading="Ansible collection \`decdn.node\`" publisher_heading="Ansible collection \`decdn.publisher\`"
notes_for "$work/notes-node.md" "$node_heading" 'Helm chart'
notes_for "$work/notes-node.md" "$node_heading" "$publisher_heading"
notes_for "$work/notes-publisher.md" "$publisher_heading" 'Helm chart'
notes_for "$work/notes-publisher.md" "$publisher_heading" "$node_heading"
pass "release notes carry only their own artifact's changelog section"
# Section boundaries and refusals, on a fixture changelog: versions that share a prefix,
# a section above and below, and a trailing comment and link references.
fx="$work/fx"
mkdir -p "$fx/scripts" "$fx/charts/decdn-node"
cp "$gate" "$fx/scripts/"
cat > "$fx/changelog.md" <<'MD'
# Changelog

## [Unreleased]

- UNRELEASED

## [0.1.10] — 2099-01-03

### Fixed

- TEN

## [0.1.1] — 2099-01-02

### Fixed

- ONE

## [0.1.0] — 2099-01-01

- ZERO

<!-- a trailing comment -->
[Unreleased]: https://example.invalid/
MD
fxgate() { # <version> [--notes <file>]: the gate on the fixture, the chart at <version>
  printf 'version: %s\n' "$1" > "$fx/charts/decdn-node/Chart.yaml"
  local v="$1"; shift
  "$fx/scripts/check-release-version.sh" "decdn-node-$v" "$@"
}
cp "$fx/changelog.md" "$fx/charts/decdn-node/CHANGELOG.md"
for v in 0.1.10:TEN 0.1.1:ONE 0.1.0:ZERO; do
  expect 0 "release gate accepts fixture section ${v%%:*}" fxgate "${v%%:*}" --notes "$work/fx-notes.md"
  [[ "$(head -n1 "$work/fx-notes.md")" == "## Helm chart \`decdn-node\` ${v%%:*}" ]] \
    || fail "release notes for ${v%%:*} have the wrong title: $(head -n1 "$work/fx-notes.md")"
  [[ "$(grep -v '^## ' "$work/fx-notes.md" | grep -v '^###' | grep .)" == "- ${v#*:}" ]] \
    || fail "release notes for ${v%%:*} are not exactly its section: $(cat "$work/fx-notes.md")"
done
pass "release notes stop at the next section and before the trailing comment and links"
fxbad() { # <description> <expected message> <version> <sed script applied to the fixture>
  sed -E "$4" "$fx/changelog.md" > "$fx/charts/decdn-node/CHANGELOG.md"
  refused "$1" "$2" fxgate "$3"
}
fxbad "a missing section"              "has no '## [0.2.0]' section" 0.2.0 ''
fxbad "a version matched as a regex"   "has no '## [0.1.1]' section" 0.1.1 's/^## \[0\.1\.1\]/## [0x1x1]/'
fxbad "an undated heading"             "is not one '## [0.1.1] — YYYY-MM-DD'" 0.1.1 's/^(## \[0\.1\.1\]) — .*/\1 — TBD/'
fxbad "a heading with no date"         "is not one '## [0.1.1] — YYYY-MM-DD'" 0.1.1 's/^(## \[0\.1\.1\]) — .*/\1/'
fxbad "a duplicated section"           "is not one '## [0.1.1] — YYYY-MM-DD'" 0.1.1 's/^## \[0\.1\.0\]/## [0.1.1]/'
fxbad "a section with no entries"      "has no '- ' entries" 0.1.2 's/^## \[0\.1\.10\].*/## [0.1.2] — 2099-01-04\n\n&/'
# Each workflow triggers on exactly the tag shapes the gate accepts for its artifacts,
# and turns the tag into a name and a version the one way that fits those shapes: the
# chart strips its prefix; the collections split <collection>-collection-v<version>.
if command -v yq >/dev/null; then
  wfdir="$repo/.github/workflows"
  got="$(yq -o=json -I0 '.on.push.tags' "$wfdir/release-chart.yml")"
  [[ "$got" == '["decdn-node-[0-9]+.[0-9]+.[0-9]+"]' ]] || fail "release-chart.yml triggers on $got"
  got="$(yq -o=json -I0 '.on.push.tags' "$wfdir/release-collection.yml")"
  [[ "$got" == '["node-collection-v[0-9]+.[0-9]+.[0-9]+","publisher-collection-v[0-9]+.[0-9]+.[0-9]+"]' ]] \
    || fail "release-collection.yml triggers on $got"
  # shellcheck disable=SC2016 # literal ${TAG...} expansions in the workflows
  {
    got="$(grep -o '\${TAG[#%][^}]*}' "$wfdir/release-chart.yml" | LC_ALL=C sort -u | xargs)"
    [[ "$got" == '${TAG#decdn-node-}' ]] || fail "release-chart.yml derives the version with $got"
    got="$(grep -o '\${TAG[#%][^}]*}' "$wfdir/release-collection.yml" | LC_ALL=C sort -u | xargs)"
    [[ "$got" == '${TAG##*-collection-v} ${TAG%-collection-v*}' ]] \
      || fail "release-collection.yml derives the collection and version with $got"
  }
  pass "release-chart.yml and release-collection.yml trigger on, and parse, their own tag shapes"
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the release trigger check would be skipped"
else
  skipped+=("release trigger check (needs yq)")
fi

# --- artifacthub.io/changes, generated from the chart changelog at release ---------
changes="$repo/scripts/chart-artifacthub-changes.py"
refuse() { # <description> <expected message, fixed string> <changelog> <version>
  expect 1 "changes generator rejects $1" "$changes" "$3" "$4"
  grep -qF -- "$2" "$work/out" || { cat "$work/out" >&2; fail "changes generator: wrong refusal for $1"; }
}
expect 2 "changes generator rejects no arguments" "$changes"
refuse "a missing version" "no '## [9.9.9]' section" "$repo/charts/decdn-node/CHANGELOG.md" 9.9.9
cat > "$work/changelog.md" <<'MD'
# Changelog

## [Unreleased]

## [1.2.30] — 2099-02-01

### Added

- Not in 1.2.3 either.

## [1.2.3] — 2099-01-01

Intro text, not an entry.

### Added

- First entry,
  wrapped over two lines.
- Second entry.

### Fixed

- A fix.

## [1.2.2] — 2098-01-01

### Removed

- Not in 1.2.3.
MD
want='- kind: added
  description: "First entry, wrapped over two lines."
- kind: added
  description: "Second entry."
- kind: fixed
  description: "A fix."'
[[ "$("$changes" "$work/changelog.md" 1.2.3)" == "$want" ]] \
  || fail "changes generator: unexpected output for the fixture: $("$changes" "$work/changelog.md" 1.2.3)"
sed 's/$/\r/' "$work/changelog.md" > "$work/changelog-crlf.md"
[[ "$("$changes" "$work/changelog-crlf.md" 1.2.3)" == "$want" ]] \
  || fail "changes generator: CRLF line endings change the output"
pass "changes generator maps headings to kinds, joins wrapped entries, matches the whole version"
refuse "an empty section" "has no entries" "$work/changelog.md" Unreleased
bad() { # <description> <expected message> <sed script applied to the fixture>
  sed "$3" "$work/changelog.md" > "$work/changelog-bad.md"
  refuse "$1" "$2" "$work/changelog-bad.md" 1.2.3
}
bad "an unknown heading"            "heading '### Notes' is not"  's/^### Fixed$/### Notes/'
bad "an indented heading"           "heading ' ### Fixed' is not" 's/^### Fixed$/ ### Fixed/'
bad "a '## ' heading in the section" "heading '## Notes' is not"  's/^### Fixed$/## Notes\n\n### Fixed/'
bad "a bullet before the first heading" "comes before the first"  's/^Intro text, not an entry\.$/- Not under a heading./'
bad "a stray paragraph"             "neither a '- ' entry"        's/^- A fix\.$/A paragraph./'
bad "a nested list"                 "a nested list or code block" 's/^- Second entry\.$/- Second entry.\n  - nested/'
bad "a code block in an entry"      "a nested list or code block" 's/^- Second entry\.$/- Second entry.\n  ```/'
bad "an empty '-' entry"            "an empty '-' entry"          's/^- A fix\.$/-/'
bad "an empty '- ' entry"           "an empty '-' entry"          's/^- A fix\.$/- /'
bad "a duplicated section"          "appears 2 times"             's/^## \[1\.2\.2\] — 2098-01-01$/## [1.2.3] — 2098-01-01/'
# The copy's fixture section parses, and so does the real changelog's [Unreleased]
# while it exists, which the first release (scripts/release.sh) turns into its section.
expect 0 "changes generator reads the released copy's charts/decdn-node/CHANGELOG.md [$version]" \
  "$changes" "$chart_log" "$version"
if sed -n '/^## \[Unreleased\]/,/^## \[[0-9]/p' "$repo/charts/decdn-node/CHANGELOG.md" | grep -q '^### '; then
  expect 0 "changes generator reads charts/decdn-node/CHANGELOG.md [Unreleased]" \
    "$changes" "$repo/charts/decdn-node/CHANGELOG.md" Unreleased
fi
if command -v yq >/dev/null && command -v jq >/dev/null && command -v helm >/dev/null; then
  # The release workflows' own steps, read by name and run as Actions runs them, on
  # released copies of the tree. Nothing else runs the publish jobs before a real
  # publish, where a broken Release step strands an artifact already on Galaxy.
  wfstep() { # <workflow file> <job> <step name>: its run script, or fail
    local run
    run="$(yq ".jobs.$2.steps[] | select(.name == \"$3\") | .run" "$repo/.github/workflows/$1")"
    [[ -n "$run" && "$run" != null ]] || fail "$1 has no $2 step '$3'"
    printf '%s\n' "$run"
  }
  # A gh that answers `release list` with $GH_RELEASES (one tag per line, as the
  # workflow's --jq prints them), and otherwise records its arguments and refuses a
  # --notes-file or dist/ asset that is not a non-empty file (an unmatched glob reaches
  # it as the literal pattern).
  mkdir -p "$work/bin"
  cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ $1 == release && $2 == list ]]; then printf '%s' "${GH_RELEASES:-}"; exit 0; fi
printf '%s\n' "$@" > "$GH_ARGS"
prev=""
for a in "$@"; do
  if [[ $prev == --notes-file || $a == dist/* ]]; then
    [[ -s $a ]] || { echo "gh stub: no file $a" >&2; exit 1; }
  fi
  prev=$a
done
SH
  chmod +x "$work/bin/gh"
  run_in() { # <dir> <tag> <run script>
    (cd "$1" && PATH="$work/bin:$PATH" GH_ARGS="$work/gh-args" TAG="$2" GITHUB_REPOSITORY=decdn/devops \
      bash --noprofile --norc -eo pipefail -c "$3") >"$work/out" 2>&1
  }
  # <dir>: its files, sorted, on one line
  files() { (cd "$1" && printf '%s\n' * | LC_ALL=C sort | xargs); }

  # Each workflow's gate step refuses the other artifact's tag (a manual dispatch).
  for spec in "release-chart.yml|chart|decdn-node-$version|node-collection-v$cversion" \
              "release-chart.yml|chart|decdn-node-$version|publisher-collection-v$cversion" \
              "release-collection.yml|collection|node-collection-v$cversion|decdn-node-$version" \
              "release-collection.yml|collection|publisher-collection-v$cversion|decdn-node-$version"; do
    IFS='|' read -r wf kind own other <<<"$spec"
    gstep="$(wfstep "$wf" build "Gate the tag against the $kind and its changelog")"
    ! run_in "$rel" "$other" "$gstep" || fail "$wf's gate step accepts $other"
    grep -q "is not a $kind tag" "$work/out" || { cat "$work/out" >&2; fail "$wf's gate step: wrong refusal for $other"; }
    run_in "$rel" "$own" "$gstep" || { cat "$work/out" >&2; fail "$wf's gate step refuses $own"; }
  done
  pass "each release workflow's gate step takes only its own artifact's tag"

  # Chart: annotate, package, check the annotation, verify the sums, create the Release.
  annotate="$(wfstep release-chart.yml build "Add the artifacthub.io/changes annotation")"
  package="$(wfstep release-chart.yml build "Package the chart and write checksums")"
  check="$(wfstep release-chart.yml build "Check the packaged artifacthub.io/changes")"
  ah="$work/ah"
  mkdir -p "$ah/scripts" "$ah/charts"
  cp "$changes" "$ah/scripts/"
  cp -RL "$repo/charts/decdn-node" "$ah/charts/"
  cp "$chart_log" "$rel/charts/decdn-node/Chart.yaml" "$ah/charts/decdn-node/"
  cp "$work/notes-chart.md" "$ah/release-notes.md"
  run_step() { run_in "$ah" "decdn-node-$version" "$1"; }
  run_step "$annotate" || { cat "$work/out" >&2; fail "release-chart.yml's annotation step failed"; }
  run_step "$package" || { cat "$work/out" >&2; fail "release-chart.yml's package step failed"; }
  [[ "$(files "$ah/dist")" == "SHA256SUMS artifacthub-repo.yml decdn-node-$version.tgz release-notes.md" ]] \
    || fail "release-chart.yml's dist/ holds $(files "$ah/dist")"
  [[ "$(awk '{print $2}' "$ah/dist/SHA256SUMS")" == "decdn-node-$version.tgz" ]] \
    || fail "release-chart.yml's SHA256SUMS lists more or less than the chart: $(cat "$ah/dist/SHA256SUMS")"
  run_step "$check" || { cat "$work/out" >&2; fail "release-chart.yml's check refuses the generated annotation"; }
  [[ "$("$changes" "$chart_log" "$version" | yq -o=json -I0)" \
     == "$(helm show chart "$ah/dist/decdn-node-$version.tgz" | yq -o=json -I0 '.annotations["artifacthub.io/changes"] | from_yaml')" ]] \
    || fail "the packaged artifacthub.io/changes differs from the generator's output"
  pass "release-chart.yml's annotation step survives its package step unchanged, and its check accepts it"
  run_in "$ah/dist" "decdn-node-$version" "$(wfstep release-chart.yml publish "Verify the artifacts are the ones build checksummed")" \
    || { cat "$work/out" >&2; fail "release-chart.yml's publish job refuses its build's checksums"; }
  run_step "$(wfstep release-chart.yml publish "Create the GitHub Release")" \
    || { cat "$work/out" >&2; fail "release-chart.yml's Release step failed"; }
  grep -qx -- "--latest=false" "$work/gh-args" || fail "release-chart.yml's Release is not created with --latest=false"
  grep -qx "decdn-node chart $version" "$work/gh-args" || fail "release-chart.yml's Release title is not 'decdn-node chart $version'"
  pass "release-chart.yml's publish job verifies its build's dist/ and attaches it to a non-Latest Release"
  yq -i '.annotations["artifacthub.io/changes"] = "not a list"' "$ah/charts/decdn-node/Chart.yaml"
  helm package "$ah/charts/decdn-node" --destination "$ah/dist" >/dev/null 2>&1 \
    || fail "helm package failed on the chart with a scalar artifacthub.io/changes"
  ! run_step "$check" || fail "release-chart.yml's check accepts a scalar artifacthub.io/changes"
  pass "release-chart.yml's check refuses an artifacthub.io/changes that is not a list"

  # Collections: each collects only its own built tarball (both are built), verifies
  # the sums and creates its Release.
  collect="$(wfstep release-collection.yml build "Collect the collection and write checksums")"
  verify="$(wfstep release-collection.yml publish "Verify the artifacts are the ones build checksummed")"
  release="$(wfstep release-collection.yml publish "Create the GitHub Release")"
  for c in node publisher; do
    co="$work/co-$c" other=node
    [[ "$c" == node ]] && other=publisher
    mkdir -p "$co/ansible/build"
    echo stub > "$co/ansible/build/decdn-node-$cversion.tar.gz"
    echo stub > "$co/ansible/build/decdn-publisher-$cversion.tar.gz"
    cp "$work/notes-$c.md" "$co/release-notes.md"
    run_in "$co" "$c-collection-v$cversion" "$collect" \
      || { cat "$work/out" >&2; fail "release-collection.yml's collect step failed for $c"; }
    [[ "$(files "$co/dist")" == "SHA256SUMS decdn-$c-$cversion.tar.gz release-notes.md" ]] \
      || fail "release-collection.yml's dist/ for $c holds $(files "$co/dist")"
    [[ "$(awk '{print $2}' "$co/dist/SHA256SUMS")" == "decdn-$c-$cversion.tar.gz" ]] \
      || fail "release-collection.yml's SHA256SUMS for $c lists more or less than the collection: $(cat "$co/dist/SHA256SUMS")"
    run_in "$co/dist" "$c-collection-v$cversion" "$verify" \
      || { cat "$work/out" >&2; fail "release-collection.yml's publish job refuses its build's checksums for $c"; }
    for want in true false; do
      LATEST="$want" run_in "$co" "$c-collection-v$cversion" "$release" \
        || { cat "$work/out" >&2; fail "release-collection.yml's Release step failed for $c"; }
      grep -qx -- "--latest=$want" "$work/gh-args" || fail "release-collection.yml's Release ignores the Latest decision ($want) for $c"
    done
    grep -qx "decdn.$c collection $cversion" "$work/gh-args" \
      || fail "release-collection.yml's Release title is not 'decdn.$c collection $cversion'"
    grep -qx "dist/decdn-$c-$cversion.tar.gz" "$work/gh-args" || fail "release-collection.yml's $c Release does not attach its tarball"
    ! grep -q "decdn-$other-" "$work/gh-args" || fail "release-collection.yml's $c Release attaches the $other collection"
    ! LATEST="" run_in "$co" "$c-collection-v$cversion" "$release" || fail "release-collection.yml's Release runs with no Latest decision"
  done
  # A decdn.publisher publish first asks Galaxy (ansible-galaxy collection download)
  # for the decdn.node its built MANIFEST.json requires; a node publish skips it.
  galaxy_dep="$(wfstep release-collection.yml publish "Require decdn.publisher's decdn.node dependency on Galaxy")"
  cat > "$work/bin/ansible-galaxy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GALAXY_ARGS"
[[ -n ${GALAXY_HAS_NODE:-} ]]
SH
  chmod +x "$work/bin/ansible-galaxy"
  gd="$work/galaxy-dep"
  mkdir -p "$gd/m" "$gd/dist"
  printf '{"collection_info": {"dependencies": {"decdn.node": ">=0.1.0"}}}' > "$gd/m/MANIFEST.json"
  tar -czf "$gd/dist/decdn-publisher-$cversion.tar.gz" -C "$gd/m" MANIFEST.json
  export GALAXY_ARGS="$work/galaxy-args"
  : > "$GALAXY_ARGS"
  run_in "$gd" "node-collection-v$cversion" "$galaxy_dep" \
    || { cat "$work/out" >&2; fail "release-collection.yml's Galaxy dependency step fails a node release"; }
  [[ ! -s $GALAXY_ARGS ]] || fail "release-collection.yml's Galaxy dependency step queries Galaxy for a node release"
  GALAXY_HAS_NODE=1 run_in "$gd" "publisher-collection-v$cversion" "$galaxy_dep" \
    || { cat "$work/out" >&2; fail "release-collection.yml's Galaxy dependency step refuses a resolvable decdn.node"; }
  for arg in 'decdn.node:>=0.1.0' --no-deps; do
    grep -qx -- "$arg" "$GALAXY_ARGS" \
      || fail "release-collection.yml's Galaxy dependency step does not pass $arg: $(xargs <"$GALAXY_ARGS")"
  done
  ! run_in "$gd" "publisher-collection-v$cversion" "$galaxy_dep" \
    || fail "release-collection.yml publishes decdn.publisher while Galaxy has no decdn.node >=0.1.0"
  grep -qF "could not resolve decdn.node >=0.1.0 on Galaxy" "$work/out" || { cat "$work/out" >&2; fail "the Galaxy dependency refusal has another message"; }
  unset GALAXY_ARGS
  # ...and it runs before anything is published.
  # shellcheck disable=SC2016 # a yq expression
  order="$(yq '.jobs.publish.steps | to_entries | map(select(.value.name == "Require decdn.publisher'"'"'s decdn.node dependency on Galaxy" or .value.name == "Publish the collection to Galaxy" or .value.name == "Create the GitHub Release") | .value.name) | join("|")' \
    "$repo/.github/workflows/release-collection.yml")"
  [[ "$order" == "Require decdn.publisher's decdn.node dependency on Galaxy|Publish the collection to Galaxy|Create the GitHub Release" ]] \
    || fail "release-collection.yml's publish job does not check decdn.node before publishing: $order"
  pass "release-collection.yml publishes decdn.publisher only when Galaxy resolves its decdn.node"
  # Latest follows decdn.node only: a node release when no higher node release exists,
  # never a publisher release; chart and publisher tags never count.
  decide="$(wfstep release-collection.yml publish "Decide whether this release becomes Latest")"
  # <description> <want true|false> <tag> <existing release tags, newline-separated>
  # (the step reads only the tag, so any version will do)
  latest_case() {
    : > "$work/gh-output"
    GH_RELEASES="$4" GITHUB_OUTPUT="$work/gh-output" run_in "$work/co-node" "$3" "$decide" \
      || { cat "$work/out" >&2; fail "release-collection.yml's Latest step failed for $1"; }
    [[ "$(cat "$work/gh-output")" == "latest=$2" ]] \
      || fail "release-collection.yml's Latest step for $1: $(cat "$work/gh-output"), want latest=$2"
  }
  n=node-collection-v p=publisher-collection-v
  latest_case "the first node release"          true  "${n}0.1.0"  ""
  latest_case "a newer release than any"        true  "${n}0.2.0"  "${n}0.1.0"$'\n'"${n}0.1.1"
  latest_case "a patch below a newer line"      false "${n}0.1.2"  "${n}0.1.1"$'\n'"${n}0.2.0"
  latest_case "0.1.9 below 0.1.10 (by version)" false "${n}0.1.9"  "${n}0.1.10"
  latest_case "0.1.10 above 0.1.9 (by version)" true  "${n}0.1.10" "${n}0.1.9"
  latest_case "higher chart and publisher releases only" true "${n}0.1.0" "decdn-node-99.0.0"$'\n'"${p}99.0.0"
  latest_case "the first publisher release"     false "${p}0.1.0"  ""
  latest_case "a publisher release above every node one" false "${p}9.0.0" "${n}0.1.0"
  pass "release-collection.yml collects only its collection's tarball, and its publish job verifies it, decides Latest by decdn.node's versions and attaches it"
elif [[ -n ${CI:-} ]]; then
  fail "yq, jq or helm is not on PATH in CI; the release workflow steps would be skipped"
else
  skipped+=("release workflow steps (needs yq, jq and helm)")
fi

# --- scripts/release.sh: version, changelog section, signed commit and tag -------------
# On a fixture repo with a bare origin: small manifests and changelogs at the 0.0.0
# placeholder, the real scripts, cliff.toml, galaxy/build.sh and each collection's
# roles.txt, and an ephemeral ssh signing key. The host's git config is kept out (GIT_CONFIG_GLOBAL). The
# make checks are stubs that log their target to $RS_MAKE_LOG and fail while
# $RS_MAKE_FAIL exists; most cases skip them with --no-verify.
if command -v git-cliff >/dev/null && command -v ssh-keygen >/dev/null; then
  rs="$work/rs" rso="$work/rs-origin.git"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  today() { date -u +%F; }
  rsgit() { git -C "$rs" "$@"; }
  rsrel() { "$rs/scripts/release.sh" "$@"; }
  rspush() { rsgit push -q origin main; }
  # <path> <subject>: change <path> in the fixture, commit and push.
  rscommit() { mkdir -p "$(dirname "$rs/$1")"; echo "$RANDOM" >> "$rs/$1"; rsgit add -A; rsgit commit -qm "$2"; rspush; }
  # <description> <expected message, fixed string> <release.sh args...>
  rsrefused() {
    local desc="$1" msg="$2"; shift 2
    expect 1 "release.sh refuses $desc" rsrel "$@"
    grep -qF -- "$msg" "$work/out" || { cat "$work/out" >&2; fail "release.sh: wrong refusal for $desc"; }
  }
  # Each git runs on its own line, so a failing one fails the test instead of comparing
  # an empty string.
  rsclean() {
    local st; st="$(rsgit status --porcelain)" || fail "git status failed in the fixture"
    [[ -z "$st" ]] || fail "release.sh $1 left the tree dirty: $st"
  }
  rssaid() { grep -qF -- "$2" "$work/out" || { cat "$work/out" >&2; fail "release.sh $1: no '$2' in its output"; }; }
  rsnotag() {
    local mine theirs
    mine="$(rsgit tag)" || fail "git tag failed in the fixture"
    theirs="$(git -C "$rso" tag)" || fail "git tag failed in the fixture origin"
    [[ -z "$mine" && -z "$theirs" ]] || fail "release.sh made a tag $1"
  }
  # <tag>: origin has it, and its main is the local HEAD.
  rspushed() {
    local theirs mine
    git -C "$rso" rev-parse -q --verify "refs/tags/$1" >/dev/null || fail "release.sh did not push $1"
    theirs="$(git -C "$rso" rev-parse main)" || fail "git rev-parse failed in the fixture origin"
    mine="$(rsgit rev-parse HEAD)" || fail "git rev-parse failed in the fixture"
    [[ "$theirs" == "$mine" ]] || fail "release.sh did not push the $1 release commit"
  }
  # <target>: the make check ran, alone.
  rsmade() { [[ "$(cat "$RS_MAKE_LOG")" == "$1" ]] || fail "release.sh ran '$(cat "$RS_MAKE_LOG")', not make $1"; }
  chart="$rs/charts/decdn-node"
  git init -q --bare -b main "$rso"
  git init -q -b main "$rs"
  rsgit config user.name test; rsgit config user.email test@example.invalid
  ssh-keygen -q -t ed25519 -N '' -C test -f "$work/rs-key"
  rsgit config gpg.format ssh; rsgit config user.signingkey "$work/rs-key.pub"
  printf 'test@example.invalid %s\n' "$(cat "$work/rs-key.pub")" > "$work/rs-allowed-signers"
  rsgit config gpg.ssh.allowedSignersFile "$work/rs-allowed-signers"
  export RS_MAKE_LOG="$work/rs-make.log" RS_MAKE_FAIL="$work/rs-make-fail"
  rsgit remote add origin "$rso"
  mkdir -p "$rs/scripts" "$rs/ansible/galaxy/node" "$rs/ansible/galaxy/publisher" "$chart"
  cp "$repo/scripts/release.sh" "$repo/scripts/check-release-version.sh" "$repo/scripts/chart-artifacthub-changes.py" "$rs/scripts/"
  cp "$repo/cliff.toml" "$rs/"
  cp "$repo/ansible/galaxy/build.sh" "$rs/ansible/galaxy/"
  # shellcheck disable=SC2016 # $$ is make's, for the shell
  printf 'lint-helm:\n\t@echo lint-helm >> "$$RS_MAKE_LOG"; test ! -e "$$RS_MAKE_FAIL"\n' > "$rs/Makefile"
  # shellcheck disable=SC2016
  printf 'galaxy-check-%%:\n\t@echo galaxy-check-$* >> "$$RS_MAKE_LOG"; test ! -e "$$RS_MAKE_FAIL"\n' > "$rs/ansible/Makefile"
  printf 'apiVersion: v2\nname: decdn-node\nversion: 0.0.0\nappVersion: "0.0.1"\n' > "$chart/Chart.yaml"
  for c in node publisher; do
    cp "$repo/ansible/galaxy/$c/roles.txt" "$rs/ansible/galaxy/$c/"
    printf 'namespace: decdn\nname: %s\nversion: 0.0.0                      # a comment\n' "$c" > "$rs/ansible/galaxy/$c/galaxy.yml"
  done
  printf 'dependencies:\n  decdn.node: ">=0.0.2"\n' >> "$rs/ansible/galaxy/publisher/galaxy.yml"
  for log in "$chart/CHANGELOG.md" "$rs"/ansible/galaxy/{node,publisher}/CHANGELOG.md; do
    printf '# Changelog\n\nIntro.\n\n## [Unreleased]\n\nInitial.\n\n### Added\n\n- The first entry.\n' > "$log"
  done
  rsgit add -A; rsgit commit -qm "feat: the fixture"; rsgit push -q -u origin main

  expect 2 "release.sh rejects no arguments"        rsrel
  expect 2 "release.sh rejects an unknown artifact" rsrel compose
  expect 2 "release.sh rejects the retired collection artifact" rsrel collection
  expect 2 "release.sh rejects an unknown level"    rsrel chart huge
  expect 2 "release.sh rejects an unknown flag"     rsrel chart --force
  expect 2 "release.sh rejects a third argument"    rsrel chart minor extra

  # Refusals before anything is written never touch the operator's own edits.
  echo "- my own edit" >> "$chart/CHANGELOG.md"
  rsrefused "--execute on a dirty tree" "not clean" chart minor --execute --no-verify
  grep -qx -- "- my own edit" "$chart/CHANGELOG.md" || fail "release.sh's refusal of a dirty tree discarded an uncommitted edit"
  rsgit switch -q -c topic
  rsrefused "--execute on a branch other than main" "not 'topic'" chart minor --execute --no-verify
  grep -qx -- "- my own edit" "$chart/CHANGELOG.md" || fail "release.sh's refusal of a branch discarded an uncommitted edit"
  rsgit checkout -q -- "$chart/CHANGELOG.md"
  rsgit switch -q main; rsgit branch -q -D topic
  pass "release.sh's refusals keep uncommitted edits"
  touch "$rs/stray"
  rsrefused "an untracked file" "not clean" chart minor
  rm "$rs/stray"
  echo x >> "$rs/README"; rsgit add -A; rsgit commit -qm "docs: unpushed"
  rsrefused "a main ahead of origin" "not origin/main" chart minor
  rscommit README "docs: pushed"; rsgit reset -q --hard HEAD~1
  rsrefused "a main behind origin" "not origin/main" chart minor
  rsgit reset -q --hard origin/main
  rsgit switch -q --detach
  rsrefused "a detached HEAD" "not 'a detached HEAD'" chart minor
  rsgit switch -q main
  rsgit config --unset user.signingkey
  rsrefused "--execute without a signing key" "no user.signingkey" chart minor --execute
  rsgit config user.signingkey "$work/no-such-key.pub"
  rsrefused "--execute with a key that cannot sign" "cannot sign" chart minor --execute
  rsgit config user.signingkey "$work/rs-key.pub"

  # First-release refusals, each on a committed variant of the fixture.
  # <description> <message> <sed script for the chart file> <file> [release.sh args]
  rsfirst() {
    local desc="$1" msg="$2" script="$3" file="$4"; shift 4
    cp "$chart/$file" "$work/rs-saved"
    sed -i -E "$script" "$chart/$file"; rsgit commit -qam "test: $desc"; rspush
    rsrefused "$desc" "$msg" chart "${@:-minor}"
    cp "$work/rs-saved" "$chart/$file"; rsgit commit -qam "test: undo $desc"; rspush
  }
  rsrefused "auto for the first release" "names its level" chart
  rsrefused "0.0.0 as the first release" "not above 0.0.0" chart 0.0.0
  rsfirst "a first release from a manifest not at 0.0.0" "not the 0.0.0 placeholder" 's/^version: .*/version: 0.3.0/' Chart.yaml
  rsfirst "a first release with no [Unreleased]" "no '## [Unreleased]' section" 's/^## \[Unreleased\]$/## [Later]/' CHANGELOG.md
  rsfirst "a first release with an empty [Unreleased]" "has no '- ' entries" '/^- /d' CHANGELOG.md

  expect 0 "release.sh dry-runs the chart's first release" rsrel chart minor
  rssaid "dry run" "release chart: decdn-node-0.1.0"
  rssaid "dry run" "+## [0.1.0] — $(today)"
  rssaid "dry run" "scripts/check-release-version.sh decdn-node-0.1.0"
  rsclean "a dry run"
  rsnotag "in a dry run"

  # Failures after the files are written restore them and commit nothing. The stub gate
  # proves it ran on the written files.
  printf '#!/bin/sh\ngrep -q "^version: 0.1.0" charts/decdn-node/Chart.yaml && echo GATE-SAW-0.1.0\nexit 1\n' \
    > "$rs/scripts/check-release-version.sh"
  rsgit commit -qam "test: break the gate"; rspush
  rsrefused "to commit when the gate fails" "the release gate refused" chart minor --execute --no-verify
  rssaid "with a failing gate" "GATE-SAW-0.1.0"
  rsclean "with a failing gate"; rsnotag "after the gate failed"
  cp "$repo/scripts/check-release-version.sh" "$rs/scripts/"
  rsgit commit -qam "test: restore the gate"; rspush
  : > "$RS_MAKE_LOG"; touch "$RS_MAKE_FAIL"
  rsrefused "to commit when the make check fails" "make lint-helm failed: nothing was committed" chart minor --execute
  rsmade lint-helm
  rm "$RS_MAKE_FAIL"
  rsclean "with a failing make check"; rsnotag "after the make check failed"
  printf '#!/bin/sh\nexit 1\n' > "$rs/.git/hooks/pre-commit"; chmod +x "$rs/.git/hooks/pre-commit"
  rsrefused "to go on when a pre-commit hook fails" "git commit failed" chart minor --execute --no-verify
  rsclean "with a failing hook"; rsnotag "after a hook failed"
  [[ "$(rsgit log -1 --format=%s)" == "test: restore the gate" ]] || fail "release.sh committed past a failing hook"
  rm "$rs/.git/hooks/pre-commit"
  pass "release.sh restores the files and commits nothing when a check or the commit fails"

  # A rejected push leaves origin as it was (--atomic: the tag is refused, so is main).
  # shellcheck disable=SC2016 # a literal $1 in the hook
  printf '#!/bin/sh\ncase "$1" in refs/tags/*) exit 1 ;; esac\n' > "$rso/hooks/update"; chmod +x "$rso/hooks/update"
  before="$(git -C "$rso" rev-parse main)"
  rsrefused "to report success when origin rejects the push" "nothing reached origin" chart minor --execute --no-verify
  [[ "$(git -C "$rso" rev-parse main)" == "$before" && -z "$(git -C "$rso" tag)" ]] \
    || fail "release.sh's rejected push moved origin (main or a tag)"
  rm "$rso/hooks/update"
  rsgit tag -d decdn-node-0.1.0 >/dev/null; rsgit reset -q --hard origin/main
  pass "release.sh's rejected push is all-or-nothing, and its undo works"

  : > "$RS_MAKE_LOG"
  expect 0 "release.sh cuts the chart's first release" rsrel chart minor --execute
  rsmade lint-helm
  grep -qx 'version: 0.1.0' "$chart/Chart.yaml" || fail "release.sh did not set Chart.yaml to 0.1.0"
  grep -qx "## \[0.1.0\] — $(today)" "$chart/CHANGELOG.md" || fail "release.sh did not date [Unreleased] as 0.1.0"
  ! grep -q '^## \[Unreleased\]' "$chart/CHANGELOG.md" || fail "release.sh left [Unreleased] after the first release"
  grep -qx '## \[Unreleased\]' "$rs/ansible/galaxy/node/CHANGELOG.md" || fail "release.sh touched the node collection's changelog"
  rspushed decdn-node-0.1.0
  [[ "$(git -C "$rso" tag)" == "decdn-node-0.1.0" ]] || fail "release.sh pushed other tags: $(git -C "$rso" tag)"
  [[ "$(rsgit log -1 --format=%s)" == "chore(release): decdn-node-0.1.0" ]] || fail "release.sh's commit subject: $(rsgit log -1 --format=%s)"
  rsgit verify-commit HEAD 2>/dev/null || fail "release.sh's release commit is not signed with user.signingkey"
  rsgit verify-tag decdn-node-0.1.0 2>/dev/null || fail "release.sh's tag is not signed with user.signingkey"
  rsclean "--execute"
  pass "release.sh's first release dates [Unreleased], sets the version, runs make lint-helm and pushes a signed commit and tag"

  rsrefused "nothing since the tag" "nothing to release" chart
  rscommit other/file "feat(compose): elsewhere"
  rscommit charts/decdn-node/values.yaml "ci: not a change"
  rsrefused "only commits outside the chart, or skipped ones" "nothing to release" chart
  rsrefused "nothing, even with a level" "nothing to release" chart minor
  rsgit tag decdn-node-0.9.0
  rsrefused "a local tag origin does not have" "delete it with git tag -d" chart
  rsgit tag -d decdn-node-0.9.0 >/dev/null
  sed -i 's/^version: .*/version: 0.5.0/' "$chart/Chart.yaml"
  rsgit commit -qam "test: drift the version"; rspush
  rsrefused "a manifest that is not the last tag's version" "fix the manifest first" chart
  sed -i 's/^version: .*/version: 0.1.0/' "$chart/Chart.yaml"
  rsgit commit -qam "test: restore the version"; rspush
  cp "$chart/CHANGELOG.md" "$work/rs-saved"
  sed -i 's/^## \[0\.1\.0\]/## [Unreleased]\n\n- Hand-written.\n\n&/' "$chart/CHANGELOG.md"
  rsgit commit -qam "test: an [Unreleased] section"; rspush
  rsrefused "an [Unreleased] section after the first release" "has an [Unreleased] section" chart
  cp "$work/rs-saved" "$chart/CHANGELOG.md"; rsgit commit -qam "test: drop [Unreleased]"; rspush

  rscommit charts/decdn-node/values.yaml "fix(chart): a fix (#12)"
  expect 0 "release.sh bumps a fix to a patch" rsrel chart
  rssaid "after a fix" "decdn-node-0.1.0 -> decdn-node-0.1.1"
  rscommit monitoring/decdn-node/alerts.yml "feat(monitoring): an alert"
  expect 0 "release.sh bumps a feature to a minor" rsrel chart
  rssaid "after a feature" "decdn-node-0.1.0 -> decdn-node-0.2.0"
  expect 0 "release.sh takes an explicit level" rsrel chart patch
  rssaid "with patch" "decdn-node-0.1.0 -> decdn-node-0.1.1"
  rsrefused "a version not above the last" "not above the last release" chart 0.1.0
  # One commit of each other kind, and release commits the tag does not mark: the exact
  # section below pins where each goes, or that it is left out.
  rscommit charts/decdn-node/values.yaml "perf(chart): a faster probe"
  rscommit charts/decdn-node/values.yaml "docs(chart): a values comment"
  rscommit charts/decdn-node/values.yaml "revert(chart): restore the old probe"
  rscommit charts/decdn-node/values.yaml "security(chart): drop a capability"
  rscommit charts/decdn-node/values.yaml "style(chart): whitespace"
  rscommit charts/decdn-node/values.yaml "chore(release): decdn-node-9.9.9"
  rscommit charts/decdn-node/values.yaml "chore(release)!: decdn-node-9.9.10"
  expect 0 "release.sh cuts the chart's second release" rsrel chart --execute --no-verify
  rspushed decdn-node-0.2.0
  sec="$(awk '/^## \[0\.2\.0\]/{on=1;next} /^## \[/{on=0} on' "$chart/CHANGELOG.md")"
  want='### Added
- **monitoring**: An alert
### Changed
- **chart**: A values comment
- **chart**: A faster probe
### Removed
- **chart**: Restore the old probe
### Fixed
- **chart**: A fix (#12)
### Security
- **chart**: Drop a capability'
  [[ "$(grep '^###\|^- ' <<<"$sec")" == "$want" ]] \
    || fail "release.sh's 0.2.0 section is not the chart's commits, each under its kind: $sec"
  grep -qx "## \[0.2.0\] — $(today)" "$chart/CHANGELOG.md" || fail "release.sh: no dated 0.2.0 heading"
  [[ "$(grep -n '^## \[' "$chart/CHANGELOG.md" | cut -d: -f2 | cut -c1-10 | xargs)" == "## [0.2.0] ## [0.1.0]" ]] \
    || fail "release.sh did not put 0.2.0 above 0.1.0"
  expect 0 "the 0.2.0 section passes the changes generator" "$rs/scripts/chart-artifacthub-changes.py" "$chart/CHANGELOG.md" 0.2.0
  rsclean "a second --execute"
  pass "release.sh's later release renders the chart's commits since its tag, newest version first"

  rscommit charts/decdn-node/templates/x.yaml "refactor(chart)!: break it"
  expect 0 "release.sh bumps a breaking change to a minor" rsrel chart
  rssaid "after a breaking change" "decdn-node-0.2.0 -> decdn-node-0.3.0"
  rssaid "after a breaking change" "+- **Breaking:** **chart**: Break it"
  expect 0 "release.sh takes an explicit major" rsrel chart major
  rssaid "with major" "decdn-node-0.2.0 -> decdn-node-1.0.0"
  # A breaking commit of a skipped type is kept, under Changed: a `### ci` heading
  # would fail the changes generator. So are a capitalised type and one cliff.toml does
  # not list.
  rscommit charts/decdn-node/templates/y.yaml "ci(chart)!: drop a value"
  rscommit charts/decdn-node/templates/z.yaml "Feat(chart): a capitalised type"
  rscommit charts/decdn-node/templates/w.yaml "deps(chart): an unlisted type"
  expect 0 "release.sh renders unusual types under Keep a Changelog kinds" rsrel chart
  rssaid "with a breaking ci commit" "+- **Breaking:** **chart**: Drop a value"
  rssaid "with a capitalised type" "+- **chart**: A capitalised type"
  rssaid "with an unlisted type" "+- **chart**: An unlisted type"
  [[ "$(grep '^+### ' "$work/out" | xargs)" == "+### Added +### Changed" ]] \
    || { cat "$work/out" >&2; fail "release.sh: unusual types rendered other headings"; }
  # Without the catch-all, the unlisted type renders a `### deps` heading: the script's
  # own guard refuses it.
  sed -i '/{ message = "\.\*"/d' "$rs/cliff.toml"
  ! cmp -s "$repo/cliff.toml" "$rs/cliff.toml" || fail "cliff.toml has no catch-all parser to drop"
  rsgit commit -qam "test: drop the catch-all"; rspush
  rsrefused "a heading that is not a Keep a Changelog kind" "not a Keep a Changelog kind" chart
  cp "$repo/cliff.toml" "$rs/"; rsgit commit -qam "test: restore the catch-all"; rspush
  expect 0 "release.sh takes an explicit version" rsrel chart 0.2.7
  rssaid "with 0.2.7" "decdn-node-0.2.0 -> decdn-node-0.2.7"
  # git-cliff drops each of these, the last two though they look conventional on one line.
  rscommit charts/decdn-node/values.yaml "Update the values"
  rscommit charts/decdn-node/values.yaml "feat(): an empty scope"
  rscommit charts/decdn-node/values.yaml $'fix(chart): a glued body\nright under the subject'
  rsrefused "commits git-cliff cannot parse" "cannot parse these commits" chart
  rssaid "with an unconventional subject" " Update the values"
  rssaid "with an empty scope" " feat(): an empty scope"
  rssaid "with a body right under the subject" " fix(chart): a glued body"
  expect 0 "release.sh releases past unconventional commits when allowed" rsrel chart --allow-unconventional
  rssaid "when allowed" "cannot parse these commits"
  ! grep -qE '^\+- .*(Update the values|An empty scope|A glued body)' "$work/out" \
    || fail "release.sh rendered a commit git-cliff cannot parse"

  # Each collection is released on its own tags and paths: its roles.txt, its overlay.
  # decdn.publisher depends on decdn.node, so its first release waits for node's.
  rsrefused "decdn.publisher's first release before decdn.node's" "origin's highest node-collection tag is none" publisher-collection minor
  : > "$RS_MAKE_LOG"
  expect 0 "release.sh cuts the node collection's first release" rsrel node-collection patch --execute
  rsmade galaxy-check-node
  rspushed node-collection-v0.0.1
  # The fixture's publisher declares decdn.node >=0.0.2: a lower node release is not enough.
  rsrefused "decdn.publisher's first release below its decdn.node constraint" \
    "needs decdn.node >=0.0.2, and origin's highest node-collection tag is 0.0.1" publisher-collection patch
  sed -i 's/">=0.0.2"/">=0.0.1"/' "$rs/ansible/galaxy/publisher/galaxy.yml"
  rsgit commit -qam "build: lower the fixture's decdn.node constraint"; rspush
  grep -qx 'version: 0.0.1                      # a comment' "$rs/ansible/galaxy/node/galaxy.yml" \
    || fail "release.sh did not set node/galaxy.yml to 0.0.1 keeping its comment: $(grep '^version' "$rs/ansible/galaxy/node/galaxy.yml")"
  grep -qx '## \[Unreleased\]' "$rs/ansible/galaxy/publisher/CHANGELOG.md" || fail "release.sh touched the publisher collection's changelog"
  : > "$RS_MAKE_LOG"
  expect 0 "release.sh cuts the publisher collection's first release after node's" rsrel publisher-collection patch --execute
  rsmade galaxy-check-publisher
  rspushed publisher-collection-v0.0.1
  # A later release is held to the constraint too: raised past the highest node tag,
  # the collection would not install from Galaxy.
  sed -i 's/">=0.0.1"/">=0.1.0"/' "$rs/ansible/galaxy/publisher/galaxy.yml"
  rsgit commit -qam "build: raise the fixture's decdn.node constraint"; rspush
  # Checked before the changelog: no releasable commit is needed to trip it (the only
  # commit since the publisher's tag is a build commit, which makes no entry).
  rsrefused "a later decdn.publisher release above its decdn.node constraint" \
    "needs decdn.node >=0.1.0, and origin's highest node-collection tag is 0.0.1" publisher-collection
  sed -i 's/">=0.1.0"/">=0.0.1"/' "$rs/ansible/galaxy/publisher/galaxy.yml"
  rsgit commit -qam "build: restore the fixture's decdn.node constraint"; rspush
  rscommit ansible/molecule/default/x.yml "feat(molecule): not shipped"
  rscommit ansible/roles/unshipped/x.yml "feat(unshipped): not in a roles.txt"
  rsrefused "a change outside what the node collection ships" "nothing to release" node-collection
  rsrefused "a change outside what the publisher collection ships" "nothing to release" publisher-collection
  rscommit ansible/roles/baseline/defaults/main.yml "refactor(baseline)!: a breaking change"
  expect 0 "release.sh bumps a breaking change at 0.0.x to a patch" rsrel node-collection
  rssaid "after a breaking change at 0.0.x" "node-collection-v0.0.1 -> node-collection-v0.0.2"
  rsrefused "a node role change for the publisher collection" "nothing to release" publisher-collection
  rscommit ansible/roles/iroh_relay/defaults/main.yml "fix(iroh_relay): a role fix"
  expect 0 "release.sh bumps the publisher collection for a role fix" rsrel publisher-collection
  rssaid "after a role fix" "publisher-collection-v0.0.1 -> publisher-collection-v0.0.2"
  ! grep -qF "Break it" "$work/out" || fail "release.sh's publisher section carries a chart commit"
  ! grep -qF "A breaking change" "$work/out" || fail "release.sh's publisher section carries a node collection commit"
  rscommit ansible/galaxy/build.sh "fix(galaxy): a build fix"
  expect 0 "release.sh counts galaxy/build.sh for the node collection" rsrel node-collection
  rssaid "after a build.sh fix" "+- **galaxy**: A build fix"
  echo unshipped >> "$rs/ansible/galaxy/publisher/roles.txt"
  rsgit commit -qam "build: ship the unshipped role"; rspush
  expect 0 "release.sh reads the collection's roles from its roles.txt" rsrel publisher-collection
  rssaid "with a role added to roles.txt" "+- **unshipped**: Not in a roles.txt"
  rssaid "with a feature at 0.0.x" "publisher-collection-v0.0.1 -> publisher-collection-v0.1.0"
  ! grep -qF "Ship the unshipped role" "$work/out" || fail "release.sh's collection section lists a build commit"
  pass "release.sh releases each collection on its own tags, roles.txt and overlay, publisher after node"
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM RS_MAKE_LOG RS_MAKE_FAIL
elif [[ -n ${CI:-} ]]; then
  fail "git-cliff or ssh-keygen is not on PATH in CI; the release.sh tests would be skipped"
else
  skipped+=("release.sh (needs git-cliff and ssh-keygen)")
fi

# --- pr-title.yml: the Conventional Commit check on PR titles --------------------------
# Its step's run script, read out of the workflow and run as Actions runs it, against
# titles it must take or refuse: the exit status is what blocks a merge.
title_run="$(awk '/^ *run: \|$/ {on=1; next} on && /^          / {sub(/^          /, ""); print; next} on {exit}' \
  "$repo/.github/workflows/pr-title.yml")"
grep -q '=~' <<<"$title_run" || fail "pr-title.yml has no run: | step with a regex"
while IFS='|' read -r want title; do
  got=refuse; TITLE="$title" bash --noprofile --norc -eo pipefail -c "$title_run" >/dev/null 2>&1 && got=take
  [[ "$got" == "$want" ]] || fail "pr-title.yml should $want '$title'"
done <<'EOF'
take|feat(iroh_relay): admit only listed endpoint IDs (#108)
take|fix(roles/x)!: break it
take|feat!: no scope
take|docs: a doc
take|chore: sync upstream decdn/decdn @ 3ebf5f17 (#80)
take|ci(deps): Bump the actions group with 2 updates (#127)
take|security(chart): drop a capability
refuse|Feat: a capitalised type
refuse|deps: an unlisted type
refuse|features: a prefix of a type
refuse|feat(): an empty scope
refuse|fix(chart):no space
refuse|fix(chart):  a double space
refuse|Update values.yaml
EOF
pass "pr-title.yml takes Conventional Commit titles and refuses the rest"

# --- lint-compose: the real file passes, each broken variant is rejected -------------
compose="$repo/compose/compose.yaml"
# The baseline first: a variant below only proves something if the unmodified file
# does not already trip the invariant it targets.
expect 0 "lint-compose accepts compose/compose.yaml" make -s -C "$repo" lint-compose
# <name> <expected message fragment> <sed expression>: the fragment pins WHICH
# invariant fired (compose/tests/*.jq print "<service>: <invariant>"), since one
# edit can trip several. Scope an edit to one service by prefixing a sed range:
# "${node}", "${sd}", "${onr}", "${cdy}", "${rly}", "${dns}" or "${aly}".
variant() {
  sed -E "$3" "$compose" > "$work/$1.yaml"
  cmp -s "$compose" "$work/$1.yaml" && fail "variant $1 did not change compose.yaml"
  # make exits 2 for any failing recipe, so tell "invariant violated" from "could
  # not render" by the message, not the exit code.
  if make -s -C "$repo" lint-compose LINT_COMPOSE_FILE="$work/$1.yaml" >"$work/out" 2>&1; then
    fail "lint-compose accepted: $1"
  fi
  grep -q 'violates an invariant' "$work/out" || { cat "$work/out" >&2; fail "lint-compose failed for another reason: $1"; }
  grep -qF -- "$2" "$work/out" || { cat "$work/out" >&2; fail "lint-compose rejected $1, but not with: $2"; }
  pass "lint-compose rejects: $1"
}
# Each range ends at the next service or top-level key. The shared hardening is the
# x-hardened anchor, merged by each service's `<<: *hardened` line, so an edit that
# weakens one service inserts an overriding key after that line ("${h}").
node='/^  decdn-node:$/,/^ {0,2}[a-z]/'
sd='/^  sponsord:$/,/^ {0,2}[a-z]/'
onr='/^  sponsord-onramp:$/,/^ {0,2}[a-z]/'
cdy='/^  caddy:$/,/^ {0,2}[a-z]/'
rly='/^  iroh-relay:$/,/^ {0,2}[a-z]/'
dns='/^  iroh-dns-server:$/,/^ {0,2}[a-z]/'
aly='/^  alloy:$/,/^ {0,2}[a-z]/'
h='s/^(\s*)<<: \*hardened$/&\n\1'
# Shape
variant "unexpected service"       "compose.yaml: services are exactly"           "s/^  caddy:$/  proxy:/"
variant "sponsord privileged"      "sponsord: sets only allowed keys (extra: privileged)" "${sd} ${h}privileged: true/"
variant "sponsord host pid"        "sponsord: sets only allowed keys (extra: pid)" "${sd} ${h}pid: host/"
variant "onramp device"            "sponsord-onramp: sets only allowed keys (extra: devices)" "${onr} ${h}devices: [\"\/dev\/mem:\/dev\/mem\"]/"
variant "hardening dropped"        "sponsord: read_only rootfs"                   "${sd} {/^    <<: \*hardened$/d}"
variant "anchor weakened"          "caddy: read_only rootfs"                      "/^x-hardened:/,/^[a-z]/ s/^(\s*)read_only: true$/\1read_only: false/"
# decdn-node
variant "bridge network"           "decdn-node: network_mode is host"             "${node} ${h}network_mode: bridge/"
variant "writable rootfs"          "decdn-node: read_only rootfs"                 "${node} ${h}read_only: false/"
variant "short stop grace"         "decdn-node: stop_grace_period"                "${node} s/^(\s*)stop_grace_period: 300s$/\1stop_grace_period: 10s/"
variant "capabilities kept"        "decdn-node: cap_drop is [ALL]"                "${node} ${h}cap_drop: [NET_RAW]/"
variant "published port"           "decdn-node: publishes no ports"               "${node} ${h}ports: [\"127.0.0.1:9090:9090\"]/"
variant "tag instead of digest"    "decdn-node: image is pinned"                  "${node} s#^(\s*)image: .*#\1image: ghcr.io/decdn/decdn-node:latest#"
variant "node config writable"     "decdn-node: mounts are exactly"               "${node} {/target: \/etc\/decdn$/{n;s/read_only: true/read_only: false/}}"
variant "origin content writable"  "decdn-node: mounts are exactly"               "${node} {/target: \/srv\/decdn-origin$/{n;s/read_only: true/read_only: false/}}"
variant "origin dir created"       "decdn-node: create_host_path on /srv/decdn-origin is true"               "${node} {/target: \/srv\/decdn-origin$/{n;n;s/create_host_path: false/create_host_path: true/}}"
variant "node data dir created"    "decdn-node: create_host_path on /var/lib/decdn is true"               "${node} {/target: \/var\/lib\/decdn$/{n;s/create_host_path: false/create_host_path: true/}}"
variant "create_host_path left out" "decdn-node: bind mount /etc/decdn sets create_host_path explicitly" "${node} {/target: \/etc\/decdn$/{n;n;d}}"
variant "short-syntax volume"      "caddy: short-syntax volume"                   "${cdy} s#^(\s*)volumes:\$#\1volumes:\n\1  - /srv/x:/srv/x:ro#"
variant "node holds a secret"      "decdn-node: sets only allowed keys (extra: secrets)" "${node} ${h}secrets: [sponsord-api-token]/"
variant "node always on"           "decdn-node: profiles are [node, origin]"      "${node} {/^    profiles: \[node, origin\]$/d}"
variant "origin without the node"  "decdn-node: profiles are [node, origin]"      "${node} s/^(\s*)profiles: \[node, origin\]$/\1profiles: [node]/"
variant "node healthcheck dropped" "decdn-node: healthcheck is"                   "${node} s/^(\s*)test: \[\"CMD\", \"decdn\", \"node\", \"health\".*/\1test: [\"NONE\"]/"
variant "node RPC URL inline"      "decdn-node: sets only allowed environment keys inline (extra: DECDN_RPC_URL)" "${node} ${h}environment:\n\1  DECDN_RPC_URL: https:\/\/rpc.invalid\/key/"
# sponsord
variant "sponsord on 0.0.0.0"      "sponsord: SPONSORD_BIND is 127.x"             "${sd} s/SPONSORD_BIND: 127\.0\.0\.1:8090/SPONSORD_BIND: 0.0.0.0:8090/"
variant "sponsord bind unset"      "sponsord: SPONSORD_BIND is 127.x"             "${sd} {/SPONSORD_BIND: /d}"
variant "sponsord bind flag"       "sponsord: no command or entrypoint override"  "${sd} ${h}command: [--bind, \"0.0.0.0:8090\"]/"
variant "sponsord by tag"          "sponsord: image is pinned"                    "${sd} s#^(\s*)image: .*#\1image: ghcr.io/decdn/sponsord:latest#"
variant "sponsord capability"      "sponsord: sets only allowed keys (extra: cap_add)" "${sd} ${h}cap_add: [NET_RAW]/"
variant "sponsord short grace"     "sponsord: stop_grace_period"                  "${sd} s/^(\s*)stop_grace_period: 120s$/\1stop_grace_period: 10s/"
variant "sponsord SIGKILL"         "sponsord: stop_signal is SIGTERM"             "${sd} ${h}stop_signal: SIGKILL/"
variant "sponsord as root"         "sponsord: runs as a non-root uid:gid"         "${sd} s/^(\s*)user: .*/\1user: \"0:0\"/"
variant "privilege escalation"     "sponsord: security_opt is exactly"            "${sd} ${h}security_opt: [\"no-new-privileges:false\"]/"
variant "seccomp unconfined"       "sponsord: security_opt is exactly"            "${sd} ${h}security_opt: [\"no-new-privileges:true\", \"seccomp:unconfined\"]/"
variant "writable keystore mount"  "sponsord: mounts are exactly"                 "${sd} ${h}volumes: [{type: bind, source: \/etc\/sponsord\/treasury-keystore.json, target: \/run\/secrets\/k, bind: {create_host_path: false}}]/"
variant "host root as data dir"    "sponsord: mounts are exactly"                 "${sd} ${h}volumes: [{type: bind, source: \/, target: \/data, bind: {create_host_path: false}}]/"
variant "docker socket"            "sponsord: mounts are exactly"                 "${sd} ${h}volumes: [{type: bind, source: \/var\/run\/docker.sock, target: \/var\/run\/docker.sock, read_only: true, bind: {create_host_path: false}}]/"
variant "sponsord extra secret"    "sponsord: mounts are exactly"                 "${sd} s/^(\s*)secrets:$/&\n\1  - sponsord-turnstile-secret/"
variant "secret moved"             "sponsord: mounts are exactly"                 "s#^(\s*)file: /etc/sponsord/treasury-keystore\.json\$#\1file: /tmp/treasury-keystore.json#"
variant "secret from environment"  "secrets.sponsord-api-token: is a single absolute host file" "s#^(\s*)file: /etc/sponsord/api-token\$#\1environment: SPONSORD_API_TOKEN#"
variant "keystore path moved"      "sponsord: SPONSORD_TREASURY_KEYSTORE is"      "${sd} s#SPONSORD_TREASURY_KEYSTORE: .*#SPONSORD_TREASURY_KEYSTORE: /tmp/k.json#"
variant "inline API token"         "sponsord: no inline SPONSORD_API_TOKEN"       "${sd} s/^(\s*)SPONSORD_BIND: (.*)$/&\n\1SPONSORD_API_TOKEN: x/"
variant "RPC URL in compose.yaml"   "sponsord: sets only allowed environment keys inline (extra: SPONSORD_RPC_URL)" "${sd} s/^(\s*)SPONSORD_BIND: (.*)$/&\n\1SPONSORD_RPC_URL: https:\/\/rpc.invalid\/key/"
variant "onramp without daemon"    "sponsord: profiles are"                       "${sd} s/^(\s*)profiles: \[sponsord, onramp\]$/\1profiles: [sponsord]/"
variant "sponsord digest default"  "sponsord: unset image digest"                 "${sd} s#^(\s*)image: .*#\1image: ghcr.io/decdn/sponsord@\\\${SPONSORD_IMAGE_DIGEST:-sha256:$(printf '0%.0s' {1..64})}#"
variant "sponsord uid default"     "sponsord: unset uid/gid"                      "${sd} s/^(\s*)user: .*/\1user: \"\\\${SPONSORD_UID:-998}:\\\${SPONSORD_GID:-998}\"/"
# sponsord-onramp
variant "onramp on 0.0.0.0"        "sponsord-onramp: ONRAMP_BIND is 127.x"        "${onr} s/ONRAMP_BIND: 127\.0\.0\.1:8080/ONRAMP_BIND: 0.0.0.0:8080/"
variant "onramp bind unset"        "sponsord-onramp: ONRAMP_BIND is 127.x"        "${onr} {/ONRAMP_BIND: /d}"
variant "onramp remote daemon"     "sponsord-onramp: ONRAMP_DAEMON_URL"           "${onr} s#ONRAMP_DAEMON_URL: http://127\.0\.0\.1:8090#ONRAMP_DAEMON_URL: http://10.0.0.1:8090#"
variant "onramp published port"    "sponsord-onramp: publishes no ports"          "${onr} ${h}ports: [\"8080:8080\"]/"
variant "onramp writable rootfs"   "sponsord-onramp: read_only rootfs"            "${onr} ${h}read_only: false/"
variant "onramp short grace"       "sponsord-onramp: stop_grace_period"           "${onr} s/^(\s*)stop_grace_period: 30s$/\1stop_grace_period: 5s/"
variant "onramp by tag"            "sponsord-onramp: image is pinned"             "${onr} s#^(\s*)image: .*#\1image: ghcr.io/decdn/sponsord-onramp:latest#"
variant "onramp holds keystore"    "sponsord-onramp: mounts are exactly"          "${onr} s/^(\s*)secrets:$/&\n\1  - source: sponsord-treasury-keystore\n\1    target: \/run\/secrets\/k/"
variant "onramp keystore volume"   "sponsord-onramp: mounts are exactly"          "${onr} s#^(\s*)volumes:\$#\1volumes:\n\1  - {type: bind, source: /etc/sponsord/treasury-keystore.json, target: /run/secrets/k, read_only: true, bind: {create_host_path: false}}#"
variant "writable gate-page mount"  "sponsord-onramp: mounts are exactly"          "${onr} {/target: \/etc\/sponsord\/onramp-gate$/{n;s/read_only: true/read_only: false/}}"
variant "onramp entrypoint flag"   "sponsord-onramp: entrypoint is exactly"       "${onr} s#^(\s*)exec sponsord-onramp\$#\1exec sponsord-onramp --bind 0.0.0.0:8080#"
variant "gate check dropped"       "sponsord-onramp: entrypoint is exactly"       "${onr} s#^(\s*)/etc/sponsord/onramp-gate/\*\) ;;\$#\1*) ;;#"
variant "gate page from a secret"  "sponsord-onramp: mounts are exactly"          "${onr} s#source: /etc/sponsord/onramp-gate\$#source: /etc/sponsord/treasury-keystore.json#"
variant "inline Turnstile secret"  "sponsord-onramp: no inline ONRAMP_TURNSTILE_SECRET" "${onr} s/^(\s*)ONRAMP_BIND: (.*)$/&\n\1ONRAMP_TURNSTILE_SECRET: x/"
variant "onramp on sponsord hosts" "sponsord-onramp: profiles are [onramp]"       "${onr} s/^(\s*)profiles: \[onramp\]$/\1profiles: [onramp, sponsord]/"
variant "resolvable domain default" "sponsord-onramp: unset domain"               "${onr} s#ONRAMP_PUBLIC_URL: .*#ONRAMP_PUBLIC_URL: https://\\\${SPONSORD_ONRAMP_DOMAIN:-unset-SPONSORD_ONRAMP_DOMAIN.invalid}#"
# caddy
variant "caddy extra capability"   "caddy: cap_add is exactly"                    "${cdy} s/cap_add: \[NET_BIND_SERVICE\]/cap_add: [NET_BIND_SERVICE, NET_ADMIN]/"
variant "caddy keeps capabilities" "caddy: cap_drop is [ALL]"                     "${cdy} ${h}cap_drop: []/"
variant "caddy as root"            "caddy: runs as a non-root uid:gid"            "${cdy} {/^    user: /d}"
variant "caddy published port"     "caddy: publishes no ports"                    "${cdy} ${h}ports: [\"443:443\"]/"
variant "caddy always on"          "caddy: profiles are [caddy]"                  "${cdy} {/^    profiles: \[caddy\]$/d}"
# Caddy holds NET_BIND_SERVICE too, but only the iroh services may run as uid 0.
variant "caddy as uid 0"           "caddy: runs as a non-root uid:gid"            "${cdy} s/^(\s*)user: .*/\1user: \"0:0\"/"
# iroh-relay: uid 0 holding NET_BIND_SERVICE alone, SIGINT, the config read-only
variant "relay extra capability"   "iroh-relay: runs as uid 0 only with cap_add exactly [NET_BIND_SERVICE]" "${rly} s/cap_add: \[NET_BIND_SERVICE\]/cap_add: [NET_BIND_SERVICE, NET_ADMIN]/"
variant "relay root, no cap_add"   "iroh-relay: runs as uid 0 only with cap_add exactly [NET_BIND_SERVICE]" "${rly} {/^    cap_add: /d}"
variant "relay keeps capabilities" "iroh-relay: cap_drop is [ALL]"                "${rly} ${h}cap_drop: []/"
variant "relay as root by name"    "iroh-relay: runs as a non-root uid:gid"       "${rly} s/^(\s*)user: .*/\1user: root/"
variant "relay SIGTERM"            "iroh-relay: stop_signal is SIGINT"            "${rly} s/^(\s*)stop_signal: SIGINT$/\1stop_signal: SIGTERM/"
variant "relay short grace"        "iroh-relay: stop_grace_period is 30s"         "${rly} s/^(\s*)stop_grace_period: 30s$/\1stop_grace_period: 5s/"
variant "relay writable config"    "iroh-relay: mounts are exactly"               "${rly} {/target: \/etc\/iroh-relay\/iroh-relay.toml$/{n;s/read_only: true/read_only: false/}}"
variant "relay config directory"   "iroh-relay: mounts are exactly"               "${rly} s#^(\s*)(source|target): /etc/iroh-relay/iroh-relay\.toml\$#\1\2: /etc/iroh-relay#"
variant "relay docker socket"      "iroh-relay: mounts are exactly"               "${rly} s#^(\s*)volumes:\$#\1volumes:\n\1  - {type: bind, source: /var/run/docker.sock, target: /var/run/docker.sock, read_only: true, bind: {create_host_path: false}}#"
variant "relay published port"     "iroh-relay: publishes no ports"               "${rly} ${h}ports: [\"443:443\"]/"
variant "relay bridge network"     "iroh-relay: network_mode is host"             "${rly} ${h}network_mode: bridge/"
variant "relay writable rootfs"    "iroh-relay: read_only rootfs"                 "${rly} ${h}read_only: false/"
variant "relay dev mode"           "iroh-relay: command is exactly"               "${rly} s#^(\s*)command: .*#\1command: [\"--dev\"]#"
variant "relay entrypoint swap"    "iroh-relay: command is exactly"               "${rly} ${h}entrypoint: [\"\/bin\/sh\"]/"
variant "relay quiet log"          "iroh-relay: RUST_LOG is set"                  "${rly} {/^      RUST_LOG: /d}"
variant "relay privileged"         "iroh-relay: sets only allowed keys (extra: privileged)"         "${rly} ${h}privileged: true/"
variant "relay low fd limit"       "iroh-relay: ulimits.nofile is 65536"          "${rly} s/^(\s*)nofile: 65536$/\1nofile: 1024/"
variant "relay by tag"             "iroh-relay: image is pinned"                  "${rly} s#^(\s*)image: .*#\1image: docker.io/n0computer/iroh-relay:v1.3.0#"
variant "relay inline secret"      "iroh-relay: sets only allowed environment keys inline (extra: ACME_KEY)" "${rly} s/^(\s*)RUST_LOG: (.*)$/&\n\1ACME_KEY: x/"
variant "relay always on"          "iroh-relay: profiles are [relay]"             "${rly} {/^    profiles: \[relay\]$/d}"
# iroh-dns-server: the relay's exception and shape
variant "dns extra capability"     "iroh-dns-server: runs as uid 0 only with cap_add exactly [NET_BIND_SERVICE]" "${dns} s/cap_add: \[NET_BIND_SERVICE\]/cap_add: [NET_BIND_SERVICE, NET_RAW]/"
variant "dns root, no cap_add"     "iroh-dns-server: runs as uid 0 only with cap_add exactly [NET_BIND_SERVICE]" "${dns} {/^    cap_add: /d}"
variant "dns keeps capabilities"   "iroh-dns-server: cap_drop is [ALL]"           "${dns} ${h}cap_drop: []/"
variant "dns as root by name"      "iroh-dns-server: runs as a non-root uid:gid"  "${dns} s/^(\s*)user: .*/\1user: root/"
variant "dns SIGTERM"              "iroh-dns-server: stop_signal is SIGINT"       "${dns} s/^(\s*)stop_signal: SIGINT$/\1stop_signal: SIGTERM/"
variant "dns short grace"          "iroh-dns-server: stop_grace_period is 30s"    "${dns} s/^(\s*)stop_grace_period: 30s$/\1stop_grace_period: 5s/"
variant "dns writable config"      "iroh-dns-server: mounts are exactly"          "${dns} {/target: \/etc\/iroh-dns-server\/config.toml$/{n;s/read_only: true/read_only: false/}}"
variant "dns config directory"     "iroh-dns-server: mounts are exactly"          "${dns} s#^(\s*)(source|target): /etc/iroh-dns-server/config\.toml\$#\1\2: /etc/iroh-dns-server#"
variant "dns docker socket"        "iroh-dns-server: mounts are exactly"          "${dns} s#^(\s*)volumes:\$#\1volumes:\n\1  - {type: bind, source: /var/run/docker.sock, target: /var/run/docker.sock, read_only: true, bind: {create_host_path: false}}#"
variant "dns published port"       "iroh-dns-server: publishes no ports"          "${dns} ${h}ports: [\"53:53\/udp\"]/"
variant "dns bridge network"       "iroh-dns-server: network_mode is host"        "${dns} ${h}network_mode: bridge/"
variant "dns writable rootfs"      "iroh-dns-server: read_only rootfs"            "${dns} ${h}read_only: false/"
variant "dns privileged"           "iroh-dns-server: sets only allowed keys (extra: privileged)" "${dns} ${h}privileged: true/"
variant "dns entrypoint swap"      "iroh-dns-server: command is exactly"          "${dns} ${h}entrypoint: [\"\/bin\/sh\"]/"
variant "dns other config"         "iroh-dns-server: command is exactly"          "${dns} s#^(\s*)command: .*#\1command: [\"--config\", \"/tmp/config.toml\"]#"
variant "dns quiet log"            "iroh-dns-server: RUST_LOG is set"             "${dns} {/^      RUST_LOG: /d}"
variant "dns low fd limit"         "iroh-dns-server: ulimits.nofile is 65536"     "${dns} s/^(\s*)nofile: 65536$/\1nofile: 1024/"
variant "dns by tag"               "iroh-dns-server: image is pinned"             "${dns} s#^(\s*)image: .*#\1image: docker.io/n0computer/iroh-dns-server:v1.3.0#"
variant "dns inline secret"        "iroh-dns-server: sets only allowed environment keys inline (extra: ACME_KEY)" "${dns} s/^(\s*)RUST_LOG: (.*)$/&\n\1ACME_KEY: x/"
variant "dns always on"            "iroh-dns-server: profiles are [dns]"          "${dns} {/^    profiles: \[dns\]$/d}"

# alloy
variant "alloy writable host root" "alloy: mounts are exactly"                    "${aly} {/target: \/host\/root$/{n;s/read_only: true/read_only: false/}}"
variant "alloy root not rslave"    "alloy: the host root is mounted with rslave"  "${aly} s/propagation: rslave, //"
variant "caddy rshared state"     "caddy: only alloy's read-only host root sets a mount propagation" "${cdy} {/target: \/data$/{n;s/bind: \{create_host_path: false\}/bind: {propagation: rshared, create_host_path: false}/}}"
variant "alloy extra mount"        "alloy: mounts are exactly"                    "${aly} s#^(\s*)volumes:\$#&\n\1  - {type: bind, source: /etc/sponsord, target: /host/etc/sponsord, read_only: true, bind: {create_host_path: false}}#"
variant "alloy docker socket"      "alloy: mounts are exactly"                    "${aly} s#^(\s*)volumes:\$#&\n\1  - {type: bind, source: /var/run/docker.sock, target: /var/run/docker.sock, read_only: true, bind: {create_host_path: false}}#"
variant "alloy as root"            "alloy: runs as a non-root uid:gid"            "${aly} s/^(\s*)user: .*/\1user: \"0:0\"/"
variant "alloy root group"         "alloy: group_add is one non-root gid"         "${aly} s/^(\s*)- \".*JOURNAL_GID.*/\1- \"0\"/"
variant "alloy capability"         "alloy: sets only allowed keys (extra: cap_add)" "${aly} ${h}cap_add: [DAC_READ_SEARCH]/"
variant "alloy host pid"           "alloy: sets only allowed keys (extra: pid)"   "${aly} ${h}pid: host/"
variant "alloy published port"     "alloy: publishes no ports"                    "${aly} ${h}ports: [\"12345:12345\"]/"
variant "alloy UI on 0.0.0.0"      "alloy: --server.http.listen-addr is 127.x"    "${aly} s/listen-addr=127\.0\.0\.1:12345/listen-addr=0.0.0.0:12345/"
variant "alloy extra flag"         "alloy: command is exactly"                    "${aly} s#^(\s*)- /etc/alloy/config.alloy\$#\1- --config.format=static\n&#"
variant "alloy inline token"       "alloy: sets only allowed environment keys inline (extra: GC_API_TOKEN)" "${aly} s/^(\s*)ALLOY_REGION: (.*)$/&\n\1GC_API_TOKEN: glc_x/"
variant "alloy always on"          "alloy: profiles are [alloy]"                  "${aly} {/^    profiles: \[alloy\]$/d}"
variant "alloy journal gid default" "alloy: unset journal gid"                    "${aly} s/ALLOY_JOURNAL_GID:-unset-ALLOY_JOURNAL_GID/ALLOY_JOURNAL_GID:-101/"
variant "alloy uid default"        "alloy: unset uid/gid"                         "${aly} s/^(\s*)user: .*/\1user: \"\\\${ALLOY_UID:-996}:\\\${ALLOY_GID:-996}\"/"
# --- compose/decdn-compose: the wrapper's decisions (no root, no docker) -----------
expect 0 "decdn-compose unit tests pass" \
  env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$repo/compose/tests" -p 'test_*.py'
expect 2 "decdn-compose refuses an unknown command" "$repo/compose/decdn-compose" deploy

# --- lint-cloud-init negatives: each broken variant must be rejected -------------------
# Skipped without cloud-init on PATH, except in CI (which installs it), so a broken
# install step cannot quietly drop these cases.
if command -v cloud-init >/dev/null; then
  userdata="$repo/cloud-init/user-data-node.yaml"
  sponsorud="$repo/cloud-init/user-data-publisher.yaml"
  expect 0 "lint-cloud-init accepts both cloud-init/ templates" make -s -C "$repo" lint-cloud-init
  expect 0 "lint-cloud-init accepts the sponsor template alone" make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$sponsorud"
  sed '1s/^#cloud-config$/# cloud-config/' "$userdata" > "$work/ci-header.yaml"
  if make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-header.yaml" >"$work/out" 2>&1 \
    || ! grep -q 'is not a valid cloud-config' "$work/out"; then
    cat "$work/out" >&2; fail "lint-cloud-init did not reject a missing #cloud-config header as invalid"
  fi
  pass "lint-cloud-init rejects: no #cloud-config header (schema)"
  # <name> <expected message fragment> <sed expression> [<template>]: the fragment pins
  # WHICH invariant fired, since one edit can trip several. The template defaults to
  # the node's user-data-node.yaml.
  ci_variant() {
    # No spaces in the file name: CLOUD_INIT_FILE is a list.
    local src=${4:-$userdata} out="$work/ci-${1// /-}.yaml"
    sed -E "$3" "$src" > "$out"
    cmp -s "$src" "$out" && fail "variant $1 did not change ${src##*/}"
    if make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$out" >"$work/out" 2>&1; then
      fail "lint-cloud-init accepted: $1"
    fi
    grep -q 'violates an invariant' "$work/out" || { cat "$work/out" >&2; fail "lint-cloud-init failed for another reason: $1"; }
    grep -qF -- "$2" "$work/out" || { cat "$work/out" >&2; fail "lint-cloud-init rejected $1, but not with: $2"; }
    pass "lint-cloud-init rejects: $1"
  }
  ref='^(\s*)DEVOPS_REF=CHANGE_ME$'
  net='^(\s*)decdn_network: arbitrum-sepolia$'
  loc='^(\s*)ansible_connection: local$'
  stage1='^(\s*)- path: /usr/local/sbin/decdn-bootstrap$'
  # Secrets
  ci_variant "RPC URL in bootstrap.env"    'bootstrap.env: unexpected key DECDN_RPC_URL' "s#$ref#&\\n\\1DECDN_RPC_URL=https://rpc.example/key#"
  ci_variant "unknown bootstrap.env key"   'bootstrap.env: unexpected key FOO'           "s#$ref#&\\n\\1FOO=bar#"
  ci_variant "RPC URL in the inventory"    'decdn_nodes.vars.decdn_rpc_url looks secret-bearing' "s#$net#&\\n\\1decdn_rpc_url: https://rpc.example/#"
  ci_variant "decdn_extra_env"             'decdn_nodes.vars.decdn_extra_env looks secret-bearing' "s#$net#&\\n\\1decdn_extra_env: {AWS_REGION: eu-west-1}#"
  ci_variant "credentials in a URL"        'a URL with embedded credentials' 's#^(\s*)DEVOPS_REPO=https://#\1DEVOPS_REPO=https://user:pw@#'
  ci_variant "another write_files path"    'write_files writes /etc/decdn/decdn.env' "s#$stage1#\\1- path: /etc/decdn/decdn.env\\n\\1  content: FOO=bar\\n&#"
  ci_variant "b64-encoded content"         'decdn-bootstrap: encoding is not allowed' "s#$stage1#&\\n\\1  encoding: b64#"
  # write_files is checked entry by entry: a second entry for a checked path could fetch
  # stage 1 from a URL (no shellcheck) or append to the inventory (no pinned-var check).
  ci_variant "stage 1 fetched from a URL"  'decdn-bootstrap twice' "s#$stage1#\\1- path: /usr/local/sbin/decdn-bootstrap\\n\\1  source: {uri: \"https://x.example/stage1\"}\\n&#"
  ci_variant "appended inventory"          'inventory.yml: append is not allowed' "s#$stage1#\\1- path: /etc/decdn-bootstrap/inventory.yml\\n\\1  append: true\\n\\1  permissions: \"0600\"\\n\\1  content: \"decdn_nodes: {vars: {decdn_verify_release_signature: false}}\"\\n&#"
  ci_variant "empty stage 1"               'decdn-bootstrap: content must be non-empty text' '/^  - path: \/usr\/local\/sbin\/decdn-bootstrap$/,/^runcmd:$/ {/^      /s/^/#/; s/^    content: \|$/    content: ""/}'
  ci_variant "secret assigned in runcmd"   'assigns a secret-looking variable' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#&\n  - "GC_API_TOKEN=x /bin/true"#'
  # Hardening and the signed install
  ci_variant "the test-only baseline skip" 'mentions TEST-ONLY-skip-baseline' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - [touch, /etc/decdn-bootstrap/TEST-ONLY-skip-baseline]\n&#'
  ci_variant "manual install method"       'decdn_node_install_method must be release' 's/^(\s*)decdn_node_install_method: release$/\1decdn_node_install_method: manual/'
  ci_variant "source install method"       'decdn_node_install_method must be release' 's/^(\s*)decdn_node_install_method: release$/\1decdn_node_install_method: source/'
  ci_variant "no host-generated wallet"    'decdn_node_generate_keystore must be true' 's/^(\s*)decdn_node_generate_keystore: true(.*)$/\1decdn_node_generate_keystore: false\2/'
  ci_variant "signature off as a host var" 'set decdn_verify_release_signature only in decdn_nodes.vars' "s#$loc#&\\n\\1decdn_verify_release_signature: false#"
  ci_variant "install method as a host var" 'set decdn_node_install_method only in decdn_nodes.vars' "s#$loc#&\\n\\1decdn_node_install_method: manual#"
  ci_variant "signature off in its group"  'decdn_verify_release_signature must not be turned off' "s#$net#&\\n\\1decdn_verify_release_signature: false#"
  ci_variant "another inventory group"     'only the decdn_nodes, decdn_origin_nodes, sponsord_hosts, sponsord_onramp_hosts groups belong here' 's#^(\s*)decdn_nodes:$#\1all: {vars: {decdn_verify_release_signature: false}}\n&#'
  # Shape
  ci_variant "localhost outside decdn_nodes" 'localhost must be in decdn_nodes or sponsord_hosts' 's/^(\s*)decdn_nodes:$/\1decdn_hosts:/'
  ci_variant "admin account without keys"  'baseline_sudo_users needs at least one named account' '/^\s*keys:$/,+1d'
  ci_variant "stage 1 not run"             'runcmd must be exactly' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - [/bin/true]#'
  ci_variant "stage 1 failure masked"      'runcmd must be exactly' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - "/usr/local/sbin/decdn-bootstrap || true"#'
  # shellcheck disable=SC2016 # a literal $DEVOPS_REPO: the variant unquotes it in stage 1
  ci_variant "shellcheck-dirty stage 1"    'decdn-bootstrap fails shellcheck' 's#git clone --quiet --no-checkout "\$DEVOPS_REPO"#git clone --quiet --no-checkout $DEVOPS_REPO#'
  # The publisher host (user-data-publisher.yaml)
  spnet='^(\s*)sponsord_network: arbitrum-sepolia$'
  onproxy='^(\s*)sponsord_onramp_proxy: caddy$'
  ci_variant "sponsord RPC URL in the inventory" 'sponsord_hosts.vars.sponsord_rpc_url looks secret-bearing' "s#$spnet#&\\n\\1sponsord_rpc_url: https://rpc.example/#" "$sponsorud"
  ci_variant "SPONSORD_RPC_URL in bootstrap.env" 'bootstrap.env: unexpected key SPONSORD_RPC_URL' "s#$ref#&\\n\\1SPONSORD_RPC_URL=https://rpc.example/key#" "$sponsorud"
  ci_variant "Turnstile secret in the inventory" 'sponsord_onramp_turnstile_secret looks secret-bearing' "s#$onproxy#&\\n\\1sponsord_onramp_turnstile_secret: x#" "$sponsorud"
  ci_variant "credentials in the onramp RPC URL" 'a URL with embedded credentials' 's#^(\s*)sponsord_onramp_rpc_url: "CHANGE_ME"$#\1sponsord_onramp_rpc_url: "https://user:key@rpc.example/"#' "$sponsorud"
  ci_variant "sponsord manual install"     'sponsord_install_method must be release' 's/^(\s*)sponsord_install_method: release$/\1sponsord_install_method: manual/' "$sponsorud"
  ci_variant "sponsord source install"     'sponsord_install_method must be release' 's/^(\s*)sponsord_install_method: release$/\1sponsord_install_method: source/' "$sponsorud"
  ci_variant "onramp manual install"       'sponsord_onramp_install_method must be release' 's/^(\s*)sponsord_onramp_install_method: release$/\1sponsord_onramp_install_method: manual/' "$sponsorud"
  ci_variant "sponsord signature off as a host var" 'set sponsord_verify_release_signature only in sponsord_hosts.vars' "s#$loc#&\\n\\1sponsord_verify_release_signature: false#" "$sponsorud"
  ci_variant "onramp pin in another group" 'set sponsord_onramp_install_method only in sponsord_onramp_hosts.vars' "s#$spnet#&\\n\\1sponsord_onramp_install_method: release#" "$sponsorud"
  ci_variant "sponsord signature off in its group" 'sponsord_verify_release_signature must not be turned off' "s#$spnet#&\\n\\1sponsord_verify_release_signature: false#" "$sponsorud"
  ci_variant "onramp signature off in its group" 'sponsord_onramp_verify_release_signature must not be turned off' "s#$onproxy#&\\n\\1sponsord_onramp_verify_release_signature: false#" "$sponsorud"
  # Every knob lint.py forbids: a signing key, a secret's path (the bootstrap's gate
  # looks for each at its default), or a generation knob the gate makes moot. Read
  # from lint.py, so a new entry is covered here too.
  forbidden="$(cd "$repo/cloud-init/tests" && python3 -B -c 'import lint; print(*sorted(lint.FORBIDDEN_VARS))')"
  [[ -n $forbidden ]] || fail "could not read FORBIDDEN_VARS from cloud-init/tests/lint.py"
  # The loop below cannot notice an entry dropped from lint.py, so the knobs that must
  # be there are found independently: every role's *_release_keyring, every role
  # default holding a path in bootstrap.sh's SECRETS, and the directories and the
  # templated Turnstile path those paths derive from.
  must=(sponsord_etc sponsord_onramp_etc sponsord_onramp_turnstile_secret_file)
  mapfile -t -O "${#must[@]}" must < <(grep -ohE '^[a-z_]+_release_keyring:' "$repo"/ansible/roles/*/defaults/main.yml | tr -d :)
  # shellcheck disable=SC2013 # SECRETS values are space-separated paths, split on purpose
  for f in $(sed -nE 's/^  \[[a-z_]+\]="?([^"]*)"?$/\1/p' "$repo/cloud-init/bootstrap.sh"); do
    k="$(grep -ohE "^[a-z_]+: \"?$f\"?([[:space:]]|$)" "$repo"/ansible/roles/*/defaults/main.yml | cut -d: -f1 || true)"
    [[ -n $k || $f == */turnstile-secret ]] || fail "no role default holds bootstrap.sh's secret path $f"
    [[ -z $k ]] || must+=("$k")
  done
  ((${#must[@]} >= 9)) || fail "found only ${#must[@]} knobs lint.py must forbid: ${must[*]}"
  for k in "${must[@]}"; do
    [[ " $forbidden " == *" $k "* ]] || fail "cloud-init/tests/lint.py FORBIDDEN_VARS is missing $k"
  done
  pass "lint.py forbids every release keyring and every secret path the bootstrap gate checks"
  for v in $forbidden; do
    if [[ $v == decdn_* ]]; then
      ci_variant "forbidden $v" "$v may not be overridden" "s#$net#&\\n\\1$v: /tmp/x#"
    else
      ci_variant "forbidden $v" "$v may not be overridden" "s#$spnet#&\\n\\1$v: /tmp/x#" "$sponsorud"
    fi
  done
  ci_variant "onramp without sponsord_hosts" 'sponsord_onramp_hosts needs sponsord_hosts too' 's/^(\s*)sponsord_hosts:$/\1molecule_hosts:/' "$sponsorud"
  ci_variant "an origin without decdn_nodes" 'decdn_origin_nodes needs decdn_nodes too' 's/^(\s*)decdn_nodes:$/\1molecule_nodes:/' "$sponsorud"
  ci_variant "an origin without a backend" 'decdn_origin_nodes.vars needs an origin backend' '/^\s*decdn_cache_origin_(kind|url):/d' "$sponsorud"
  ci_variant "an http origin without a URL" 'an origin of kind http needs decdn_cache_origin_url' '/^\s*decdn_cache_origin_url:/d' "$sponsorud"
  ci_variant "an unknown origin kind" "decdn_cache_origin_kind is 'htp', not http, fs or s3" 's/^(\s*)decdn_cache_origin_kind: http$/\1decdn_cache_origin_kind: htp/' "$sponsorud"
  ci_variant "an s3 origin without a region" 'an origin of kind s3 needs decdn_cache_origin_s3_bucket and decdn_cache_origin_s3_region' 's/^(\s*)decdn_cache_origin_kind: http$/\1decdn_cache_origin_kind: s3\n\1decdn_cache_origin_s3_bucket: b/' "$sponsorud"
  ci_variant "an empty origin in the list" 'decdn_cache_origins[0] needs a kind of http, fs or s3' '/^\s*decdn_cache_origin_url:/d; s/^(\s*)decdn_cache_origin_kind: http$/\1decdn_cache_origins: [{}]/' "$sponsorud"
  ci_variant "a list origin without its path" 'decdn_cache_origins[0] (fs) needs path' '/^\s*decdn_cache_origin_url:/d; s/^(\s*)decdn_cache_origin_kind: http$/\1decdn_cache_origins: [{kind: fs}]/' "$sponsorud"
  # The sponsord_* groups and host vars outrank decdn_origin_nodes.vars, so the backend
  # the lint checks there must be the only one.
  ci_variant "an origin backend emptied in sponsord_hosts" 'set decdn_cache_origin_kind only in decdn_origin_nodes.vars' "s#$spnet#&\\n\\1decdn_cache_origin_kind: \"\"#" "$sponsorud"
  ci_variant "an origin backend as a host var" 'set decdn_cache_origin_url only in decdn_origin_nodes.vars' "s#$loc#&\\n\\1decdn_cache_origin_url: https://other.example/#" "$sponsorud"
  ci_variant "an optional backend key in sponsord_hosts" 'set decdn_cache_origin_s3_endpoint_url only in decdn_origin_nodes.vars' "s#$spnet#&\\n\\1decdn_cache_origin_s3_endpoint_url: https://s3.other.example#" "$sponsorud"
  ci_variant "a backend on a cache node"   'set decdn_cache_origins only in decdn_origin_nodes.vars' "s#$net#&\\n\\1decdn_cache_origins: [{kind: fs, path: /srv}]#"
  ci_variant "an origin node built from source" 'decdn_node_install_method must be release' 's/^(\s*)decdn_node_install_method: release$/\1decdn_node_install_method: source/' "$sponsorud"
  ci_variant "S3 keys in the origin vars" 'decdn_origin_nodes.vars.decdn_extra_env looks secret-bearing' 's/^(\s*)decdn_cache_origin_kind: http$/&\n\1decdn_extra_env: {AWS_SECRET_ACCESS_KEY: x}/' "$sponsorud"
  ci_variant "a second connection"         "sponsord_onramp_hosts.hosts.localhost.ansible_connection is 'ssh'" '/^\s*sponsord_onramp_hosts:$/,/^\s*vars:$/ s/^(\s*)localhost:$/&\n\1  ansible_connection: ssh/' "$sponsorud"
  ci_variant "hosts as a list"             'sponsord_onramp_hosts must hold exactly localhost' '/^\s*sponsord_onramp_hosts:$/,/^\s*vars:$/ {s/^(\s*)hosts:$/\1hosts: [localhost]/; /^\s*localhost:$/d}' "$sponsorud"
  ci_variant "the inventory as a list"     'inventory: must be a mapping of groups, not a list' 's/^(\s*)decdn_nodes:$/\1- decdn_nodes:/'
  ci_variant "no connection at all"         'localhost needs ansible_connection: local' '/^\s*ansible_connection: local$/d'
  # The lint reads YAML through yq, cloud-init through PyYAML and Ansible its own way:
  # an anchor merged into a mapping (`<<: *x`) can read one way here and another on
  # the host. And any module besides the templates' own runs code this never sees,
  # e.g. a bootcmd that writes the test-only switch from pieces.
  ci_variant "a bootcmd"                    'bootcmd: only the top-level keys' 's#^runcmd:$#bootcmd:\n  - [sh, -c, "true"]\n&#'
  ci_variant "an anchor in the user-data"   'the user-data uses YAML anchors or aliases' 's#^(\s*)- path: /etc/decdn-bootstrap/bootstrap.env$#\1- \&env\n\1  path: /etc/decdn-bootstrap/bootstrap.env#'
  ci_variant "an alias in the inventory"   'inventory: uses YAML anchors or aliases' "s#$net#&\\n\\1x: \\&r 1\\n\\1y: *r#"
  ci_variant "another host in the onramp group" 'sponsord_onramp_hosts must hold exactly localhost' '/^\s*sponsord_onramp_hosts:$/,/^\s*vars:$/ s/^(\s*)localhost:$/&\n\1other.example:/' "$sponsorud"
  # A node and a sponsor on one host: the node template plus the sponsord groups.
  sed -E 's/^(\s*)decdn_region: .*$/&\n      sponsord_hosts:\n        hosts:\n          localhost:\n        vars:\n          sponsord_install_method: release\n          sponsord_version: "0.1.0"\n      sponsord_onramp_hosts:\n        hosts:\n          localhost:\n        vars:\n          sponsord_onramp_install_method: release\n          sponsord_onramp_version: "0.1.0"/' \
    "$userdata" > "$work/ci-colocated.yaml"
  expect 0 "lint-cloud-init accepts a node co-located with sponsord" \
    make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-colocated.yaml"
  # The publisher template cut down as its header says: a sponsor alone (the admin
  # account moved into sponsord_hosts' vars) and an origin alone.
  sed -E '/^      decdn_nodes:$/,/^      sponsord_hosts:$/{/^      sponsord_hosts:$/!d}
    s/^(\s*)sponsord_network: arbitrum-sepolia$/&\n\1baseline_sudo_users: [{name: alice, keys: ["ssh-ed25519 AAAA alice"]}]\n\1baseline_sudo_autodetect_runner: false/' \
    "$sponsorud" > "$work/ci-sponsor-alone.yaml"
  grep -q '^      decdn_nodes:$' "$work/ci-sponsor-alone.yaml" && fail "the sponsor-alone variant kept decdn_nodes"
  expect 0 "lint-cloud-init accepts the publisher template as a sponsor alone" \
    make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-sponsor-alone.yaml"
  sed -E '/^      sponsord_hosts:$/,/^$/d; /^      # The onramp runs beside/,/^$/d' "$sponsorud" > "$work/ci-origin-alone.yaml"
  grep -qE '^      sponsord_(onramp_)?hosts:$' "$work/ci-origin-alone.yaml" && fail "the origin-alone variant kept a sponsord group"
  expect 0 "lint-cloud-init accepts the publisher template as an origin alone" \
    make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-origin-alone.yaml"
  ci_variant "one sponsord version moved" 'set sponsord_version and sponsord_onramp_version together' 's/^(\s*)sponsord_onramp_install_method: release$/&\n\1sponsord_onramp_version: "0.0.9"/' "$sponsorud"
  ci_variant "an onramp pin without its digest" 'set all of sponsord_onramp_decdn_release' 's/^(\s*)sponsord_onramp_install_method: release$/&\n\1sponsord_onramp_cli_release: v0.0.9/' "$sponsorud"
  ci_variant "onramp nested under children" 'sponsord_hosts may hold only hosts and vars, not' '/^      sponsord_onramp_hosts:$/,/^$/{s/^      /          /}; s/^          sponsord_onramp_hosts:$/        children:\n&/' "$sponsorud"
  ci_variant "query in the onramp RPC URL" 'sponsord_onramp_rpc_url must be a public http(s) URL' 's#^(\s*)sponsord_onramp_rpc_url: "CHANGE_ME"$#\1sponsord_onramp_rpc_url: "https://rpc.example/?api_key=x"#' "$sponsorud"
  ci_variant "fragment in the onramp RPC URL" 'sponsord_onramp_rpc_url must be a public http(s) URL' 's#^(\s*)sponsord_onramp_rpc_url: "CHANGE_ME"$#\1sponsord_onramp_rpc_url: "https://rpc.example/rpc\#k"#' "$sponsorud"
  ci_variant "onramp RPC URL in another group" 'set sponsord_onramp_rpc_url only in sponsord_onramp_hosts.vars' "s#$spnet#&\\n\\1sponsord_onramp_rpc_url: https://rpc.example/#" "$sponsorud"
  expect 0 "lint-cloud-init accepts a public onramp RPC URL" make -s -C "$repo" lint-cloud-init \
    CLOUD_INIT_FILE="$(sed -E 's#^(\s*)sponsord_onramp_rpc_url: "CHANGE_ME"$#\1sponsord_onramp_rpc_url: "https://sepolia-rollup.arbitrum.io/rpc"#' "$sponsorud" > "$work/ci-public-rpc.yaml"; echo "$work/ci-public-rpc.yaml")"
  # Ansible applies one baseline_sudo_users list, never the union of two groups'.
  ci_variant "two admin lists" 'set baseline_sudo_users in one place' 's/^(\s*)sponsord_onramp_install_method: release$/&\n\1baseline_sudo_users: [{name: bob, keys: ["ssh-ed25519 AAAA bob"]}]/' "$sponsorud"
  # The Makefile itself: an empty list checks nothing, and a bad file fails the whole list.
  expect 2 "lint-cloud-init refuses an empty CLOUD_INIT_FILE" make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE=
  if make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-stage-1-not-run.yaml $userdata" >"$work/out" 2>&1; then
    fail "lint-cloud-init accepted a list whose first file is broken"
  fi
  grep -qF 'runcmd must be exactly' "$work/out" || { cat "$work/out" >&2; fail "lint-cloud-init failed the list for another reason"; }
  pass "lint-cloud-init fails a list whose first file is broken"
  # Non-secret knobs whose names look secret must still pass.
  sed -E "s#$net#&\\n\\1baseline_sudo_passwordless: false\\n\\1decdn_keystore_file: /var/lib/decdn/keystore.json#" \
    "$userdata" > "$work/ci-knobs.yaml"
  expect 0 "lint-cloud-init accepts non-secret knobs with secret-looking names" \
    make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-knobs.yaml"
elif [[ -n ${CI:-} ]]; then
  fail "cloud-init is not on PATH in CI; the lint-cloud-init negatives would be skipped"
else
  skipped+=("lint-cloud-init negatives (needs cloud-init on PATH; CI installs it)")
fi

# --- cloud-init's baseline guard: per play, not over the whole playbook (#90) ---------
# bootstrap.sh feeds cloud-init/baseline-plays.awk the output of
# `site.yml --tags baseline --list-hosts --list-tasks`. These fixtures follow that output
# for a sponsor-only host. The node's play lists baseline tasks but no host, so it must
# not vouch for the sponsord play.
plays_out() { # <sponsord play's task lines>
  printf '\nplaybook: playbooks/site.yml\n\n'
  printf "  play #1 (decdn_nodes): Provision a hardened deCDN node\tTAGS: []\n    pattern: ['decdn_nodes']\n    hosts (0):\n    tasks:\n"
  printf '      baseline : Install base packages\tTAGS: [baseline]\n\n'
  printf "  play #2 (sponsord_onramp_hosts): Require every sponsord-onramp host to be a sponsord host\tTAGS: []\n    pattern: ['sponsord_onramp_hosts']\n    hosts (1):\n      localhost\n    tasks:\n\n"
  printf "  play #3 (sponsord_hosts): Provision sponsord\tTAGS: []\n    pattern: ['sponsord_hosts']\n    hosts (1):\n      localhost\n    tasks:\n%b\n" "$1"
}
guard_plays() { # <groups> <sponsord play's task lines>
  plays_out "$2" | awk -v groups="$1" -f "$repo/cloud-init/baseline-plays.awk"
}
hardened='      baseline : Install base packages\tTAGS: [baseline]\n      Apply DevSec OS hardening\tTAGS: [baseline]'
expect 0 "baseline guard accepts a sponsor host whose play selects baseline" guard_plays sponsord_hosts "$hardened"
expect 1 "baseline guard refuses a sponsord play without baseline (another play's tasks do not count)" \
  guard_plays sponsord_hosts '      Apply DevSec OS hardening\tTAGS: [baseline]'
grep -q 'a play for sponsord_hosts selects no baseline task' "$work/out" \
  || { cat "$work/out" >&2; fail "the baseline guard refused, but not for sponsord_hosts' play"; }
expect 1 "baseline guard refuses a group whose play does not list localhost" \
  guard_plays "decdn_nodes sponsord_hosts" "$hardened"
grep -q 'no play targets decdn_nodes with localhost in it' "$work/out" \
  || { cat "$work/out" >&2; fail "the baseline guard refused, but not for decdn_nodes"; }
expect 2 "baseline guard refuses an empty group list" guard_plays "" "$hardened"
# A play's pattern counts for its positive terms only: node.yml's
# decdn_nodes:!decdn_origin_nodes play is a decdn_nodes play, never an origin one.
excl_out() { # <decdn_nodes play's task lines>
  printf "  play #1 (decdn_nodes:!decdn_origin_nodes): Provision deCDN cache nodes\tTAGS: []\n    pattern: ['decdn_nodes:!decdn_origin_nodes']\n    hosts (1):\n      localhost\n    tasks:\n%b\n" "$1"
}
excl_plays() { excl_out "$2" | awk -v groups="$1" -f "$repo/cloud-init/baseline-plays.awk"; }
expect 0 "baseline guard counts a decdn_nodes:!decdn_origin_nodes play for decdn_nodes" excl_plays decdn_nodes "$hardened"
expect 1 "baseline guard does not count an excluded group's play" excl_plays decdn_origin_nodes "$hardened"
grep -q 'no play targets decdn_origin_nodes with localhost in it' "$work/out" \
  || { cat "$work/out" >&2; fail "the baseline guard counted the exclusion as a decdn_origin_nodes play"; }
expect 1 "baseline guard refuses a bare decdn_nodes:!decdn_origin_nodes play" \
  excl_plays decdn_nodes '      Apply DevSec OS hardening\tTAGS: [baseline]'
# bootstrap.sh's gate and lint.py agree on the groups a user-data may use, and the
# bootstrap's hint has its own instructions for each.
boot="$repo/cloud-init/bootstrap.sh"
host_groups="$(sed -nE 's/^readonly HOST_GROUPS=\((.*)\)$/\1/p' "$boot")"
[[ -n $host_groups ]] || fail "cloud-init/bootstrap.sh: no HOST_GROUPS"
[[ "$host_groups" == "$(cd "$repo/cloud-init/tests" && python3 -B -c 'import lint; print(*lint.GROUPS)')" ]] \
  || fail "cloud-init/bootstrap.sh HOST_GROUPS ($host_groups) differs from lint.py's GROUPS"
for g in $host_groups; do
  grep -qE "^  \[$g\]=" "$boot" || fail "cloud-init/bootstrap.sh: no SECRETS entry for $g"
  # A group with no secrets of its own (decdn_origin_nodes) is never missing one, so
  # it needs no instructions.
  grep -qE "^  \[$g\]=\"\"$" "$boot" && continue
  grep -qE "^    $g\)$" "$boot" || fail "cloud-init/bootstrap.sh: the hint has no case arm for $g"
done
pass "bootstrap.sh's groups match lint.py's, each with its secrets and, if it has any, its hint"
# The same contract, read from the playbooks with nothing booted. The molecule boots
# run the guard too, but in Docker and only for the groups their inventories use.
# `hosts` and `tags` may each be a string or a list; tags match exactly.
if command -v yq >/dev/null; then
  for g in decdn_nodes decdn_origin_nodes sponsord_hosts; do
    n=0
    for pb in node.yml origin.yml sponsord.yml; do
      # A play's positive pattern terms: decdn_nodes:!decdn_origin_nodes targets
      # decdn_nodes only.
      plays="[.[] | select([.hosts] | flatten | map(split(\":\")) | flatten | map(split(\",\")) | flatten | any_c(. == \"$g\"))]"
      n=$((n + $(yq "$plays | length" "$repo/ansible/playbooks/$pb")))
      [[ "$(yq "$plays | map(select((.roles // []) | map(select(.role == \"baseline\" and ([.tags // []] | flatten | any_c(. == \"baseline\")))) | length == 0)) | length" "$repo/ansible/playbooks/$pb")" == 0 ]] \
        || fail "playbooks/$pb: a $g play lacks the baseline role tagged baseline (cloud-init's phase 1 relies on it)"
    done
    ((n >= 1)) || fail "no play in node.yml, origin.yml or sponsord.yml targets $g"
  done
  pass "every decdn_nodes, decdn_origin_nodes and sponsord_hosts play runs baseline under the baseline tag"
  # baseline-plays.sh, the command bootstrap.sh runs, against the real playbooks and the
  # templates' inventories, then against a copy whose sponsord play lost the tag (#90).
  # Listing tasks needs ansible-core only, not the collections.
  if command -v ansible-playbook >/dev/null; then
    for t in user-data-node:decdn_nodes user-data-publisher:sponsord_hosts; do
      yq '.write_files[] | select(.path == "/etc/decdn-bootstrap/inventory.yml") | .content' \
        "$repo/cloud-init/${t%%:*}.yaml" > "$work/${t%%:*}-inventory.yml"
    done
    bplays() { # <ansible dir> <inventory> <group>...
      local dir=$1; shift
      (cd "$dir" && HOME="$work" ANSIBLE_DEPRECATION_WARNINGS=0 "$repo/cloud-init/baseline-plays.sh" "$@" </dev/null)
    }
    expect 0 "baseline-plays.sh accepts the node template's host" bplays "$repo/ansible" "$work/user-data-node-inventory.yml" decdn_nodes
    # The publisher's origin runs origin.yml's play, not node.yml's: bootstrap.sh
    # passes decdn_origin_nodes for it, and decdn_nodes would find no play.
    expect 0 "baseline-plays.sh accepts the publisher template's host" \
      bplays "$repo/ansible" "$work/user-data-publisher-inventory.yml" decdn_origin_nodes sponsord_hosts
    expect 1 "baseline-plays.sh finds no cache-node play for the publisher's origin" \
      bplays "$repo/ansible" "$work/user-data-publisher-inventory.yml" decdn_nodes
    grep -q 'no play targets decdn_nodes with localhost in it' "$work/out" \
      || { cat "$work/out" >&2; fail "baseline-plays.sh refused the origin as a cache node, but not for decdn_nodes"; }
    mkdir -p "$work/notag"
    cp -r "$repo/ansible/playbooks" "$repo/ansible/ansible.cfg" "$work/notag/"
    ln -s "$repo/ansible/roles" "$work/notag/roles"
    yq -i '(.[] | select(.hosts == "sponsord_hosts") | .roles[] | select(.role == "baseline")) |= del(.tags)' \
      "$work/notag/playbooks/sponsord.yml"
    expect 1 "baseline-plays.sh refuses a sponsord play that lost its baseline tag (#90)" \
      bplays "$work/notag" "$work/user-data-publisher-inventory.yml" sponsord_hosts
    grep -q 'a play for sponsord_hosts selects no baseline task' "$work/out" \
      || { cat "$work/out" >&2; fail "baseline-plays.sh refused, but not for sponsord_hosts' play"; }
  elif [[ -n ${CI:-} ]]; then
    fail "ansible-playbook is not on PATH in CI; the baseline-plays.sh cases would be skipped"
  else
    skipped+=("baseline-plays.sh against the real playbooks (needs ansible-core)")
  fi
  # The two templates differ only in their inventory: stage 1, the login hint and the
  # final message are the same bytes in both.
  shared='{"files": [.write_files[] | select(.path == "/usr/local/sbin/decdn-bootstrap" or .path == "/etc/profile.d/decdn-bootstrap.sh")], "final_message": .final_message}'
  node_shared="$(yq -o=json "$shared" "$repo/cloud-init/user-data-node.yaml")"
  [[ "$(yq '.files | length' <<<"$node_shared")" == 2 && "$(yq '.final_message | length > 0' <<<"$node_shared")" == true ]] \
    || fail "cloud-init/user-data-node.yaml: stage 1, the login hint or final_message not found"
  [[ "$node_shared" == "$(yq -o=json "$shared" "$repo/cloud-init/user-data-publisher.yaml")" ]] \
    || fail "cloud-init/user-data-node.yaml and user-data-publisher.yaml differ in stage 1, the login hint or final_message"
  pass "the cloud-init templates share stage 1, the login hint and final_message byte for byte"
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the baseline-tag check would be skipped"
else
  skipped+=("baseline-tag check (needs yq)")
fi

# --- the shared pieces stay identical across roles ---------------------------------
# decdn_build_user/home and the rustup pins are defined in all three roles' defaults
# (one build user and toolchain per host), as are the decommission cap and prompt
# timeout (one typed confirmation per host), and the root-side installer is copied
# into decdn_node and sponsord (sponsord_onramp uses sponsord's).
shared_keys() { # <defaults file>
  grep -E '^(decdn_build_user|decdn_build_home|decdn_rustup_version|decdn_rustup_sha256|decdn_decommission_max_hosts|decdn_decommission_prompt_seconds):|^  (x86_64|aarch64)-unknown-linux-gnu:' "$1"
}
want=$(shared_keys "$repo/ansible/roles/decdn_node/defaults/main.yml")
for r in sponsord sponsord_onramp; do
  [ "$(shared_keys "$repo/ansible/roles/$r/defaults/main.yml")" = "$want" ] \
    || fail "$r/defaults/main.yml: decdn_build_* / decdn_rustup_* / decdn_decommission_* differ from decdn_node's"
done
cmp -s "$repo/ansible/roles/decdn_node/files/install-build-output.py" \
       "$repo/ansible/roles/sponsord/files/install-build-output.py" \
  || fail "decdn_node and sponsord files/install-build-output.py differ"
pass "source-build and decommission defaults, and the installer, identical across roles"
# iroh_relay and iroh_dns_server have no source build (and their own per-triple
# sha256 pins), so only their decommission keys are compared.
decom_keys() { grep -E '^decdn_decommission_(max_hosts|prompt_seconds):' "$1" || true; }
want_decom="$(decom_keys "$repo/ansible/roles/decdn_node/defaults/main.yml")"
[ "$(grep -c . <<<"$want_decom")" -eq 2 ] \
  || fail "decdn_node/defaults/main.yml: expected both decdn_decommission_* keys, found: $want_decom"
for r in iroh_relay iroh_dns_server; do
  [ "$(decom_keys "$repo/ansible/roles/$r/defaults/main.yml")" = "$want_decom" ] \
    || fail "$r/defaults/main.yml: decdn_decommission_* differ from decdn_node's"
done
# One confirmation names every service the run stops, so each role's prompt must
# know every group decommission.yml covers.
for r in decdn_node sponsord sponsord_onramp iroh_relay iroh_dns_server; do
  for g in decdn_nodes iroh_relay_hosts iroh_dns_server_hosts sponsord_onramp_hosts sponsord_hosts; do
    grep -qF "if '$g' in _decom_groups" "$repo/ansible/roles/$r/tasks/decommission.yml" \
      || fail "$r/tasks/decommission.yml: the confirmation prompt does not name $g's service"
  done
done
pass "the decommission defaults and the confirmation's service list agree across all five roles"

# --- the release pins agree ----------------------------------------------------------
# decdn/sponsord releases sponsord and sponsord-onramp from one tag, and the onramp's
# installers should hand users the decdn the node role deploys. The pins are copied
# into compose/sponsord-onramp.env.example and the chart's appVersion; the chart
# check is here, not in lint-helm, so a PR that bumps only the role still runs it.
pin() { # <role> <var>: a scalar default, quotes stripped
  sed -nE "s/^$2: *\"?([^\" #]*)\"?.*/\1/p" "$repo/ansible/roles/$1/defaults/main.yml"
}
envpin() { sed -nE "s/^$1=//p" "$repo/compose/sponsord-onramp.env.example"; }
for p in "decdn_node decdn_node_version" "sponsord sponsord_version" "sponsord_onramp sponsord_onramp_version"; do
  # shellcheck disable=SC2086  # "<role> <var>", split on purpose
  [ -n "$(pin $p)" ] || fail "${p#* }: no default in roles/${p% *}/defaults/main.yml"
done
[ "$(pin sponsord sponsord_version)" = "$(pin sponsord_onramp sponsord_onramp_version)" ] \
  || fail "sponsord_version and sponsord_onramp_version differ (one decdn/sponsord release ships both)"
[ "$(pin sponsord_onramp sponsord_onramp_cli_release)" = "v$(pin sponsord sponsord_version)" ] \
  || fail "sponsord_onramp_cli_release is not v<sponsord_version>"
[ "$(pin sponsord_onramp sponsord_onramp_decdn_release)" = "v$(pin decdn_node decdn_node_version)" ] \
  || fail "sponsord_onramp_decdn_release is not v<decdn_node_version>"
for k in DECDN_RELEASE:decdn_release DECDN_SUMS_SHA256:decdn_sums_sha256 \
         CLI_RELEASE:cli_release CLI_SUMS_SHA256:cli_sums_sha256; do
  [ "$(envpin "ONRAMP_${k%%:*}")" = "$(pin sponsord_onramp "sponsord_onramp_${k#*:}")" ] \
    || fail "compose/sponsord-onramp.env.example ONRAMP_${k%%:*} differs from sponsord_onramp_${k#*:}"
done
app="$(sed -nE 's/^appVersion: *"?([^" #]*)"?.*/\1/p' "$repo/charts/decdn-node/Chart.yaml")"
[ "$app" = "$(pin decdn_node decdn_node_version)" ] \
  || fail "charts/decdn-node/Chart.yaml appVersion '$app' is not decdn_node_version"
# compose.yaml pins n0's iroh images by digest, with the release they are named in
# the comment above each image line; it must be the release the roles install. The
# wrapper's DNS_VERSION (the DNS server has no --version; health reads /healthz) too.
for p in "iroh_relay iroh-relay" "iroh_dns_server iroh-dns-server"; do
  role="${p% *}" img="${p#* }"
  named="$(sed -nE "s#.*n0computer/$img v([0-9][0-9.]*[0-9]).*#\1#p" "$repo/compose/compose.yaml")"
  want="$(pin "$role" "${role}_version")"
  # Two empty strings agree: a missing comment or pin must not.
  if [ -z "$named" ] || [ -z "$want" ]; then
    fail "no n0computer/$img version in compose/compose.yaml, or no ${role}_version"
  fi
  [ "$named" = "$want" ] \
    || fail "compose/compose.yaml names n0computer/$img v$named, not ${role}_version $(pin "$role" "${role}_version")"
  grep -qE "image: \\$\\{[A-Z_]+:-docker\.io/n0computer/$img\}@\\$\\{[A-Z_]+:-sha256:[0-9a-f]{64}\}$" "$repo/compose/compose.yaml" \
    || fail "compose/compose.yaml: n0computer/$img is not pinned by a default digest"
done
dns_version="$(sed -nE 's/^DNS_VERSION = "([^"]*)"$/\1/p' "$repo/compose/decdn-compose")"
[ -n "$dns_version" ] || fail "compose/decdn-compose has no DNS_VERSION"
[ "$dns_version" = "$(pin iroh_dns_server iroh_dns_server_version)" ] \
  || fail "compose/decdn-compose DNS_VERSION is not iroh_dns_server_version"
# Artifact Hub scans the images the annotation lists, so it must name the one the
# chart deploys by default.
if command -v yq >/dev/null; then
  ah_images="$(yq '.annotations["artifacthub.io/images"]' "$repo/charts/decdn-node/Chart.yaml" | yq -o=json -I0 '[.[].image]')" \
    || fail "charts/decdn-node/Chart.yaml: cannot read the artifacthub.io/images annotation"
  [ "$ah_images" = "[\"ghcr.io/decdn/decdn-node:$app\"]" ] \
    || fail "charts/decdn-node/Chart.yaml artifacthub.io/images is $ah_images, not [ghcr.io/decdn/decdn-node:$app]"
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the artifacthub.io/images check would be skipped"
else
  skipped+=("artifacthub.io/images check (needs yq)")
fi
# Both vendored KEYS hold the same maintainer keys (they differ in header text only),
# and those are the fingerprints SECURITY.md publishes, so swapping a key takes a
# visible edit there too.
command -v gpg >/dev/null || fail "gpg is required (the vendored KEYS checks)"
fprs() { # <KEYS file>: its primary-key fingerprints, sorted
  local out
  out="$(gpg --show-keys --with-colons "$1")" || fail "gpg --show-keys failed on $1"
  awk -F: '$1 == "pub" {p = 1} $1 == "fpr" && p {print $10; p = 0}' <<<"$out" | sort
}
want_fprs="$(fprs "$repo/ansible/roles/decdn_node/files/decdn-release-KEYS.asc")"
[ -n "$want_fprs" ] || fail "decdn_node/files/decdn-release-KEYS.asc: no keys"
[ "$(fprs "$repo/ansible/roles/sponsord/files/sponsord-release-KEYS.asc")" = "$want_fprs" ] \
  || fail "the decdn and sponsord release KEYS hold different keys"
[ "$(sed -nE 's/^Fingerprint: *//p' "$repo/SECURITY.md" | tr -d ' ' | sort)" = "$want_fprs" ] \
  || fail "SECURITY.md's Fingerprint: lines differ from the vendored KEYS"
pass "release pins agree across roles, Compose (incl. its iroh images), the chart and its artifacthub.io/images; the vendored KEYS match SECURITY.md"
# Compose's Alloy image is the release the grafana_alloy role installs: the comment
# above its digest names the tag the digest was taken from.
alloy_tag="$(sed -nE 's|^ *# grafana/alloy v([0-9][0-9.]*), the grafana_alloy role.*|\1|p' "$repo/compose/compose.yaml")"
[ -n "$alloy_tag" ] || fail "compose/compose.yaml: no '# grafana/alloy v<version>, the grafana_alloy role…' comment above the alloy image"
[ "$alloy_tag" = "$(pin grafana_alloy grafana_alloy_version)" ] \
  || fail "compose/compose.yaml pins grafana/alloy v$alloy_tag, but grafana_alloy_version is $(pin grafana_alloy grafana_alloy_version): re-pin the image's index digest"
pass "Compose's grafana/alloy image is grafana_alloy_version"
# compose/alloy/config.alloy is generated from the grafana_alloy role's template.
if command -v ansible-playbook >/dev/null; then
  expect 0 "compose/alloy/config.alloy is a fresh render of the grafana_alloy template" \
    "$repo/scripts/render-compose-alloy.sh" --check
elif [[ -n ${CI:-} ]]; then
  fail "ansible-playbook is not on PATH in CI; the compose/alloy/config.alloy mirror check would be skipped"
else
  skipped+=("compose/alloy/config.alloy mirror check (needs ansible-core)")
fi
# iroh_relay's tasks_from node-ids runs `decdn whoami` on the inventory's nodes, where
# decdn_node's defaults are not loaded: its fallbacks must be those defaults.
ids="$repo/ansible/roles/iroh_relay/tasks/node-ids.yml"
node_defaults="$repo/ansible/roles/decdn_node/defaults/main.yml"
for key in decdn_user decdn_cli_bin decdn_config_file; do
  want="$(sed -nE "s/^$key: ([^[:space:]#]+).*/\1/p" "$node_defaults")"
  [ -n "$want" ] || fail "decdn_node/defaults/main.yml: no $key"
  grep -qF "hostvars[item].$key | default('$want')" "$ids" \
    || fail "iroh_relay/tasks/node-ids.yml: the $key fallback is not decdn_node's default ($want)"
done
pass "iroh_relay's node-ID fallbacks match decdn_node's defaults"
# A tag-scoped relay run (--tags iroh_relay / relay) must still read the inventory's
# node IDs: the include and its tasks (apply) carry every tag the role has.
if command -v yq >/dev/null; then
  pb="$repo/ansible/playbooks/iroh_relay.yml"
  role_tags="$(yq -o=json '[.[] | .roles[]? | select(.role == "iroh_relay") | .tags] | .[0] | sort' "$pb")"
  inc='.[] | select(.name == "Read the deCDN nodes'"'"' endpoint IDs for the relay allowlist") | .tasks[0]'
  [[ "$role_tags" != null && "$role_tags" != "[]" \
     && "$(yq -o=json "[$inc | .tags] | .[0] | sort" "$pb")" == "$role_tags" \
     && "$(yq -o=json "[$inc | .[\"ansible.builtin.include_role\"].apply.tags] | .[0] | sort" "$pb")" == "$role_tags" ]] \
    || fail "playbooks/iroh_relay.yml: the node-ID read must carry the iroh_relay role's tags ($role_tags), on the include and in apply"
  pass "iroh_relay.yml reads the node IDs under the relay role's tags"
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the node-ID tag check would be skipped"
else
  skipped+=("node-ID tag check (needs yq)")
fi

# decommission.yml must check every sponsord host for a held top-up before any play
# stops a service: a refusal after the node and onramp plays would leave the host
# half decommissioned. The role checks again right before its own stop.
if command -v yq >/dev/null; then
  pb="$repo/ansible/playbooks/decommission.yml"
  [[ "$(yq '.[0].hosts' "$pb")" == decdn_nodes:sponsord_onramp_hosts:sponsord_hosts:iroh_relay_hosts:iroh_dns_server_hosts \
     && "$(yq '.[0].tasks[0]["ansible.builtin.assert"] | has("that")' "$pb")" == true \
     && "$(yq '.[0].tasks[1]["ansible.builtin.include_role"].tasks_from' "$pb")" == topup-hold ]] \
    || fail "playbooks/decommission.yml: the first play must check the host cap, then sponsord's top-up hold"
  pass "decommission.yml checks the host cap and a held top-up before it stops anything"
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the decommission play-order check would be skipped"
else
  skipped+=("decommission play-order check (needs yq)")
fi

# The chart renders monitoring/ through a symlink, and lint-helm is what checks the
# dashboards and rules there (promtool, the sponsord unit tests, uids). A PR that
# touches only monitoring/ runs it only if ci.yml's helm path filter lists it.
if command -v yq >/dev/null; then
  yq '.jobs.changes.steps[] | select(.id == "filter") | .with.filters' "$repo/.github/workflows/ci.yml" \
    | yq -e '.helm | (contains(["charts/**"]) and contains(["monitoring/**"]))' >/dev/null \
    || fail "ci.yml: the helm path filter must list charts/** and monitoring/**"
  pass "ci.yml runs lint-helm on charts/** and monitoring/**"
elif [[ -n ${CI:-} ]]; then
  fail "yq is not on PATH in CI; the helm path-filter check would be skipped"
else
  skipped+=("helm path-filter check (needs yq)")
fi

# --- baseline firewall holes per host shape, and playbook guards ---------------------
if command -v ansible >/dev/null; then
  expect 0 "firewall holes resolve per host shape, co-located included" \
    "$repo/ansible/tests/firewall-holes/check.sh"
  # playbooks/sponsord.yml refuses an onramp host outside sponsord_hosts. Its guard
  # play is lifted out with yq and run alone (running the whole playbook would need
  # the roles' collections just to parse), from a directory without ansible.cfg,
  # against a fixture nothing connects to.
  if command -v yq >/dev/null; then
    yq '[.[] | select(.name == "Require every sponsord-onramp host to be a sponsord host")]' \
      "$repo/ansible/playbooks/sponsord.yml" > "$work/guard.yml"
    [[ "$(yq 'length' "$work/guard.yml")" == 1 ]] \
      || fail "playbooks/sponsord.yml has no single sponsord-onramp placement play"
    guard() { # <limit>
      (cd "$repo/ansible/tests/playbook-guards" && ANSIBLE_DEPRECATION_WARNINGS=0 \
        ansible-playbook -i inventory.yml "$work/guard.yml" --limit "$1" </dev/null)
    }
    expect 0 "sponsord.yml accepts an onramp host that is also a sponsord host" guard both
    expect 2 "sponsord.yml refuses an onramp host outside sponsord_hosts" guard onramp-only
    grep -q "is in sponsord_onramp_hosts but not in sponsord_hosts" "$work/out" \
      || { cat "$work/out" >&2; fail "the onramp-only refusal did not come from the placement check"; }
    # playbooks/origin.yml refuses an origin outside decdn_nodes or without an origin
    # backend; node.yml warns about an origin backend outside decdn_origin_nodes. The
    # plays' pre_tasks are lifted out as tasks, without the roles or fact gathering.
    lift() { # <playbook> <play name>
      yq "[.[] | select(.name == \"$2\") | {\"name\": .name, \"hosts\": .hosts, \"gather_facts\": false, \"tasks\": .pre_tasks}]" \
        "$repo/ansible/playbooks/$1" > "$work/guard.yml"
      [[ "$(yq 'length' "$work/guard.yml")" == 1 && "$(yq '.[0].tasks | length' "$work/guard.yml")" -ge 1 ]] \
        || fail "playbooks/$1 has no single '$2' play with pre_tasks"
    }
    lift origin.yml "Provision deCDN origin nodes"
    expect 0 "origin.yml accepts an origin in decdn_nodes with decdn_cache_origin_kind" guard origin-ok
    expect 0 "origin.yml accepts an origin in decdn_nodes with decdn_cache_origins" guard origin-list
    expect 2 "origin.yml refuses an origin outside decdn_nodes" guard origin-orphan
    grep -q "is in decdn_origin_nodes but not in decdn_nodes" "$work/out" \
      || { cat "$work/out" >&2; fail "the origin-orphan refusal did not come from the decdn_nodes check"; }
    expect 2 "origin.yml refuses an origin without an origin backend" guard origin-none
    grep -q "is in decdn_origin_nodes but has no origin backend" "$work/out" \
      || { cat "$work/out" >&2; fail "the origin-none refusal did not come from the backend check"; }
    lift node.yml "Provision deCDN cache nodes"
    expect 0 "node.yml runs a node with an origin backend outside decdn_origin_nodes" guard node-with-origin
    grep -q "WARNING: node-with-origin has an origin backend" "$work/out" \
      || { cat "$work/out" >&2; fail "node.yml does not warn about an origin backend outside decdn_origin_nodes"; }
    expect 0 "node.yml runs a cache node" guard node-only
    ! grep -q "WARNING:" "$work/out" || { cat "$work/out" >&2; fail "node.yml warns about a cache node"; }
    guard origin-ok >"$work/out" 2>&1 || true
    grep -q "skipping: no hosts matched" "$work/out" \
      || { cat "$work/out" >&2; fail "node.yml's play matches an origin (decdn_origin_nodes) host"; }
    pass "node.yml's play leaves decdn_origin_nodes to origin.yml"
    # Every pre_task is tagged always: lift() runs them untagged, but a --tags run
    # (cloud-init's phase 1 is --tags baseline) would otherwise skip the refusals.
    for pb in node.yml origin.yml; do
      untagged="$(yq '[.[] | select(.pre_tasks) | .pre_tasks[] | select([.tags] | flatten | any_c(. == "always") | not) | .name] | .[]' \
        "$repo/ansible/playbooks/$pb")" || fail "yq could not read playbooks/$pb"
      [[ -z $untagged ]] || fail "playbooks/$pb has pre_tasks not tagged always: $untagged"
    done
    pass "node.yml's and origin.yml's guards run under any --tags"
    # site.yml runs each node once: node.yml's play on the cache nodes and origin.yml's
    # (through publisher.yml) on the origins, disjoint, together every decdn_nodes and
    # decdn_origin_nodes host. Read from --list-hosts, which needs no collections.
    play_hosts() { # <playbook>: "<play name>\t<host>" per host, "<play name>\t" per play
      (cd "$repo/ansible" && ANSIBLE_DEPRECATION_WARNINGS=0 \
        ansible-playbook -i tests/playbook-guards/inventory.yml "playbooks/$1" --list-hosts </dev/null) \
        | awk '/^  play #/ {sub(/^  play #[0-9]+ \([^)]*\): /, ""); sub(/\tTAGS:.*/, ""); p = $0; print p "\t"; next}
               /^      [^ ]/ {print p "\t" $1}'
    }
    play_hosts site.yml > "$work/site-plays" || fail "ansible-playbook --list-hosts failed on site.yml"
    play_hosts publisher.yml > "$work/publisher-plays" || fail "ansible-playbook --list-hosts failed on publisher.yml"
    cache=$'Provision deCDN cache nodes\t' orig=$'Provision deCDN origin nodes\t'
    [[ "$(grep -cx "$cache" "$work/site-plays")" == 1 && "$(grep -cx "$orig" "$work/site-plays")" == 1 ]] \
      || fail "site.yml does not run the cache-node play and the origin play exactly once each"
    [[ "$(grep -cx "$orig" "$work/publisher-plays")" == 1 ]] || fail "publisher.yml does not run the origin play once"
    ! grep -qx "$cache" "$work/publisher-plays" || fail "publisher.yml runs the cache-node play"
    want="$(cd "$repo/ansible" && ansible -i tests/playbook-guards/inventory.yml 'decdn_nodes:decdn_origin_nodes' --list-hosts \
      | awk 'NR > 1 {print $1}' | sort)"
    got="$(grep -E "^($cache|$orig)." "$work/site-plays" | cut -f2 | sort)"
    [[ -n $want && "$got" == "$want" ]] \
      || fail "site.yml's node and origin plays do not cover each node exactly once: got [$(xargs <<<"$got")], want [$(xargs <<<"$want")]"
    pass "site.yml runs every node exactly once: cache nodes in node.yml, origins in origin.yml"
    # ansible/Makefile refuses a LIMIT that matches no host of the target's playbook,
    # which ansible-playbook itself reports as success. ANSIBLE_ARGS keeps the run a listing.
    # ansible/Makefile's limit_guard (scripts/limit-guard.sh) refuses a run that selects
    # no host, or skips a host LIMIT names, both of which ansible-playbook reports as
    # success. ANSIBLE_ARGS keeps the real run a listing.
    mkl() { # <target> <LIMIT, or empty for none> [inventory]
      local lim=(); [[ -z $2 ]] || lim=(LIMIT="$2")
      make -s -C "$repo/ansible" "$1" "${lim[@]}" INVENTORY="${3:-tests/playbook-guards/inventory.yml}" \
        ANSIBLE_ARGS=--list-hosts </dev/null
    }
    refused() { # <description> <message fragment> <mkl args...>
      local desc=$1 msg=$2; shift 2
      expect 2 "$desc" mkl "$@"
      grep -qF -- "$msg" "$work/out" || { cat "$work/out" >&2; fail "$desc: not refused with: $msg"; }
    }
    refused "make check-node refuses LIMIT=<an origin>" \
      "no play in playbooks/node.yml selects a host of tests/playbook-guards/inventory.yml within LIMIT='origin-ok'" check-node origin-ok
    refused "make deploy-origin refuses LIMIT=<a cache node>" \
      "no play in playbooks/origin.yml selects a host" deploy-origin node-only
    refused "make check-node refuses a LIMIT that names an origin among cache nodes" \
      "LIMIT='node-only,origin-ok' includes hosts no play in playbooks/node.yml selects" check-node node-only,origin-ok
    if ! grep -qx '  origin-ok' "$work/out" || ! grep -qF 'deployed by the -origin targets' "$work/out"; then
      cat "$work/out" >&2; fail "check-node's partial-LIMIT refusal does not name origin-ok and the -origin targets"
    fi
    ! grep -qx '  node-only' "$work/out" || fail "check-node's partial-LIMIT refusal names a host it runs"
    refused "make check-relay refuses a group LIMIT that mixes in other hosts" \
      "includes hosts no play in playbooks/iroh_relay.yml selects" check-relay 'relay-only:node-only'
    grep -qF "Check those hosts' groups" "$work/out" || { cat "$work/out" >&2; fail "check-relay's refusal gives the node/origin hint"; }
    refused "make backup refuses LIMIT=<a relay>" "no play in playbooks/backup.yml selects a host" backup relay-only
    # Without a LIMIT, an inventory the playbook selects nothing in.
    printf 'all:\n  children:\n    decdn_nodes:\n      hosts:\n        n1: {}\n' > "$work/nodes-only.yml"
    refused "make check-relay refuses an inventory with no relay" \
      "no play in playbooks/iroh_relay.yml selects a host of $work/nodes-only.yml: the run" check-relay "" "$work/nodes-only.yml"
    expect 0 "make check-node takes an inventory of cache nodes, no LIMIT" mkl check-node "" "$work/nodes-only.yml"
    # A LIMIT outside the inventory is ansible's own refusal, passed through.
    refused "make check-node passes on ansible's refusal of an unknown LIMIT" \
      "ansible-playbook --list-hosts failed on playbooks/node.yml" check-node no-such-host
    grep -q "no hosts to target" "$work/out" || { cat "$work/out" >&2; fail "limit_guard hid ansible's own error"; }
    expect 0 "make check-node takes LIMIT=<a cache node>" mkl check-node node-only
    expect 0 "make deploy-origin takes LIMIT=<an origin>" mkl deploy-origin origin-ok
    expect 0 "make check takes LIMIT=<a cache node and an origin>" mkl check node-only,origin-ok
    expect 0 "make check-node with --syntax-check skips limit_guard" \
      make -s -C "$repo/ansible" check-node LIMIT=node-only INVENTORY=tests/playbook-guards/inventory.yml ANSIBLE_ARGS=--syntax-check
    # decommission.yml's host cap covers the whole run: a node-only host and a
    # sponsord host pass each role's own per-play cap but not this one. Only the
    # cap task is lifted (the hold check needs the roles).
    yq '[.[0] | .tasks = [.tasks[0]]]' "$repo/ansible/playbooks/decommission.yml" > "$work/guard.yml"
    expect 0 "decommission.yml accepts one host" guard node-only
    expect 2 "decommission.yml refuses a node host plus a sponsord host" guard node-only,both
    grep -q "This run decommissions 2 hosts" "$work/out" \
      || { cat "$work/out" >&2; fail "the two-host refusal did not come from the run-wide host cap"; }
    expect 2 "decommission.yml refuses a node host plus a relay host" guard node-only,relay-only
    grep -q "This run decommissions 2 hosts" "$work/out" \
      || { cat "$work/out" >&2; fail "the node + relay refusal did not come from the run-wide host cap"; }
    expect 2 "decommission.yml refuses a node host plus a DNS server host" guard node-only,dns-only
    grep -q "This run decommissions 2 hosts" "$work/out" \
      || { cat "$work/out" >&2; fail "the node + DNS server refusal did not come from the run-wide host cap"; }
    # playbooks/iroh_relay.yml refuses a relay on an onramp host (both want 80/443).
    yq '[.[] | select(.name == "Refuse an iroh relay on a sponsord-onramp host")]' \
      "$repo/ansible/playbooks/iroh_relay.yml" > "$work/guard.yml"
    [[ "$(yq 'length' "$work/guard.yml")" == 1 ]] \
      || fail "playbooks/iroh_relay.yml has no single relay/onramp placement play"
    expect 0 "iroh_relay.yml accepts a relay host of its own" guard relay-only
    expect 2 "iroh_relay.yml refuses a relay on a sponsord-onramp host" guard relay-onramp
    grep -q "is in both iroh_relay_hosts and sponsord_onramp_hosts" "$work/out" \
      || { cat "$work/out" >&2; fail "the relay-onramp refusal did not come from the placement check"; }
    # playbooks/iroh_dns_server.yml refuses a DNS server on a relay or onramp host (443).
    yq '[.[] | select(.name == "Refuse an iroh DNS server on an iroh relay or sponsord-onramp host")]' \
      "$repo/ansible/playbooks/iroh_dns_server.yml" > "$work/guard.yml"
    [[ "$(yq 'length' "$work/guard.yml")" == 1 ]] \
      || fail "playbooks/iroh_dns_server.yml has no single DNS server placement play"
    expect 0 "iroh_dns_server.yml accepts a DNS server host of its own" guard dns-only
    expect 0 "iroh_dns_server.yml accepts a DNS server beside a deCDN node" guard dns-node
    for shape in dns-relay:iroh_relay_hosts dns-onramp:sponsord_onramp_hosts; do
      expect 2 "iroh_dns_server.yml refuses a DNS server also in ${shape##*:}" guard "${shape%%:*}"
      grep -q "is in iroh_dns_server_hosts and also in ${shape##*:}" "$work/out" \
        || { cat "$work/out" >&2; fail "the ${shape%%:*} refusal did not come from the placement check"; }
    done
    # The relay's allowlist reads the inventory's deCDN nodes (tasks_from node-ids).
    # Which nodes (tasks_from node-hosts) is resolved without contacting any: the
    # default group, an explicit list, a missing group, a host outside the inventory.
    mkdir -p "$work/relay-ids"
    cat > "$work/relay-ids/with-nodes.yml" <<'YML'
all:
  vars: {ansible_connection: local}
  children:
    iroh_relay_hosts: {hosts: {relay: {}}}
    decdn_nodes: {hosts: {node-a: {}, node-b: {}}}
YML
    cat > "$work/relay-ids/no-nodes.yml" <<'YML'
all:
  vars: {ansible_connection: local}
  children:
    iroh_relay_hosts: {hosts: {relay: {}}}
YML
    cat > "$work/relay-ids/hosts.yml" <<'YML'
- name: Resolve the relay's node hosts
  hosts: iroh_relay_hosts
  gather_facts: false
  tasks:
    - name: Resolve them
      ansible.builtin.include_role:
        name: iroh_relay
        tasks_from: node-hosts
    - name: Print them
      ansible.builtin.debug:
        msg: "node hosts: {{ _iroh_relay_node_hosts | to_json }}"
YML
    relay_ids() { # <inventory> [ansible-playbook args...]
      local inv="$1"; shift
      (cd "$work/relay-ids" && ANSIBLE_DEPRECATION_WARNINGS=0 ANSIBLE_ROLES_PATH="$repo/ansible/roles" \
        ansible-playbook -i "$inv" "$@" </dev/null)
    }
    expect 0 "the relay reads decdn_nodes by default" relay_ids with-nodes.yml hosts.yml
    grep -qF 'node hosts: [\"node-a\", \"node-b\"]' "$work/out" \
      || { cat "$work/out" >&2; fail "the relay's default node hosts are not groups['decdn_nodes']"; }
    expect 2 "the relay refuses an inventory without deCDN nodes" relay_ids no-nodes.yml hosts.yml
    grep -q "has none" "$work/out" || { cat "$work/out" >&2; fail "the empty-group refusal did not come from node-hosts"; }
    expect 0 "the relay accepts an explicit empty node list" \
      relay_ids no-nodes.yml hosts.yml -e '{"iroh_relay_allowlist_node_hosts": []}'
    expect 2 "the relay refuses a node host outside the inventory" \
      relay_ids with-nodes.yml hosts.yml -e '{"iroh_relay_allowlist_node_hosts": ["node-a", "ghost"]}'
    grep -q 'not in the inventory: \[\\"ghost\\"\]' "$work/out" \
      || { cat "$work/out" >&2; fail "the outside-host refusal did not name the host"; }
    # The playbook skips the read for the other modes and with it turned off (the
    # include would otherwise run whoami on the nodes).
    yq '[.[] | select(.name == "Read the deCDN nodes'"'"' endpoint IDs for the relay allowlist")]
        + [{"name": "Marker", "hosts": "iroh_relay_hosts", "gather_facts": false,
            "tasks": [{"name": "Reached the relay play", "ansible.builtin.debug": {"msg": "relay-play-reached"}}]}]' \
      "$repo/ansible/playbooks/iroh_relay.yml" > "$work/relay-ids/read.yml"
    [[ "$(yq 'length' "$work/relay-ids/read.yml")" == 2 ]] \
      || fail "playbooks/iroh_relay.yml has no single node-ID read play"
    for skip in '{"iroh_relay_access": "everyone"}' '{"iroh_relay_allowlist_from_inventory": false}'; do
      expect 0 "iroh_relay.yml skips the node-ID read with $skip" relay_ids with-nodes.yml read.yml -e "$skip"
      if ! grep -q "relay-play-reached" "$work/out" || grep -q "Resolve the deCDN nodes to read" "$work/out"; then
        cat "$work/out" >&2; fail "iroh_relay.yml did not skip the node-ID read with $skip"
      fi
    done
  elif [[ -n ${CI:-} ]]; then
    fail "yq is not on PATH in CI; the playbook-guard cases would be skipped"
  else
    skipped+=("playbook guards (needs yq)")
  fi
elif [[ -n ${CI:-} ]]; then
  fail "ansible is not on PATH in CI; the firewall-holes check would be skipped"
else
  skipped+=("firewall holes and playbook guards (need ansible-core on PATH)")
fi

# --- upstream-mirror generators (optional: needs a decdn/decdn checkout) --------------
if [[ -n "${UPSTREAM:-}" ]]; then
  # Against the release the roles pin, as the upstream-drift workflow checks.
  expect 0 "network profiles current"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" \
    --ref "v$(pin decdn_node decdn_node_version)" --check
  expect 2 "network profiles: bad ref is an error, not drift"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" --ref no/such/ref --check
else
  skipped+=("upstream-mirror generators (set UPSTREAM=<decdn checkout>)")
fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
echo "all script tests passed"
