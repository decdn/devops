#!/usr/bin/env bash
# Stage 2 of the cloud-init bootstrap (see README.md). Stage 1 is the small
# /usr/local/sbin/decdn-bootstrap that user-data.yaml writes. It clones this repo at the
# pinned ref, verifies the checkout, then execs this script from it.
#
# This script turns the host into a node by running ansible/playbooks/site.yml against
# localhost:
#   1. Install the pinned ansible-core into a venv, with hashes enforced
#      (requirements.txt), and the pinned Galaxy collections (collections.lock.yml).
#   2. Syntax-check site.yml and check that the inventory puts localhost in decdn_nodes.
#      Without that membership the play matches no host and exits 0, and the udp/4433
#      hole in playbooks/group_vars/decdn_nodes.yml never loads.
#   3. Pick the phase:
#      - no /etc/decdn/decdn.env: run `baseline` only (SSH, firewall, patching,
#        the admin account), then record "awaiting-secret". The node role would stop at
#        its RPC gate anyway, so stopping here keeps cloud-init's status clean.
#      - decdn.env present: run the whole playbook (install, keystore, service), then
#        record "complete".
#
# Re-running it is how the operator continues after writing decdn.env, and how a host
# picks up a new pinned ref: `sudo decdn-bootstrap`.
set -Eeuo pipefail

readonly CONF_DIR=/etc/decdn-bootstrap
readonly INVENTORY=$CONF_DIR/inventory.yml
readonly VENV=/opt/decdn-bootstrap/venv
readonly STATE_DIR=/var/lib/decdn-bootstrap
readonly STATE_FILE=$STATE_DIR/state
readonly LOGIN_HINT=/etc/profile.d/decdn-bootstrap.sh
# The decdn_node role's default decdn_env_file (roles/decdn_node/defaults/main.yml).
readonly ENV_FILE=/etc/decdn/decdn.env

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo

# World-readable on purpose: the login hint below runs as the admin account.
set_state() {
  install -d -m 0755 "$STATE_DIR"
  printf '%s\n' "$1" >"$STATE_FILE.tmp"
  chmod 0644 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

die() {
  echo "decdn-bootstrap: $*" >&2
  [[ $EUID -ne 0 ]] || set_state failed
  exit 1
}

trap 'set_state failed; echo "decdn-bootstrap: FAILED (see the output above; re-run: sudo decdn-bootstrap)" >&2' ERR

[[ $EUID -eq 0 ]] || die "run as root (sudo decdn-bootstrap)"
[[ -f $INVENTORY ]] || die "$INVENTORY is missing (it is written by the cloud-init user-data)"
if grep -n 'CHANGE_ME' "$INVENTORY" >&2; then
  die "$INVENTORY still has CHANGE_ME placeholders (the lines above); edit them, then re-run"
fi

# Extra ansible-playbook arguments from bootstrap.env, for example
# `--skip-tags baseline` in the containerised CI test. Split on whitespace.
read -ra extra_args <<<"${DECDN_BOOTSTRAP_ANSIBLE_ARGS:-}"

set_state running

# A login hint for the admin account, written before anything can fail so that a failed
# first boot shows it too. It prints nothing once the node is complete. It lives in
# /etc/profile.d rather than a MOTD, because DevSec ssh_hardening disables the PAM motd.
cat >"$LOGIN_HINT" <<EOF
# Written by decdn-bootstrap ($repo/cloud-init/bootstrap.sh).
case "\$(cat $STATE_FILE 2>/dev/null)" in
  running)
    echo "deCDN: the bootstrap is running (cloud-init status --wait; log: /var/log/cloud-init-output.log)" ;;
  awaiting-secret)
    echo "deCDN: hardened, waiting for its RPC secret. Write 0600 $ENV_FILE, then run: sudo decdn-bootstrap" ;;
  failed)
    echo "deCDN: the last bootstrap run FAILED. Re-run it: sudo decdn-bootstrap" ;;
esac
EOF
chmod 0644 "$LOGIN_HINT"

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
members=$(ansible -i "$INVENTORY" decdn_nodes --list-hosts)
grep -qE '^\s+localhost$' <<<"$members" \
  || die "$INVENTORY does not put localhost in the decdn_nodes group (site.yml would match nothing)"

# --- 3. Converge ----------------------------------------------------------------
if [[ -e $ENV_FILE ]]; then
  ansible-playbook -i "$INVENTORY" playbooks/site.yml "${extra_args[@]}"
  set_state complete
else
  ansible-playbook -i "$INVENTORY" playbooks/site.yml --tags baseline "${extra_args[@]}"
  set_state awaiting-secret
fi

state=$(<"$STATE_FILE")
echo "decdn-bootstrap: $state"
if [[ $state == awaiting-secret ]]; then
  cat <<EOF
Next: SSH in as your admin account and write the RPC endpoint (the URL may embed an API key,
so it never goes in user-data):
  umask 077
  sudo mkdir -p /etc/decdn
  echo 'DECDN_RPC_URL=https://…' | sudo tee $ENV_FILE >/dev/null
  sudo chmod 600 $ENV_FILE
  sudo decdn-bootstrap
EOF
fi
