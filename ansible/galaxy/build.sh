#!/usr/bin/env bash
# Stage and build one of the public Galaxy collections:
#
#   galaxy/build.sh node        decdn.node: what a node operator runs
#   galaxy/build.sh publisher   decdn.publisher: what a publisher runs beside its origins
#
# Only the roles listed in galaxy/<collection>/roles.txt ship, with that directory's
# overlay (galaxy.yml, README.md, CHANGELOG.md, meta/). All deploy machinery
# (inventory, Makefile, ansible.cfg) is excluded BY CONSTRUCTION — it is simply
# never copied into the staging tree. This keeps the artifact clean and leaves the
# internal project untouched (no galaxy.yml at the project root, so ansible-lint
# and ansible still see a plain project).
#
# Output: ansible/build/decdn-<collection>-<version>.tar.gz
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # ansible/galaxy
ansible_dir="$(cd "$here/.." && pwd)"                  # ansible/
repo_root="$(cd "$ansible_dir/.." && pwd)"             # repo root

collection="${1:-}"
case "$collection" in
  node|publisher) ;;
  *) echo "usage: $0 node|publisher" >&2; exit 2 ;;
esac
overlay="$here/$collection"
mapfile -t roles < <(grep -vE '^[[:space:]]*(#|$)' "$overlay/roles.txt")
((${#roles[@]} > 0)) || { echo "build.sh: $overlay/roles.txt lists no role" >&2; exit 1; }

build_dir="$ansible_dir/build"
stage="$build_dir/ansible_collections/decdn/$collection"

echo "staging decdn.$collection -> $stage"
rm -rf "$stage"
# Drop stale artifacts from earlier builds so the output dir holds exactly the
# tarball we are about to produce (galaxy-check globs build/decdn-<collection>-*.tar.gz).
rm -f "$build_dir/decdn-$collection-"*.tar.gz
mkdir -p "$stage/roles" "$stage/meta"

# Canonical role sources (shared with the internal project).
for role in "${roles[@]}"; do
  [[ -d "$ansible_dir/roles/$role" ]] || { echo "build.sh: roles.txt names $role, which is not under roles/" >&2; exit 1; }
  cp -R "$ansible_dir/roles/$role" "$stage/roles/$role"
done

# Collection overlay + license (the artifact must be self-contained).
cp "$overlay/galaxy.yml" "$stage/galaxy.yml"
cp "$overlay/README.md" "$stage/README.md"
cp "$overlay/CHANGELOG.md" "$stage/CHANGELOG.md"
cp "$overlay/meta/runtime.yml" "$stage/meta/runtime.yml"
cp "$repo_root/LICENSE" "$stage/LICENSE"

# ansible-galaxy validates galaxy.yml (required keys, semver, tag charset) here.
ansible-galaxy collection build "$stage" --output-path "$build_dir" --force

shopt -s nullglob
for tarball in "$build_dir/decdn-$collection-"*.tar.gz; do
  echo "built: $tarball"
done
