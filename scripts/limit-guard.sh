#!/usr/bin/env bash
# ansible/Makefile's preflight for every playbook target. Run from ansible/ (the
# Makefile does):
#
#   scripts/limit-guard.sh <inventory> <playbook> <limit, or empty> [ANSIBLE_ARGS...]
#
# ansible-playbook reports success for a run that skips hosts: --limit refuses a host
# missing from the inventory, but a host the plays' own patterns exclude only prints
# "no hosts matched" and exits 0. So `make deploy-node LIMIT=<an origin>` (node.yml
# leaves decdn_origin_nodes to origin.yml), or LIMIT='node-1,origin-1', would report a
# deploy of a host it never touched. This lists the hosts the playbook's plays select
# (--list-hosts, which connects to nothing) and refuses:
#   - a run in which no play selects a host, with or without a LIMIT;
#   - a LIMIT that resolves to any host no play selects, naming each. A group LIMIT
#     that mixes kinds is refused too: subtract what the target does not cover
#     (LIMIT='eu:!decdn_origin_nodes') or use `make deploy`.
# A --limit passed in ANSIBLE_ARGS is not checked, and --syntax-check lists no hosts,
# so it skips the guard.
set -euo pipefail

die() { echo "limit-guard: $*" >&2; exit 1; }
(($# >= 3)) || die "usage: limit-guard.sh <inventory> <playbook> <limit> [ansible-playbook args...]"
inventory=$1 playbook=$2 limit=$3
shift 3
for a in "$@"; do [[ $a == --syntax-check ]] && exit 0; done

limit_args=()
[[ -z $limit ]] || limit_args=(--limit "$limit")
# stdout only: warnings and errors go straight to the terminal.
listing="$(ansible-playbook -i "$inventory" "$playbook" --list-hosts "${limit_args[@]}" "$@" </dev/null)" \
  || die "ansible-playbook --list-hosts failed on $playbook (see the error above)"
# The hosts of every play: the 6-space lines under each "    hosts (N):", up to the
# next line that is not one (--list-tasks in ANSIBLE_ARGS adds a tasks block).
grep -q '^playbook: ' <<<"$listing" || die "could not read ansible-playbook --list-hosts output for $playbook"
selected="$(awk '/^    hosts \([0-9]+\):$/ {on = 1; next} on && /^      [^ ]/ {print $1; next} {on = 0}' \
  <<<"$listing" | sort -u)"

if [[ -z $selected ]]; then
  scope=""
  [[ -z $limit ]] || scope=" within LIMIT='$limit'"
  die "no play in $playbook selects a host of $inventory$scope: the run would do nothing and exit 0"
fi
[[ -n $limit ]] || exit 0

# Every host the LIMIT resolves to in the inventory, whatever its groups.
wanted="$(ansible -i "$inventory" all "${limit_args[@]}" --list-hosts </dev/null)" \
  || die "ansible could not resolve LIMIT='$limit' in $inventory (see the error above)"
wanted="$(awk 'NR > 1 && NF {print $1}' <<<"$wanted" | sort -u)"
[[ -n $wanted ]] || die "LIMIT='$limit' resolves to no host of $inventory"
skipped="$(comm -23 <(printf '%s\n' "$wanted") <(printf '%s\n' "$selected"))"
if [[ -n $skipped ]]; then
  echo "limit-guard: LIMIT='$limit' includes hosts no play in $playbook selects, which the run would skip and still exit 0:" >&2
  while read -r h; do echo "  $h"; done <<<"$skipped" >&2
  case "${playbook##*/}" in
    node.yml) echo "An origin (decdn_origin_nodes) is deployed by the -origin targets, or by deploy/deploy-publisher." >&2 ;;
    origin.yml) echo "A cache node (decdn_nodes, not decdn_origin_nodes) is deployed by the -node targets, or by deploy." >&2 ;;
    *) echo "Check those hosts' groups against the playbook's plays, or narrow LIMIT." >&2 ;;
  esac
  exit 1
fi
