#!/usr/bin/env bash
# Fail when an inventory vault file is not ansible-vault encrypted. A vault.yml (or
# .yaml, .json) anywhere under a group_vars/<group>/ or host_vars/<host>/ directory
# (Ansible loads those directories recursively) is the one secrets file this
# repository commits, so it must hold ciphertext and nothing else: the exact
# ansible-vault header, then hex lines only. The plaintext secret.yml beside it stays
# git-ignored.
#
#   scripts/check-vault-encrypted.sh [file ...]       (the pre-commit hook passes files)
#   scripts/check-vault-encrypted.sh --inventory DIR  (every vault file under DIR)
#   scripts/check-vault-encrypted.sh                  (the same, for inventory/)
set -euo pipefail

# The first line ansible-vault writes: format 1.1, or 1.2 with a --vault-id label.
# shellcheck disable=SC2016  # a literal $ in the regex, not an expansion
header_re='^\$ANSIBLE_VAULT;1\.[12];AES256(;[[:graph:]]+)?$'

files=()
if (($# == 0)) || [[ $1 == --inventory ]]; then
  (($# <= 2)) || { echo "usage: check-vault-encrypted.sh [file ...] | --inventory DIR" >&2; exit 2; }
  inventory="${2:-inventory}"
  [[ -d $inventory ]] || { echo "check-vault-encrypted: no $inventory/ directory" >&2; exit 2; }
  dirs=()
  for d in "$inventory/group_vars" "$inventory/host_vars"; do [[ -d $d ]] && dirs+=("$d"); done
  if ((${#dirs[@]})); then
    list="$(find "${dirs[@]}" -mindepth 2 \( -name vault.yml -o -name vault.yaml -o -name vault.json \))"
    while IFS= read -r f; do [[ -n $f ]] && files+=("$f"); done <<<"$list"
  fi
else
  files=("$@")
fi

# encrypted <file>: the header on line 1, then at least one line, every one hex.
encrypted() {
  local first line n=0
  [[ -f $1 && -r $1 ]] || return 1
  {
    IFS= read -r first || return 1
    [[ $first =~ $header_re ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[0-9a-f]+$ ]] || return 1
      n=$((n + 1))
    done
  } <"$1"
  ((n > 0))
}

rc=0
for f in ${files[@]+"${files[@]}"}; do
  encrypted "$f" && continue
  echo "check-vault-encrypted: $f is not ansible-vault encrypted (the vault header, then only ciphertext). Encrypt it before committing (ansible-vault encrypt $f), and change it with ansible-vault edit, never by decrypting it in place or appending to it." >&2
  rc=1
done
exit "$rc"
