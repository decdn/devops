#!/usr/bin/env bash
# Render tests for the decdn-node chart. Run via `make lint-helm` from the repo root.
#
#   charts/decdn-node/tests/render-test.sh
#
# Needs: helm, yq (mikefarah v4), python3 >= 3.11 (tomllib), and kubeconform on
# PATH unless KUBECONFORM is overridden.
# Optional env:
#   KUBECONFORM   command to run kubeconform (default: `kubeconform`; the Makefile
#                 passes a digest-pinned container). Set to "" to skip, loudly.
#   DECDN_CLI     path to a real `decdn` binary: also run `decdn config validate`
#                 on every positive render (catches value/type errors the key check
#                 can't). Skipped, loudly, when unset.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chart="$(dirname "$here")"
repo="$(cd "$chart/../.." && pwd)"
schema_files="$repo/ansible/molecule/schema/files"
checker="$schema_files/check-schema-keys.py"
kubeconform="${KUBECONFORM-kubeconform}"
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

# --- positive renders -----------------------------------------------------------
for values in "$chart"/ci/*.yaml; do
  name="$(basename "$values" .yaml)"
  helm lint --strict --quiet "$chart" -f "$values" >/dev/null \
    || { helm lint --strict "$chart" -f "$values" >&2 || true; fail "helm lint ($name)"; }
  helm template t "$chart" -f "$values" > "$work/$name.yaml" || fail "helm template ($name)"
  yq 'select(.kind == "ConfigMap") | .data["node.toml"]' "$work/$name.yaml" > "$work/$name.toml"
  [ -s "$work/$name.toml" ] || fail "no node.toml in the rendered ConfigMap ($name)"
  python3 "$checker" "$work/$name.toml" >/dev/null 2>"$work/$name.err" \
    || { cat "$work/$name.err" >&2; fail "schema keys ($name)"; }
  if [ -n "$kubeconform" ]; then
    # Only the ServiceMonitor CRD lacks a bundled schema; skip it by kind, so any
    # other unrecognised resource (e.g. a typo'd kind) still fails.
    $kubeconform -strict -summary -skip ServiceMonitor -kubernetes-version 1.30.0 \
      < "$work/$name.yaml" > "$work/$name.kc" 2>&1 \
      || { cat "$work/$name.kc" >&2; fail "kubeconform ($name)"; }
  fi
  pass "render + lint + schema keys${kubeconform:+ + kubeconform}: $name"
done
[ -n "$kubeconform" ] || skipped+=("kubeconform (KUBECONFORM is empty)")

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
  | yq 'select(.kind == "ConfigMap") | .data["node.toml"]' \
  | grep -qx 'node_to_node_pull_through_enabled = false' || fail "explicit pull-through=false should win"
pass "pull-through derivation"

# Resolve-only discovery: dns_origin alone must still produce the table.
grep -qx '\[network.discovery\]' "$work/ci-resolve-only.toml" || fail "resolve-only: no [network.discovery]"
grep -qx 'dns_origin = "resolve-only.example.invalid"' "$work/ci-resolve-only.toml" || fail "resolve-only: dns_origin"
absent pkarr_url "$work/ci-resolve-only.toml" || fail "resolve-only: pkarr_url leaked"
pass "resolve-only discovery"

# --- workload and exposure invariants, per render --------------------------------
# Explicit checks rather than `assert`, which PYTHONOPTIMIZE would turn into no-ops.
for name in ci-values ci-origins ci-resolve-only; do
  yq ea -o=json '[.]' "$work/$name.yaml" > "$work/$name.json"
  python3 - "$work/$name.json" "$work/$name.toml" "$chart/ci/$name.yaml" <<'PY' || fail "workload/exposure invariants ($name)"
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
expect_fail "missing required address"     schema   "missing propert(y|ies) 'slash_judge_address'" --set config.blockchain.slash_judge_address=null
expect_fail "malformed address"            schema   "/config/blockchain/slash_judge_address"      --set config.blockchain.slash_judge_address=0x12
expect_fail "zero address"                 schema   "/config/blockchain/payment_pool_address.*'not' failed|payment_pool_address.*not" --set config.blockchain.payment_pool_address=0x0000000000000000000000000000000000000000
expect_fail "lowercase region"             schema   "/config/identity/region.*does not match"    --set config.identity.region=de
expect_fail "missing chain_id"             schema   "missing propert(y|ies) 'chain_id'"          --set config.blockchain.chain_id=null
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
expect_fail "unpinned image"               template 'published no release image'                 --set image.digest= --set image.tag=
expect_fail "bad service type"             schema   '/service/type'                              --set service.type=ExternalName
expect_fail "origin + origins"             template 'mutually exclusive'                         --set config.cache.origin.kind=fs --set config.cache.origin.path=/o --set 'config.cache.origins[0].kind=fs'
expect_fail "max_blob > cache_size"        template 'max_blob_size_mb must be <='                --set config.cache.max_blob_size_mb=20000
expect_fail "integer beyond 2^53"          template 'too large to render exactly'                --set-json 'config.payment.credit_max=18446744073709551615'
expect_fail "null inside a list element"   template 'null inside a list element'                 --set-json 'config.cache.origins=[{"kind":"fs","path":null}]'
expect_fail "policy off, not acknowledged" template 'allowUnrestrictedMetrics'                   --set networkPolicy.allowUnrestrictedMetrics=false
expect_fail "ServiceMonitor, policy blocks" template 'metrics.networkPolicy.from'                --set metrics.serviceMonitor.enabled=true --set networkPolicy.enabled=true

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
