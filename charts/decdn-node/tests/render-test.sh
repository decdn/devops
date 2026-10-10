#!/usr/bin/env bash
# Render tests for the decdn-node chart. Run via `make lint-helm` from the repo root.
#
#   charts/decdn-node/tests/render-test.sh
#
# Needs: helm, yq (mikefarah v4), python3 >= 3.11 (tomllib), and kubeconform and
# promtool on PATH unless KUBECONFORM / PROMTOOL are overridden.
# Optional env:
#   KUBECONFORM   command to run kubeconform (default: `kubeconform`; the Makefile
#                 passes a digest-pinned container). Set to "" to skip, loudly.
#   PROMTOOL      command to run promtool, reading the rules on stdin (default:
#                 `promtool`; the Makefile passes a digest-pinned container). Set
#                 to "" to skip, loudly.
#   PROMTOOL_IMAGE  promtool's container image, for `promtool test rules`, which
#                 reads files rather than stdin: the test directory is mounted into
#                 it (the Makefile passes the same pinned image). Unset: PROMTOOL is
#                 run in that directory instead, so it must then be a local binary.
#                 Skipped with PROMTOOL.
#   DECDN_CLI     path to a real `decdn` binary: also run `decdn config validate`
#                 on every positive render (catches value/type errors the key check
#                 can't). Skipped, loudly, when unset.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="$(dirname "$here")"
repo="$(cd "$chart/../.." && pwd)"
monitoring="$repo/monitoring"
schema_files="$repo/ansible/molecule/schema/files"
checker="$schema_files/check-schema-keys.py"
kubeconform="${KUBECONFORM-kubeconform}"
promtool="${PROMTOOL-promtool}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
skipped=()

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# grep that distinguishes "no match" (1) from "error, e.g. missing file" (2), so a
# negated check cannot pass because the file under test does not exist.
absent() { # <ERE> <file>
  local rc=0
  grep -qE -- "$1" "$2" || rc=$?
  [ "$rc" -eq 1 ] || { [ "$rc" -eq 0 ] && return 1; fail "grep error ($rc) on $2"; }
}

# --- the shared schema-key checker itself --------------------------------------
fixtures="$schema_files/checker-fixtures"
python3 "$checker" "$fixtures/good.toml" >/dev/null || fail "checker rejects good.toml"
if python3 "$checker" "$fixtures/bad.toml" >/dev/null 2>"$work/bad.err"; then
  fail "checker accepts bad.toml"
fi
while IFS= read -r path; do
  grep -qxF "  $path" "$work/bad.err" || { cat "$work/bad.err" >&2; fail "checker did not flag $path"; }
done < "$fixtures/bad.expected"
: > "$work/empty.toml"
if python3 "$checker" "$work/empty.toml" >/dev/null 2>&1; then fail "checker accepts an empty file"; fi
pass "schema-key checker: good/bad/empty fixtures"

# --- the monitoring symlink -----------------------------------------------------
# The node's dashboards and rules live in the repo's monitoring/decdn-node/, which
# operators on every deploy path import from; the chart reaches them through
# files/monitoring, a relative symlink, because .Files cannot read outside the chart.
# helm package must turn it into regular files, and nothing of sponsord's may ship.
link_target="../../../monitoring/decdn-node"
# Prints what is wrong and returns non-zero, so the negatives below can call it too.
check_monitoring_link() { # <chart dir> <monitoring dir> <empty scratch dir>
  local chart_dir="$1" mon="$2" scratch="$3" target
  [ -L "$chart_dir/files/monitoring" ] || { echo "files/monitoring is not a symlink"; return 1; }
  target="$(readlink "$chart_dir/files/monitoring")"
  [ "$target" = "$link_target" ] || { echo "files/monitoring -> $target, not $link_target"; return 1; }
  helm package "$chart_dir" --destination "$scratch" > "$scratch/helm.log" 2>&1 \
    || { cat "$scratch/helm.log"; echo "helm package failed"; return 1; }
  python3 - "$scratch" "$mon/decdn-node" <<'PY' 2>&1
import pathlib, sys, tarfile
scratch, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
tgz = sorted(scratch.glob("*.tgz"))
if len(tgz) != 1:
    sys.exit(f"helm package wrote {len(tgz)} archives")
prefix = "decdn-node/files/monitoring/"
with tarfile.open(tgz[0]) as t:
    members = t.getmembers()
mon = [m for m in members if m.name.startswith(prefix)]
bad = [m.name for m in mon if not m.isfile()]
if bad:
    sys.exit(f"not regular files in the package: {bad}")
want = sorted(p.name for p in src.iterdir() if p.suffix == ".json" or p.name == "prometheus-alerts.yml")
if not want:
    sys.exit(f"no dashboards or rules in {src}")
got = sorted(m.name[len(prefix):] for m in mon)
if got != want:
    sys.exit(f"packaged files/monitoring {got}\n  != dashboards and rules in monitoring/decdn-node {want}")
leak = [m.name for m in members if "sponsord" in m.name.lower() or "iroh-relay" in m.name.lower()]
if leak:
    sys.exit(f"sponsord or iroh-relay files in the chart package: {leak}")
if any(m.name == "decdn-node/artifacthub-repo.yml" for m in members):
    sys.exit("artifacthub-repo.yml is in the chart package (.helmignore it; release.yml pushes it on its own)")
PY
}
out="$(check_monitoring_link "$chart" "$monitoring" "$(mktemp -d "$work/pkg.XXXX")")" || fail "$out"
pass "files/monitoring links to monitoring/decdn-node and packages as regular files"

# Its negatives, on a repo-shaped copy (cp -R keeps the relative link a link).
neg="$work/neg"
mkdir -p "$neg/charts"
cp -R "$chart" "$neg/charts/"
cp -R "$monitoring" "$neg/"
negchart="$neg/charts/decdn-node"
out="$(check_monitoring_link "$negchart" "$neg/monitoring" "$(mktemp -d "$work/pkg.XXXX")")" \
  || fail "the unchanged copy fails the monitoring check: $out"
expect_link_fail() { # <description> <message ERE>
  local out
  if out="$(check_monitoring_link "$negchart" "$neg/monitoring" "$(mktemp -d "$work/pkg.XXXX")")"; then
    fail "monitoring check should have failed: $1"
  fi
  grep -qE -- "$2" <<<"$out" || { echo "$out" >&2; fail "wrong failure ($2) for: $1"; }
  pass "rejects: $1"
}
cp "$negchart/.helmignore" "$work/helmignore"
sed -i '/^artifacthub-repo\.yml$/d' "$negchart/.helmignore"
expect_link_fail "artifacthub-repo.yml packaged (not .helmignored)" "artifacthub-repo.yml is in the chart package"
cp "$work/helmignore" "$negchart/.helmignore"
rm "$negchart/files/monitoring"
cp -R "$neg/monitoring/decdn-node" "$negchart/files/monitoring"
expect_link_fail "files/monitoring a copy, not a symlink" "is not a symlink"
rm -r "$negchart/files/monitoring"
ln -s "$neg/monitoring/decdn-node" "$negchart/files/monitoring"
expect_link_fail "files/monitoring an absolute symlink" "not \.\./\.\./\.\./monitoring/decdn-node"
rm "$negchart/files/monitoring"
ln -s "$link_target" "$negchart/files/monitoring"
mv "$neg/monitoring/decdn-node" "$neg/monitoring/renamed"
expect_link_fail "monitoring/decdn-node renamed, link dangling" "helm package failed"
mv "$neg/monitoring/renamed" "$neg/monitoring/decdn-node"
touch "$neg/monitoring/decdn-node/README.md"
expect_link_fail "a stray file in monitoring/decdn-node" "!= dashboards and rules"
rm "$neg/monitoring/decdn-node/README.md"
cp "$neg/monitoring/sponsord/dashboard-sponsord.json" "$neg/monitoring/decdn-node/"
expect_link_fail "the sponsord dashboard copied into monitoring/decdn-node" "sponsord or iroh-relay files in the chart package"
rm "$neg/monitoring/decdn-node/dashboard-sponsord.json"
cp "$neg/monitoring/iroh-relay/dashboard-iroh-relay.json" "$neg/monitoring/decdn-node/"
expect_link_fail "the iroh-relay dashboard copied into monitoring/decdn-node" "sponsord or iroh-relay files in the chart package"

# --- positive renders -----------------------------------------------------------
for values in "$chart"/ci/*.yaml; do
  name="$(basename "$values" .yaml)"
  helm lint --strict --quiet "$chart" -f "$values" >/dev/null \
    || { helm lint --strict "$chart" -f "$values" >&2 || true; fail "helm lint ($name)"; }
  helm template t "$chart" -f "$values" > "$work/$name.yaml" || fail "helm template ($name)"
  # Filter on the key, not just the kind: the dashboard ConfigMaps would otherwise
  # contribute `null` documents here.
  yq 'select(.kind == "ConfigMap" and .data["node.toml"] != null) | .data["node.toml"]' \
    "$work/$name.yaml" > "$work/$name.toml"
  [ -s "$work/$name.toml" ] || fail "no node.toml in the rendered ConfigMap ($name)"
  python3 "$checker" "$work/$name.toml" >/dev/null 2>"$work/$name.err" \
    || { cat "$work/$name.err" >&2; fail "schema keys ($name)"; }
  if [ -n "$kubeconform" ]; then
    # Only the Prometheus Operator CRDs (ServiceMonitor, PrometheusRule) lack a
    # bundled schema; skip them by kind, so any other unrecognised resource (e.g. a
    # typo'd kind) still fails. Their shape is checked in the invariants below.
    $kubeconform -strict -summary -skip ServiceMonitor,PrometheusRule -kubernetes-version 1.30.0 \
      < "$work/$name.yaml" > "$work/$name.kc" 2>&1 \
      || { cat "$work/$name.kc" >&2; fail "kubeconform ($name)"; }
  fi
  pass "render + lint + schema keys${kubeconform:+ + kubeconform}: $name"
done
[ -n "$kubeconform" ] || skipped+=("kubeconform (KUBECONFORM is empty)")

# The image is the digest when set, else the tag, else appVersion (which `make
# test-scripts` holds equal to the decdn_node role's pin). Both containers run it.
app="$(yq '.appVersion' "$chart/Chart.yaml")"
digest="sha256:$(printf 'a%.0s' {1..64})"
image_of() { # <helm args...>: the StatefulSet's container and init container images, one per line
  helm template t "$chart" -f "$chart/ci/ci-values.yaml" "$@" \
    | yq 'select(.kind == "StatefulSet") | (.spec.template.spec.initContainers[].image, .spec.template.spec.containers[].image)'
}
for c in "unpinned|ghcr.io/decdn/decdn-node:$app|--set image.tag= --set image.digest=" \
         "tag|ghcr.io/decdn/decdn-node:9.9.9|--set image.tag=9.9.9 --set image.digest=" \
         "digest over tag|ghcr.io/decdn/decdn-node@$digest|--set image.tag=9.9.9 --set image.digest=$digest"; do
  IFS='|' read -r what want args <<<"$c"
  # shellcheck disable=SC2086  # helm args, split on purpose
  got="$(image_of $args)" || fail "helm template (image: $what)"
  [ "$(sort -u <<<"$got")" = "$want" ] || fail "image ($what) renders '$got', want '$want' in every container"
done
pass "image precedence: digest, then tag, then appVersion ($app), in every container"

toml="$work/ci-values.toml"

# The key check only proves emitted keys are legal. A table that silently vanished
# would pass it, so pin the widest render's table set exactly (same list as the
# molecule schema scenario).
tables="$(grep -oE '^\[+[a-z_0-9.]+' "$toml" | tr -d '[' | sort -u)" || fail "no tables in ci-values render"
expected="blockchain
cache
cache.circuit_breaker
cache.origin
cache.origin.credentials
cache.origin_retry
cache.serve_economics
cache.tinylfu
client
content
dht.rate_limit
identity
load_shed
network
network.discovery
network.discovery.peers.253bad481e6371866c9f6276b2a7b3a10ca16255668e740e6fc01da1cacc4350
observability
payment
probe.rate_limit
receipts
security"
[ "$tables" = "$expected" ] || { diff <(echo "$expected") <(echo "$tables") >&2 || true; fail "table set of ci-values render"; }
keys="$(grep -cE '^[a-z_0-9]+ = ' "$toml" || true)"
[ "$keys" -ge 125 ] || fail "only $keys scalar keys in ci-values render (expected >= 125)"
pass "breadth: $keys keys, $(echo "$tables" | grep -c '') tables"

for name in ci-values ci-origins ci-resolve-only; do
  f="$work/$name.toml"
  absent '^(rpc_url|[a-z_]*password|[a-z_]*secret|access_key_id|secret_access_key|session_token) =' "$f" \
    || fail "secret-bearing key in $name"
  # Integers stay integers (Helm decodes YAML numbers as float64), in arrays too.
  absent '(= |\[|, )-?[0-9]+\.0(\]|,|$)' "$f" || fail "whole number rendered as float in $name"
done
pass "no secret-bearing keys, no float-rendered integers"

# Pull-through derivation (ported from the role): origins => false, none => true.
grep -qx 'node_to_node_pull_through_enabled = false' "$work/ci-origins.toml" || fail "pull-through with origins should derive false"
grep -qx 'node_to_node_pull_through_enabled = true' "$work/ci-resolve-only.toml" || fail "pull-through without origin should derive true"
helm template t "$chart" -f "$chart/ci/ci-resolve-only.yaml" \
  --set config.cache.node_to_node_pull_through_enabled=false \
  | yq 'select(.kind == "ConfigMap" and .data["node.toml"] != null) | .data["node.toml"]' \
  | grep -qx 'node_to_node_pull_through_enabled = false' || fail "explicit pull-through=false should win"
pass "pull-through derivation"

# Resolve-only discovery: dns_origin alone must still produce the table.
grep -qx '\[network.discovery\]' "$work/ci-resolve-only.toml" || fail "resolve-only: no [network.discovery]"
grep -qx 'dns_origin = "resolve-only.example.invalid"' "$work/ci-resolve-only.toml" || fail "resolve-only: dns_origin"
absent pkarr_url "$work/ci-resolve-only.toml" || fail "resolve-only: pkarr_url leaked"
pass "resolve-only discovery"

# --- workload and exposure invariants, per render --------------------------------
# Explicit checks rather than `assert`, which PYTHONOPTIMIZE would turn into no-ops.
# The alert rules, checked raw rather than rendered: Helm's fromYaml keeps the last
# of a duplicated key (a second `expr:` silently replaces the real one), so only the
# file itself still shows it. promtool also catches PromQL and template syntax,
# which would otherwise make the operator drop the whole PrometheusRule.
if [ -n "$promtool" ]; then
  $promtool check rules < "$chart/files/monitoring/prometheus-alerts.yml" > "$work/promtool.out" 2>&1 \
    || { cat "$work/promtool.out" >&2; fail "promtool check rules (files/monitoring/prometheus-alerts.yml)"; }
  pass "promtool check rules: $(grep -o '[0-9]* rules found' "$work/promtool.out")"
  $promtool check rules < "$monitoring/sponsord/prometheus-alerts.yml" > "$work/promtool.out" 2>&1 \
    || { cat "$work/promtool.out" >&2; fail "promtool check rules (monitoring/sponsord/prometheus-alerts.yml)"; }
  pass "promtool check rules (sponsord): $(grep -o '[0-9]* rules found' "$work/promtool.out")"
  $promtool check rules < "$monitoring/iroh-relay/prometheus-alerts.yml" > "$work/promtool.out" 2>&1 \
    || { cat "$work/promtool.out" >&2; fail "promtool check rules (monitoring/iroh-relay/prometheus-alerts.yml)"; }
  pass "promtool check rules (iroh-relay): $(grep -o '[0-9]* rules found' "$work/promtool.out")"

  # The sponsord rules do time arithmetic on unix-time gauges, the iroh-relay
  # rules divide one counter's rate by another's, and every *Down rule has an
  # absence arm, which only a series that stops can exercise. Only a unit test
  # catches mistakes in those.
  # promtool compares annotations exactly and they are prose, so each test runs
  # against a copy with them stripped (monitoring/<service>/prometheus-alerts_test.yml).
  mkdir "$work/rules-test"
  for svc in decdn-node sponsord iroh-relay; do
    yq 'del(.groups[].rules[].annotations)' "$monitoring/$svc/prometheus-alerts.yml" \
      > "$work/rules-test/$svc-alerts.yml"
    cp "$monitoring/$svc/prometheus-alerts_test.yml" "$work/rules-test/$svc-alerts_test.yml"
  done
  chmod -R a+rX "$work/rules-test"
  for svc in decdn-node sponsord iroh-relay; do
    if [ -n "${PROMTOOL_IMAGE:-}" ]; then
      docker run --rm -v "$work/rules-test:/w:ro" -w /w --entrypoint promtool "$PROMTOOL_IMAGE" \
        test rules "$svc-alerts_test.yml" > "$work/promtool.out" 2>&1
    else
      (cd "$work/rules-test" && $promtool test rules "$svc-alerts_test.yml") > "$work/promtool.out" 2>&1
    fi || { cat "$work/promtool.out" >&2; fail "promtool test rules (monitoring/$svc/prometheus-alerts_test.yml)"; }
    pass "promtool test rules: $svc alerts"
  done
else
  skipped+=("promtool (PROMTOOL is empty): alert rule syntax and the decdn-node, sponsord and iroh-relay rule tests are NOT checked")
fi

# The sponsord and iroh-relay dashboards live outside the chart (monitoring/<service>/),
# so the chart never renders them (the monitoring-link check above keeps them out of
# the package). They must still parse and carry a uid no other dashboard uses:
# Grafana imports by uid.
python3 - "$monitoring" <<'PY' || fail "sponsord / iroh-relay dashboards"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
uids = [json.load(open(p)).get("uid") for p in sorted((root / "decdn-node").glob("*.json"))]
if not uids:
    sys.exit("no dashboard in monitoring/decdn-node/")
dash = []
for svc in ("sponsord", "iroh-relay"):
    found = sorted((root / svc).glob("*.json"))
    if not found:
        sys.exit(f"no dashboard in monitoring/{svc}/")
    dash += found
for p in dash:
    uid = json.load(open(p)).get("uid")
    if not (isinstance(uid, str) and 0 < len(uid) <= 40):
        sys.exit(f"{p.name}: uid {uid!r} is not a 1-40 character string")
    uids.append(uid)
if len(uids) != len(set(uids)):
    sys.exit(f"duplicate dashboard uids: {sorted(uids)}")
PY
pass "sponsord and iroh-relay dashboards parse with their own uids"

# iroh-relay's metric names are checked against what the pinned release exports
# (monitoring/iroh-relay/exported-metrics.txt, captured from the real binary): a
# typo would render "no data" or a rule that never fires. Every metric an expr
# selects (an identifier before `{`) is checked, whatever its prefix, and so is
# every series the rule tests feed in; only `up` comes from the scraper itself.
yq -o=json '.' "$monitoring/iroh-relay/prometheus-alerts.yml" > "$work/relay-alerts.json"
yq -o=json '.' "$monitoring/iroh-relay/prometheus-alerts_test.yml" > "$work/relay-alerts-test.json"
python3 - "$monitoring/iroh-relay" "$work/relay-alerts.json" "$work/relay-alerts-test.json" <<'PY' \
  || fail "iroh-relay metric names"
import json, pathlib, re, sys
d = pathlib.Path(sys.argv[1])
have = set(re.findall(r"^([a-z_]+)\s", (d / "exported-metrics.txt").read_text(), re.M)) | {"up"}
if not any(n.startswith("relayserver_") for n in have):
    sys.exit("exported-metrics.txt lists no relayserver_* series")
def strings(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key and isinstance(v, str):
                yield v
            else:
                yield from strings(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v, key)
metric = re.compile(r"([A-Za-z_:][A-Za-z0-9_:]*)\s*\{")
sources = [(p.name, json.load(open(p)), "expr") for p in sorted(d.glob("*.json"))]
sources += [("prometheus-alerts.yml", json.load(open(sys.argv[2])), "expr"),
            ("prometheus-alerts_test.yml", json.load(open(sys.argv[3])), "series")]
seen = 0
for name, doc, key in sources:
    for expr in strings(doc, key):
        for m in metric.findall(expr):
            seen += 1
            if m not in have:
                sys.exit(f"{name}: {m} is not exported by the pinned iroh-relay (in {expr!r})")
if not seen:
    sys.exit("no metric selector found in monitoring/iroh-relay/ (the check would be vacuous)")
PY
pass "iroh-relay dashboard and rules name only exported series"

# The monitoring files the ci-values render must carry in full.
yq -o=json '.' "$chart/files/monitoring/prometheus-alerts.yml" > "$work/alerts.json"
for name in ci-values ci-origins ci-resolve-only; do
  yq ea -o=json '[.]' "$work/$name.yaml" > "$work/$name.json"
  python3 - "$work/$name.json" "$work/$name.toml" "$chart/ci/$name.yaml" \
    "$work/alerts.json" "$chart/files/monitoring" <<'PY' || fail "workload/exposure invariants ($name)"
import json, sys, tomllib
docs = [d for d in json.load(open(sys.argv[1])) if d]
cfg = tomllib.load(open(sys.argv[2], "rb"))
name = sys.argv[3].rsplit("/", 1)[-1]
errors = []
def check(cond, msg):
    if not cond:
        errors.append(msg)
def one(kind, component=None):
    found = [d for d in docs if d["kind"] == kind
             and (component is None or d["metadata"]["labels"].get("app.kubernetes.io/component") == component)]
    check(len(found) <= 1, f"more than one {kind}/{component}")
    return found[0] if found else None

sts = one("StatefulSet")
spec = sts["spec"]; pod = spec["template"]["spec"]
main = pod["containers"][0]; init = pod["initContainers"][0]
ports = {p["name"]: p for p in main["ports"]}
quic_port, metrics_port = cfg["network"]["bind_port"], cfg["observability"]["metrics_port"]

check(spec["replicas"] == 1, "replicas != 1")
check(pod["automountServiceAccountToken"] is False, "SA token automounted")
check(pod["terminationGracePeriodSeconds"] >= 300, "drain window < 300s")
check(pod["securityContext"]["runAsNonRoot"] is True, "runAsNonRoot")
for ctr in pod["containers"] + pod["initContainers"]:
    sc = ctr["securityContext"]
    check(sc["readOnlyRootFilesystem"] is True and sc["allowPrivilegeEscalation"] is False, f"{ctr['name']} securityContext")
    check(sc["capabilities"]["drop"] == ["ALL"], f"{ctr['name']} caps")

# Secrets: no envFrom, env limited to the RPC URL + declared passthrough keys, the
# key Secret never in the daemon, the password never on the PVC.
check("envFrom" not in main, "envFrom present: DECDN_* in the Secret would override node.toml")
env_names = [e["name"] for e in main.get("env", [])]
check(env_names[0] == "DECDN_RPC_URL", "DECDN_RPC_URL not injected")
check(not any(n.startswith("DECDN_") for n in env_names[1:]), "extra DECDN_* env injected")
check(not any(m["name"] == "keys" for m in main["volumeMounts"]), "key Secret mounted in daemon")
pwfile = main["args"][main["args"].index("--keystore-password-file") + 1]
check(pwfile.startswith("/run/decdn/"), f"password file {pwfile} not on the in-memory volume")
vols = {v["name"]: v for v in pod["volumes"]}
check(vols["run-secrets"]["emptyDir"].get("medium") == "Memory", "run-secrets not in memory")
check("keystore.password\" \"$DATA_DIR" not in init["args"][0] and "$SECRETS_DIR/keystore.password" in init["args"][0],
      "init installs the password onto the PVC")
check(cfg["blockchain"]["eth_keystore"] == cfg["identity"]["data_dir"] + "/keystore.json", "eth_keystore path")

# Ports agree across node.toml, the pod, the Services and the NetworkPolicy.
check(cfg["observability"]["metrics_bind"] == "0.0.0.0", "metrics_bind")
check(ports["quic"]["containerPort"] == quic_port and ports["quic"]["protocol"] == "UDP", "quic containerPort")
check(ports["metrics"]["containerPort"] == metrics_port, "metrics containerPort")
for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
    check(main[probe]["httpGet"]["port"] == "metrics", f"{probe} port")

msvc = one("Service", "metrics")
check(msvc["spec"]["type"] == "ClusterIP", "metrics Service not ClusterIP")
check([(p["port"], p["protocol"]) for p in msvc["spec"]["ports"]] == [(metrics_port, "TCP")], "metrics Service ports")
qsvc = one("Service", "quic")
if qsvc:
    check([(p["port"], p["protocol"], p["targetPort"]) for p in qsvc["spec"]["ports"]] == [(quic_port, "UDP", "quic")],
          "public Service must carry only UDP quic")

np = one("NetworkPolicy")
if name == "ci-resolve-only.yaml":
    check(np is None, "NetworkPolicy rendered although disabled")
else:
    ingress = np["spec"]["ingress"]
    check(ingress[0] == {"ports": [{"protocol": "UDP", "port": quic_port}]}, "QUIC ingress rule")
    tcp_rules = [r for r in ingress if any(p["protocol"] == "TCP" for p in r["ports"])]
    for r in tcp_rules:
        check(r.get("from"), "metrics ingress rule without `from` admits everyone")
        check(r["ports"] == [{"protocol": "TCP", "port": metrics_port}], "metrics ingress port")
    check(len(ingress) == 1 + len(tcp_rules), "unexpected ingress rules")
    check(("Egress" in np["spec"]["policyTypes"]) == bool(np["spec"].get("egress")), "Egress policyType vs rules")

if name == "ci-values.yaml":
    check("hostPort" not in ports["quic"], "hostPort open by default")
    check(len(tcp_rules) == 1, "metrics rule missing although metrics.networkPolicy.from is set")
    check(one("ServiceMonitor") is not None, "ServiceMonitor missing")
    # Target labels the dashboards/alerts select on.
    relabel = {r.get("targetLabel"): r for r in one("ServiceMonitor")["spec"]["endpoints"][0].get("relabelings", [])}
    check(relabel.get("job", {}).get("replacement") == "decdn-node", "ServiceMonitor job relabel")
    check(relabel.get("region", {}).get("replacement") == cfg["identity"]["region"], "ServiceMonitor region relabel")
    check(relabel.get("deployment_environment", {}).get("replacement") == "ci", "ServiceMonitor deployment_environment relabel")
    check(relabel.get("instance", {}).get("sourceLabels") == ["__meta_kubernetes_pod_name"], "ServiceMonitor instance relabel")
    # PrometheusRule: every shipped rule, extras merged in, the rule's own labels kept.
    shipped = [r for g in json.load(open(sys.argv[4]))["groups"] for r in g["rules"]]
    pr = one("PrometheusRule", "alerts")
    check(pr is not None, "PrometheusRule missing")
    if pr:
        rules = [r for g in pr["spec"]["groups"] for r in g["rules"]]
        check(len(rules) == len(shipped) > 0, f"PrometheusRule has {len(rules)} rules, files/monitoring has {len(shipped)}")
        # sponsord has no Kubernetes path: its rules must never reach the node's.
        check(not [r for r in rules if r["alert"].startswith("Sponsord")], "sponsord rules in the PrometheusRule")
        check(all(r["labels"].get("team") == "node-ops" for r in rules), "ruleLabels not merged into every rule")
        # ci-values sets ruleLabels.severity: a rule's own severity must win, and
        # only a rule without one may take the extra.
        check([r["labels"].get("severity") for r in rules]
              == [r.get("labels", {}).get("severity", "overridden") for r in shipped],
              "ruleLabels overrode a rule's own labels")
    # One sidecar-labelled ConfigMap per shipped dashboard, each valid JSON with its
    # own uid: the sidecar provisions by uid, so a shared one silently drops a
    # dashboard. Grafana caps uids at 40 characters.
    import pathlib
    want = sorted(p.name for p in pathlib.Path(sys.argv[5]).glob("*.json"))
    check(want, "no dashboards in files/monitoring/")
    cms = [d for d in docs if d["kind"] == "ConfigMap"
           and d["metadata"]["labels"].get("app.kubernetes.io/component") == "dashboard"]
    check(sorted(k for d in cms for k in d["data"]) == want, "dashboard ConfigMaps vs files/monitoring")
    uids = []
    for d in cms:
        check(d["metadata"]["labels"].get("grafana_dashboard") == "1", "dashboard sidecar label")
        for k, v in d["data"].items():
            uid = json.loads(v).get("uid")
            if isinstance(uid, str) and 0 < len(uid) <= 40:
                uids.append(uid)
            else:
                check(False, f"{k}: uid {uid!r} is not a 1-40 character string")
    check(len(uids) == len(set(uids)), f"duplicate dashboard uids: {sorted(uids)}")
else:
    check(not [d for d in docs if d["kind"] == "PrometheusRule"], "PrometheusRule rendered while disabled")
    check(not [d for d in docs if d["kind"] == "ConfigMap"
               and d["metadata"]["labels"].get("app.kubernetes.io/component") == "dashboard"],
          "dashboard ConfigMaps rendered while disabled")
if name == "ci-origins.yaml":
    check(ports["quic"].get("hostPort") == 5000, "hostPort")
    check(qsvc["spec"]["ports"][0].get("nodePort") == 30443, "nodePort")
    check(len(tcp_rules) == 0, "metrics ingress rule rendered with empty from")
    check([o["kind"] for o in cfg["cache"]["origins"]] == ["http", "fs", "s3"], "origins count/order")
    check(cfg["cache"]["origins"][2]["credentials"]["profile"] == "mirror", "nested credentials under the wrong origin")
    check(env_names == ["DECDN_RPC_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"], "passthrough env")
    check(main["env"][0]["valueFrom"]["secretKeyRef"]["key"] == "rpc", "rpcUrlKey")
    check([i["key"] for i in vols["keys"]["secret"]["items"]] == ["ks", "ns", "pw"], "custom key names")
    check(pod["serviceAccountName"] == "decdn-sa" and one("ServiceAccount") is None, "external ServiceAccount")

if errors:
    print("\n".join(f"  {e}" for e in errors), file=sys.stderr)
    sys.exit(1)
PY
  pass "workload + exposure invariants: $name"
done

# --- negative renders: each must FAIL, with a message naming the problem ----------
base="$chart/ci/ci-resolve-only.yaml"
schema_err="values don't meet the specifications"
tmpl_err="execution error at"
expect_fail() { # <description> <layer: schema|template> <message ERE> <helm args...>
  local desc="$1" layer="$2" msg="$3"; shift 3
  local out marker
  if out="$(helm template t "$chart" -f "$base" "$@" 2>&1)"; then
    fail "render should have failed: $desc"
  fi
  if [ "$layer" = schema ]; then marker="$schema_err"; else marker="$tmpl_err"; fi
  if ! grep -qF -- "$marker" <<<"$out" || ! grep -qE -- "$msg" <<<"$out"; then
    echo "$out" >&2
    fail "wrong failure ($layer: $msg) for: $desc"
  fi
  pass "rejects: $desc"
}
expect_fail "missing keystore Secret"      template 'secrets.keystore.existingSecret is required' --set secrets.keystore.existingSecret=
expect_fail "missing env Secret"           template 'secrets.env.existingSecret is required'      --set secrets.env.existingSecret=
expect_fail "DECDN_* passthrough key"      template 'passthroughKeys: DECDN_BIND_PORT is refused'  --set 'secrets.env.passthroughKeys[0]=DECDN_BIND_PORT'
# A --set null is dropped by some Helm versions (missing property) and kept by others
# (got null); both are correct rejections.
expect_fail "missing required address"     schema   "missing propert(y|ies) 'slash_judge_address'|/config/blockchain/slash_judge_address': got null" --set config.blockchain.slash_judge_address=null
expect_fail "malformed address"            schema   "/config/blockchain/slash_judge_address"      --set config.blockchain.slash_judge_address=0x12
expect_fail "zero address"                 schema   "/config/blockchain/payment_pool_address.*'not' failed|payment_pool_address.*not" --set config.blockchain.payment_pool_address=0x0000000000000000000000000000000000000000
expect_fail "lowercase region"             schema   "/config/identity/region.*does not match"    --set config.identity.region=de
expect_fail "missing chain_id"             schema   "missing propert(y|ies) 'chain_id'|/config/blockchain/chain_id': got null" --set config.blockchain.chain_id=null
expect_fail "empty origins list"           schema   "/config/cache/origins"                      --set-json 'config.cache.origins=[]'
expect_fail "managed metrics_port"         template 'observability.metrics_port is managed'      --set config.observability.metrics_port=9999
expect_fail "managed metrics_bind"         template 'observability.metrics_bind is managed'      --set config.observability.metrics_bind=127.0.0.1
expect_fail "managed bind_port"            template 'network.bind_port is managed'               --set config.network.bind_port=4000
expect_fail "managed data_dir"             template 'identity.data_dir is managed'               --set config.identity.data_dir=/data
expect_fail "managed eth_keystore"         template 'blockchain.eth_keystore is managed'         --set config.blockchain.eth_keystore=/k.json
expect_fail "managed cache_dir"            template 'cache.cache_dir is managed'                 --set config.cache.cache_dir=/c
expect_fail "non-table section"            template 'config.network must be a table'             --set config.network=foo
expect_fail "rpc_url in config"            template 'config.blockchain.rpc_url: secret-bearing'  --set config.blockchain.rpc_url=https://x.invalid
expect_fail "rpc-url (dashed) in config"   template 'config.blockchain.rpc-url: secret-bearing'  --set config.blockchain.rpc-url=https://x.invalid
expect_fail "secret key in origins list"   template 'secret_access_key: secret-bearing'          --set-json 'config.cache.origins=[{"kind":"s3","bucket":"b","credentials":{"secret_access_key":"x"}}]'
expect_fail "password key in config"       template 'aws_password: secret-bearing'               --set config.cache.origin.credentials.aws_password=x --set config.cache.origin.kind=s3
expect_fail "replicas knob"                schema   "additional propert(y|ies) 'replicas'"       --set replicas=2
expect_fail "bad service type"             schema   '/service/type'                              --set service.type=ExternalName
expect_fail "origin + origins"             template 'mutually exclusive'                         --set config.cache.origin.kind=fs --set config.cache.origin.path=/o --set 'config.cache.origins[0].kind=fs'
expect_fail "max_blob > cache_size"        template 'max_blob_size_mb must be <='                --set config.cache.max_blob_size_mb=20000
expect_fail "integer beyond 2^53"          template 'too large to render exactly'                --set-json 'config.payment.credit_max=18446744073709551615'
expect_fail "null inside a list element"   template 'null inside a list element'                 --set-json 'config.cache.origins=[{"kind":"fs","path":null}]'
expect_fail "policy off, not acknowledged" template 'allowUnrestrictedMetrics'                   --set networkPolicy.allowUnrestrictedMetrics=false
expect_fail "podLabels overrides selector" template 'podLabels.app.kubernetes.io/instance is set by the chart' --set-json 'podLabels={"app.kubernetes.io/instance":"x"}'
expect_fail "podAnnotations checksum"      template 'podAnnotations.checksum/config is set by the chart' --set-json 'podAnnotations={"checksum/config":"pinned"}'
expect_fail "runAsNonRoot false"           template 'runAsNonRoot must be true'                  --set podSecurityContext.runAsNonRoot=false
expect_fail "runAsNonRoot removed"         template 'runAsNonRoot must be true'                  --set podSecurityContext.runAsNonRoot=null
expect_fail "runAsUser 0"                  template 'runAsUser must not be 0'                    --set podSecurityContext.runAsUser=0
expect_fail "container runAsUser 0"        template 'must not run as root'                       --set securityContext.runAsUser=0
expect_fail "seccomp Unconfined"           template 'must not be Unconfined'                     --set podSecurityContext.seccompProfile.type=Unconfined
expect_fail "privilege escalation"         template 'allowPrivilegeEscalation must be false'     --set securityContext.allowPrivilegeEscalation=true
expect_fail "privileged"                   template 'privileged must not be true'                --set securityContext.privileged=true
expect_fail "writable root filesystem"     template 'readOnlyRootFilesystem must be true'        --set securityContext.readOnlyRootFilesystem=false
expect_fail "capabilities added"           template 'capabilities.add must be empty'             --set 'securityContext.capabilities.add[0]=NET_ADMIN'
expect_fail "capabilities not dropped"     template 'capabilities.drop must include ALL'         --set-json 'securityContext.capabilities.drop=["NET_RAW"]'
expect_fail "ServiceMonitor, policy blocks" template 'metrics.networkPolicy.from'                --set metrics.serviceMonitor.enabled=true --set networkPolicy.enabled=true
expect_fail "non-string rule label"        schema   '/metrics/prometheusRule/ruleLabels'         --set-json 'metrics.prometheusRule.ruleLabels={"team":1}'
expect_fail "invalid dashboard label key"  schema   '/metrics/grafanaDashboards/label'           --set 'metrics.grafanaDashboards.label=not a label'
expect_fail "unknown monitoring knob"      schema   "additional propert(y|ies) 'rules'"          --set metrics.prometheusRule.rules=x

# Long release names: every rendered object keeps a unique name. The dashboard
# ConfigMaps used to truncate to 63 characters and collide.
long="$(printf 'n%.0s' $(seq 1 63))"
helm template t "$chart" -f "$chart/ci/ci-values.yaml" --set fullnameOverride="$long" \
  | yq -N '.kind + "/" + .metadata.name' | grep -v '^null' | sort | uniq -d > "$work/dupes"
[ ! -s "$work/dupes" ] || { cat "$work/dupes" >&2; fail "duplicate object names with a 63-character fullname"; }
pass "unique object names with a 63-character fullname"

# Dashboards enabled with none in files/monitoring/ must fail the render, not render nothing.
nodash="$work/nodash"
# -L: files/monitoring is a relative symlink; copied as a link it would dangle in
# $work, the rm would remove nothing and the render would fail for the wrong reason.
cp -RL "$chart" "$nodash"
if [ -L "$nodash/files/monitoring" ] || [ ! -d "$nodash/files/monitoring" ]; then
  fail "the scratch chart copy kept files/monitoring as a symlink"
fi
rm -f "$nodash"/files/monitoring/*.json
if out="$(helm template t "$nodash" -f "$chart/ci/ci-values.yaml" 2>&1)"; then
  fail "render should fail: dashboards enabled, none shipped"
fi
grep -q 'holds no \*.json dashboards' <<<"$out" || { echo "$out" >&2; fail "wrong failure for missing dashboards"; }
pass "rejects: dashboards enabled, none shipped"

# --- optional: the real binary --------------------------------------------------
if [ -n "${DECDN_CLI:-}" ]; then
  data="$work/data"; mkdir -m 0700 "$data"
  printf 'render-test-password\n' > "$work/pw"; chmod 0600 "$work/pw"
  "$DECDN_CLI" key-gen --output-dir "$data" --keystore-password-file "$work/pw" >/dev/null
  for values in "$chart"/ci/*.yaml; do
    name="$(basename "$values" .yaml)"
    sed "s#/var/lib/decdn/node#$data#g" "$work/$name.toml" > "$work/$name.local.toml"
    DECDN_RPC_URL=https://rpc.example.invalid/ "$DECDN_CLI" config validate \
      --config "$work/$name.local.toml" --keystore-password-file "$work/pw" >"$work/$name.validate" 2>&1 \
      || { cat "$work/$name.validate" >&2; fail "decdn config validate ($name)"; }
    pass "decdn config validate: $name"
  done
else
  skipped+=("decdn config validate (DECDN_CLI unset): value types are NOT checked")
fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
echo "all chart render tests passed"
