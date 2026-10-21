#!/usr/bin/env bash
# Check the playbooks the built collections ship, as a Galaxy consumer runs them:
#
#   galaxy/check-playbooks.sh node|publisher   (`make galaxy-check-<collection>` runs it)
#
# Installs the collection's tarball under build/ (decdn.publisher's with the decdn.node
# one it depends on) into a scratch collections path, then
#   - syntax-checks every playbook it ships by its FQCN (decdn.node.node, …), which
#     resolves each static role reference against the installed collections (not an
#     include_role's: stage-playbooks.py checks those names and their tasks_from, and
#     molecule/collection runs decdn.node's);
#   - runs tests/firewall-holes/check.sh on its playbooks/, which runs a probe AS a
#     collection playbook: the firewall holes must come out as they do from
#     ansible/playbooks/, so the shipped group_vars/ load and agree;
#   - runs examples/collection-fleet as a private copy of it runs (its ansible.cfg,
#     the collection's hosts example as inventory/hosts.yml): the inventory parses,
#     and every decdn.<collection>.<playbook> its docs and CI name ships and passes a
#     syntax check. Its tracked files only, so stage a new one first.
# galaxy-importer cannot do the first: its ansible-lint sees one collection, outside
# any collections path, so it only warns that it cannot find the roles.
# The roles' own dependencies (devsec.hardening, ansible.posix) come from `make deps`
# (ansible/collections) or ANSIBLE_COLLECTIONS_PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # ansible/galaxy
ansible_dir="$(cd "$here/.." && pwd)"                  # ansible/
build_dir="$ansible_dir/build"

collection="${1:-}"
case "$collection" in
  node) needs=(node) ;;
  publisher) needs=(node publisher) ;;
  *) echo "usage: $0 node|publisher" >&2; exit 2 ;;
esac
shopt -s nullglob
tarballs=()
for c in "${needs[@]}"; do
  found=("$build_dir"/decdn-"$c"-*.tar.gz)
  ((${#found[@]} == 1)) || { echo "check-playbooks.sh: want one decdn-$c tarball under build/ (make build-$c): ${found[*]:-none}" >&2; exit 1; }
  tarballs+=("${found[0]}")
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --no-deps: decdn.publisher's dependency is the decdn.node tarball installed with
# it, and the rest is already vendored. Ansible refuses a non-blocking stdio, so the
# output goes to a file, never a pipe.
ansible-galaxy collection install --no-deps -p "$work" "${tarballs[@]}" </dev/null >"$work/install.log" 2>&1 \
  || { cat "$work/install.log" >&2; echo "check-playbooks.sh: could not install the built collections" >&2; exit 1; }
export ANSIBLE_COLLECTIONS_PATH="$work:$ansible_dir/collections${ANSIBLE_COLLECTIONS_PATH:+:$ANSIBLE_COLLECTIONS_PATH}"
export ANSIBLE_DEPRECATION_WARNINGS=0
# Hermetic: no roles path (an exported ANSIBLE_ROLES_PATH, ~/.ansible/roles or a
# config's roles_path could stand in for a role the collections lack) and no config
# file from the caller.
mkdir "$work/no-roles"
export ANSIBLE_ROLES_PATH="$work/no-roles"
unset ANSIBLE_CONFIG

inventory="$ansible_dir/tests/firewall-holes/inventory.yml"
playbooks="$work/ansible_collections/decdn/$collection/playbooks"
n=0
for pb in "$playbooks"/*.yml; do
  fqcn="decdn.$collection.$(basename "$pb" .yml)"
  # From the scratch dir, so no ansible.cfg is read.
  (cd "$work" && ansible-playbook -i "$inventory" "$fqcn" --syntax-check </dev/null >"$work/syntax.log" 2>&1) \
    || { cat "$work/syntax.log" >&2; echo "check-playbooks.sh: $fqcn fails its syntax check" >&2; exit 1; }
  n=$((n + 1))
done
((n > 0)) || { echo "check-playbooks.sh: decdn.$collection ships no playbook" >&2; exit 1; }
echo "ok   decdn.$collection: $n playbooks pass a syntax check by FQCN"

# examples/collection-fleet, as a private copy of it runs: its tracked files, its
# ansible.cfg (read from the copy's directory; ANSIBLE_COLLECTIONS_PATH stands in for
# its collections/), the collection's hosts example as inventory/hosts.yml. Every
# decdn.<collection>.<playbook> its docs and CI name must ship, and passes a syntax
# check against that inventory, after the inventory parses as its CI parses it.
example="$ansible_dir/../examples/collection-fleet"
fleet="$work/fleet"
mkdir "$fleet"
git -C "$example" ls-files -z | (cd "$example" && xargs -0 cp --parents -t "$fleet") \
  || { echo "check-playbooks.sh: could not copy examples/collection-fleet" >&2; exit 1; }
hosts_example="hosts-$collection.yml.example"
cp "$fleet/inventory/$hosts_example" "$fleet/inventory/hosts.yml"
named="$(cd "$fleet" && grep -ohE "decdn\.$collection\.[a-z_]+" README.md AGENTS.md .github/workflows/ci.yml | sort -u)"
[[ -n $named ]] || { echo "check-playbooks.sh: examples/collection-fleet names no decdn.$collection playbook" >&2; exit 1; }
(cd "$fleet" && ansible-inventory --graph </dev/null >"$work/inventory.log" 2>&1) \
  || { cat "$work/inventory.log" >&2; echo "check-playbooks.sh: examples/collection-fleet's $hosts_example does not parse" >&2; exit 1; }
n=0
for fqcn in $named; do
  [[ -f "$playbooks/${fqcn##*.}.yml" ]] \
    || { echo "check-playbooks.sh: examples/collection-fleet names $fqcn, which decdn.$collection does not ship" >&2; exit 1; }
  (cd "$fleet" && ansible-playbook "$fqcn" --syntax-check </dev/null >"$work/syntax.log" 2>&1) \
    || { cat "$work/syntax.log" >&2; echo "check-playbooks.sh: $fqcn fails its syntax check in examples/collection-fleet" >&2; exit 1; }
  n=$((n + 1))
done
echo "ok   examples/collection-fleet with $hosts_example: the inventory parses and the $n decdn.$collection playbooks it names pass a syntax check"
"$ansible_dir/tests/firewall-holes/check.sh" "$playbooks"
