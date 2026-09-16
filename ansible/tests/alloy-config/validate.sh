#!/usr/bin/env bash
# Validate roles/grafana_alloy's rendered output against a REAL Grafana Alloy
# binary — the pinned one operators actually install.
#
# The molecule `grafana-cloud` scenario runs the role against a stub that exits 0
# for every subcommand: excellent for proving plumbing, worthless for proving the
# configuration is loadable. `alloy validate` builds the component graph, so it
# catches the whole class the stub waves through — illegal '#' comments, a
# component that does not exist, a block nested in the wrong parent. The unit
# check does the same for ExecStart: every flag must exist in `alloy run --help`.
#
# The binary comes from the SAME pinned .deb + sha256 the role installs
# (roles/grafana_alloy/defaults/main.yml, handed over by render.yml), so bumping
# grafana_alloy_version without re-pinning the digest fails here rather than on a
# production host.
#
# Usage:
#   ansible/tests/alloy-config/validate.sh
#   ALLOY_BIN=/path/to/alloy ansible/tests/alloy-config/validate.sh   # skip the download
#   ALLOY_CACHE_DIR=~/.cache/alloy ansible/tests/alloy-config/validate.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ansible_dir="$(cd "$here/../.." && pwd)"

work=""
cleanup() {
  if [ -n "$work" ]; then rm -rf "$work"; fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
render_dir="$work/render"
mkdir -p "$render_dir"

# --- Render every variable combination ---------------------------------------
# Also drops pin.env (the role's pinned version + digests) into render_dir.
# Run from ansible/ so the project's ansible.cfg applies (interpreter discovery
# stays quiet; `become` is overridden per-play).
# Run from ansible/ so the project's ansible.cfg applies (quiet interpreter
# discovery; its project-wide `become` is overridden per play in render.yml).
(cd "$ansible_dir" && ALLOY_RENDER_DIR="$render_dir" \
  ansible-playbook -i localhost, -c local "$here/render.yml" >/dev/null) \
  || fail "rendering roles/grafana_alloy templates failed (re-run: ansible-playbook $here/render.yml)"

shopt -s nullglob
configs=("$render_dir"/*.alloy)
units=("$render_dir"/*.service)
[ "${#configs[@]}" -gt 0 ] || fail "render.yml produced no configuration files"
[ "${#units[@]}" -gt 0 ] || fail "render.yml produced no systemd units"

# --- Resolve the pinned release ----------------------------------------------
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) fail "unsupported architecture $(uname -m) — the role pins amd64/arm64 only" ;;
esac

# shellcheck source=/dev/null  # generated above from the role's own defaults
. "$render_dir/pin.env"
version="$GRAFANA_ALLOY_VERSION"
case "$arch" in
  amd64) sha256="$GRAFANA_ALLOY_SHA256_AMD64" ;;
  arm64) sha256="$GRAFANA_ALLOY_SHA256_ARM64" ;;
esac
[ -n "$version" ] || fail "grafana_alloy_version is empty in the role defaults"

cache_dir="${ALLOY_CACHE_DIR:-$ansible_dir/.cache/alloy}/$version-$arch"
alloy="${ALLOY_BIN:-$cache_dir/alloy}"

if [ ! -x "$alloy" ]; then
  if [ -n "${ALLOY_BIN:-}" ]; then
    fail "ALLOY_BIN=$ALLOY_BIN is not an executable file"
  fi
  [ -n "$sha256" ] || fail "no grafana_alloy_sha256 pin for $arch in the role defaults"
  deb="alloy-$version-1.$arch.deb"
  url="https://github.com/grafana/alloy/releases/download/v$version/$deb"
  echo "fetching pinned Grafana Alloy $version ($arch)"
  curl -fsSL --retry 3 -o "$work/$deb" "$url"
  echo "$sha256  $work/$deb" | sha256sum --check --status || fail \
    "sha256 mismatch for $deb — grafana_alloy_version and grafana_alloy_sha256 must be bumped together"
  dpkg-deb -x "$work/$deb" "$work/unpacked" \
    || fail "dpkg-deb is required to unpack the pinned .deb (or point ALLOY_BIN at a binary)"
  mkdir -p "$cache_dir"
  install -m 0755 "$work/unpacked/usr/bin/alloy" "$cache_dir/alloy"
fi

echo "using $("$alloy" --version | head -1)"

# --- Gate 1: the configuration loads -----------------------------------------
# No credentials are exported on purpose: sys.env() on an unset variable yields
# "" and still validates, which is exactly the property the role's deploy-time
# gate relies on (it runs before any secret is in scope).
for config in "${configs[@]}"; do
  name="$(basename "$config")"
  "$alloy" validate "$config" || fail "alloy validate rejected $name"
  if grep -qE '^[[:space:]]*#' "$config"; then
    fail "$name contains a '#' comment — Alloy's syntax only accepts // and /* */"
  fi
  # shellcheck disable=SC2016  # literal '${GC_' is the point: Alloy never expands it
  if grep -qF '${GC_' "$config"; then
    fail "$name still carries a \${GC_*} placeholder — Alloy never expands those; use sys.env(\"GC_…\")"
  fi
  if ! grep -qF 'sys.env("GC_API_TOKEN")' "$config"; then
    fail "$name does not read the API token via sys.env — credentials must never be literals"
  fi
  echo "ok: $name"
done

# --- Gate 2: every ExecStart flag exists -------------------------------------
# `alloy run` ignores nothing: an unknown flag exits non-zero, i.e. a systemd
# crash-loop on the target host the moment the unit starts.
known_flags="$("$alloy" run --help 2>&1 | grep -oE '(^|[[:space:]])--[a-zA-Z0-9.-]+' | tr -d '[:blank:]')"
for unit in "${units[@]}"; do
  name="$(basename "$unit")"
  while read -r flag; do
    [ -n "$flag" ] || continue
    grep -qxF -- "$flag" <<<"$known_flags" \
      || fail "$name passes $flag to \`alloy run\`, which Alloy $version does not define"
  done < <(grep -oE '^[[:space:]]*--[a-zA-Z0-9.-]+' "$unit" | tr -d '[:blank:]')
  echo "ok: $name"
done

echo "PASS: roles/grafana_alloy renders configuration Alloy $version accepts"
