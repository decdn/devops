#!/usr/bin/env bash
# Downloads the `decdn` CLI of the decdn/decdn release the chart pins
# (`appVersion`), verified as the decdn_node role verifies a release, and prints
# its path. CI's `helm` job runs the chart's render tests against it:
#
#   DECDN_CLI="$(scripts/fetch-decdn-cli.sh "$RUNNER_TEMP/decdn")"
#   export DECDN_CLI
#   make lint-helm
#
# (Not `DECDN_CLI="$(…)" make lint-helm` on one line: that drops the fetch's exit
# status, and lint-helm then skips the check instead of failing.)
#
# Usage:  scripts/fetch-decdn-cli.sh <dir>
#
# Linux only (the release ships linux-gnu binaries). <dir> is created if missing
# and receives the binary; nothing else is written there, and nothing at all
# unless every check passes. Progress goes to stderr, the path alone to stdout.
#
# SHA256SUMS must carry a good signature from a still-valid key in the vendored
# ansible/roles/decdn_node/files/decdn-release-KEYS.asc, and no other signature
# gpg rejects; the archive must match exactly one manifest entry; and the binary
# must report `decdn <version>` (roles/decdn_node/tasks/install.yml has the
# reasons for each).
#
# A release line (X.Y, as the chart's appVersion is) resolves to its newest
# finished release as roles/decdn_node/tasks/resolve-release.yml resolves one: the
# highest vX.Y.N that is not a draft or a prerelease and has a SHA256SUMS.asc
# asset, from GitHub's release list (sent with GITHUB_TOKEN when it is set and the
# list is GitHub's API, which lifts the unauthenticated rate limit; an override
# never gets the token).
#
# Overrides, for the tests' fixture release: DECDN_VERSION (default: the chart's
# appVersion; X.Y or X.Y.Z), DECDN_RELEASE_INDEX (default: decdn/decdn's GitHub
# release list), DECDN_RELEASE_BASE (default: decdn/decdn's GitHub releases; any
# URL curl takes, file:// included, for both) and DECDN_RELEASE_KEYS (default: the
# vendored keyring). Each override is reported on stderr.
#
# Exit: 0 done; 1 any failure; 2 usage.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 1 && -n "$1" && "$1" != -* ]] || {
  sed -n 's/^# Usage: *//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}
dest="$1"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version="${DECDN_VERSION:-$(sed -nE 's/^appVersion: *"?([^" #]*)"?.*/\1/p' "$root/charts/decdn-node/Chart.yaml")}"
# The version lands in a URL and a file name: a release number and nothing else.
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
  die "the decdn version is '$version', not X.Y or X.Y.Z (charts/decdn-node/Chart.yaml appVersion)"
index="${DECDN_RELEASE_INDEX:-https://api.github.com/repos/decdn/decdn/releases?per_page=100}"
base="${DECDN_RELEASE_BASE:-https://github.com/decdn/decdn/releases/download}"
keys="${DECDN_RELEASE_KEYS:-$root/ansible/roles/decdn_node/files/decdn-release-KEYS.asc}"
for v in DECDN_VERSION DECDN_RELEASE_INDEX DECDN_RELEASE_BASE DECDN_RELEASE_KEYS; do
  [[ -z "${!v:-}" ]] || echo "note: $v=${!v} overrides the default" >&2
done
[[ -f "$keys" ]] || die "no release keyring at $keys"

if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  # The token goes to GitHub's API only, never to an index override (a mirror).
  auth=()
  if [[ -n "${GITHUB_TOKEN:-}" && "$index" == https://api.github.com/* ]]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  releases=$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" "$index") ||
    die "cannot read the decdn release list at $index"
  patch=$(python3 -I -c '
import json, re, sys
want = re.compile(r"v" + re.escape(sys.argv[1]) + r"\.(0|[1-9][0-9]*)")
best = -1
for r in json.loads(sys.stdin.read()):
    m = want.fullmatch(r.get("tag_name") or "")
    if m and not r.get("draft", True) and not r.get("prerelease", True) \
            and "SHA256SUMS.asc" in [a.get("name") for a in r.get("assets", [])]:
        best = max(best, int(m.group(1)))
print(best)
' "$version" <<<"$releases") || die "the decdn release list at $index is not a JSON release list"
  [[ "$patch" -ge 0 ]] || die "no finished v$version.N decdn release in $index"
  echo "decdn $version resolves to $version.$patch" >&2
  version="$version.$patch"
fi
# The triples roles/decdn_node/vars/main/arch.yml maps.
[[ "$(uname -s)" == Linux ]] || die "decdn releases Linux binaries only; this is $(uname -s)"
case "$(uname -m)" in
  x86_64) target=x86_64-unknown-linux-gnu ;;
  aarch64) target=aarch64-unknown-linux-gnu ;;
  *) die "unsupported architecture $(uname -m): decdn releases x86_64 and aarch64 only" ;;
esac
archive="decdn-$version-$target.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "fetching decdn v$version ($target)" >&2
for f in SHA256SUMS SHA256SUMS.asc "$archive"; do
  curl -fsSL --retry 3 --retry-connrefused -o "$work/$f" "$base/v$version/$f" ||
    die "could not download $base/v$version/$f"
done

# An isolated GNUPGHOME: "signed by a key in the vendored KEYS", never "by any key
# this machine trusts". gpg must exit 0 (no signature it rejects, as in the role),
# and its status output must show a good signature from a key that is neither
# expired nor revoked: `gpg --verify` exits 0 for those. On failure, gpg's own
# output says why (a NO_PUBKEY names the key a rotated KEYS would need).
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpgfail() { cat "$work/gpg.log" "$work/gpg-status" >&2 2>/dev/null || true; die "$@"; }
: >"$work/gpg-status"
gpg --batch --quiet --no-autostart --import "$keys" 2>"$work/gpg.log" ||
  gpgfail "could not import $keys"
rc=0
gpg --batch --no-autostart --status-fd 3 --verify "$work/SHA256SUMS.asc" "$work/SHA256SUMS" \
  3>"$work/gpg-status" 2>"$work/gpg.log" || rc=$?
if grep -qE '^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG|EXPSIG)' "$work/gpg-status"; then
  gpgfail "SHA256SUMS of v$version is signed by an EXPIRED or REVOKED key, or the signature expired: re-sync $keys from upstream KEYS"
fi
if ((rc != 0)) || ! grep -q '^\[GNUPG:\] VALIDSIG ' "$work/gpg-status"; then
  gpgfail "SHA256SUMS of v$version carries no good signature from a key in $keys, or one gpg rejects (gpg exited $rc)"
fi

# The archive's name field, matched exactly once (not a substring, not a count of OKs).
entry=$(awk -v f="$archive" 'substr($0, index($0, " ") + 2) == f' "$work/SHA256SUMS")
n=$(printf '%s\n' "$entry" | grep -c . || true)
[[ "$n" -eq 1 ]] || die "SHA256SUMS has $n entries for $archive (expected exactly 1)"
(cd "$work" && printf '%s\n' "$entry" | sha256sum --check --strict --quiet -) ||
  die "$archive does not match SHA256SUMS"

# Each archive holds exactly one flat binary. Checked before it is installed, with
# the role's release-mode backstop: exactly `decdn <version>`.
mkdir "$work/bin"
tar -xzf "$work/$archive" -C "$work/bin" decdn || die "$archive holds no flat \`decdn\` binary"
got=$("$work/bin/decdn" --version) || die "decdn --version failed"
[[ "$got" == "decdn $version" ]] || die "the binary reports '$got', not 'decdn $version'"
echo "$got" >&2
mkdir -p "$dest"
install -m 0755 "$work/bin/decdn" "$dest/decdn"
printf '%s\n' "$dest/decdn"
