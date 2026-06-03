#!/usr/bin/env bash
# Stage and build the public `decdn.node` Galaxy collection.
#
# Only the roles/baseline + roles/decdn_node sources ship. The internal anvil
# devnet (anvil/caddy/contracts roles) and all deploy machinery (inventory,
# molecule, Makefile, ansible.cfg) are excluded BY CONSTRUCTION — they are simply
# never copied into the staging tree. This keeps the artifact clean and leaves the
# internal project untouched (no galaxy.yml at the project root, so ansible-lint /
# ansible / molecule still see a plain project).
#
# Output: ansible/build/decdn-node-<version>.tar.gz
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # ansible/galaxy
ansible_dir="$(cd "$here/.." && pwd)"                  # ansible/
repo_root="$(cd "$ansible_dir/.." && pwd)"             # repo root

build_dir="$ansible_dir/build"
stage="$build_dir/ansible_collections/decdn/node"
roles=(baseline decdn_node)

echo "staging decdn.node -> $stage"
rm -rf "$stage"
# Drop stale artifacts from earlier builds so the output dir holds exactly the
# tarball we are about to produce (galaxy-check globs build/decdn-node-*.tar.gz).
rm -f "$build_dir"/decdn-node-*.tar.gz
mkdir -p "$stage/roles" "$stage/meta"

# Canonical role sources (shared with the internal project).
for role in "${roles[@]}"; do
  cp -R "$ansible_dir/roles/$role" "$stage/roles/$role"
done

# Collection overlay + license (the artifact must be self-contained).
cp "$here/galaxy.yml" "$stage/galaxy.yml"
cp "$here/README.md" "$stage/README.md"
cp "$here/CHANGELOG.md" "$stage/CHANGELOG.md"
cp "$here/meta/runtime.yml" "$stage/meta/runtime.yml"
cp "$repo_root/LICENSE" "$stage/LICENSE"

# ansible-galaxy validates galaxy.yml (required keys, semver, tag charset) here.
ansible-galaxy collection build "$stage" --output-path "$build_dir" --force

shopt -s nullglob
for tarball in "$build_dir"/decdn-node-*.tar.gz; do
  echo "built: $tarball"
done
