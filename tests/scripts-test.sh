#!/usr/bin/env bash
# Tests for the repo's own guard rails that no molecule scenario or chart render
# exercises: the ansible/ Makefile's scoping guards, the molecule driver's guards
# and locks (scripts/molecule.sh), the release gate, the
# lint-compose and lint-cloud-init invariants (negative cases), the firewall holes
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
mk decommission LIMIT=h | grep -q -- "playbooks/decommission.yml --limit 'h'" \
  || fail "decommission LIMIT=h does not scope the playbook"
pass "decommission LIMIT=h scopes playbooks/decommission.yml"
mk backup | grep -q -- "playbooks/backup.yml" || fail "backup does not run playbooks/backup.yml"
pass "backup runs playbooks/backup.yml fleet-wide by default"
expect 2 "deploy-relay refuses LIMIT from the environment"  env LIMIT=h make -s -C "$repo/ansible" -n deploy-relay
mk deploy-relay LIMIT=h | grep -q -- "playbooks/iroh_relay.yml --limit 'h'" \
  || fail "deploy-relay LIMIT=h does not run playbooks/iroh_relay.yml scoped to h"
pass "deploy-relay LIMIT=h scopes playbooks/iroh_relay.yml"
expect 2 "deploy-dns refuses LIMIT from the environment"    env LIMIT=h make -s -C "$repo/ansible" -n deploy-dns
mk deploy-dns LIMIT=h | grep -q -- "playbooks/iroh_dns_server.yml --limit 'h'" \
  || fail "deploy-dns LIMIT=h does not run playbooks/iroh_dns_server.yml scoped to h"
pass "deploy-dns LIMIT=h scopes playbooks/iroh_dns_server.yml"

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
# The real changelog must parse before release day: the section for this version, and
# [Unreleased], which the release PR folds into it.
expect 0 "changes generator reads charts/decdn-node/CHANGELOG.md [$version]" \
  "$changes" "$repo/charts/decdn-node/CHANGELOG.md" "$version"
if sed -n '/^## \[Unreleased\]/,/^## \[[0-9]/p' "$repo/charts/decdn-node/CHANGELOG.md" | grep -q '^### '; then
  expect 0 "changes generator reads charts/decdn-node/CHANGELOG.md [Unreleased]" \
    "$changes" "$repo/charts/decdn-node/CHANGELOG.md" Unreleased
fi
if command -v yq >/dev/null && command -v jq >/dev/null && command -v helm >/dev/null; then
  # release.yml's own steps, read by name and run as Actions runs them, on a released
  # copy of the chart: the annotation step, then helm package, then the check.
  step() { # <step name>: its run script, or fail
    local run
    run="$(yq ".jobs.build.steps[] | select(.name == \"$1\") | .run" "$repo/.github/workflows/release.yml")"
    [[ -n "$run" && "$run" != null ]] || fail "release.yml has no build step '$1'"
    printf '%s\n' "$run"
  }
  annotate="$(step "Add the artifacthub.io/changes annotation")"
  check="$(step "Check the packaged artifacthub.io/changes")"
  ah="$work/ah"
  mkdir -p "$ah/scripts" "$ah/charts" "$ah/dist"
  cp "$changes" "$ah/scripts/"
  cp -RL "$repo/charts/decdn-node" "$ah/charts/"
  cp "$rel/charts/decdn-node/CHANGELOG.md" "$ah/charts/decdn-node/"
  run_step() { (cd "$ah" && TAG="v$version" bash --noprofile --norc -eo pipefail -c "$1") >"$work/out" 2>&1; }
  run_step "$annotate" || { cat "$work/out" >&2; fail "release.yml's annotation step failed"; }
  helm package "$ah/charts/decdn-node" --destination "$ah/dist" >"$work/out" 2>&1 \
    || { cat "$work/out" >&2; fail "helm package failed on the chart with artifacthub.io/changes"; }
  run_step "$check" || { cat "$work/out" >&2; fail "release.yml's check refuses the generated annotation"; }
  [[ "$("$changes" "$rel/charts/decdn-node/CHANGELOG.md" "$version" | yq -o=json -I0)" \
     == "$(helm show chart "$ah/dist/decdn-node-$version.tgz" | yq -o=json -I0 '.annotations["artifacthub.io/changes"] | from_yaml')" ]] \
    || fail "the packaged artifacthub.io/changes differs from the generator's output"
  pass "release.yml's annotation step survives helm package unchanged, and its check accepts it"
  yq -i '.annotations["artifacthub.io/changes"] = "not a list"' "$ah/charts/decdn-node/Chart.yaml"
  helm package "$ah/charts/decdn-node" --destination "$ah/dist" >/dev/null 2>&1 \
    || fail "helm package failed on the chart with a scalar artifacthub.io/changes"
  ! run_step "$check" || fail "release.yml's check accepts a scalar artifacthub.io/changes"
  pass "release.yml's check refuses an artifacthub.io/changes that is not a list"
elif [[ -n ${CI:-} ]]; then
  fail "yq, jq or helm is not on PATH in CI; the artifacthub.io/changes release steps would be skipped"
else
  skipped+=("artifacthub.io/changes release steps (needs yq, jq and helm)")
fi

# --- lint-compose: the real file passes, each broken variant is rejected -------------
compose="$repo/compose/compose.yaml"
# The baseline first: a variant below only proves something if the unmodified file
# does not already trip the invariant it targets.
expect 0 "lint-compose accepts compose/compose.yaml" make -s -C "$repo" lint-compose
# <name> <expected message fragment> <sed expression>: the fragment pins WHICH
# invariant fired (compose/tests/*.jq print "<service>: <invariant>"), since one
# edit can trip several. Scope an edit to one service by prefixing a sed range:
# "${node}", "${sd}", "${onr}" or "${cdy}".
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
# Each range ends at the next service or top-level key.
node='/^  decdn-node:$/,/^ {0,2}[a-z]/'
sd='/^  sponsord:$/,/^ {0,2}[a-z]/'
onr='/^  sponsord-onramp:$/,/^ {0,2}[a-z]/'
cdy='/^  caddy:$/,/^ {0,2}[a-z]/'
# Shape
variant "unexpected service"       "compose.yaml: services are exactly"           "s/^  caddy:$/  proxy:/"
variant "sponsord privileged"      "sponsord: sets only allowed keys (extra: privileged)" "${sd} s/^(\s*)cap_drop: \[ALL\]$/&\n\1privileged: true/"
variant "sponsord host pid"        "sponsord: sets only allowed keys (extra: pid)" "${sd} s/^(\s*)network_mode: host$/&\n\1pid: host/"
variant "onramp device"            "sponsord-onramp: sets only allowed keys (extra: devices)" "${onr} s/^(\s*)network_mode: host$/&\n\1devices: [\"\/dev\/mem:\/dev\/mem\"]/"
# decdn-node
variant "bridge network"           "decdn-node: network_mode is host"             "${node} s/^(\s*)network_mode: host$/\1network_mode: bridge/"
variant "writable rootfs"          "decdn-node: read_only rootfs"                 "${node} s/^(\s*)read_only: true$/\1read_only: false/"
variant "short stop grace"         "decdn-node: stop_grace_period"                "${node} s/^(\s*)stop_grace_period: 300s$/\1stop_grace_period: 10s/"
variant "capabilities kept"        "decdn-node: cap_drop is [ALL]"                "${node} s/^(\s*)cap_drop: \[ALL\]$/\1cap_drop: [NET_RAW]/"
variant "published port"           "decdn-node: publishes no ports"               "${node} s/^(\s*)network_mode: host$/&\n\1ports: [\"127.0.0.1:9090:9090\"]/"
variant "tag instead of digest"    "decdn-node: image is pinned"                  "${node} s#^(\s*)image: .*#\1image: ghcr.io/decdn/decdn-node:latest#"
variant "node config writable"     "decdn-node: mounts are exactly"               "${node} s#- /etc/decdn:/etc/decdn:ro\$#- /etc/decdn:/etc/decdn#"
variant "node always on"           "decdn-node: profiles are [node]"              "${node} {/^    profiles: \[node\]$/d}"
# sponsord
variant "sponsord on 0.0.0.0"      "sponsord: SPONSORD_BIND is 127.x"             "${sd} s/SPONSORD_BIND: 127\.0\.0\.1:8090/SPONSORD_BIND: 0.0.0.0:8090/"
variant "sponsord bind unset"      "sponsord: SPONSORD_BIND is 127.x"             "${sd} {/SPONSORD_BIND: /d}"
variant "sponsord bind flag"       "sponsord: no command or entrypoint override"  "${sd} s/^(\s*)network_mode: host$/&\n\1command: [--bind, \"0.0.0.0:8090\"]/"
variant "sponsord by tag"          "sponsord: image is pinned"                    "${sd} s#^(\s*)image: .*#\1image: ghcr.io/decdn/sponsord:latest#"
variant "sponsord capability"      "sponsord: sets only allowed keys (extra: cap_add)" "${sd} s/^(\s*)cap_drop: \[ALL\]$/&\n\1cap_add: [NET_RAW]/"
variant "sponsord short grace"     "sponsord: stop_grace_period"                  "${sd} s/^(\s*)stop_grace_period: 120s$/\1stop_grace_period: 10s/"
variant "sponsord SIGKILL"         "sponsord: stop_signal is SIGTERM"             "${sd} s/^(\s*)stop_signal: SIGTERM$/\1stop_signal: SIGKILL/"
variant "sponsord as root"         "sponsord: runs as a non-root uid:gid"         "${sd} s/^(\s*)user: .*/\1user: \"0:0\"/"
variant "privilege escalation"     "sponsord: security_opt is exactly"            "${sd} s/- no-new-privileges:true$/- no-new-privileges:false/"
variant "seccomp unconfined"       "sponsord: security_opt is exactly"            "${sd} s/^(\s*)- no-new-privileges:true$/&\n\1- seccomp:unconfined/"
variant "writable keystore mount"  "sponsord: mounts are exactly"                 "${sd} {/target: \/run\/secrets\/treasury-keystore\.json$/{n;s/read_only: true/read_only: false/}}"
variant "host root as data dir"    "sponsord: mounts are exactly"                 "${sd} s#^(\s*)volumes:\$#\1volumes:\n\1  - /:/data#"
variant "docker socket"            "sponsord: mounts are exactly"                 "${sd} s#^(\s*)volumes:\$#\1volumes:\n\1  - /var/run/docker.sock:/var/run/docker.sock:ro#"
variant "keystore path moved"      "sponsord: SPONSORD_TREASURY_KEYSTORE is"      "${sd} s#SPONSORD_TREASURY_KEYSTORE: .*#SPONSORD_TREASURY_KEYSTORE: /tmp/k.json#"
variant "inline API token"         "sponsord: no inline SPONSORD_API_TOKEN"       "${sd} s/^(\s*)SPONSORD_BIND: (.*)$/&\n\1SPONSORD_API_TOKEN: x/"
variant "RPC URL in compose.yaml"   "sponsord: sets only allowed environment keys inline (extra: SPONSORD_RPC_URL)" "${sd} s/^(\s*)SPONSORD_BIND: (.*)$/&\n\1SPONSORD_RPC_URL: https:\/\/rpc.invalid\/key/"
variant "node RPC URL inline"      "decdn-node: sets only allowed environment keys inline (extra: DECDN_RPC_URL)" "${node} s/^(\s*)read_only: true$/\1environment:\n\1  DECDN_RPC_URL: https:\/\/rpc.invalid\/key\n&/"
variant "onramp without daemon"    "sponsord: profiles are"                       "${sd} s/^(\s*)profiles: \[sponsord, onramp\]$/\1profiles: [sponsord]/"
variant "sponsord digest default"  "sponsord: unset image digest"                 "${sd} s#^(\s*)image: .*#\1image: ghcr.io/decdn/sponsord@\\\${SPONSORD_IMAGE_DIGEST:-sha256:$(printf '0%.0s' {1..64})}#"
variant "sponsord uid default"     "sponsord: unset uid/gid"                      "${sd} s/^(\s*)user: .*/\1user: \"\\\${SPONSORD_UID:-998}:\\\${SPONSORD_GID:-998}\"/"
# sponsord-onramp
variant "onramp on 0.0.0.0"        "sponsord-onramp: ONRAMP_BIND is 127.x"        "${onr} s/ONRAMP_BIND: 127\.0\.0\.1:8080/ONRAMP_BIND: 0.0.0.0:8080/"
variant "onramp bind unset"        "sponsord-onramp: ONRAMP_BIND is 127.x"        "${onr} {/ONRAMP_BIND: /d}"
variant "onramp remote daemon"     "sponsord-onramp: ONRAMP_DAEMON_URL"           "${onr} s#ONRAMP_DAEMON_URL: http://127\.0\.0\.1:8090#ONRAMP_DAEMON_URL: http://10.0.0.1:8090#"
variant "onramp published port"    "sponsord-onramp: publishes no ports"          "${onr} s/^(\s*)network_mode: host$/&\n\1ports: [\"8080:8080\"]/"
variant "onramp writable rootfs"   "sponsord-onramp: read_only rootfs"            "${onr} s/^(\s*)read_only: true$/\1read_only: false/"
variant "onramp short grace"       "sponsord-onramp: stop_grace_period"           "${onr} s/^(\s*)stop_grace_period: 30s$/\1stop_grace_period: 5s/"
variant "onramp by tag"            "sponsord-onramp: image is pinned"             "${onr} s#^(\s*)image: .*#\1image: ghcr.io/decdn/sponsord-onramp:latest#"
variant "onramp holds keystore"    "sponsord-onramp: mounts are exactly"          "${onr} s#^(\s*)volumes:\$#\1volumes:\n\1  - /etc/sponsord/treasury-keystore.json:/run/secrets/k:ro#"
variant "writable turnstile mount" "sponsord-onramp: mounts are exactly"          "${onr} {/target: \/run\/secrets\/turnstile-secret$/{n;s/read_only: true/read_only: false/}}"
variant "writable gate-page mount"  "sponsord-onramp: mounts are exactly"          "${onr} {/target: \/etc\/sponsord\/onramp-gate$/{n;s/read_only: true/read_only: false/}}"
variant "onramp entrypoint flag"   "sponsord-onramp: entrypoint is exactly"       "${onr} s#^(\s*)exec sponsord-onramp\$#\1exec sponsord-onramp --bind 0.0.0.0:8080#"
variant "gate check dropped"       "sponsord-onramp: entrypoint is exactly"       "${onr} s#^(\s*)/etc/sponsord/onramp-gate/\*\) ;;\$#\1*) ;;#"
variant "gate page from a secret"  "sponsord-onramp: mounts are exactly"          "${onr} s#source: /etc/sponsord/onramp-gate\$#source: /etc/sponsord/treasury-keystore.json#"
variant "inline Turnstile secret"  "sponsord-onramp: no inline ONRAMP_TURNSTILE_SECRET" "${onr} s/^(\s*)ONRAMP_BIND: (.*)$/&\n\1ONRAMP_TURNSTILE_SECRET: x/"
variant "onramp on sponsord hosts" "sponsord-onramp: profiles are [onramp]"       "${onr} s/^(\s*)profiles: \[onramp\]$/\1profiles: [onramp, sponsord]/"
variant "resolvable domain default" "sponsord-onramp: unset domain"               "${onr} s#ONRAMP_PUBLIC_URL: .*#ONRAMP_PUBLIC_URL: https://\\\${SPONSORD_ONRAMP_DOMAIN:-unset-SPONSORD_ONRAMP_DOMAIN.invalid}#"
# caddy
variant "caddy extra capability"   "caddy: cap_add is exactly"                    "${cdy} s/cap_add: \[NET_BIND_SERVICE\]/cap_add: [NET_BIND_SERVICE, NET_ADMIN]/"
variant "caddy keeps capabilities" "caddy: cap_drop is [ALL]"                     "${cdy} {/^    cap_drop: /d}"
variant "caddy as root"            "caddy: runs as a non-root uid:gid"            "${cdy} {/^    user: /d}"
variant "caddy published port"     "caddy: publishes no ports"                    "${cdy} s/^(\s*)network_mode: host$/&\n\1ports: [\"443:443\"]/"
variant "caddy always on"          "caddy: profiles are [caddy]"                  "${cdy} {/^    profiles: \[caddy\]$/d}"

# --- lint-cloud-init negatives: each broken variant must be rejected -------------------
# Skipped without cloud-init on PATH, except in CI (which installs it), so a broken
# install step cannot quietly drop these cases.
if command -v cloud-init >/dev/null; then
  userdata="$repo/cloud-init/user-data.yaml"
  sponsorud="$repo/cloud-init/user-data-sponsord.yaml"
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
  # the node's user-data.yaml.
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
  ci_variant "another inventory group"     'only the decdn_nodes, sponsord_hosts, sponsord_onramp_hosts groups belong here' 's#^(\s*)decdn_nodes:$#\1all: {vars: {decdn_verify_release_signature: false}}\n&#'
  # Shape
  ci_variant "localhost outside decdn_nodes" 'localhost must be in decdn_nodes or sponsord_hosts' 's/^(\s*)decdn_nodes:$/\1decdn_hosts:/'
  ci_variant "admin account without keys"  'baseline_sudo_users needs at least one named account' '/^\s*keys:$/,+1d'
  ci_variant "stage 1 not run"             'runcmd must be exactly' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - [/bin/true]#'
  ci_variant "stage 1 failure masked"      'runcmd must be exactly' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - "/usr/local/sbin/decdn-bootstrap || true"#'
  # shellcheck disable=SC2016 # a literal $DEVOPS_REPO: the variant unquotes it in stage 1
  ci_variant "shellcheck-dirty stage 1"    'decdn-bootstrap fails shellcheck' 's#git clone --quiet --no-checkout "\$DEVOPS_REPO"#git clone --quiet --no-checkout $DEVOPS_REPO#'
  # The sponsor host (user-data-sponsord.yaml)
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
  ci_variant "onramp without sponsord_hosts" 'sponsord_onramp_hosts needs sponsord_hosts too' 's/^(\s*)sponsord_hosts:$/\1decdn_nodes:/' "$sponsorud"
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
# bootstrap.sh's gate and lint.py agree on the groups a user-data may use, and the
# bootstrap's hint has its own instructions for each.
boot="$repo/cloud-init/bootstrap.sh"
host_groups="$(sed -nE 's/^readonly HOST_GROUPS=\((.*)\)$/\1/p' "$boot")"
[[ -n $host_groups ]] || fail "cloud-init/bootstrap.sh: no HOST_GROUPS"
[[ "$host_groups" == "$(cd "$repo/cloud-init/tests" && python3 -B -c 'import lint; print(*lint.GROUPS)')" ]] \
  || fail "cloud-init/bootstrap.sh HOST_GROUPS ($host_groups) differs from lint.py's GROUPS"
for g in $host_groups; do
  grep -qE "^  \[$g\]=" "$boot" || fail "cloud-init/bootstrap.sh: no SECRETS entry for $g"
  grep -qE "^    $g\)$" "$boot" || fail "cloud-init/bootstrap.sh: the hint has no case arm for $g"
done
pass "bootstrap.sh's groups match lint.py's, each with its secrets and its hint"
# The same contract, read from the playbooks with nothing booted. The molecule boots
# run the guard too, but in Docker and only for the groups their inventories use.
# `hosts` and `tags` may each be a string or a list; tags match exactly.
if command -v yq >/dev/null; then
  for g in decdn_nodes sponsord_hosts; do
    n=0
    for pb in site.yml sponsord.yml; do
      plays="[.[] | select([.hosts] | flatten | any_c(. == \"$g\"))]"
      n=$((n + $(yq "$plays | length" "$repo/ansible/playbooks/$pb")))
      [[ "$(yq "$plays | map(select((.roles // []) | map(select(.role == \"baseline\" and ([.tags // []] | flatten | any_c(. == \"baseline\")))) | length == 0)) | length" "$repo/ansible/playbooks/$pb")" == 0 ]] \
        || fail "playbooks/$pb: a $g play lacks the baseline role tagged baseline (cloud-init's phase 1 relies on it)"
    done
    ((n >= 1)) || fail "no play in site.yml or sponsord.yml targets $g"
  done
  pass "every decdn_nodes and sponsord_hosts play runs baseline under the baseline tag"
  # baseline-plays.sh, the command bootstrap.sh runs, against the real playbooks and the
  # templates' inventories, then against a copy whose sponsord play lost the tag (#90).
  # Listing tasks needs ansible-core only, not the collections.
  if command -v ansible-playbook >/dev/null; then
    for t in user-data:decdn_nodes user-data-sponsord:sponsord_hosts; do
      yq '.write_files[] | select(.path == "/etc/decdn-bootstrap/inventory.yml") | .content' \
        "$repo/cloud-init/${t%%:*}.yaml" > "$work/${t%%:*}-inventory.yml"
    done
    bplays() { # <ansible dir> <inventory> <group>...
      local dir=$1; shift
      (cd "$dir" && HOME="$work" ANSIBLE_DEPRECATION_WARNINGS=0 "$repo/cloud-init/baseline-plays.sh" "$@" </dev/null)
    }
    expect 0 "baseline-plays.sh accepts the node template's host" bplays "$repo/ansible" "$work/user-data-inventory.yml" decdn_nodes
    expect 0 "baseline-plays.sh accepts the sponsor template's host" bplays "$repo/ansible" "$work/user-data-sponsord-inventory.yml" sponsord_hosts
    mkdir -p "$work/notag"
    cp -r "$repo/ansible/playbooks" "$repo/ansible/ansible.cfg" "$work/notag/"
    ln -s "$repo/ansible/roles" "$work/notag/roles"
    yq -i '(.[] | select(.hosts == "sponsord_hosts") | .roles[] | select(.role == "baseline")) |= del(.tags)' \
      "$work/notag/playbooks/sponsord.yml"
    expect 1 "baseline-plays.sh refuses a sponsord play that lost its baseline tag (#90)" \
      bplays "$work/notag" "$work/user-data-sponsord-inventory.yml" sponsord_hosts
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
  node_shared="$(yq -o=json "$shared" "$repo/cloud-init/user-data.yaml")"
  [[ "$(yq '.files | length' <<<"$node_shared")" == 2 && "$(yq '.final_message | length > 0' <<<"$node_shared")" == true ]] \
    || fail "cloud-init/user-data.yaml: stage 1, the login hint or final_message not found"
  [[ "$node_shared" == "$(yq -o=json "$shared" "$repo/cloud-init/user-data-sponsord.yaml")" ]] \
    || fail "cloud-init/user-data.yaml and user-data-sponsord.yaml differ in stage 1, the login hint or final_message"
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
pass "release pins agree across roles, Compose, the chart and its artifacthub.io/images; the vendored KEYS match SECURITY.md"
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
