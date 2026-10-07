#!/usr/bin/env bash
# Tests for the repo's own guard rails that no molecule scenario or chart render
# exercises: the ansible/ Makefile's scoping guards, the molecule driver's guards
# and locks (scripts/molecule.sh), the release gate, the
# lint-compose and lint-cloud-init invariants (negative cases), the firewall holes
# playbooks/group_vars/ derives per host, and — with
# UPSTREAM=<decdn checkout> — the upstream-mirror generators' exit codes.
# `make test-scripts` runs it; CI's `scripts` job does too. Needs make, docker
# (compose v2), jq, flock; the cloud-init cases also need cloud-init, shellcheck and yq,
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
      sponsord-onramp:sponsord-onramp-source; do
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
  ci_variant "b64-encoded content"         'encoding b64 hides its content' "s#$stage1#&\\n\\1  encoding: b64#"
  ci_variant "secret assigned in runcmd"   'assigns a secret-looking variable' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#&\n  - "GC_API_TOKEN=x /bin/true"#'
  # Hardening and the signed install
  ci_variant "the test-only baseline skip" 'mentions TEST-ONLY-skip-baseline' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - [touch, /etc/decdn-bootstrap/TEST-ONLY-skip-baseline]\n&#'
  ci_variant "manual install method"       'decdn_node_install_method must be release' 's/^(\s*)decdn_node_install_method: release$/\1decdn_node_install_method: manual/'
  ci_variant "source install method"       'decdn_node_install_method must be release' 's/^(\s*)decdn_node_install_method: release$/\1decdn_node_install_method: source/'
  ci_variant "no host-generated wallet"    'decdn_node_generate_keystore must be true' 's/^(\s*)decdn_node_generate_keystore: true(.*)$/\1decdn_node_generate_keystore: false\2/'
  ci_variant "signature off as a host var" 'set decdn_verify_release_signature only in decdn_nodes.vars' "s#$loc#&\\n\\1decdn_verify_release_signature: false#"
  ci_variant "install method as a host var" 'set decdn_node_install_method only in decdn_nodes.vars' "s#$loc#&\\n\\1decdn_node_install_method: manual#"
  ci_variant "another signing key"         'decdn_release_keyring may not be overridden' "s#$net#&\\n\\1decdn_release_keyring: /tmp/KEYS.asc#"
  ci_variant "another env file path"       'decdn_env_file may not be overridden' "s#$net#&\\n\\1decdn_env_file: /etc/decdn/other.env#"
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
  ci_variant "another sponsord signing key" 'sponsord_release_keyring may not be overridden' "s#$spnet#&\\n\\1sponsord_release_keyring: /tmp/KEYS.asc#" "$sponsorud"
  ci_variant "another treasury keystore path" 'sponsord_treasury_keystore_file may not be overridden' "s#$spnet#&\\n\\1sponsord_treasury_keystore_file: /tmp/k.json#" "$sponsorud"
  ci_variant "treasury wallet generation" 'sponsord_generate_treasury_wallet may not be overridden' "s#$spnet#&\\n\\1sponsord_generate_treasury_wallet: true#" "$sponsorud"
  ci_variant "onramp without sponsord_hosts" 'sponsord_onramp_hosts needs sponsord_hosts too' 's/^(\s*)sponsord_hosts:$/\1decdn_nodes:/' "$sponsorud"
  ci_variant "another host in the onramp group" 'sponsord_onramp_hosts must hold exactly localhost' '/^\s*sponsord_onramp_hosts:$/,/^\s*vars:$/ s/^(\s*)localhost:$/&\n\1other.example:/' "$sponsorud"
  # A node and a sponsor on one host: the node template plus the sponsord groups.
  sed -E 's/^(\s*)decdn_region: .*$/&\n      sponsord_hosts:\n        hosts:\n          localhost:\n        vars:\n          sponsord_install_method: release\n          sponsord_version: "0.1.0"\n      sponsord_onramp_hosts:\n        hosts:\n          localhost:\n        vars:\n          sponsord_onramp_install_method: release/' \
    "$userdata" > "$work/ci-colocated.yaml"
  expect 0 "lint-cloud-init accepts a node co-located with sponsord" \
    make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-colocated.yaml"
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

# --- the source install method's shared pieces stay identical across roles --------
# decdn_build_user/home and the rustup pins are defined in all three roles' defaults
# (one build user and toolchain per host), and the root-side installer is copied
# into decdn_node and sponsord (sponsord_onramp uses sponsord's).
shared_keys() { # <defaults file>
  grep -E '^(decdn_build_user|decdn_build_home|decdn_rustup_version|decdn_rustup_sha256):|^  (x86_64|aarch64)-unknown-linux-gnu:' "$1"
}
want=$(shared_keys "$repo/ansible/roles/decdn_node/defaults/main.yml")
for r in sponsord sponsord_onramp; do
  [ "$(shared_keys "$repo/ansible/roles/$r/defaults/main.yml")" = "$want" ] \
    || fail "$r/defaults/main.yml: decdn_build_* / decdn_rustup_* differ from decdn_node's"
done
cmp -s "$repo/ansible/roles/decdn_node/files/install-build-output.py" \
       "$repo/ansible/roles/sponsord/files/install-build-output.py" \
  || fail "decdn_node and sponsord files/install-build-output.py differ"
pass "source-build defaults and installer identical across roles"

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
  expect 0 "network profiles current"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" --check
  expect 2 "network profiles: bad ref is an error, not drift"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" --ref no/such/ref --check
else
  skipped+=("upstream-mirror generators (set UPSTREAM=<decdn checkout>)")
fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
echo "all script tests passed"
