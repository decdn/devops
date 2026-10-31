#!/usr/bin/env bash
# The baseline firewall's public holes are derived from a host's groups in
# playbooks/group_vars/ (all.yml builds the list; decdn_nodes.yml, decdn_origin_nodes.yml,
# sponsord_hosts.yml, iroh_relay_hosts.yml, iroh_dns_server_hosts.yml and
# decdn_gateway_hosts.yml all point baseline_extra_inbound at it). Resolve them for
# every host shape in inventory.yml, outside any role, which is how the sponsord
# play sees a co-located node, and compare with expected.json.
# Needs ansible-core and jq. tests/scripts-test.sh runs it.
#   check.sh [<playbook-dir>]   default ansible/playbooks. For an installed
#   collection's .../ansible_collections/<ns>/<name>/playbooks (galaxy/check-playbooks.sh),
#   it runs a probe as the collection playbook <ns>.<name>.firewall_holes_probe
#   instead, which proves the group_vars/ beside a collection playbook load.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
playbooks="${1:-$here/../../playbooks}"
[[ -d "$playbooks/group_vars" ]] || { echo "$playbooks has no group_vars/" >&2; exit 1; }

work="$(mktemp -d)"
probe=""   # the probe playbook, while it sits in a collection's playbooks/
trap 'rm -rf "$work"; [[ -z "$probe" ]] || rm -f "$probe"' EXIT

collection_re='^(.*)/ansible_collections/([a-z0-9_]+)/([a-z0-9_]+)/playbooks$'
playbooks="$(cd "$playbooks" && pwd)"
mode="playbook-dir"
if [[ "$playbooks" =~ $collection_re ]]; then
  mode="collection"
  root="${BASH_REMATCH[1]}" fqcn="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.firewall_holes_probe"
  probe="$playbooks/firewall_holes_probe.yml"
elif [[ "$playbooks" == */ansible_collections/* ]]; then
  # Never fall back to the weaker mode for something that looks like a collection.
  echo "$playbooks is under ansible_collections/ but not a collection's playbooks/" >&2
  exit 1
fi
# Each host writes its resolved list to <host>.json with the core copy module (the
# json stdout callback lives in ansible.posix, which a core-only install lacks).
# From this directory, so ansible/ansible.cfg (inventory, become) is not read.
(
  cd "$here"
  export ANSIBLE_DEPRECATION_WARNINGS=0
  if [[ "$mode" == collection ]]; then
    cat >"$probe" <<'PROBE'
---
- name: Write each host's baseline_extra_inbound
  hosts: all
  gather_facts: false
  tasks:
    - name: Write it to <host>.json
      ansible.builtin.copy:
        dest: "{{ probe_out }}/{{ inventory_hostname }}.json"
        content: "{{ baseline_extra_inbound | to_json }}"
        mode: "0600"
PROBE
    ANSIBLE_COLLECTIONS_PATH="$root" ansible-playbook -i "$here/inventory.yml" "$fqcn" -e "probe_out=$work" \
      </dev/null >"$work/ansible.log" 2>&1
  else
    ansible all -i "$here/inventory.yml" --playbook-dir "$playbooks" \
      -m ansible.builtin.copy \
      -a "dest=$work/{{ inventory_hostname }}.json content={{ baseline_extra_inbound | to_json }} mode=0600" \
      </dev/null >"$work/ansible.log" 2>&1
  fi
) || { cat "$work/ansible.log" >&2 2>/dev/null || true; echo "ansible could not resolve the inventory" >&2; exit 1; }
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
grep -qE '^sponsord_onramp_proxy: nginx([[:space:]]|$)' "$roles/sponsord_onramp/defaults/main.yml" \
  || { echo "sponsord_onramp_proxy's default is not nginx: update the fallback in playbooks/group_vars/all.yml" >&2; exit 1; }
grep -qE '^iroh_relay_enable_quic_addr_discovery: true([[:space:]]|$)' "$roles/iroh_relay/defaults/main.yml" \
  || { echo "iroh_relay_enable_quic_addr_discovery's default is not true: update the fallback in playbooks/group_vars/all.yml" >&2; exit 1; }

echo "ok   baseline_extra_inbound matches for $(jq -r 'keys | join(", ")' <<<"$want") ($mode: $playbooks)"
