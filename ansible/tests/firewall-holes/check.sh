#!/usr/bin/env bash
# The baseline firewall's public holes are derived from a host's groups in
# playbooks/group_vars/ (all.yml builds the list; decdn_nodes.yml, decdn_origin_nodes.yml,
# sponsord_hosts.yml, iroh_relay_hosts.yml and iroh_dns_server_hosts.yml all point
# baseline_extra_inbound at it). Resolve them for
# every host shape in inventory.yml, outside any role, which is how the sponsord
# play sees a co-located node, and compare with expected.json.
# Needs ansible-core and jq. tests/scripts-test.sh runs it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
playbooks="$here/../../playbooks"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Each host writes its resolved list to <host>.json with the core copy module (the
# json stdout callback lives in ansible.posix, which a core-only install lacks).
# From this directory, so ansible/ansible.cfg (inventory, become) is not read.
(
  cd "$here"
  ANSIBLE_DEPRECATION_WARNINGS=0 ansible all -i "$here/inventory.yml" --playbook-dir "$playbooks" \
    -m ansible.builtin.copy \
    -a "dest=$work/{{ inventory_hostname }}.json content={{ baseline_extra_inbound | to_json }} mode=0600" \
    </dev/null >"$work/ansible.log" 2>&1
) || { cat "$work/ansible.log" >&2; echo "ansible could not resolve the inventory" >&2; exit 1; }
got="$(cd "$work" && jq -S -n '[inputs | {key: (input_filename | rtrimstr(".json")), value: .}] | from_entries' ./*.json \
  | jq -S 'with_entries(.key |= ltrimstr("./"))')"
want="$(jq -S . "$here/expected.json")"

if [[ "$got" != "$want" ]]; then
  echo "baseline_extra_inbound differs from expected.json:" >&2
  diff <(echo "$want") <(echo "$got") >&2 || true
  exit 1
fi
# all.yml falls back to three role defaults outside the roles' plays; they must agree.
roles="$here/../../roles"
grep -qE '^decdn_bind_port: 4433([[:space:]]|$)' "$roles/decdn_node/defaults/main.yml" \
  || { echo "decdn_bind_port's default is not 4433: update the fallback in playbooks/group_vars/all.yml" >&2; exit 1; }
grep -qE '^sponsord_onramp_proxy: caddy([[:space:]]|$)' "$roles/sponsord_onramp/defaults/main.yml" \
  || { echo "sponsord_onramp_proxy's default is not caddy: update the fallback in playbooks/group_vars/all.yml" >&2; exit 1; }
grep -qE '^iroh_relay_enable_quic_addr_discovery: true([[:space:]]|$)' "$roles/iroh_relay/defaults/main.yml" \
  || { echo "iroh_relay_enable_quic_addr_discovery's default is not true: update the fallback in playbooks/group_vars/all.yml" >&2; exit 1; }

echo "baseline_extra_inbound matches for $(jq -r 'keys | join(", ")' <<<"$want")"
