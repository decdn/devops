#!/usr/bin/env bash
# Usage (from ansible/, for ansible.cfg): baseline-plays.sh <inventory> <group>...
#
# Exit 0 when, under `--tags baseline`, every playbooks/site.yml play for each named
# group that lists localhost selects a baseline task, and each group has one; 1
# otherwise (baseline-plays.awk says which), or on any ansible-playbook failure.
# bootstrap.sh runs it before relying on `--tags baseline` to harden the host, and
# tests/scripts-test.sh runs it against the real playbooks, so both use this command
# line.
set -euo pipefail

(($# >= 2)) || { echo "usage: baseline-plays.sh <inventory> <group>..." >&2; exit 2; }
inventory=$1
shift
plays=$(ansible-playbook -i "$inventory" playbooks/site.yml --tags baseline --list-hosts --list-tasks)
awk -v groups="$*" -f "$(dirname "${BASH_SOURCE[0]}")/baseline-plays.awk" <<<"$plays"
