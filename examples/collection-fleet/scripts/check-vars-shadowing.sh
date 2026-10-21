#!/usr/bin/env bash
# Fail when two vars sources in inventory/group_vars/ or inventory/host_vars/ share a
# name. Ansible loads the first of <name> (a file or a directory), <name>.yml,
# <name>.yaml and <name>.json that exists, and ignores the rest without a word: a
# group_vars/decdn_nodes/ directory (made, say, to hold a git-ignored secret.yml)
# silently drops every setting in group_vars/decdn_nodes.yml beside it.
#
#   scripts/check-vars-shadowing.sh [inventory dir]   (default: inventory)
#
# The pre-commit hook runs it on your working tree, where git-ignored secret.yml
# files exist; CI runs it on the tracked files.
set -euo pipefail

inventory="${1:-inventory}"
[[ -d $inventory ]] || { echo "check-vars-shadowing: no $inventory/ directory" >&2; exit 2; }
shopt -s nullglob dotglob
rc=0
for dir in "$inventory/group_vars" "$inventory/host_vars"; do
  declare -A seen=()
  for path in "$dir"/*; do
    entry="${path##*/}" name="${path##*/}"
    if [[ -f $path ]]; then
      case $entry in *.yml | *.yaml | *.json) name="${entry%.*}" ;; esac
    fi
    seen[$name]+="${seen[$name]:+ }$entry"
  done
  for name in "${!seen[@]}"; do
    read -ra entries <<<"${seen[$name]}"
    ((${#entries[@]} > 1)) || continue
    echo "check-vars-shadowing: $dir/ has ${entries[*]}: Ansible reads only one of them, and ignores the rest without a word. Merge them into $name/ (main.yml beside secret.yml, say)." >&2
    rc=1
  done
  unset seen
done
exit "$rc"
