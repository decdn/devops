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
  # The non-secret endpoints may be inventory literals; the token may NOT. This
  # catches a token pasted into a group_vars file and rendered into the 0644
  # config on the host. Patterns stay in lockstep with the preflight gate
  # ("Refuse a Grafana Cloud token smuggled into inventory"): access-policy
  # tokens, service-account tokens, and base64 JSON API keys.
  if grep -qE 'glc_|glsa_|eyJ' "$config"; then
    fail "$name contains a literal Grafana Cloud token — it belongs only in the 0600 env file"
  fi
  echo "ok: $name"
done

# --- Gate 1b: the machine-monitoring matrix renders what it claims ------------
# `alloy validate` proves each file loads; these greps prove the Jinja branches
# actually switched. Without them a knob could silently render nothing and still
# pass every other gate.
assert_has() {   # file, needle, why
  grep -qF "$2" "$render_dir/$1" || fail "$1 is missing $3 ($2)"
}
assert_lacks() { # file, needle, why
  ! grep -qF "$2" "$render_dir/$1" || fail "$1 unexpectedly contains $3 ($2)"
}

# Defaults: machine metrics, agent self-metrics and journald are all ON, and the
# job labels Grafana Cloud's Linux Server integration dashboards key off.
assert_has defaults.alloy 'prometheus.exporter.unix "host"' "the host metrics exporter"
assert_has defaults.alloy 'prometheus.exporter.self "alloy"' "agent self-monitoring"
assert_has defaults.alloy 'loki.source.journal "host"' "the journald source"
assert_has defaults.alloy 'loki.write "cloud"' "the Loki writer"
assert_has defaults.alloy '"job"' "an explicit job label"
assert_has defaults.alloy 'integrations/node_exporter' "the Grafana Cloud integration job label"
assert_has defaults.alloy '__journal__systemd_unit' "the journal field mapping"
# Daemon log-stream service_name rule. ALIGNMENT-SENSITIVE needles: the
# one-space `target_label = "service_name"` / `replacement = …` forms belong to
# the node-metric identity rule, so only these column-aligned spellings pin the
# journald rule.
assert_has defaults.alloy 'source_labels = ["unit"]' "the unit scoping of the daemon log-stream rule"
assert_has defaults.alloy 'regex         = "decdn-node\\.service"' "the daemon unit match"
assert_has defaults.alloy 'target_label  = "service_name"' "the daemon log-stream service_name rule"
assert_has defaults.alloy 'replacement   = "decdn-node"' "the daemon log-stream service_name value"
assert_has defaults.alloy 'systemd {' "the per-unit systemd collector"
assert_has defaults.alloy 'loki.process "daemon_level"' "the daemon JSON-level stage"
# shellcheck disable=SC2016  # literal backticks: Alloy's raw-string syntax
assert_has defaults.alloy 'selector = `{unit="decdn-node.service"}`' "the daemon unit scoping of the level stage"
assert_has defaults.alloy 'expression = "^(?:debug)$"' "the anchored daemon debug drop"
assert_has logsonly.alloy 'loki.process "daemon_level"' "the daemon JSON-level stage"
assert_lacks logsonly.alloy 'stage.drop' "a daemon level drop after the priority guardrail was cleared"

# Sub-knob isolation.
assert_has hostonly.alloy 'prometheus.exporter.unix "host"' "the host metrics exporter"
assert_lacks hostonly.alloy 'loki.' "log components while logs are disabled"
assert_lacks hostonly.alloy 'prometheus.exporter.self' "self metrics while they are disabled"
assert_lacks hostonly.alloy 'systemd {' "the systemd collector block with no systemd collector enabled"
assert_has logsonly.alloy 'loki.source.journal "host"' "the journald source"
assert_has logsonly.alloy 'path           = "/var/log/journal"' "the explicit journal path"
assert_lacks logsonly.alloy 'prometheus.exporter' "any exporter while only logs are enabled"
assert_lacks logsonly.alloy 'action        = "drop"' "a drop rule after both guardrail regexes were cleared"

# A blank service_name switches the whole identity off together: metric rule,
# journald rule and OTTL statement. The has-check keeps the lacks-checks honest
# (they must not pass merely because logs went missing).
assert_has minimal.alloy 'loki.relabel "journal_identity"' "the journal identity relabeller, which must survive a blank service_name"
assert_lacks minimal.alloy '"service_name"' "any service_name rule (metric or log) once it was blanked"
assert_lacks minimal.alloy 'service.name' "the OTLP service.name attribute once it was blanked"

# BACKWARDS COMPATIBILITY: sub-knobs off == the pre-machine-monitoring pipeline.
assert_lacks legacy.alloy 'prometheus.exporter' "any exporter"
assert_lacks legacy.alloy 'discovery.relabel' "any target relabeller"
assert_lacks legacy.alloy 'loki.' "any log component"
assert_has legacy.alloy 'sys.env("GC_PROM_REMOTE_WRITE_URL")' "the env fallback for remote-write"
assert_has legacy.alloy 'sys.env("GC_PROM_USERNAME")' "the env fallback for the instance ID"
assert_has legacy.alloy 'sys.env("GC_OTLP_ENDPOINT")' "the env fallback for OTLP"
# With nothing in inventory the OTLP username is resolved entirely at runtime:
# the stack-specific key first, the Prometheus ID (what every pre-existing
# deployment used) only as the fallback.
assert_has legacy.alloy 'username = coalesce(sys.env("GC_OTLP_USERNAME"), sys.env("GC_PROM_USERNAME"))' \
  "the OTLP username fallback chain"
assert_lacks legacy.alloy 'GC_LOKI' "a Loki credential lookup while logs are disabled"
assert_lacks legacy.alloy '"job"' "an explicit job label, which did not exist before this change"

# Inventory-driven connection settings: every non-secret sys.env lookup is gone,
# the token's is not.
for key in GC_PROM_REMOTE_WRITE_URL GC_PROM_USERNAME GC_OTLP_ENDPOINT GC_OTLP_USERNAME GC_LOKI_URL GC_LOKI_USERNAME; do
  assert_lacks inventory.alloy "sys.env(\"$key\")" "an env lookup that inventory already supplies"
done
assert_lacks inventory.alloy 'coalesce(' "a runtime fallback where inventory supplies every value"
assert_has inventory.alloy 'https://prometheus-prod-99.render.invalid/api/prom/push' "the inventory remote-write URL"
assert_has inventory.alloy 'https://logs-prod-99.render.invalid/loki/api/v1/push' "the inventory Loki URL"
assert_has inventory.alloy 'sys.env("GC_API_TOKEN")' "the token env lookup, which must never move to inventory"
# Numeric instance IDs arrive from YAML as ints; Alloy needs quoted strings.
assert_has inventory.alloy 'username = "1234567"' "the Prometheus instance ID as a quoted string"
assert_has inventory.alloy 'username = "2345678"' "the OTLP stack instance ID as a quoted string"
assert_has inventory.alloy 'username = "7654321"' "the Loki instance ID as a quoted string"

# The upgrade shape: an inventory Prometheus ID must NOT be silently reused as
# the OTLP username without giving the host's own key precedence.
assert_has otlpfallback.alloy 'username = coalesce(sys.env("GC_OTLP_USERNAME"), "1234567")' \
  "the OTLP username deferring to the host key before the Prometheus ID"

# Escape hatches: the collector veto must remove the collector AND its scoping
# block from the rendered lists (upstream would otherwise re-enable it), and a
# blank node job must restore the implicit component-ID identity.
assert_has vetoed.alloy 'prometheus.exporter.unix "host"' "the host metrics exporter"
assert_lacks vetoed.alloy 'systemd {' "the systemd block for a vetoed collector"
assert_lacks vetoed.alloy 'enable_collectors        =' "an enable list whose only entry was vetoed"
assert_has vetoed.alloy 'disable_collectors       =' "the veto list itself"
assert_has defaults.alloy 'enable_collectors        = ["systemd"]' "the systemd collector on the enable list"
assert_lacks vetoed.alloy '"job"         = "decdn-node"' "a node job label that was explicitly blanked"
assert_has vetoed.alloy 'replacement  = "integrations/node_exporter"' "the host job label"

# Unit hardening follows the enabled signals.
assert_has hostonly.service 'ProtectHome=read-only' "the ProtectHome relaxation host metrics require"
assert_has legacy.service 'ProtectHome=true' "the strict ProtectHome used when host metrics are off"
assert_has logsonly.service 'SupplementaryGroups=systemd-journal adm' "the journal reader groups"
assert_lacks hostonly.service 'SupplementaryGroups' "journal groups while logs are disabled"
assert_lacks legacy.service 'SupplementaryGroups' "journal groups while logs are disabled"
echo "ok: machine-monitoring render matrix"

# --- Gate 1c: the daemon's level comes from its JSON body ----------------------
# Loading proves syntax, not behaviour. Lift the RENDERED
# loki.process "daemon_level" block out of defaults.alloy, feed it sample lines
# through loki.source.api, and read what loki.echo prints: the level label must
# follow the JSON field (in journald's vocabulary), debug must be dropped, and a
# text line or another unit must keep its journald level.
harness="$work/level-harness"
mkdir -p "$harness/data"
read -r api_port http_port < <(python3 -c '
import socket
socks = [socket.socket() for _ in range(2)]
for s in socks: s.bind(("127.0.0.1", 0))
print(*(s.getsockname()[1] for s in socks))')
{
  cat <<ALLOY
loki.source.api "in" {
  http {
    listen_address = "127.0.0.1"
    listen_port    = $api_port
  }
  forward_to = [loki.process.daemon_level.receiver]
}

loki.echo "out" { }

ALLOY
  awk '/^loki\.process "daemon_level" \{/ { on = 1 } on { print } on && /^\}/ { exit }' \
    "$render_dir/defaults.alloy" \
    | sed 's|forward_to = \[loki\.relabel\.journal_identity\.receiver\]|forward_to = [loki.echo.out.receiver]|'
} >"$harness/config.alloy"
grep -qF 'forward_to = [loki.echo.out.receiver]' "$harness/config.alloy" \
  || fail "could not lift loki.process \"daemon_level\" out of defaults.alloy"

"$alloy" run "$harness/config.alloy" --storage.path="$harness/data" \
  --server.http.listen-addr="127.0.0.1:$http_port" >"$harness/alloy.log" 2>&1 &
alloy_pid=$!
trap 'kill "$alloy_pid" 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 100); do
  curl -fs "http://127.0.0.1:$http_port/-/ready" >/dev/null && break
  kill -0 "$alloy_pid" 2>/dev/null || { cat "$harness/alloy.log" >&2; fail "alloy run exited on the level harness"; }
  sleep 0.2
done

now="$(date +%s%N)"
curl -fsS -H 'Content-Type: application/json' "http://127.0.0.1:$api_port/loki/api/v1/push" --data @- <<JSON \
  || fail "pushing sample lines to the level harness failed"
{"streams":[
  {"stream":{"unit":"decdn-node.service","level":"info"},"values":[
    ["$now","{\"level\":\"WARN\",\"fields\":{\"message\":\"m-warn\"}}"],
    ["$now","{\"level\":\"ERROR\",\"fields\":{\"message\":\"m-error\"}}"],
    ["$now","{\"level\":\"DEBUG\",\"fields\":{\"message\":\"m-debug\"}}"],
    ["$now","m-text is not json"]]},
  {"stream":{"unit":"other.service","level":"info"},"values":[
    ["$now","{\"level\":\"ERROR\",\"fields\":{\"message\":\"m-other\"}}"]]}
]}
JSON

# The pipeline is asynchronous: wait for the last expected entry, then assert.
for _ in $(seq 50); do
  [ "$(grep -c 'received log entry' "$harness/alloy.log")" -ge 4 ] && break
  sleep 0.1
done
sleep 0.5 # let a (wrongly) undropped debug line land too
kill "$alloy_pid" 2>/dev/null || true
wait "$alloy_pid" 2>/dev/null || true

assert_entry() { # marker, expected labels, why
  grep -F "$1" "$harness/alloy.log" | grep -qF "labels=\"$2\"" \
    || fail "level harness: $3 — got: $(grep -F "$1" "$harness/alloy.log" || echo '<no entry>')"
}
assert_entry m-warn '{level=\"warning\", unit=\"decdn-node.service\"}' "a JSON WARN must be level=warning"
assert_entry m-error '{level=\"error\", unit=\"decdn-node.service\"}' "a JSON ERROR must be level=error"
assert_entry m-text '{level=\"info\", unit=\"decdn-node.service\"}' "a non-JSON line must keep its journald level"
assert_entry m-other '{level=\"info\", unit=\"other.service\"}' "another unit's JSON must not be re-levelled"
! grep -qF m-debug "$harness/alloy.log" \
  || fail "level harness: a JSON DEBUG line survived the priority guardrail"
echo "ok: daemon log level follows the JSON body"

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
