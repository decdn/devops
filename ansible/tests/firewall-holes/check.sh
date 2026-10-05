#!/usr/bin/env bash
# The baseline firewall's public holes are derived from a host's groups in
# playbooks/group_vars/ (all.yml builds the list; decdn_nodes.yml and
# sponsord_hosts.yml both point baseline_extra_inbound at it). Resolve them for
# every host shape in inventory.yml, outside any role, which is how the sponsord
# play sees a co-located node, and compare with expected.json.
# Needs ansible-core and jq. tests/scripts-test.sh runs it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
playbooks="$here/../../playbooks"

got="$(
  # From this directory, so ansible/ansible.cfg (inventory, become) is not read.
  cd "$here"
  ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=json ANSIBLE_DEPRECATION_WARNINGS=0 \
    ansible all -i "$here/inventory.yml" --playbook-dir "$playbooks" \
      -m ansible.builtin.debug -a var=baseline_extra_inbound </dev/null \
  | jq -S '[.plays[0].tasks[0].hosts | to_entries[] | {key, value: .value.baseline_extra_inbound}] | from_entries'
)"
want="$(jq -S . "$here/expected.json")"

if [[ "$got" != "$want" ]]; then
  echo "baseline_extra_inbound differs from expected.json:" >&2
  diff <(echo "$want") <(echo "$got") >&2 || true
  exit 1
fi
echo "baseline_extra_inbound matches for $(jq -r 'keys | join(", ")' <<<"$want")"
