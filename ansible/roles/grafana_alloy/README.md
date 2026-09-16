# grafana_alloy

Opt-in Grafana Cloud Application Observability for an Ansible-deployed deCDN
node ([decdn/devops#55](https://github.com/decdn/devops/issues/55)): a dedicated,
loopback-only [Grafana Alloy](https://grafana.com/docs/alloy/) agent that

- scrapes the node's `/metrics` (Prometheus exposition on loopback port 9090)
  and pushes it to your Grafana Cloud Prometheus, stamped with low-cardinality
  identity labels, and
- receives the daemon's OTLP span exports (`otlp_endpoint`) on gRPC `127.0.0.1:4317`
  and HTTP `127.0.0.1:4318`, probabilistically samples traces (default keep-ratio 0.25),
  batches them, and exports via OTLP/HTTP to your Grafana Cloud org.

The Helm-chart path is separate and deliberately untouched by this role.

## Opt in

Set ONE variable — mirrored into both roles, so it must be overridden at group or
host level only:

```yaml
# e.g. inventory/group_vars/<group>.yml or host_vars/<host>.yml
decdn_grafana_cloud_enabled: true
```

Then provision credentials **on the target host** (they never transit the control
machine):

```bash
umask 077
sudo install -m 600 -o root -g root grafana-alloy.env /etc/decdn/grafana-alloy.env
```

using `roles/grafana_alloy/files/grafana-alloy.env.example` as the template. The
four required keys are `GC_PROM_REMOTE_WRITE_URL`, `GC_OTLP_ENDPOINT`,
`GC_PROM_USERNAME` and `GC_API_TOKEN`; both URLs must be `https://`.
`config.alloy` reads each of them at load time with `sys.env("GC_…")` — Alloy has
**no** `--config.expand-env` flag, so a `${GC_…}` placeholder would be a literal
string, not an expansion. The file on disk stays free of secret literals, and the
role only ever greps shapes on the host rather than reading values back.

With the flag off, the role removes the unit, rendered config, state directory
and service account **it installed** — identified by the managed-by marker in
`/etc/systemd/system/alloy.service`. An Alloy installed by anything else (the
upstream apt repo, another role, by hand) carries no marker and is left strictly
alone, which matters because the flag is `false` by default on every host.
Binary/package removal is manual.

## Variables

All prefixed `grafana_alloy_*` (see `defaults/main.yml` for comments and pinned
upstream version/sha256). Highlights:

| Variable | Default | Notes |
| --- | --- | --- |
| `decdn_grafana_cloud_enabled` | `false` | THE opt-in switch (mirrored in `decdn_node`) |
| `grafana_alloy_install_method` | `release` | `manual` copies a control-machine binary (CI stubs) |
| `grafana_alloy_version` / `grafana_alloy_sha256` | pin | Bump together from upstream release digests |
| `grafana_alloy_trace_sampling_ratio` | `0.25` | Trace keep-ratio, validated to `[0,1]` |
| `grafana_alloy_otlp_grpc_port` | `4317` | Hard-coupled to the literal emitted into node.toml |
| `grafana_alloy_region` | `decdn_region` | Required identity attribute; derived from the node region |

Label variables (`service_name`, `service_namespace`, `instance_id`,
`deployment_environment`, `region`) ship on EVERY series/span/log line — keep
them low-cardinality; unique label sets are what your Grafana Cloud bill scales
with. Guardrails: one scrape interval per fleet (`30s`), sampling above zero for
spans, and no per-request/per-hash label values.

## Couplings & guards

Two couplings between roles are pinned by constants plus molecule assertions:

1. This role's `prometheus.scrape` targets `127.0.0.1:<decdn_metrics_port>`, using
   the node role's configured metrics port directly.
2. `decdn_node` injects `otlp_endpoint = "http://127.0.0.1:4317"` when the flag
   flips on — the port constant here.

If you move either default, update BOTH sides and the molecule guard in
`ansible/molecule/grafana-cloud/`.

## Testing

Three layers, because the first one cannot prove correctness on its own:

1. **`grafana-cloud` molecule scenario** — the role end-to-end against a *stub*
   binary (plumbing, rendered content, hardened unit, teardown scope), plus
   negative preflight cases in `validation` and disabled-path assertions in
   `default`. The stub exits 0 for every subcommand, so a green run says nothing
   about whether Alloy can load the config.
2. **`make lint-alloy`** (CI job `alloy-config`) — renders these templates in
   several variable combinations and feeds them to the REAL pinned Alloy binary:
   `alloy validate` (component graph, not just syntax) and a check that every
   `ExecStart` flag exists in `alloy run --help`. See
   `ansible/tests/alloy-config/`.
3. **Deploy time** — the role runs `alloy validate` against the just-rendered
   file with the installed binary before any restart.

Re-run `make lint-alloy` whenever `grafana_alloy_version` is bumped: the harness
downloads the same digest-pinned `.deb` the role installs, so a version bumped
without its sha256 fails there rather than on a host.
