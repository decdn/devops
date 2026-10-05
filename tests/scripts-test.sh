#!/usr/bin/env bash
# Tests for the repo's own guard rails that no molecule scenario or chart render
# exercises: the ansible/ Makefile's scoping guards, the release gate, the
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

# --- molecule suite lock: a second run must refuse, not share the containers ----------
# Hold the lock, then start the suite for real. flock -n refuses at once, so no
# scenario runs and — since deps sits behind the lock — no galaxy install either;
# make reports the recipe failure as 2. A directory lock, like the default.
lock="$work/molecule.lock"
mkdir "$lock"
# The sleep itself holds the lock fd, so killing it releases the lock (a
# `flock <path> sleep` holder would leave an orphaned sleep holding it).
( exec 9<"$lock"; flock 9; exec sleep 60 ) & holder=$!
until ! flock -n "$lock" true; do sleep 0.1; done
for target in molecule molecule-serial; do
  expect 2 "$target refuses to start while another suite holds the lock" \
    make -C "$repo/ansible" "$target" MOLECULE_LOCK="$lock"
  grep -q "another molecule suite holds $lock" "$work/out" \
    || { cat "$work/out" >&2; fail "$target lock refusal does not say why"; }
  ! grep -q "ansible-galaxy" "$work/out" \
    || { cat "$work/out" >&2; fail "$target ran deps outside the lock"; }
done
kill "$holder"; wait "$holder" 2>/dev/null || true

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
  expect 0 "lint-cloud-init accepts cloud-init/user-data.yaml" make -s -C "$repo" lint-cloud-init
  sed '1s/^#cloud-config$/# cloud-config/' "$userdata" > "$work/ci-header.yaml"
  if make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-header.yaml" >"$work/out" 2>&1 \
    || ! grep -q 'is not a valid cloud-config' "$work/out"; then
    cat "$work/out" >&2; fail "lint-cloud-init did not reject a missing #cloud-config header as invalid"
  fi
  pass "lint-cloud-init rejects: no #cloud-config header (schema)"
  # <name> <expected message fragment> <sed expression>: the fragment pins WHICH
  # invariant fired, since one edit can trip several.
  ci_variant() {
    sed -E "$3" "$userdata" > "$work/ci-$1.yaml"
    cmp -s "$userdata" "$work/ci-$1.yaml" && fail "variant $1 did not change user-data.yaml"
    if make -s -C "$repo" lint-cloud-init CLOUD_INIT_FILE="$work/ci-$1.yaml" >"$work/out" 2>&1; then
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
  ci_variant "no host-generated wallet"    'decdn_node_generate_keystore must be true' 's/^(\s*)decdn_node_generate_keystore: true(.*)$/\1decdn_node_generate_keystore: false\2/'
  ci_variant "signature off as a host var" 'set decdn_verify_release_signature only in decdn_nodes.vars' "s#$loc#&\\n\\1decdn_verify_release_signature: false#"
  ci_variant "install method as a host var" 'set decdn_node_install_method only in decdn_nodes.vars' "s#$loc#&\\n\\1decdn_node_install_method: manual#"
  ci_variant "another signing key"         'decdn_release_keyring may not be overridden' "s#$net#&\\n\\1decdn_release_keyring: /tmp/KEYS.asc#"
  ci_variant "another env file path"       'decdn_env_file may not be overridden' "s#$net#&\\n\\1decdn_env_file: /etc/decdn/other.env#"
  ci_variant "another inventory group"     'only the decdn_nodes group belongs here' 's#^(\s*)decdn_nodes:$#\1all: {vars: {decdn_verify_release_signature: false}}\n&#'
  # Shape
  ci_variant "localhost outside decdn_nodes" 'localhost must be in decdn_nodes' 's/^(\s*)decdn_nodes:$/\1decdn_hosts:/'
  ci_variant "admin account without keys"  'baseline_sudo_users needs at least one named account' '/^\s*keys:$/,+1d'
  ci_variant "stage 1 not run"             'runcmd must be exactly' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - [/bin/true]#'
  ci_variant "stage 1 failure masked"      'runcmd must be exactly' 's#^  - \[/usr/local/sbin/decdn-bootstrap\]$#  - "/usr/local/sbin/decdn-bootstrap || true"#'
  # shellcheck disable=SC2016 # a literal $DEVOPS_REPO: the variant unquotes it in stage 1
  ci_variant "shellcheck-dirty stage 1"    'decdn-bootstrap fails shellcheck' 's#git clone --quiet --no-checkout "\$DEVOPS_REPO"#git clone --quiet --no-checkout $DEVOPS_REPO#'
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
  expect 0 "monitoring assets current" "$repo/scripts/sync-monitoring.sh" "$UPSTREAM" --check
  expect 2 "network profiles: bad ref is an error, not drift"  "$repo/scripts/sync-network-profiles.py" "$UPSTREAM" --ref no/such/ref --check
  expect 2 "monitoring assets: bad ref is an error, not drift" "$repo/scripts/sync-monitoring.sh" "$UPSTREAM" no/such/ref --check
else
  skipped+=("upstream-mirror generators (set UPSTREAM=<decdn checkout>)")
fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
echo "all script tests passed"
