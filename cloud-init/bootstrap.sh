#!/usr/bin/env bash
# Stage 2 of the cloud-init bootstrap (see README.md). Stage 1 is the small
# /usr/local/sbin/decdn-bootstrap that the user-data writes. It takes a lock, records
# "running", clones this repo at the pinned ref, verifies the checkout, then execs this
# script from it.
#
# This script converges the host by running ansible/playbooks/site.yml against
# localhost. site.yml imports sponsord.yml, so one playbook serves a node
# (user-data.yaml), a sponsor host (user-data-sponsord.yaml) or both, by the inventory's
# groups:
#   1. Install the pinned ansible-core into a venv, with hashes enforced
#      (requirements.txt), and the pinned Galaxy collections (collections.lock.yml).
#   2. Syntax-check site.yml. Check that the inventory puts localhost in decdn_nodes or
#      sponsord_hosts, and in sponsord_hosts whenever it is in sponsord_onramp_hosts.
#      Without that membership the plays match no host and exit 0, and the firewall
#      holes in playbooks/group_vars/ never load. Then check that, under
#      `--tags baseline`, each decdn_nodes and sponsord_hosts play the host is in still
#      selects the baseline role (baseline-plays.sh), since phase 1 relies on it.
#   3. Pick the phase. Each of the host's groups needs its secrets on the host (SECRETS
#      below):
#      - any missing: run `baseline` only (SSH, firewall, patching, the admin account),
#        list the missing paths in $STATE_DIR/awaiting and record "awaiting-secret".
#        The roles would stop at their secret gates anyway, so stopping here keeps
#        cloud-init's status clean.
#      - all present: run the whole playbook (install, keys, services), then record
#        "complete".
#
# `sudo decdn-bootstrap` (stage 1, then this) is how the operator continues after
# writing the secrets, and how a host picks up a new pinned ref.
set -euo pipefail

readonly CONF_DIR=/etc/decdn-bootstrap
readonly INVENTORY=$CONF_DIR/inventory.yml
readonly VENV=/opt/decdn-bootstrap/venv
readonly STATE_DIR=/var/lib/decdn-bootstrap
readonly STATE_FILE=$STATE_DIR/state
# The missing secrets' paths, one per line, for the login hint. Paths only, never content.
readonly AWAITING_FILE=$STATE_DIR/awaiting
# The secrets each group's role reads on the host, at the role defaults that
# `make lint-cloud-init` forbids a user-data to move:
#   decdn_nodes: decdn_env_file (roles/decdn_node/defaults/main.yml).
#   sponsord_hosts: sponsord_secret_env_file, sponsord_treasury_keystore_file,
#     sponsord_treasury_password_file (roles/sponsord/defaults/main.yml). Not the API
#     token: the role generates it.
#   sponsord_onramp_hosts: sponsord_onramp_turnstile_secret_file
#     (roles/sponsord_onramp/defaults/main.yml).
readonly HOST_GROUPS=(decdn_nodes sponsord_hosts sponsord_onramp_hosts)
declare -rA SECRETS=(
  [decdn_nodes]=/etc/decdn/decdn.env
  [sponsord_hosts]="/etc/sponsord/secret.env /etc/sponsord/treasury-keystore.json /etc/sponsord/treasury-password"
  [sponsord_onramp_hosts]=/etc/sponsord/turnstile-secret
)
# Test hook for the molecule `cloud-init` scenarios only: baseline's hardening means
# nothing in a container. bootstrap.env carries no Ansible arguments, so there is no
# route for extra-vars; this marker is the only way to skip baseline, and
# `make lint-cloud-init` rejects a user-data that mentions it.
readonly SKIP_BASELINE_MARKER=$CONF_DIR/TEST-ONLY-skip-baseline

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo

# World-readable on purpose: the login hint (/etc/profile.d/decdn-bootstrap.sh, written
# by the user-data) reads it as the admin account. Stage 1 has a copy of this function.
set_state() {
  install -d -m 0755 "$STATE_DIR"
  printf '%s\n' "$1" >"$STATE_FILE.tmp"
  chmod 0644 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# The same, for the list of missing secrets. No arguments removes the file.
set_awaiting() {
  if (($# == 0)); then
    rm -f "$AWAITING_FILE"
    return
  fi
  install -d -m 0755 "$STATE_DIR"
  printf '%s\n' "$@" >"$AWAITING_FILE.tmp"
  chmod 0644 "$AWAITING_FILE.tmp"
  mv -f "$AWAITING_FILE.tmp" "$AWAITING_FILE"
}

die() { echo "decdn-bootstrap: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo decdn-bootstrap)"
# Any non-zero exit records "failed": a failed command under set -e, a die, or a signal
# (an SSH session dropping mid-run). An ERR trap alone would miss the last two.
trap 'rc=$?; if ((rc != 0)); then set_state failed
  echo "decdn-bootstrap: FAILED (see the output above; re-run: sudo decdn-bootstrap)" >&2; fi' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f $INVENTORY ]] || die "$INVENTORY is missing (it is written by the cloud-init user-data)"
if grep -n 'CHANGE_ME' "$INVENTORY" >&2; then
  die "$INVENTORY still has CHANGE_ME placeholders (the lines above); edit them, then re-run"
fi

extra_args=()
if [[ -e $SKIP_BASELINE_MARKER ]]; then
  echo "decdn-bootstrap: WARNING: $SKIP_BASELINE_MARKER exists; skipping host hardening (test use only)" >&2
  extra_args=(--skip-tags baseline)
fi

set_state running
# A list left by an earlier run is stale from here on.
set_awaiting

# --- 1. Pinned toolchain ------------------------------------------------------
# A venv whose interpreter no longer runs (the distro's python3 changed under it after a
# release upgrade) is rebuilt instead of being patched.
if ! "$VENV/bin/python" -c '' 2>/dev/null; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
fi
# --only-binary: no compiler on the host, and nothing built from an sdist at boot.
"$VENV/bin/pip" install --quiet --disable-pip-version-check --no-input \
  --require-hashes --only-binary=:all: -r "$repo/cloud-init/requirements.txt"

cd "$repo/ansible" # so ansible.cfg (roles_path, collections_path) applies
export PATH="$VENV/bin:$PATH"
# Fail on an inventory that does not parse, instead of warning and running against no
# hosts (ansible/Makefile sets the same).
export ANSIBLE_INVENTORY_UNPARSED_FAILED=True

# --force: a re-run after a ref bump must replace a collection that the new lock pins at
# a different version. Without it, ansible-galaxy keeps any installed version.
ansible-galaxy collection install --force -p collections -r "$repo/cloud-init/collections.lock.yml"

# --- 2. Checks before touching the host ----------------------------------------
ansible-playbook -i "$INVENTORY" playbooks/site.yml --syntax-check

declare -A member=()
groups_in=()
for g in "${HOST_GROUPS[@]}"; do
  # A group the inventory does not define lists no hosts and exits 0 (with a warning).
  # Any other failure must stop the run: read as "not a member", it would skip that
  # group's secrets.
  members=$(ansible -i "$INVENTORY" "$g" --list-hosts) \
    || die "could not list group $g in $INVENTORY (see the ansible error above)"
  if grep -qE '^\s+localhost$' <<<"$members"; then
    member[$g]=1
    groups_in+=("$g")
  fi
done
[[ -n ${member[decdn_nodes]:-} || -n ${member[sponsord_hosts]:-} ]] \
  || die "$INVENTORY puts localhost in neither decdn_nodes nor sponsord_hosts (site.yml would match nothing)"
# playbooks/sponsord.yml asserts the same, in a play that `--tags baseline` skips.
[[ -z ${member[sponsord_onramp_hosts]:-} || -n ${member[sponsord_hosts]:-} ]] \
  || die "$INVENTORY puts localhost in sponsord_onramp_hosts but not in sponsord_hosts (the onramp runs beside the daemon)"
echo "decdn-bootstrap: localhost is in ${groups_in[*]}"

# Phase 1 below relies on every decdn_nodes and sponsord_hosts play the host is in
# tagging the baseline role `baseline`. If one lost the role or its tag,
# --tags baseline would skip it and exit 0, and the host would be reported hardened
# without being so. The check is per play: --list-tasks lists every play, hostless
# ones too, so another group's play would satisfy a check over the whole output.
base_groups=()
for g in decdn_nodes sponsord_hosts; do
  [[ -z ${member[$g]:-} ]] || base_groups+=("$g")
done
"$repo/cloud-init/baseline-plays.sh" "$INVENTORY" "${base_groups[@]}" \
  || die "--tags baseline would not harden this host (see above; was the baseline role or its tag removed from a play?)"

# --- 3. Converge ----------------------------------------------------------------
missing=()
missing_groups=()
for g in "${groups_in[@]}"; do
  read -ra files <<<"${SECRETS[$g]}"
  before=${#missing[@]}
  for f in "${files[@]}"; do
    [[ -e $f ]] || missing+=("$f")
  done
  ((${#missing[@]} == before)) || missing_groups+=("$g")
done

if ((${#missing[@]} == 0)); then
  ansible-playbook -i "$INVENTORY" playbooks/site.yml "${extra_args[@]}"
  set_state complete
else
  ansible-playbook -i "$INVENTORY" playbooks/site.yml --tags baseline "${extra_args[@]}"
  set_awaiting "${missing[@]}"
  set_state awaiting-secret
fi
# The final state is recorded: a session dropping while the hint below prints must not
# rewrite it to "failed".
trap - EXIT HUP INT TERM

state=$(<"$STATE_FILE")
echo "decdn-bootstrap: $state"
[[ $state == awaiting-secret ]] || exit 0

echo "Missing on this host: ${missing[*]}"
echo "Next: SSH in as your admin account and write them (never in user-data):"
for g in "${missing_groups[@]}"; do
  case $g in
    decdn_nodes)
      cat <<'EOF'

The node's RPC endpoint (the URL may embed an API key):
  umask 077
  sudo mkdir -p /etc/decdn
  echo 'DECDN_RPC_URL=https://…' | sudo tee /etc/decdn/decdn.env >/dev/null
  sudo chmod 600 /etc/decdn/decdn.env
EOF
      ;;
    sponsord_hosts)
      cat <<'EOF'

sponsord's treasury wallet (the one that owns sponsord_pool_id) and its RPC endpoint.
secret.env holds SPONSORD_RPC_URL and nothing else:
  umask 077
  sudo mkdir -p /etc/sponsord
  sudo install -m 0600 treasury-keystore.json /etc/sponsord/treasury-keystore.json
  sudo install -m 0600 treasury-password      /etc/sponsord/treasury-password
  echo 'SPONSORD_RPC_URL=https://…' | sudo tee /etc/sponsord/secret.env >/dev/null
  sudo chmod 600 /etc/sponsord/secret.env
EOF
      ;;
    sponsord_onramp_hosts)
      cat <<'EOF'

The onramp's Cloudflare Turnstile secret:
  umask 077
  printf '%s' '<secret>' | sudo tee /etc/sponsord/turnstile-secret >/dev/null
  sudo chmod 600 /etc/sponsord/turnstile-secret
EOF
      ;;
    *)
      cat <<EOF

The secrets of $g: cloud-init/README.md of decdn/devops says where they go.
EOF
      ;;
  esac
done
echo
echo "Then run: sudo decdn-bootstrap"
